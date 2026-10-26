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
        self.assertIsNone(rows[0]['permission'])  # the stored approval mode would mislead
        self.assertEqual(rows[0]['folder'], 'demo-app')
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

    def test_own_input_does_not_count_as_someone_at_the_keyboard(self):
        # Real input at tick 1000, the helper acts 61000..62000 and its keystrokes land at 61500.
        self.assertEqual(h.own_adjusted_idle(61500, 70000, (61000, 62000), 1000), 69)
        # Input after the helper's window (plus grace) is a person.
        self.assertEqual(h.own_adjusted_idle(65000, 70000, (61000, 62000), 1000), 5)
        # While the helper is still acting, its own input is ignored.
        self.assertEqual(h.own_adjusted_idle(61500, 61800, (61000, None), 1000), 60)
        # Tick counts wrap around after 49.7 days.
        self.assertEqual(h.own_adjusted_idle(0xFFFFF000, 0x00000800, None, None), 6)


def drive(fake, presence=None, driver_class=None, notify=None):
    """Hub, fake driver, watcher and runner without threads; tests run actions themselves."""
    sources = fake.sources()
    hub = h.Hub('示範電腦', sources, h.FixedPresence(presence or fake.cfg['presence']), on_events=fake.on_events)
    driver = (driver_class or h.FakeDriver)(fake, hub, reply_after=0.2)
    watcher = h.UiWatcher(hub, driver, notify, '示範電腦')
    hub.prompts = watcher.prompt_for
    runner = h.ActionRunner(hub, driver, hub.presence, watcher, notify, '示範電腦', h.load_strings(),
                            verify_seconds=3, doc_wait=1)
    watcher.tick()
    return hub, driver, watcher, runner


def run_all(runner):
    while runner.queue:
        runner.run(runner.actions[runner.queue.pop(0)])


