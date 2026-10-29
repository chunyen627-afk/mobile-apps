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
E = 'local_66666666-6666-4666-8666-666666666666'
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
        self.assertEqual([r['title'] for r in rows], ['整理專案 README', '修正建置錯誤', '選擇部署方式', '週報草稿'])
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

    def test_option_question_waits_until_its_result_arrives(self):
        transcript = h.Transcript(self.sources['claude'].transcript_path(E), h.ClaudeParser)
        events = drain(transcript)
        self.assertNotIn('AskUserQuestion', [e.get('tool') for e in events], 'the question is a card, not a tool row')
        question = transcript.page(0, '')['question']
        self.assertEqual(question['questionId'], 'toolu_demo_question')
        self.assertEqual([q['multiSelect'] for q in question['questions']], [False, True])
        self.assertEqual([o['label'] for o in question['questions'][0]['options']], ['藍綠部署', '直接覆蓋'])
        with Path(transcript.path).open('a', encoding='utf-8') as handle:
            handle.write(json.dumps({'type': 'user', 'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': 'toolu_demo_question', 'content': 'answered'}]}}) + '\n')
        transcript.refresh()
        page = transcript.page(0, '')
        self.assertIsNone(page['question'])
        self.assertEqual(page['events'][-1]['text'], '已回答選項題')

    def test_reply_buttons_last_until_the_next_message(self):
        C = 'local_33333333-3333-4333-8333-333333333333'
        transcript = h.Transcript(self.sources['claude'].transcript_path(C), h.ClaudeParser)
        events = drain(transcript)
        self.assertFalse([e for e in events if e['kind'].startswith('tool')], 'the next-step box is not a tool row')
        suggestions = transcript.page(0, '')['suggestions']
        self.assertEqual(suggestions['ask'], '要接著寫下週計畫嗎？')
        self.assertEqual(suggestions['replies'], [{'label': '好，繼續', 'message': '好，繼續寫下週計畫。'},
                                                  {'label': '先停', 'message': '先停在這裡。'}])
        with Path(transcript.path).open('a', encoding='utf-8') as handle:
            handle.write(json.dumps({'type': 'user', 'message': {'content': '好，繼續寫下週計畫。'}}, ensure_ascii=False) + '\n')
        transcript.refresh()
        self.assertIsNone(transcript.page(0, '')['suggestions'])

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

    def test_a_second_action_still_counts_from_the_last_real_input(self):
        presence = h.WindowsPresence()
        ticks = {'now': 61000, 'last': 1000}
        presence.ticks = lambda: ticks['now']
        presence.last_input = lambda: ticks['last']
        presence.begin_own()
        ticks.update(now=62000, last=61500)  # the first message's keystrokes
        presence.end_own()
        ticks['now'] = 86000                  # the next phone message, 25 s later
        self.assertEqual(presence.idle_seconds(), 85)
        presence.begin_own()
        self.assertEqual(presence.idle_seconds(), 85)
        ticks['now'] = 87000
        presence.end_own()
        ticks.update(now=90000, last=89000)   # a person after that does count
        presence.begin_own()
        self.assertEqual(presence.idle_seconds(), 1)

    def test_focus_failure_names_the_window_in_front(self):
        base = h.FAILURE_TEXT['focus-failed']
        message = 'could not bring the window to the front; in front: Taskmgr'
        self.assertEqual(h.failure_text('focus-failed', message), base + '；擋在前面的是：工作管理員')
        self.assertTrue(h.failure_text('focus-failed', '...; in front: SomeTool').endswith('：SomeTool'))
        self.assertIn('選單或對話框', h.failure_text('focus-failed', 'x; in front: same-app'))
        # Older workers (no detail) and other errors keep the plain text.
        self.assertEqual(h.failure_text('focus-failed', 'could not bring the window to the front'), base)
        self.assertEqual(h.failure_text('paste-failed', ''), h.FAILURE_TEXT['paste-failed'])
        self.assertEqual(h.failure_text('odd-code', 'raw text'), 'raw text')


def drive(fake, presence=None, driver_class=None, notify=None):
    """Hub, fake driver, watcher and runner without threads; tests run actions themselves."""
    sources = fake.sources()
    hub = h.Hub('示範電腦', sources, h.FixedPresence(presence or fake.cfg['presence']), on_events=fake.on_events)
    hub.strings = h.load_strings()
    driver = (driver_class or h.FakeDriver)(fake, hub, reply_after=0.2)
    watcher = h.UiWatcher(hub, driver, notify, '示範電腦')
    hub.prompts = watcher.prompt_for
    hub.ui = watcher.current
    hub.popups = watcher.popup_list
    runner = h.ActionRunner(hub, driver, hub.presence, watcher, notify, '示範電腦', hub.strings,
                            verify_seconds=3, doc_wait=1, settle_seconds=0)
    watcher.tick()
    return hub, driver, watcher, runner


