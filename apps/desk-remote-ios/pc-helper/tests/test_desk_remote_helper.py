"""Unit tests for the read-only helper. Run from pc-helper/:  python -m unittest discover -s tests -v

Everything runs on hand-written fixtures (../fixtures/fake-helper); no real conversation is read.
"""
import ipaddress
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import desk_remote_helper as h  # noqa: E402

FIXTURES = HERE.parent.parent / 'fixtures' / 'fake-helper'
A = 'local_11111111-1111-4111-8111-111111111111'
B = 'local_22222222-2222-4222-8222-222222222222'
X = '0a000000-0000-4000-8000-000000000001'
Y = '0a000000-0000-4000-8000-000000000002'
TOKEN = json.loads((FIXTURES / 'fake-config.json').read_text(encoding='utf-8'))['token']


def drain(transcript):
    transcript.refresh()
    return transcript.page(0, '')['events']


class ConfigTests(unittest.TestCase):
    def write(self, **cfg):
        base = {'bind_ip': '10.1.2.3', 'port': 1, 'allowed_networks': ['10.1.0.0/16'], 'token': 'x' * 32}
        base.update(cfg)
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder)
        path = folder / 'config.json'
        path.write_text(json.dumps(base), encoding='utf-8')
        return path

    def test_accepts_specific_address_inside_network(self):
        cfg, networks = h.load_config(self.write())
        self.assertEqual(cfg['bind_ip'], '10.1.2.3')
        self.assertEqual(networks, [ipaddress.ip_network('10.1.0.0/16')])

    def test_rejects_any_address_outside_address_and_short_token(self):
        for bad in ({'bind_ip': '0.0.0.0'}, {'bind_ip': '192.168.1.5'}, {'token': 'short'}):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                h.load_config(self.write(**bad))


class AuthGateTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.sent = []
        self.gate = h.AuthGate('right-token-' + 'x' * 24, lambda *a: self.sent.append(a), 'PC',
                               clock=lambda: self.now)

    def test_right_token_passes_and_wrong_is_401(self):
        self.assertIsNone(self.gate.check('Bearer right-token-' + 'x' * 24))
        self.assertEqual(self.gate.check('Bearer nope')[0], 401)
        self.assertEqual(self.gate.check(None)[0], 401)
        self.assertEqual(self.gate.check('Basic right-token-' + 'x' * 24)[0], 401)

    def test_five_wrong_tokens_lock_everything_for_ten_minutes(self):
        codes = [self.gate.check('Bearer wrong')[0] for _ in range(5)]
        self.assertEqual(codes, [401, 401, 401, 401, 429])
        self.assertEqual(self.gate.check('Bearer right-token-' + 'x' * 24)[0], 429)
        time.sleep(0.2)  # the lock notification is sent on its own thread
        self.assertEqual(len(self.sent), 1)
        self.now += 601
        self.assertIsNone(self.gate.check('Bearer right-token-' + 'x' * 24))

    def test_old_failures_expire(self):
        for _ in range(4):
            self.gate.check('Bearer wrong')
        self.now += 601
        self.assertEqual(self.gate.check('Bearer wrong')[0], 401)


class FakeEnvironment(unittest.TestCase):
    def setUp(self):
        self.fake = h.FakeSetup(FIXTURES)
        self.addCleanup(shutil.rmtree, self.fake.root, True)
        self.sources = self.fake.sources()


class ClaudeTests(FakeEnvironment):
    def test_list_is_newest_first_without_archived_and_reports_bad_files(self):
        rows = self.sources['claude'].list_sessions(50)
        self.assertEqual([r['title'] for r in rows], ['整理專案 README', '修正建置錯誤', '週報草稿'])
        self.assertEqual(self.sources['claude'].warning, 'Claude 對話清單有 1 個檔案無法解析')
        first = rows[0]
        self.assertEqual(first['id'], A)
        self.assertEqual(first['folder'], 'demo-app')  # never the full path
        self.assertEqual(first['status'], 'active')
        self.assertEqual(first['permission'], '自動')
        self.assertEqual(rows[1]['status'], 'needs-action')
        self.assertEqual(rows[2]['status'], 'idle')
        self.assertTrue(all(r['updatedAt'].endswith('Z') for r in rows))

    def test_transcript_events_skip_noise_thinking_and_subagents(self):
        path = self.sources['claude'].transcript_path(A)
        events = drain(h.Transcript(path, h.ClaudeParser))
        self.assertEqual([(e['kind'], e.get('tool', '')) for e in events], [
            ('user', ''), ('assistant', ''), ('tool_call', 'Read'), ('tool_result', 'Read'),
            ('tool_call', 'Bash'), ('tool_result', 'Bash'), ('assistant', '')])
        self.assertEqual(events[2]['text'], 'C:\\work\\demo-app\\README.md')
        self.assertEqual(events[4]['text'], 'git status --short')
        self.assertTrue(events[3]['truncated'])
        self.assertEqual(len(events[3]['text']), h.TEXT_LIMITS['tool_result'])
        joined = ' '.join(e['text'] for e in events)
        self.assertNotIn('system-reminder', joined)
        self.assertNotIn('subagent', joined)

    def test_error_results_are_marked(self):
        events = drain(h.Transcript(self.sources['claude'].transcript_path(B), h.ClaudeParser))
        self.assertTrue(events[2]['isError'])

    def test_rejects_ids_that_are_not_desktop_ids(self):
        for bad in ('..\\..\\x', 'local_123', A + '/../x'):
            self.assertIsNone(self.sources['claude'].transcript_path(bad))