class DrivingTests(FakeEnvironment):
    def test_send_opens_the_conversation_by_link_and_confirms_it_in_the_transcript(self):
        hub, driver, _, runner = drive(self.fake)
        code, body = runner.submit('send', 'claude', A, {'text': '請再檢查一次', 'clientMsgId': 'c1'})
        self.assertEqual((code, body['state']), (202, 'queued'))
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertEqual([c[0] for c in driver.calls], ['open', 'send'])
        events = drain(hub.transcript('claude', A))
        self.assertIn('請再檢查一次', [e['text'] for e in events])

    def test_same_client_message_id_is_sent_once(self):
        _, _, _, runner = drive(self.fake)
        first = runner.submit('send', 'claude', A, {'text': 'x', 'clientMsgId': 'same'})[1]
        second = runner.submit('send', 'claude', A, {'text': 'x', 'clientMsgId': 'same'})[1]
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(len(runner.queue), 1)

    def test_someone_at_the_pc_blocks_until_the_phone_confirms(self):
        presence = dict(self.fake.cfg['presence'], idleSeconds=5)
        _, _, _, runner = drive(self.fake, presence)
        code, body = runner.submit('send', 'claude', A, {'text': 'x'})
        self.assertEqual((code, body['error'], body['idleSeconds']), (409, 'busy-user', 5))
        self.assertEqual(runner.submit('send', 'claude', A, {'text': 'x', 'force': True})[0], 202)
        self.assertEqual(runner.submit('new', 'codex', None, {'text': 'x'})[0], 409)

    def test_locked_pc_refuses_even_when_forced(self):
        presence = dict(self.fake.cfg['presence'], locked=True)
        _, _, _, runner = drive(self.fake, presence)
        code, body = runner.submit('send', 'claude', A, {'text': 'x', 'force': True})
        self.assertEqual((code, body['error']), (423, 'locked'))

    def test_wrong_conversation_open_never_types(self):
        class StuckDriver(h.FakeDriver):
            def open(self, app, info):
                self.calls.append(('open', app, info['id']))  # the link does nothing
        _, driver, _, runner = drive(self.fake, driver_class=StuckDriver)
        body = runner.submit('send', 'claude', A, {'text': 'x'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'title-mismatch')
        self.assertNotIn('send', [c[0] for c in driver.calls])

    def test_codex_falls_back_to_the_sidebar_only_for_a_unique_title(self):
        class StuckDriver(h.FakeDriver):
            def open(self, app, info):
                self.calls.append(('open', app, info['id']))
        _, driver, _, runner = drive(self.fake, driver_class=StuckDriver)
        body = runner.submit('send', 'codex', Y, {'text': 'hello'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done')
        self.assertEqual([c[0] for c in driver.calls], ['open', 'invoke', 'send'])
        # Give Y the same title as another thread: the sidebar cannot tell them apart.
        connection = h.sqlite3.connect(self.fake.root / 'pc' / 'codex' / 'state_5.sqlite')
        connection.execute("UPDATE threads SET name = '回覆 A1' WHERE id = ?", (Y,))
        connection.commit()
        connection.close()
        driver.open_doc['codex'] = '別的對話'
        driver.calls.clear()
        runner.hub.info_cache.clear()
        body = runner.submit('send', 'codex', Y, {'text': 'hello'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'duplicate-title')
        self.assertNotIn('send', [c[0] for c in driver.calls])

    def test_send_that_never_shows_up_is_reported(self):
        class SilentDriver(h.FakeDriver):
            def send(self, app, doc, text):
                self.calls.append(('send', app, doc))
        _, _, _, runner = drive(self.fake, driver_class=SilentDriver)
        body = runner.submit('send', 'claude', A, {'text': 'lost'})[1]
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', False))
        self.assertIn('還沒在對話紀錄看到', status['message'])

    def test_permission_answers_only_the_question_on_screen(self):
        hub, driver, watcher, runner = drive(self.fake)
        prompt = watcher.prompt_for('claude', B)
        self.assertEqual(prompt['text'], self.fake.prompts_data[f'claude/{B}']['text'])
        self.assertIsNone(watcher.prompt_for('claude', A))
        self.assertEqual(runner.submit('permission', 'claude', B, {'promptId': 'old', 'decision': 'allow_once'})[1]['error'],
                         'prompt-changed')
        self.assertEqual(runner.submit('permission', 'claude', B, {'promptId': prompt['promptId'], 'decision': 'always'})[0], 400)
        body = runner.submit('permission', 'claude', B, {'promptId': prompt['promptId'], 'decision': 'allow_once'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '已允許一次')
        self.assertIsNone(watcher.prompt_for('claude', B))
        self.assertIn('已補上分號並存檔（示範）', [e['text'] for e in drain(hub.transcript('claude', B))])

    def test_deny_works_while_someone_uses_the_pc_but_allow_once_waits(self):
        presence = dict(self.fake.cfg['presence'], idleSeconds=3)
        _, _, watcher, runner = drive(self.fake, presence)
        prompt = watcher.prompt_for('claude', B)
        allow = runner.submit('permission', 'claude', B, {'promptId': prompt['promptId'], 'decision': 'allow_once'})
        self.assertEqual(allow[1]['error'], 'busy-user')  # Claude's dropdown needs the mouse
        self.assertEqual(runner.submit('permission', 'claude', B, {'promptId': prompt['promptId'], 'decision': 'deny'})[0], 202)

    def test_new_conversation_reports_its_id(self):
        _, driver, _, runner = drive(self.fake)
        body = runner.submit('new', 'codex', None, {'text': '幫我看一下 README'})[1]
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified'], status['title']), ('done', True, '幫我看一下 README'))
        self.assertTrue(h.CODEX_ID.match(status['sessionId']))
        self.assertEqual(driver.calls[-1], ('new_send', 'codex', '新對話'))
        body = runner.submit('new', 'codex', None, {'text': 'x', 'project': 'demo-app'})[1]
        run_all(runner)
        self.assertEqual(driver.calls[-1], ('new_send', 'codex', '在 demo-app 中開始新對話'))

    def test_every_action_and_question_is_sent_to_ntfy(self):
        sent = []
        _, _, watcher, runner = drive(self.fake, notify=lambda *a: sent.append(a))
        self.assertEqual(len([s for s in sent if s[0].startswith('🔔')]), 1)
        watcher.tick()
        self.assertEqual(len([s for s in sent if s[0].startswith('🔔')]), 1, 'same question twice')
        runner.submit('send', 'claude', A, {'text': '秘密內容不能進通知'})
        run_all(runner)
        self.assertTrue(any(s[0] == '📱 手機送出訊息：Claude' for s in sent), sent)
        self.assertFalse(any('秘密內容' in s[1] for s in sent), 'message text leaked into ntfy')

    def test_finished_turn_is_notified_once(self):
        sent = []
        hub, driver, watcher, _ = drive(self.fake, notify=lambda *a: sent.append(a))
        path = hub.sources['claude'].transcript_path(A)
        watcher.check_turns()
        driver.write('claude', path, 'user', '再一題')
        watcher.check_turns()
        driver.write('claude', path, 'assistant', '好了')
        watcher.check_turns()
        watcher.check_turns()
        self.assertEqual([s[0] for s in sent if s[0].startswith('✅')], ['✅ Claude 完成一輪'])


class HttpTests(FakeEnvironment):
    def setUp(self):
        super().setUp()
        self.start_server([ipaddress.ip_network('127.0.0.0/8')])

    def start_server(self, networks, driving=True):
        if driving:
            hub, _, _, self.runner = drive(self.fake)
            threading.Thread(target=self.runner.run_forever, daemon=True).start()
            hub.capabilities = ['read', 'send', 'permission', 'new', 'open']
        else:
            hub, self.runner = h.Hub('示範電腦', self.sources, h.FixedPresence(self.fake.cfg['presence'])), None
        self.hub = hub
        gate = h.AuthGate(TOKEN, None, '示範電腦')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), h.handler_for(hub, gate, networks, self.runner))
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'

    def get(self, path, token=TOKEN, method='GET', body=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode('utf-8') if body is not None else None)
        request = urllib.request.Request(self.base + path, method=method, data=data,
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
        self.assertEqual(body['capabilities'], ['read', 'send', 'permission', 'new', 'open'])
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
        prompt = page['prompt']['promptId']
        self.assertEqual(page['prompt']['text'], self.fake.prompts_data[f'claude/{B}']['text'])
        started = time.monotonic()
        code, again = self.get(f"/v1/claude/sessions/{B}/events?after={page['cursor']}&epoch={page['epoch']}"
                               f'&wait=2&prompt={prompt}')
        self.assertGreaterEqual(time.monotonic() - started, 1.5)
        self.assertEqual(again['events'], [])

    def test_post_message_then_poll_the_action(self):
        code, body = self.get(f'/v1/claude/sessions/{A}/messages', method='POST', body={'text': '從手機來的'})
        self.assertEqual(code, 202)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            code, status = self.get(f"/v1/actions/{body['id']}")
            if status['state'] in ('done', 'failed'):
                break
            time.sleep(0.2)
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertEqual(self.get('/v1/actions/nope')[0], 404)

    def test_post_rejects_bad_bodies_paths_and_missing_token(self):
        path = f'/v1/claude/sessions/{A}/messages'
        self.assertEqual(self.get(path, method='POST', body={'text': 'x'}, token=None)[0], 401)
        self.assertEqual(self.get(path, method='POST', raw=b'not json')[0], 400)
        self.assertEqual(self.get(path, method='POST', body=['list'])[0], 400)
        self.assertEqual(self.get(path, method='POST', body={'text': '   '})[0], 400)
        self.assertEqual(self.get(path, method='POST', raw=b'{"text":"' + b'x' * (70 * 1024) + b'"}')[0], 413)
        self.assertEqual(self.get('/v1/claude/sessions/..%2Fx/messages', method='POST', body={'text': 'x'})[0], 404)
        self.assertEqual(self.get('/v1/claude/sessions/local_00000000-0000-4000-8000-000000000000/messages',
                                  method='POST', body={'text': 'x'})[0], 404)
        self.assertEqual(self.get('/v1/state', method='PUT')[0], 405)

    def test_read_only_server_refuses_posts(self):
        self.start_server([ipaddress.ip_network('127.0.0.0/8')], driving=False)
        self.assertEqual(self.get(f'/v1/claude/sessions/{A}/messages', method='POST', body={'text': 'x'})[0], 405)
        self.assertEqual(self.get('/v1/state')[1]['capabilities'], ['read'])

    def test_codex_and_bad_paths(self):
        self.assertEqual([s['id'] for s in self.get('/v1/codex/sessions')[1]['sessions']], [X, Y])
        self.assertEqual(self.get('/v1/codex/sessions/..%2F..%2Fsecret/events')[0], 404)
        self.assertEqual(self.get('/v1/other/sessions')[0], 404)

    def test_requests_from_outside_allowed_networks_are_forbidden(self):
        self.start_server([ipaddress.ip_network('10.0.0.0/8')])
        self.assertEqual(self.get('/health', token=None)[0], 403)


class StringsTests(unittest.TestCase):
    def test_both_apps_have_every_control_name(self):
        strings = h.load_strings()
        for key in ('edit', 'deny', 'allow_once', 'new'):
            self.assertTrue(strings['claude'][key] and strings['codex'][key], key)
        self.assertTrue(strings['claude']['more_allow'])
        self.assertIn('{project}', strings['codex']['new_in_project'])

    def test_worker_script_is_ascii(self):
        data = (HERE.parent / 'uia_worker.ps1').read_bytes()
        self.assertTrue(all(b < 128 for b in data), 'PowerShell 5.1 misreads non-ASCII scripts without a BOM')


if __name__ == '__main__':
    unittest.main()