class FastClock:
    """A monotonic clock that jumps a second per reading, so timeouts pass without waiting."""

    def __init__(self):
        self.now = 0.0

    def __call__(self):
        self.now += 1.0
        return self.now


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

    def test_app_closed_to_the_tray_is_brought_back_by_the_link(self):
        class TrayDriver(h.FakeDriver):
            hidden = True

            def docs(self, app):
                return None if self.hidden else super().docs(app)

            def open(self, app, info):
                self.hidden = False  # the link shows the window again
                super().open(app, info)
        _, driver, _, runner = drive(self.fake, driver_class=TrayDriver)
        body = runner.submit('send', 'codex', X, {'text': 'hello'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done', runner.status(body['id']))
        self.assertEqual([c[0] for c in driver.calls], ['open', 'send'])

    def test_app_that_never_shows_a_window_is_reported(self):
        class GoneDriver(h.FakeDriver):
            def docs(self, app):
                return None
        _, driver, _, runner = drive(self.fake, driver_class=GoneDriver)
        body = runner.submit('send', 'codex', X, {'text': 'hello'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'app-not-running')
        self.assertNotIn('send', [c[0] for c in driver.calls])

    def closed_presence(self, **extra):
        presence = dict(self.fake.cfg['presence'], **extra)
        presence['windows'] = dict(presence['windows'], codex=False)
        return presence

    def test_launch_shows_a_closed_app_and_the_state_says_so(self):
        hub, driver, _, runner = drive(self.fake, self.closed_presence())
        self.assertFalse(hub.state()['apps']['codex']['running'])
        code, body = runner.submit('launch', 'codex', None, {})
        self.assertEqual(code, 202)
        run_all(runner)
        done = runner.status(body['id'])
        self.assertEqual((done['state'], done['verified'], done['message']), ('done', True, '已在電腦上開啟桌面版'))
        self.assertEqual(driver.calls, [('launch', 'codex')])
        self.assertTrue(hub.state()['apps']['codex']['running'])

    def test_launch_leaves_an_open_app_alone(self):
        _, driver, _, runner = drive(self.fake)
        body = runner.submit('launch', 'claude', None, {})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '桌面版已經開著')
        self.assertEqual(driver.calls, [])

    def test_launch_waits_for_nobody_at_the_keyboard_unless_forced(self):
        _, driver, _, runner = drive(self.fake, self.closed_presence(idleSeconds=5))
        code, body = runner.submit('launch', 'codex', None, {})
        self.assertEqual((code, body['error']), (409, 'busy-user'))
        self.assertEqual(runner.submit('launch', 'codex', None, {'force': True})[0], 202)
        run_all(runner)
        self.assertEqual(driver.calls, [('launch', 'codex')])

    def test_launch_with_no_window_fails_quietly(self):
        class DeadDriver(h.FakeDriver):
            def launch(self, app):
                self.calls.append(('launch', app))
        sent = []
        _, _, _, runner = drive(self.fake, self.closed_presence(), driver_class=DeadDriver,
                                notify=lambda *a: sent.append(a))
        runner.clock = FastClock()
        sent.clear()  # the fixture's waiting permission question was announced when it was seen
        body = runner.submit('launch', 'codex', None, {})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'app-not-running')
        self.assertEqual(sent, [])  # the phone asked on its own and shows it

    def test_wrong_conversation_open_never_types(self):
        class StuckDriver(h.FakeDriver):
            def open(self, app, info):
                self.calls.append(('open', app, info['id']))  # the link does nothing

            def invoke_title(self, app, title):
                self.calls.append(('invoke_title', app, title))  # nor does the sidebar
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

    def test_message_queued_behind_a_question_counts_as_delivered(self):
        class QueueingDriver(h.FakeDriver):
            def send(self, app, doc, text, image=None):
                self.calls.append(('send', app, doc))
                path = self.hub.sources[app].transcript_path(self.session_for_doc(app, doc))
                with Path(path).open('a', encoding='utf-8') as handle:
                    handle.write(json.dumps({'type': 'queue-operation', 'operation': 'enqueue',
                                             'content': text}, ensure_ascii=False) + '\n')
        _, _, _, runner = drive(self.fake, driver_class=QueueingDriver)
        body = runner.submit('send', 'claude', A, {'text': '排隊的訊息'})[1]
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertIn('排在等待中的權限詢問之後', status['message'])

    def test_send_that_never_shows_up_is_reported(self):
        class SilentDriver(h.FakeDriver):
            def send(self, app, doc, text, image=None):
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

    def test_answer_that_leaves_the_question_on_screen_fails(self):
        class DeadButtonDriver(h.FakeDriver):
            def answer(self, app, doc, decision, expect):
                self.calls.append(('answer', app, decision))
                return 'invoke'  # reports success, changes nothing
        _, _, watcher, runner = drive(self.fake, driver_class=DeadButtonDriver)
        runner.clock = FastClock()
        prompt = watcher.prompt_for('claude', B)
        body = runner.submit('permission', 'claude', B, {'promptId': prompt['promptId'], 'decision': 'allow_once'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'still-asking')

    def test_deny_works_while_someone_uses_the_pc_but_allow_once_waits(self):
        presence = dict(self.fake.cfg['presence'], idleSeconds=3)
        _, _, watcher, runner = drive(self.fake, presence)
        prompt = watcher.prompt_for('claude', B)
        allow = runner.submit('permission', 'claude', B, {'promptId': prompt['promptId'], 'decision': 'allow_once'})
        self.assertEqual(allow[1]['error'], 'busy-user')  # Claude's dropdown needs the mouse
        self.assertEqual(runner.submit('permission', 'claude', B, {'promptId': prompt['promptId'], 'decision': 'deny'})[0], 202)

    def test_answers_must_fit_the_question_waiting_now(self):
        hub, driver, _, runner = drive(self.fake)
        good = [{'labels': ['藍綠部署']}, {'labels': ['ntfy', 'Email']}]
        def submit(**payload):
            return runner.submit('answer', 'claude', E, dict({'questionId': 'toolu_demo_question', 'answers': good}, **payload))
        self.assertEqual(submit(questionId='old')[1]['error'], 'question-changed')
        self.assertEqual(submit(answers=[{'labels': ['藍綠部署']}])[0], 400)                       # one answer missing
        self.assertEqual(submit(answers=[{'labels': ['不存在']}, {'labels': ['ntfy']}])[0], 400)   # unknown option
        self.assertEqual(submit(answers=[{'labels': ['藍綠部署', '直接覆蓋']}, {'labels': ['ntfy']}])[0], 400)  # single
        self.assertEqual(submit(answers=[{'labels': []}, {'labels': ['ntfy']}])[0], 400)          # nothing chosen
        code, body = submit(answers=[{'labels': [], 'other': '先問運維'}, {'labels': ['ntfy', 'Email']}])
        self.assertEqual(code, 202)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['message']), ('done', '已回答'), status)
        self.assertEqual([c[0] for c in driver.calls], ['open', 'answer_question'])
        self.assertIsNone(hub.transcript('claude', E).page(0, '')['question'])
        self.assertEqual(submit()[1]['error'], 'question-changed', 'an answered question cannot be answered again')

    def test_answer_the_pc_did_not_take_fails(self):
        class DeafDriver(h.FakeDriver):
            def answer_question(self, app, doc, question, answers):
                self.calls.append(('answer_question', app, question['questionId']))
        _, _, _, runner = drive(self.fake, driver_class=DeafDriver)
        runner.clock = FastClock()
        body = runner.submit('answer', 'claude', E, {'questionId': 'toolu_demo_question',
                                                     'answers': [{'labels': ['直接覆蓋']}, {'labels': ['ntfy']}]})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'still-asking')

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

    def test_questions_and_failures_are_notified_but_not_what_the_phone_did(self):
        sent = []
        _, _, watcher, runner = drive(self.fake, notify=lambda *a: sent.append(a))
        self.assertEqual(len([s for s in sent if s[0].startswith('🔔')]), 1)
        watcher.tick()
        self.assertEqual(len([s for s in sent if s[0].startswith('🔔')]), 1, 'same question twice')
        runner.submit('send', 'claude', A, {'text': '秘密內容不能進通知'})
        run_all(runner)
        self.assertFalse(any(s[0].startswith('📱') for s in sent), 'a phone action that worked was notified')
        presence = dict(self.fake.cfg['presence'])
        code, body = runner.submit('send', 'claude', A, {'text': '秘密內容不能進通知'})
        runner.presence = h.FixedPresence(dict(presence, locked=True))  # locked before it runs: fails
        run_all(runner)
        self.assertEqual([s[0] for s in sent if s[0].startswith('⚠️')], ['⚠️ 手機送出訊息失敗：Claude'])
        self.assertFalse(any('秘密內容' in s[1] for s in sent), 'message text leaked into ntfy')

    def test_claude_ignoring_its_link_falls_back_to_the_sidebar(self):
        class DeafDriver(h.FakeDriver):
            def open(self, app, info):
                self.calls.append(('open', app, info['id']))  # the link does nothing
        _, driver, _, runner = drive(self.fake, driver_class=DeafDriver)
        body = runner.submit('open', 'claude', A, {})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done')
        self.assertEqual([c[0] for c in driver.calls], ['open', 'invoke'])

    def test_new_conversation_brings_a_tray_app_back_first(self):
        class TrayDriver(h.FakeDriver):
            hidden = True

            def docs(self, app):
                return None if self.hidden else super().docs(app)

            def open(self, app, info):
                super().open(app, info)
                self.hidden = False
        _, driver, _, runner = drive(self.fake, driver_class=TrayDriver)
        body = runner.submit('new', 'codex', None, {'text': '從系統匣叫出來'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done')
        self.assertEqual([c[0] for c in driver.calls], ['open', 'new_send'])

    def test_a_new_option_question_is_notified_once(self):
        sent = []
        hub, _, watcher, _ = drive(self.fake, notify=lambda *a: sent.append(a))
        self.assertFalse(any(s[0].startswith('❓') for s in sent), 'a question waiting at startup is not news')
        path = hub.sources['claude'].transcript_path(A)
        line = {'type': 'assistant', 'timestamp': '2026-10-27T01:00:00Z', 'message': {'role': 'assistant', 'content': [
            {'type': 'tool_use', 'id': 'toolu_new_question', 'name': 'AskUserQuestion', 'input': {'questions': [
                {'question': '要用哪個？', 'header': '選擇', 'multiSelect': False,
                 'options': [{'label': '甲'}, {'label': '乙'}]}]}}]}}
        with path.open('a', encoding='utf-8') as handle:
            handle.write(json.dumps(line, ensure_ascii=False) + '\n')
        watcher.check_turns()
        watcher.check_turns()
        self.assertEqual([s[0] for s in sent if s[0].startswith('❓')], ['❓ Claude 在等你選擇'])

    def test_finished_turn_is_not_notified(self):
        # The phone shows a finished turn; ntfy is only for what needs the user (10/28).
        sent = []
        hub, driver, watcher, _ = drive(self.fake, notify=lambda *a: sent.append(a))
        path = hub.sources['claude'].transcript_path(A)
        watcher.check_turns()
        before = list(sent)  # the fixture's waiting permission prompt (🔔) is still sent
        driver.write('claude', path, 'user', '再一題')
        watcher.check_turns()
        self.assertEqual(watcher.turns[('claude', A)], 'working')
        driver.write('claude', path, 'assistant', '好了')
        watcher.check_turns()
        watcher.check_turns()
        self.assertEqual(watcher.turns[('claude', A)], 'idle')
        self.assertEqual(sent, before)
        self.assertFalse([s for s in sent if '一輪' in s[0]])


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
        # 64 KB for every body except messages, which may carry a photo (12 MB).
        self.assertEqual(self.get(f'/v1/claude/sessions/{A}/permission', method='POST',
                                  raw=b'{"text":"' + b'x' * (70 * 1024) + b'"}')[0], 413)
        self.assertEqual(self.get(path, method='POST', raw=b'{"text":"' + b'x' * (70 * 1024) + b'"}')[1]['message'],
                         '訊息太長（上限 20000 字）')
        self.assertEqual(self.get('/v1/claude/sessions/..%2Fx/messages', method='POST', body={'text': 'x'})[0], 404)
        self.assertEqual(self.get('/v1/claude/sessions/local_00000000-0000-4000-8000-000000000000/messages',
                                  method='POST', body={'text': 'x'})[0], 404)
        self.assertEqual(self.get('/v1/state', method='PUT')[0], 405)

    def test_question_wakes_a_long_poll_and_can_be_answered(self):
        code, page = self.get(f'/v1/claude/sessions/{E}/events')
        self.assertEqual(page['question']['questionId'], 'toolu_demo_question')
        started = time.monotonic()
        code, again = self.get(f"/v1/claude/sessions/{E}/events?after={page['cursor']}&epoch={page['epoch']}"
                               '&wait=10&question=')
        self.assertLess(time.monotonic() - started, 3, 'a question the phone does not know must not wait')
        self.assertIsNotNone(again['question'])
        code, body = self.get(f'/v1/claude/sessions/{E}/answer', method='POST', body={
            'questionId': 'toolu_demo_question', 'answers': [{'labels': ['藍綠部署']}, {'labels': ['Email']}]})
        self.assertEqual(code, 202, body)

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


class MetaTests(FakeEnvironment):
    """Model, effort, context use and plan limits (read from files the desktop apps write)."""

    def test_labels_read_like_the_desktop_apps(self):
        self.assertEqual(h.model_label('claude-opus-5-5'), 'Opus 5.5')
        self.assertEqual(h.model_label('claude-fable-5-1[1m]'), 'Fable 5.1')
        self.assertEqual(h.model_label('claude-haiku-4-5-20251001'), 'Haiku 4.5')
        self.assertEqual(h.model_label('gpt-6.1-sol'), 'GPT-6.1 Sol')
        self.assertEqual(h.model_label('something-else'), 'something-else')
        self.assertIsNone(h.model_label(None))
        self.assertEqual(h.ui_model('模型：Opus 5.5 高', '模型：'), ('Opus 5.5', '高'))
        self.assertEqual(h.ui_model('模型：Sonnet 5.5', '模型：'), ('Sonnet 5.5', None))
        self.assertEqual(h.ui_model('別的按鈕', '模型：'), (None, None))
        self.assertEqual(h.ui_model('GPT-6.1 Sol 高', ''), ('GPT-6.1 Sol', '高'))
        self.assertEqual(h.ui_model('GPT-6.1 Sol 高', None), (None, None))
        self.assertEqual(h.ui_usage('使用量：每週 · 所有模型：46% 週日上午11:00 重設', '使用量：'),
                         {'label': '每週 · 所有模型', 'percent': 46, 'resetsText': '週日上午11:00 重設'})
        self.assertIsNone(h.ui_usage('使用量：讀不懂', '使用量：'))
        self.assertEqual(h.context_info(250, 1000), {'used': 250, 'window': 1000, 'percent': 25})
        self.assertEqual(h.context_info(250, None), {'used': 250, 'window': None, 'percent': None})
        self.assertIsNone(h.context_info(None, 1000))
        self.assertEqual([h.window_label(m) for m in (300, 10080, 2880, 120)], ['5 小時', '每週', '2 天', '2 小時'])

    def meta(self, app, session_id):
        transcript = h.Transcript(self.sources[app].transcript_path(session_id), self.sources[app].parser)
        transcript.refresh()
        return self.sources[app].meta(session_id, transcript.parser)

    def test_claude_meta_from_conversation_file_and_last_reply(self):
        self.assertEqual(self.meta('claude', A), {
            'model': 'Opus 5.5', 'modelId': 'claude-opus-5-5', 'effort': '高',
            'context': {'used': 183203, 'window': 1_000_000, 'percent': 18}, 'permission': '自動'})
        # No confirmed window for this model, and no reply with usage: tokens only, no guess.
        meta = self.meta('claude', B)
        self.assertEqual((meta['model'], meta['effort'], meta['context']), ('Sonnet 5.5', '中', None))
        self.assertIsNone(self.sources['claude'].context_window('claude-sonnet-5-5'))
        self.assertEqual(h.ClaudeSource('x', 'y', {'claude-sonnet-5': 200000}).context_window('claude-sonnet-5-5'), 200000)

    def test_codex_meta_and_limits_from_the_rollout(self):
        self.assertEqual(self.meta('codex', X), {
            'model': 'GPT-6.1 Sol', 'modelId': 'gpt-6.1-sol', 'effort': '高',
            'context': {'used': 64600, 'window': 258400, 'percent': 25}, 'permission': '代我核准', 'note': None})
        usage = self.sources['codex'].usage()
        self.assertEqual(usage['windows'], [{'label': '每週', 'percent': 5, 'resetsAt': h.iso(1793616560), 'resetsText': None}])
        self.assertEqual(usage['sampledAt'], '2026-10-26T10:01:05Z')

    def test_an_imported_codex_thread_says_it_has_no_data_yet(self):
        # Y's rollout has no turn_context and the database has no model: imported from another account.
        self.assertEqual(self.meta('codex', Y), {
            'model': None, 'modelId': None, 'effort': None, 'context': None, 'permission': None,
            'note': '匯入的舊對話，回覆一次後才有資料'})
        # A rollout tail that holds no turn_context still gets the model from the database.
        parser = h.CodexParser()
        self.assertEqual(self.sources['codex'].meta(X, parser)['model'], 'GPT-6.1 Sol')
        self.assertIsNone(self.sources['codex'].meta(X, parser)['note'])

    def test_claude_limits_are_the_signed_in_organisations_newest(self):
        usage = self.sources['claude'].usage()
        self.assertEqual([(w['label'], w['percent']) for w in usage['windows']], [('5 小時', 3), ('每週', 46)])
        self.assertEqual(usage['sampledAt'], h.iso(1793060000000))

    def test_claude_limits_take_the_week_from_the_button_when_the_file_is_behind(self):
        t = 1793094566  # the file's sample (10/27 09:49Z, when the office's file stopped)
        sample = {'windows': [{'label': '5 小時', 'percent': 7, 'resetsAt': None, 'resetsText': None},
                              {'label': '每週', 'percent': 53, 'resetsAt': None, 'resetsText': None}],
                  'sampledAt': h.iso(t)}
        button = {'label': '每週 · 所有模型', 'percent': 61, 'resetsText': '週日上午11:00 重設'}
        week = {'label': '每週', 'percent': 61, 'resetsAt': None, 'resetsText': '週日上午11:00 重設'}
        # A day later: the 5-hour figure has reset since, the button is the week.
        self.assertEqual(h.merge_claude_usage(sample, button, t + 86000, t + 86400),
                         {'windows': [week], 'sampledAt': h.iso(t + 86000)})
        # Within five hours both show; the time is the older one's.
        merged = h.merge_claude_usage(sample, button, t + 600, t + 900)
        self.assertEqual([(w['label'], w['percent']) for w in merged['windows']], [('5 小時', 7), ('每週', 61)])
        self.assertEqual(merged['sampledAt'], h.iso(t))
        # A button read before the sample only lends its reset time.
        older = h.merge_claude_usage(sample, button, t - 60, t + 60)
        self.assertEqual([(w['percent'], w['resetsText']) for w in older['windows']], [(7, None), (53, '週日上午11:00 重設')])
        # No file at all: the button alone; neither: nothing.
        self.assertEqual(h.merge_claude_usage(None, button, t, t)['windows'], [week])
        self.assertIsNone(h.merge_claude_usage(None, None, None, t))
        # An old sample and no button: the week stays, marked with its time.
        self.assertEqual(h.merge_claude_usage(sample, None, None, t + 86400),
                         {'windows': [sample['windows'][1]], 'sampledAt': h.iso(t)})

    def test_limits_carry_a_mark_of_the_account_and_never_its_id(self):
        hub, _, _, _ = drive(self.fake)
        usage = hub.state()['usage']
        codex, claude = usage['codex']['account'], usage['claude']['account']
        self.assertEqual(codex, h.account_mark('codex', 'demo-account-not-real'))
        self.assertEqual(len(codex), 16)
        self.assertNotIn('demo-account', json.dumps(usage))
        self.assertIsNotNone(claude)
        self.assertNotEqual(h.account_mark('claude', 'x'), h.account_mark('codex', 'x'))
        self.assertIsNone(h.account_mark('codex', None))
        (self.fake.root / 'pc' / 'codex' / 'auth.json').unlink()
        self.assertIsNone(self.sources['codex'].account())

    APP_SERVER = r'''
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get('id') == 1:
        print(json.dumps({'id': 1, 'result': {'userAgent': 'stand-in'}}), flush=True)
    elif message.get('method') == 'account/rateLimits/read':
        print(json.dumps({'method': 'account/updated', 'params': {}}), flush=True)
        print(json.dumps({'id': 2, 'result': {'rateLimits': {'primary': {'usedPercent': 0, 'windowDurationMins': 10080,
              'resetsAt': 1793783001}, 'secondary': None}}}), flush=True)
'''

    def test_codex_limits_come_from_codex_itself_when_newer_than_the_last_reply(self):
        script = self.fake.root / 'app_server.py'
        script.write_text(self.APP_SERVER, encoding='utf-8')
        live = h.CodexLiveLimits([sys.executable, '-I', str(script)], timeout=20)
        live.refresh()
        self.assertEqual(live.latest[1], {'primary': {'used_percent': 0, 'window_minutes': 10080, 'resets_at': 1793783001}})
        codex = self.sources['codex']
        self.assertEqual(codex.usage()['windows'][0]['percent'], 5)  # no live answer yet: the last reply's
        codex.live = live
        usage = codex.usage()
        self.assertEqual(usage['windows'], [{'label': '每週', 'percent': 0, 'resetsAt': h.iso(1793783001), 'resetsText': None}])
        self.assertEqual(usage['sampledAt'], h.iso(live.latest[0]))
        live.latest = (1700000000, live.latest[1])  # an answer older than the last reply loses
        self.assertEqual(codex.usage()['windows'][0]['percent'], 5)

    def test_a_codex_that_does_not_answer_leaves_the_limits_alone(self):
        script = self.fake.root / 'silent.py'
        script.write_text('import sys\nfor line in sys.stdin:\n    pass\n', encoding='utf-8')
        live = h.CodexLiveLimits([sys.executable, '-I', str(script)], timeout=1)
        live.refresh()
        self.assertIsNone(live.latest)
        self.assertIsNone(h.CodexLiveLimits.rollout_shape({'rateLimits': None}))
        missing = h.CodexLiveLimits([str(self.fake.root / 'no-such-codex.exe')])
        missing.refresh()
        self.assertIsNone(missing.latest)

    def test_fake_fresh_usage_is_another_pc_that_read_its_limits_later(self):
        hub, _, _, _ = drive(self.fake)
        usage = h.fake_fresh_usage(hub.usage, 'codex', '37')()
        self.assertEqual(usage['codex']['windows'][0]['percent'], 37)
        self.assertGreater(usage['codex']['sampledAt'], hub.usage()['codex']['sampledAt'])
        self.assertEqual(hub.usage()['codex']['windows'][0]['percent'], 5)  # the original is untouched

    def test_the_watcher_keeps_the_last_usage_button_while_the_window_is_hidden(self):
        hub, driver, watcher, _ = drive(self.fake)
        read_at = watcher.current('claude')['usageAt']
        self.assertIsNotNone(read_at)
        hidden = dict(driver.inspect('claude'), usage=None)
        driver.inspect = lambda app: hidden
        watcher.look('claude')
        self.assertEqual((watcher.current('claude')['usageAt'], '46%' in watcher.current('claude')['usage']), (read_at, True))

    def test_the_usage_card_gives_the_session_limit_and_its_reset_time(self):
        t = 1793200000
        self.assertEqual(h.relative_reset('2 小時 56 分後重設', t), t + 2 * 3600 + 56 * 60)
        self.assertEqual(h.relative_reset('45 分後重設', t), t + 45 * 60)
        self.assertEqual(h.relative_reset('1 天 3 小時後重設', t), t + 86400 + 3 * 3600)
        self.assertIsNone(h.relative_reset('週日上午11:00 重設', t))
        self.assertIsNone(h.relative_reset('後重設', t))
        rows = [{'label': '工作階段限制', 'percent': 5.0, 'reset': '2 小時 56 分後重設'},
                {'label': '每週 · 所有模型', 'percent': 62, 'reset': '週日上午11:00 重設'}, {'label': 'x'}]
        session = {'label': '工作階段', 'percent': 5, 'resetsAt': h.iso(t + 10560), 'resetsText': None}
        week = {'label': '每週', 'percent': 62, 'resetsAt': None, 'resetsText': '週日上午11:00 重設'}
        self.assertEqual(h.card_windows(rows, t, t + 60), [session, week])
        self.assertEqual(h.card_windows(rows, t, t + 10560), [week])  # the session has reset since
        sample = {'windows': [{'label': '5 小時', 'percent': 7, 'resetsAt': None, 'resetsText': None}],
                  'sampledAt': h.iso(t - 86400)}
        button = {'label': '每週 · 所有模型', 'percent': 63, 'resetsText': '週日上午11:00 重設'}
        # The card wins over an older file; a button read after the card gives the week.
        self.assertEqual(h.merge_claude_usage(sample, None, None, t + 60, rows, t),
                         {'windows': [session, week], 'sampledAt': h.iso(t)})
        merged = h.merge_claude_usage(sample, button, t + 30, t + 60, rows, t)
        self.assertEqual([(w['label'], w['percent']) for w in merged['windows']], [('工作階段', 5), ('每週', 63)])
        # A card older than the file, or none, leaves the earlier rules.
        self.assertEqual(h.merge_claude_usage(sample, button, t, t, rows, t - 2 * 86400)['windows'][-1]['percent'], 63)

    def test_claude_4_29_card_rows_keep_their_wording_and_expire(self):
        read = h.datetime(2026, 10, 28, 23, 34).timestamp()  # a Wednesday, local time
        self.assertEqual(h.datetime(2026, 10, 28).weekday(), 2)
        thursday = h.datetime(2026, 10, 29, 2, 20).timestamp()
        self.assertEqual(h.clock_reset('週四上午2:20 重設', read), thursday)
        self.assertEqual(h.clock_reset('週日下午1:05 重設', read), h.datetime(2026, 11, 1, 13, 5).timestamp())
        self.assertEqual(h.clock_reset('週三上午12:00 重設', read), h.datetime(2026, 11, 4, 0, 0).timestamp())
        self.assertIsNone(h.clock_reset('2 小時後重設', read))
        rows = [{'label': '5 小時限制', 'percent': 6, 'reset': '週四上午2:20 重設'},
                {'label': '每週 · Fable', 'percent': 53, 'reset': '週日上午11:00 重設'},
                {'label': '每週', 'percent': 62, 'reset': '週日上午11:00 重設'}]
        shown = h.card_windows(rows, read, read + 60)
        self.assertEqual([(w['label'], w['percent'], w['resetsText'], w['resetsAt']) for w in shown],
                         [('5 小時', 6, '週四上午2:20 重設', None), ('每週 · Fable', 53, '週日上午11:00 重設', None),
                          ('每週', 62, '週日上午11:00 重設', None)])
        self.assertEqual([w['label'] for w in h.card_windows(rows, read, thursday + 1)], ['每週 · Fable', '每週'])

    def test_the_card_is_read_only_while_nobody_uses_the_pc_and_not_too_often(self):
        presence = dict(self.fake.cfg['presence'], idleSeconds=5)
        hub, driver, watcher, _ = drive(self.fake, presence)
        self.assertIsNone(watcher.current('claude').get('card'))  # someone at the PC: not read
        presence['idleSeconds'] = 420
        reads = []
        real = driver.usage_card
        driver.usage_card = lambda app: reads.append(app) or real(app)
        watcher.tick()
        watcher.tick()
        self.assertEqual(reads, ['claude'])  # once, then not again within five minutes
        self.assertEqual(watcher.current('claude')['card'][0]['percent'], 5)
        watcher.last_card_check -= 301
        presence['locked'] = True
        watcher.tick()
        self.assertEqual(reads, ['claude'])  # never on a locked PC

    def test_the_last_usage_button_reading_survives_a_restart(self):
        hub, driver, _, _ = drive(self.fake)
        memory = self.fake.root / 'usage_seen.json'
        watcher = h.UiWatcher(hub, driver, memory=memory)
        watcher.look('claude')
        watcher.check_card()
        saved = json.loads(memory.read_text(encoding='utf-8'))
        self.assertIn('46%', saved['claude']['usage'])
        self.assertEqual(saved['claude']['card'][0]['label'], '工作階段限制')
        hidden = dict(driver.inspect('claude'), usage=None, window=False)
        driver.inspect = lambda app: hidden
        again = h.UiWatcher(hub, driver, memory=memory)  # the helper started again, window in the tray
        again.look('claude')
        self.assertEqual(again.current('claude')['usageAt'], saved['claude']['usageAt'])
        hub.ui, hub.usage_cache = again.current, (0.0, None)
        self.assertEqual(hub.usage()['claude']['windows'][-1]['percent'], 46)
        memory.write_text('not json', encoding='utf-8')
        self.assertEqual(h.UiWatcher(hub, driver, memory=memory).current('claude'), {})

    def test_state_and_events_carry_usage_meta_and_the_weekly_reset_from_the_screen(self):
        hub, _, _, _ = drive(self.fake)
        hub.capabilities = hub.capabilities + ['model']
        state = hub.state()
        # The usage card was read at the first look (nobody at the PC): the session and the week.
        session, week = state['usage']['claude']['windows']
        self.assertEqual((session['label'], session['percent'], session['resetsText']), ('工作階段', 5, None))
        self.assertAlmostEqual(h.datetime.fromisoformat(session['resetsAt'].replace('Z', '+00:00')).timestamp(),
                               time.time() + 2 * 3600 + 56 * 60, delta=120)
        self.assertEqual(week, {'label': '每週', 'percent': 46, 'resetsAt': None, 'resetsText': '週日上午11:00 重設'})
        self.assertEqual(state['usage']['codex']['windows'][0]['percent'], 5)
        self.assertEqual(state['models']['claude'], ['Opus 5.5', 'Sonnet 5.5', 'Haiku 5.5', 'Fable 5.1'])
        self.assertIn('GPT-6.1 Terra', state['models']['codex'])
        page = hub.events('claude', A, 0, '', 0)
        self.assertEqual((page['meta']['model'], page['meta']['context']['percent']), ('Opus 5.5', 18))

    def test_switching_the_model_picks_it_on_screen_and_checks_the_conversation_file(self):
        hub, driver, watcher, runner = drive(self.fake)
        self.assertEqual(runner.submit('model', 'claude', A, {'model': 'GPT-9'})[0], 400)
        self.assertEqual(runner.submit('model', 'codex', X, {'model': 'Opus 5.5'})[0], 400)  # each app its own list
        code, body = runner.submit('model', 'claude', A, {'model': 'Sonnet 5.5'})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified'], status['message']), ('done', True, '已切換為 Sonnet 5.5'))
        self.assertEqual([c[0] for c in driver.calls], ['open', 'set_model'])
        watcher.tick()
        self.assertEqual(hub.events('claude', A, 0, '', 0)['meta']['model'], 'Sonnet 5.5')
        code, body = runner.submit('model', 'claude', A, {'model': 'Sonnet 5.5'})
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '本來就是 Sonnet 5.5')

    def test_codex_switch_trusts_the_button_until_the_next_reply(self):
        hub, driver, watcher, runner = drive(self.fake)
        code, body = runner.submit('model', 'codex', X, {'model': 'GPT-6 Luna'})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified'], status['message']),
                         ('done', True, '已切換為 GPT-6 Luna（下一則回覆起使用）'))
        watcher.tick()
        meta = hub.events('codex', X, 0, '', 0)['meta']
        self.assertEqual((meta['model'], meta['effort'], meta['modelId']), ('GPT-6 Luna', '高', 'gpt-6.1-sol'))

    def test_a_model_switch_waits_for_an_idle_pc(self):
        presence = dict(self.fake.cfg['presence'], idleSeconds=5)
        _, _, _, runner = drive(self.fake, presence)
        self.assertEqual(runner.submit('model', 'claude', A, {'model': 'Haiku 5.5'})[0], 409)
        self.assertEqual(runner.submit('model', 'claude', A, {'model': 'Haiku 5.5', 'force': True})[0], 202)