class CodexTests(FakeEnvironment):
    def test_database_list_hides_subthreads_and_archived(self):
        rows = self.sources['codex'].list_sessions(50)
        self.assertEqual([r['id'] for r in rows], [X, Y])
        self.assertEqual(rows[0]['title'], '回覆 A1')  # the sidebar name, not the first message
        self.assertEqual(rows[0]['permission'], '代我核准')
        self.assertIsNone(self.sources['codex'].warning)

    def test_index_fallback_when_database_is_missing(self):
        (self.fake.root / 'pc' / 'codex' / 'state_5.sqlite').unlink()
        source = self.sources['codex']
        rows = source.list_sessions(50)
        self.assertEqual([r['title'] for r in rows], ['回覆 A1', '評估 iPhone App 的做法'])
        self.assertIn('舊索引', source.warning)
        self.assertTrue(all(r['hasTranscript'] for r in rows))

    def test_modern_rollout_shows_each_message_once(self):
        events = drain(h.Transcript(self.sources['codex'].transcript_path(X), h.CodexParser))
        self.assertEqual([(e['kind'], e['text'].strip()) for e in events], [
            ('user', '測試：請回覆 A1'), ('assistant', 'A1'), ('status', '完成'),
            ('user', '列出目前資料夾的檔案'), ('tool_call', 'Get-ChildItem -Name'),
            ('tool_result', 'README.md\nmain.c'), ('assistant', '有 README.md 和 main.c 兩個檔案。'), ('status', '完成')])

    def test_legacy_rollout(self):
        events = drain(h.Transcript(self.sources['codex'].transcript_path(Y), h.CodexParser))
        self.assertEqual([(e['kind'], e['text']) for e in events], [
            ('user', '評估 iPhone App 的做法'), ('tool_call', 'powershell -c Get-Date'),
            ('tool_result', '2026年10月26日 13:00:04'), ('assistant', '建議先做模擬器版本，再整合進工具箱。')])


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder)
        self.path = folder / 't.jsonl'
        self.path.write_bytes(b'')

    @staticmethod
    def line(text):
        return (json.dumps({'type': 'user', 'message': {'content': text}}, ensure_ascii=False) + '\n').encode('utf-8')

    def append(self, data):
        with self.path.open('ab') as handle:
            handle.write(data)

    def test_partial_lines_wait_and_cursor_pages_only_new_events(self):
        t = h.Transcript(self.path, h.ClaudeParser)
        self.append(self.line('一'))
        first = drain(t)
        self.assertEqual([e['text'] for e in first], ['一'])
        whole = self.line('二')
        self.append(whole[:7])
        t.refresh()
        page = t.page(1, t.epoch)
        self.assertEqual(page['events'], [])
        self.assertFalse(page['reset'])
        self.append(whole[7:])
        t.refresh()
        page = t.page(1, t.epoch)
        self.assertEqual([(e['seq'], e['text']) for e in page['events']], [(2, '二')])
        self.assertEqual(page['cursor'], 2)

    def test_wrong_epoch_or_shrunk_file_resets(self):
        t = h.Transcript(self.path, h.ClaudeParser)
        self.append(self.line('一') + self.line('二'))
        t.refresh()
        self.assertTrue(t.page(1, 'other')['reset'])
        old_epoch = t.epoch
        self.path.write_bytes(self.line('新'))
        t.refresh()
        self.assertNotEqual(t.epoch, old_epoch)
        self.assertEqual([e['text'] for e in t.page(0, '')['events']], ['新'])

    def test_large_file_reads_only_the_tail(self):
        original = h.TAIL_BYTES
        h.TAIL_BYTES = 200
        self.addCleanup(setattr, h, 'TAIL_BYTES', original)
        self.append(b''.join(self.line(f'第{i}則') for i in range(50)))
        t = h.Transcript(self.path, h.ClaudeParser)
        page = (t.refresh(), t.page(0, ''))[1]
        self.assertTrue(page['earlier'])
        self.assertLess(len(page['events']), 50)
        self.assertEqual(page['events'][-1]['text'], '第49則')
        self.assertTrue(all(e['text'].startswith('第') for e in page['events']))

    def test_unparsable_lines_are_counted_not_fatal(self):
        self.append(b'{broken\n' + self.line('ok'))
        t = h.Transcript(self.path, h.ClaudeParser)
        self.assertEqual([e['text'] for e in drain(t)], ['ok'])
        self.assertEqual(t.skipped, 1)

    def test_long_text_keeps_full_item(self):
        self.append(self.line('長' * 20000))
        t = h.Transcript(self.path, h.ClaudeParser)
        event = drain(t)[0]
        self.assertEqual(len(event['text']), h.TEXT_LIMITS['user'])
        self.assertEqual(len(t.item(event['itemId'])), 20000)