JPEG = b'\xff\xd8\xff\xe0' + b'demo photo bytes' * 64


class MoreControlsTests(FakeEnvironment):
    """Photos, effort, permission mode, stop, notification links and alerts (0.5.0)."""

    def test_a_photo_is_pasted_from_a_private_file_that_is_removed(self):
        import base64
        hub, driver, _, runner = drive(self.fake)
        before = set(glob_photos())
        code, body = runner.submit('send', 'claude', A, {'text': '看這張', 'image': base64.b64encode(JPEG).decode()})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertIn(('send', 'claude', hub.info('claude', A)['doc'], ('image', len(JPEG))), driver.calls)
        self.assertEqual(set(glob_photos()), before, 'the photo file was left behind')
        self.assertEqual(runner.actions[body['id']]['images'], [], 'the photo stayed in memory')
        # A photo alone (no text) also counts once the transcript shows it.
        body = runner.submit('send', 'codex', X, {'image': base64.b64encode(JPEG).decode()})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['verified'], True)
        bad = runner.submit('send', 'claude', A, {'text': 'x', 'image': base64.b64encode(b'GIF89a...').decode()})
        self.assertEqual(bad[0], 400)
        self.assertEqual(runner.submit('send', 'claude', A, {'text': 'x', 'image': 'not base64!'})[0], 400)

    def test_several_photos_go_in_one_message(self):
        import base64
        hub, driver, _, runner = drive(self.fake)
        before = set(glob_photos())
        photos = [base64.b64encode(JPEG + bytes([n])).decode() for n in range(3)]
        code, body = runner.submit('send', 'claude', A, {'text': '三張', 'images': photos})
        self.assertEqual(code, 202, body)
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['verified'], True)
        self.assertIn(('send', 'claude', hub.info('claude', A)['doc']) + (('image', len(JPEG) + 1),) * 3, driver.calls)
        self.assertEqual(set(glob_photos()), before, 'a photo file was left behind')
        events = hub.events('claude', A, 0, '', 0)['events']
        self.assertEqual([e['text'] for e in events if e['kind'] == 'user'][-4:], ['[圖片]'] * 3 + ['三張'])
        # Photos alone, at most ten, every one a JPEG or PNG.
        self.assertEqual(runner.submit('send', 'codex', X, {'images': photos[:2]})[0], 202)
        self.assertEqual(runner.submit('send', 'claude', A, {'images': photos * 4})[0], 400)
        self.assertEqual(runner.submit('send', 'claude', A, {'images': []})[0], 400)
        self.assertEqual(runner.submit('send', 'claude', A, {'images': photos[:1] + ['bad']})[0], 400)


class FastModeTests(FakeEnvironment):
    """Codex's lightning switch (asked 10/29): read from config.toml, pressed in the model menu."""

    def test_config_says_whether_fast_mode_is_on(self):
        source = self.sources['codex']
        config = source.home / 'config.toml'
        self.assertFalse(source.fast(), 'the fake setup starts with it off')
        config.unlink()
        self.assertIsNone(source.fast(), 'no config file')
        config.write_text('model = "gpt-6.1-sol"\nservice_tier = "default"\n[profiles.quick]\nservice_tier = "fast"\n',
                          encoding='utf-8')
        self.assertFalse(source.fast())
        config.write_text('profile = "quick"\nservice_tier = "default"\n[profiles.quick]\nservice_tier = "fast"\n',
                          encoding='utf-8')
        self.assertTrue(source.fast(), 'the active profile wins')
        config.write_text('service_tier = "ultrafast"  # set from the app\n', encoding='utf-8')
        self.assertTrue(source.fast())

    def test_the_phone_switches_it_and_the_state_shows_it(self):
        hub, driver, _, runner = drive(self.fake)
        (self.sources['codex'].home / 'config.toml').write_text('service_tier = "default"\n', encoding='utf-8')
        self.assertEqual(hub.state()['fast'], {}, 'only once windows can be driven')
        hub.capabilities = hub.capabilities + ['fast']  # as build_driving sets it
        self.assertEqual(hub.state()['fast'], {'codex': False})
        code, body = runner.submit('fast', 'codex', X, {'fast': True})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified'], status['message']), ('done', True, '已切換為快速模式'), status)
        self.assertEqual(hub.state()['fast'], {'codex': True})
        body = runner.submit('fast', 'codex', X, {'fast': True})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '本來就是快速模式')
        self.assertEqual(runner.submit('fast', 'claude', A, {'fast': True})[0], 400, 'Claude has no fast mode')
        self.assertEqual(runner.submit('fast', 'codex', X, {'fast': 'yes'})[0], 400)