class HelpersTests(unittest.TestCase):
    def test_folder_name_and_iso(self):
        self.assertEqual(h.folder_name('C:\\Users\\someone\\proj'), 'proj')
        self.assertEqual(h.folder_name('file:///C:/work/demo%20app'), 'demo app')
        self.assertIsNone(h.folder_name(None))
        self.assertEqual(h.iso(1793011805000), h.iso(1793011805))
        self.assertEqual(h.iso('2026-10-26T10:50:05.372Z'), '2026-10-26T10:50:05Z')
        self.assertIsNone(h.iso('not a time'))


class HttpTests(FakeEnvironment):
    def setUp(self):
        super().setUp()
        self.start_server([ipaddress.ip_network('127.0.0.0/8')])

    def start_server(self, networks):
        hub = h.Hub('示範電腦', self.sources, h.FixedPresence(self.fake.cfg['presence']),
                    self.fake.prompts, self.fake.on_events)
        gate = h.AuthGate(TOKEN, None, '示範電腦')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), h.handler_for(hub, gate, networks))
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'

    def get(self, path, token=TOKEN, method='GET'):
        request = urllib.request.Request(self.base + path, method=method,
                                         headers={'Authorization': f'Bearer {token}'} if token else {})
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_health_is_open_and_v1_needs_the_token(self):
        self.assertEqual(self.get('/health', token=None)[0], 200)
        self.assertEqual(self.get('/v1/state', token=None)[0], 401)
        self.assertEqual(self.get('/v1/state', token='wrong')[0], 401)
        code, body = self.get('/v1/state')
        self.assertEqual(code, 200)
        self.assertEqual(body['pc']['name'], '示範電腦')
        self.assertEqual(body['capabilities'], ['read'])
        self.assertEqual(body['apps']['claude'], {'running': True, 'available': True})

    def test_lists_events_long_poll_and_items(self):
        code, body = self.get('/v1/claude/sessions?limit=2')
        self.assertEqual((code, [s['id'] for s in body['sessions']][:1]), (200, [A]))
        self.assertEqual(len(body['sessions']), 2)
        code, page = self.get(f'/v1/claude/sessions/{A}/events')
        self.assertTrue(page['reset'])
        self.assertEqual(page['events'][-1]['kind'], 'assistant')
        # The scripted conversation gains a user line about 3 s after it is first opened.
        started = time.monotonic()
        code, more = self.get(f"/v1/claude/sessions/{A}/events?after={page['cursor']}&epoch={page['epoch']}&wait=20")
        self.assertEqual(code, 200)
        self.assertFalse(more['reset'])
        self.assertEqual([e['text'] for e in more['events']], ['再加上解除安裝的步驟。'])
        self.assertLess(time.monotonic() - started, 15)
        item = next(e for e in page['events'] if e.get('truncated'))
        code, full = self.get(f"/v1/claude/sessions/{A}/items/{item['itemId']}")
        self.assertEqual(code, 200)
        self.assertGreater(len(full['text']), len(item['text']))

    def test_prompt_is_returned_and_known_prompt_does_not_spin(self):
        code, page = self.get(f'/v1/claude/sessions/{B}/events')
        self.assertEqual(page['prompt']['promptId'], 'demo-prompt-1')
        started = time.monotonic()
        code, again = self.get(f"/v1/claude/sessions/{B}/events?after={page['cursor']}&epoch={page['epoch']}"
                               '&wait=2&prompt=demo-prompt-1')
        self.assertGreaterEqual(time.monotonic() - started, 1.5)
        self.assertEqual(again['events'], [])

    def test_codex_and_bad_paths(self):
        self.assertEqual([s['id'] for s in self.get('/v1/codex/sessions')[1]['sessions']], [X, Y])
        self.assertEqual(self.get('/v1/codex/sessions/..%2F..%2Fsecret/events')[0], 404)
        self.assertEqual(self.get('/v1/other/sessions')[0], 404)
        self.assertEqual(self.get('/v1/state', method='POST')[0], 405)

    def test_requests_from_outside_allowed_networks_are_forbidden(self):
        self.start_server([ipaddress.ip_network('10.0.0.0/8')])
        self.assertEqual(self.get('/health', token=None)[0], 403)


if __name__ == '__main__':
    unittest.main()