class RecentTests(FakeEnvironment):
    """The phone's PC list links straight to each PC's newest conversations (10/29)."""

    def test_a_rollout_written_after_its_index_time_counts_and_leads_the_list(self):
        hub = drive(self.fake)[0]
        written = time.time() + 120
        os.utime(self.sources['codex'].transcript_path(Y), (written, written))
        self.assertEqual({r['id']: r['updatedAt'] for r in self.sources['codex'].list_sessions(50)}[Y], h.iso(written))
        recent = hub.state()['recent']
        self.assertEqual((recent[0]['app'], recent[0]['id'], recent[0]['updatedAt']), ('codex', Y, h.iso(written)))
        self.assertEqual(recent[0]['status'], 'active')  # written within the last minute
        self.assertEqual(recent[0]['title'], '評估 iPhone App 的做法')
        self.assertEqual([r['updatedAt'] for r in recent], sorted((r['updatedAt'] for r in recent), reverse=True))
        self.assertEqual(sum(r['app'] == 'claude' for r in recent), 3, 'three per app')
        self.assertEqual(sum(r['app'] == 'codex' for r in recent), 2, 'Codex has two listed conversations')

    def test_an_app_without_conversations_is_left_out(self):
        hub = drive(self.fake)[0]
        hub.sources['codex'].list_sessions = lambda limit, now=None: []
        self.assertEqual({r['app'] for r in hub.state()['recent']}, {'claude'})


class PopupTests(FakeEnvironment):
    """A window that pops up on the desktop (a firewall question blocked sending, 10/29)."""

    def popup_setup(self, presence=None):
        sent = []
        hub, driver, watcher, runner = drive(self.fake, presence, notify=lambda *a: sent.append(a))
        driver.fake_popups = [dict(h.FAKE_POPUP)]
        sent.clear()
        watcher.tick()
        return hub, driver, watcher, runner, sent

    def test_a_popup_is_told_once_and_listed_for_the_phone(self):
        hub, driver, watcher, _, sent = self.popup_setup()
        self.assertEqual(len(sent), 1, sent)
        title, message = sent[0][0], sent[0][1]
        self.assertIn('Windows 安全性', title)
        self.assertIn('是否要允許', message)
        watcher.tick()
        self.assertEqual(len(sent), 1, 'told again about the same window')
        popups = hub.state()['popups']
        self.assertEqual([(p['title'], p['buttons']) for p in popups], [('Windows 安全性', ['允許', '取消'])])
        self.assertNotIn('hwnd', popups[0])
        driver.fake_popups = []
        watcher.tick()
        self.assertEqual(hub.state()['popups'], [])

    def test_the_phone_presses_one_of_its_buttons(self):
        hub, driver, watcher, runner, sent = self.popup_setup()
        popup = hub.state()['popups'][0]
        self.assertEqual(runner.submit('popup', None, popup['id'], {'button': '刪除'})[0], 400)
        self.assertEqual(runner.submit('popup', None, 'ffffffffffff', {'button': '允許'})[0], 404)
        code, body = runner.submit('popup', None, popup['id'], {'button': '允許'})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertIn('已在電腦上按「允許」', status['message'])
        self.assertIn(('press_popup', 'Windows 安全性', '允許'), driver.calls)
        self.assertEqual(hub.state()['popups'], [])
        self.assertEqual(len(sent), 1, 'a press the phone asked for was notified')

    def test_pressing_needs_no_idle_pc_and_a_gone_window_fails(self):
        presence = dict(self.fake.cfg['presence'], idleSeconds=3)
        hub, driver, watcher, runner, sent = self.popup_setup(presence)
        popup = hub.state()['popups'][0]
        body = runner.submit('popup', None, popup['id'], {'button': '取消'})[1]
        driver.fake_popups = []
        watcher.tick()
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['error']), ('failed', 'popup-gone'), status)
        self.assertIn('⚠️ 手機按電腦上的視窗失敗', sent[-1][0])

    def test_a_send_blocked_by_a_popup_says_so(self):
        class BlockedDriver(h.FakeDriver):
            def send(self, app, doc, text, images=None):
                raise h.ActionError('focus-failed', 'could not bring the window to the front; in front: SecurityHealthHost')
        hub, driver, watcher, runner = drive(self.fake, driver_class=BlockedDriver)
        driver.fake_popups = [dict(h.FAKE_POPUP)]
        watcher.tick()
        body = runner.submit('send', 'claude', A, {'text': 'hello'})[1]
        run_all(runner)
        self.assertIn('電腦上有跳出的視窗擋著', runner.status(body['id'])['message'])

    def test_the_route_takes_a_press(self):
        hub, driver, watcher, runner, _ = self.popup_setup()
        popup = hub.state()['popups'][0]
        server = ThreadingHTTPServer(('127.0.0.1', 0), h.handler_for(hub, h.AuthGate(TOKEN), [ipaddress.ip_network('127.0.0.0/8')], runner))
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        def post(path):
            request = urllib.request.Request(f'http://127.0.0.1:{server.server_address[1]}{path}', method='POST',
                                             data=json.dumps({'button': '允許'}).encode('utf-8'),
                                             headers={'Authorization': f'Bearer {TOKEN}'})
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    return response.status, json.loads(response.read())
            except urllib.error.HTTPError as exc:
                return exc.code, json.loads(exc.read())
        code, body = post(f'/v1/popups/{popup["id"]}/press')
        self.assertEqual((code, body['kind'], body['app']), (202, 'popup', ''), body)
        self.assertEqual(post('/v1/popups/nothex/press')[0], 404)

    def test_effort_and_mode_switch_and_show_in_meta(self):
        hub, driver, watcher, runner = drive(self.fake)
        self.assertEqual(runner.submit('effort', 'codex', X, {'effort': '高'})[1]['error'], 'not-supported')
        self.assertEqual(runner.submit('effort', 'claude', A, {'effort': '極限'})[0], 400)
        body = runner.submit('effort', 'claude', A, {'effort': '超高'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '推理強度已切換為 超高')
        body = runner.submit('mode', 'claude', A, {'mode': '計畫'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '權限模式已切換為 計畫')
        watcher.tick()
        meta = hub.events('claude', A, 0, '', 0)['meta']
        self.assertEqual((meta['effort'], meta['permission']), ('超高', '計畫'))
        body = runner.submit('mode', 'codex', X, {'mode': '要求核准'})[1]
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['verified'], status['message']), (False, '已選「要求核准」（下一則回覆起生效）'))

    def test_a_codex_mode_pick_shows_until_the_next_turn_records_one(self):
        hub, _, watcher, runner = drive(self.fake)
        self.assertIsNone(hub.events('codex', Y, 0, '', 0)['meta']['permission'])
        body = runner.submit('mode', 'codex', Y, {'mode': '代我核准'})[1]
        run_all(runner)
        watcher.tick()
        meta = hub.events('codex', Y, 0, '', 0)['meta']
        self.assertEqual((meta['permission'], meta.get('permissionPending')), ('代我核准', True))
        self.assertEqual(meta['note'], '匯入的舊對話，回覆一次後才有資料')
        # The next turn writes its own mode; from then on the rollout answers, not the pick.
        later = h.iso(time.time() + 5)
        with Path(hub.transcript('codex', Y).path).open('a', encoding='utf-8') as handle:
            handle.write(json.dumps({'timestamp': later, 'type': 'turn_context',
                                     'payload': {'model': 'gpt-6.1-sol', 'approvals_reviewer': 'user'}}) + '\n')
        meta = hub.events('codex', Y, 0, '', 0)['meta']
        self.assertEqual((meta['permission'], meta.get('permissionPending'), meta['model']), ('要求核准', None, 'GPT-6.1 Sol'))
        self.assertNotIn(('codex', Y), hub.chosen_modes)

    def test_an_imported_codex_page_is_recognised_by_its_import_title(self):
        hub, driver, _, runner = drive(self.fake)
        self.assertEqual(hub.info('codex', Y)['aliases'], ['iPhone App 做法評估'])
        body = runner.submit('mode', 'codex', Y, {'mode': '代我核准'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done', runner.status(body['id']))
        self.assertEqual(driver.docs('codex'), ['iPhone App 做法評估'])
        self.assertEqual(hub.info('codex', Y)['doc'], 'iPhone App 做法評估')  # learned: no reopening next time
        opens = len([c for c in driver.calls if c[0] == 'open'])
        body = runner.submit('send', 'codex', Y, {'text': '舊對話也收得到'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done', runner.status(body['id']))
        self.assertEqual(len([c for c in driver.calls if c[0] == 'open']), opens + 1)  # only to bring it up front

    def test_a_codex_page_its_link_opened_under_another_name_counts_unless_taken(self):
        hub, driver, _, runner = drive(self.fake)
        driver.page_titles[Y] = '評估 做法'  # neither its database nor its import title (like 測試 回覆)
        body = runner.submit('mode', 'codex', Y, {'mode': '代我核准'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done', runner.status(body['id']))
        self.assertEqual(hub.info('codex', Y)['doc'], '評估 做法')
        # Already on screen under that unknown name (opened by hand): step away and back to see the link work.
        hub.page_names.clear()
        hub.info_cache.clear()
        before = len(driver.calls)
        body = runner.submit('mode', 'codex', Y, {'mode': '要求核准'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['state'], 'done', runner.status(body['id']))
        self.assertEqual([c[2] for c in driver.calls[before:] if c[0] == 'open'], [Y, X, Y])
        self.assertEqual(hub.info('codex', Y)['doc'], '評估 做法')
        # A page title another conversation goes by is never taken for this one.
        hub.page_names.clear()
        hub.info_cache.clear()
        driver.open_doc['codex'] = '別的頁面'
        driver.page_titles[Y] = hub.info('codex', X)['doc']
        body = runner.submit('mode', 'codex', Y, {'mode': '要求核准'})[1]
        run_all(runner)
        self.assertIn(('invoke', 'codex', '評估 iPhone App 的做法'), driver.calls)  # fell back to the sidebar
        self.assertNotIn(('codex', Y), hub.page_names)

    def test_stop_presses_the_button_only_while_a_turn_runs(self):
        _, driver, watcher, runner = drive(self.fake)
        body = runner.submit('stop', 'claude', A, {})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'not-running')
        runner.submit('send', 'claude', A, {'text': '長任務：慢慢做'})
        run_all(runner)
        watcher.tick()
        self.assertTrue(watcher.current('claude')['running'])
        body = runner.submit('stop', 'claude', A, {})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '已停止')

    def test_an_interrupted_turn_ends_as_a_status_not_a_message(self):
        parser = h.ClaudeParser()
        parser.feed({'type': 'user', 'message': {'role': 'user', 'content': '請寫長文'}})
        self.assertEqual(parser.status, 'working')
        out = parser.feed({'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'text', 'text': '[Request interrupted by user]'}]}})
        self.assertEqual((out, parser.status), ([{'kind': 'status', 'text': '已中止', 'ts': None}], 'idle'))
        out = parser.feed({'type': 'user', 'message': {'role': 'user', 'content': '[Request interrupted by user for tool use]'}})
        self.assertEqual(out[0]['kind'], 'status')

    def test_a_message_sent_during_a_turn_stays_in_the_conversation(self):
        parser = h.ClaudeParser()
        # As Claude 2.1.308 writes it (live 10/28): a queued_command attachment, not a user message.
        out = parser.feed({'type': 'attachment', 'timestamp': '2026-10-28T16:30:30.461Z', 'attachment': {
            'type': 'queued_command', 'commandMode': 'prompt', 'origin': {'kind': 'human'}, 'humanTurn': True,
            'timestamp': '2026-10-28T16:30:30.461Z', 'prompt': [
                {'type': 'text', 'text': '<system-reminder>\nLinked sessions now\n</system-reminder>'},
                {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AAAA'}},
                {'type': 'text', 'text': 'app要更新嗎'}]}})
        self.assertEqual(out, [{'kind': 'user', 'text': '[圖片]', 'ts': '2026-10-28T16:30:30Z'},
                               {'kind': 'user', 'text': 'app要更新嗎', 'ts': '2026-10-28T16:30:30Z'}])
        self.assertEqual(parser.feed({'type': 'attachment', 'attachment': {'type': 'queued_command', 'prompt': '純文字'}})[0]['text'], '純文字')
        # Other attachments, and queued commands that no person sent, are not messages.
        self.assertEqual(parser.feed({'type': 'attachment', 'attachment': {'type': 'queued_command', 'origin': {'kind': 'task'},
                                                                           'prompt': 'x'}}), [])
        self.assertEqual(parser.feed({'type': 'attachment', 'attachment': {'type': 'todo', 'prompt': 'x'}}), [])

    def test_someone_at_the_pc_does_not_block_stop_or_codex_menus(self):
        presence = dict(self.fake.cfg['presence'], idleSeconds=5)
        _, _, _, runner = drive(self.fake, presence)
        self.assertEqual(runner.submit('stop', 'claude', A, {})[0], 202)
        self.assertEqual(runner.submit('mode', 'codex', X, {'mode': '代我核准'})[0], 202)
        self.assertEqual(runner.submit('effort', 'claude', A, {'effort': '低'})[0], 409)

    def test_notifications_carry_a_link_to_the_conversation(self):
        sent = []
        drive(self.fake, notify=lambda *a: sent.append(a))
        prompt = next(s for s in sent if s[0].startswith('🔔'))
        self.assertEqual(prompt[4], h.open_link('示範電腦', 'claude', B, '修正建置錯誤'))
        self.assertTrue(prompt[4].startswith('deskremote://open?pc=%E7%A4%BA'), prompt[4])
        self.assertEqual(h.open_link('辦公室', elevate=True), 'deskremote://open?pc=%E8%BE%A6%E5%85%AC%E5%AE%A4&elevate=1')

    def test_limits_and_context_alert_once_when_they_cross(self):
        sent = []
        hub, _, watcher, _ = drive(self.fake, notify=lambda *a: sent.append(a))
        hub.alerts = {'usage_percent': 50, 'context_percent': 90}
        watcher.check_usage()
        watcher.check_turns()
        self.assertFalse(any(s[0].startswith('⚠️') for s in sent), sent)
        hub.alerts = {'usage_percent': 40, 'context_percent': 10}
        hub.usage_cache = (0.0, None)
        for _ in range(2):
            watcher.check_usage()
            watcher.check_turns()
        warnings = [s[0] for s in sent if s[0].startswith('⚠️')]
        self.assertEqual(warnings, ['⚠️ Claude 額度已用 46%', '⚠️ Claude 上下文快滿了'], warnings)

    def test_state_lists_what_the_phone_may_pick(self):
        hub, _, _, _ = drive(self.fake)
        hub.capabilities = hub.capabilities + ['effort', 'mode', 'stop']
        state = hub.state()
        self.assertEqual(state['efforts'], {'claude': ['低', '中', '高', '超高', '最高', 'Ultracode']})
        self.assertEqual(state['modes']['codex'], ['要求核准', '代我核准'])
        self.assertEqual(state['stop'], ['claude', 'codex'])


def glob_photos():
    return Path(tempfile.gettempdir()).glob('desk-remote-photo-*')


class ScreenCaptureTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'win32', 'captures the real Windows desktop')
    def test_capture_goes_through_a_pipe_and_leaves_no_file(self):
        temp = Path(tempfile.gettempdir())
        before = set(temp.glob('desk-remote-screen-*'))
        data = h.capture_screen()
        self.assertIsNotNone(data, 'no picture (is the PC locked?)')
        self.assertTrue(data.startswith(b'\xff\xd8\xff'), 'not a JPEG')
        self.assertEqual(set(temp.glob('desk-remote-screen-*')), before, 'a screenshot file was written')


class ScreenHttpTests(FakeEnvironment):
    def test_screen_is_a_jpeg_behind_the_token_and_refused_when_locked(self):
        hub = h.Hub('示範電腦', self.sources, h.FixedPresence(self.fake.cfg['presence']))
        server = ThreadingHTTPServer(('127.0.0.1', 0), h.handler_for(hub, h.AuthGate(TOKEN), [ipaddress.ip_network('127.0.0.0/8')]))
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f'http://127.0.0.1:{server.server_address[1]}/v1/screen'

        def fetch(token=TOKEN):
            request = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    return response.status, response.headers.get('Content-Type'), response.read()
            except urllib.error.HTTPError as exc:
                return exc.code, exc.headers.get('Content-Type'), exc.read()
        self.assertEqual(fetch()[0], 404)
        hub.screen = lambda: JPEG
        self.assertEqual(fetch(), (200, 'image/jpeg', JPEG))
        self.assertEqual(fetch('wrong')[0], 401)
        hub.presence = h.FixedPresence(dict(self.fake.cfg['presence'], locked=True))
        self.assertEqual(fetch()[0], 423)
        hub.presence = h.FixedPresence(self.fake.cfg['presence'])
        hub.screen = lambda: None
        self.assertEqual(fetch()[0], 503)


class StringsTests(unittest.TestCase):
    def test_both_apps_have_every_control_name(self):
        strings = h.load_strings()
        for key in ('edit', 'deny', 'allow_once', 'new'):
            self.assertTrue(strings['claude'][key] and strings['codex'][key], key)
        self.assertTrue(strings['claude']['more_allow'])
        self.assertIn('{project}', strings['codex']['new_in_project'])

    def test_powershell_scripts_are_ascii(self):
        scripts = sorted(HERE.parent.glob('*.ps1'))
        self.assertGreaterEqual(len(scripts), 4)
        for script in scripts:
            with self.subTest(script=script.name):
                bad = [n for n, line in enumerate(script.read_bytes().splitlines(), 1) if any(b > 127 for b in line)]
                self.assertEqual(bad, [], 'PowerShell 5.1 misreads non-ASCII scripts without a BOM')


if __name__ == '__main__':
    unittest.main()


