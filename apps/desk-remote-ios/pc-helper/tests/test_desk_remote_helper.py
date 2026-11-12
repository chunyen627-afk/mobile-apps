"""Unit tests for the read-only helper. Run from pc-helper/:  python -m unittest discover -s tests -v

Everything runs on hand-written fixtures (../fixtures/fake-helper); no real conversation is read.
"""
import base64
import ipaddress
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import urllib.error
import urllib.parse
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
        self.gate = h.AuthGate('right-token-' + 'x' * 24, clock=lambda: self.now)

    def test_right_token_passes_and_wrong_is_401(self):
        self.assertIsNone(self.gate.check('Bearer right-token-' + 'x' * 24))
        self.assertEqual(self.gate.check('Bearer nope')[0], 401)
        self.assertEqual(self.gate.check(None)[0], 401)
        self.assertEqual(self.gate.check('Basic right-token-' + 'x' * 24)[0], 401)

    def test_five_wrong_tokens_lock_everything_for_ten_minutes(self):
        codes = [self.gate.check('Bearer wrong')[0] for _ in range(5)]
        self.assertEqual(codes, [401, 401, 401, 401, 429])
        self.assertEqual(self.gate.check('Bearer right-token-' + 'x' * 24)[0], 429)
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
        # The scheduled task's run ("每日收益校正", scheduledTaskId) is not listed (11/1).
        self.assertEqual([r['title'] for r in rows], ['整理專案 README', '修正建置錯誤', '選擇部署方式', '週報草稿'])
        self.assertEqual(self.sources['claude'].warning, 'Claude 對話清單有 1 個檔案無法解析')
        # 週報草稿 was started from 整理專案 README (spawnedFrom): the phone nests it under A.
        self.assertEqual({r['title']: r['parent'] for r in rows}['週報草稿'], A)
        self.assertIsNone(rows[0]['parent'])
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


def codex_question_lines(call_id='call_q1', title='哪一顆行星最靠近太陽？', options=('A. 金星', 'B. 水星', 'C. 火星')):
    """What Codex writes for `request_user_input_async` (live 11/5): the card as an AgentMessage
    carrying `questions`, its words repeated as text, then a plain message and the turn's end."""
    question = {'title': title}
    if options:
        question['options'] = list(options)
    text = title + ''.join(f'\n- {o}' for o in options or [])
    return [{'timestamp': '2026-11-04T16:21:18Z', 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                'type': 'AgentMessage', 'id': call_id, 'content': [{'type': 'Text', 'text': text}],
                'phase': 'final_answer', 'delivery': 'async', 'questions': [question]}}},
            {'timestamp': '2026-11-04T16:21:21Z', 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                'type': 'AgentMessage', 'id': 'msg_after', 'content': [{'type': 'Text', 'text': '請點選你的答案。'}]}}},
            {'timestamp': '2026-11-04T16:21:21Z', 'type': 'event_msg', 'payload': {'type': 'task_complete'}}]


def codex_reply_line(call_id, title, answer):
    item_id = json.dumps(['request_user_input_async', call_id, 0])
    text = ('<send_user_message_question_reply>\n' + json.dumps([{'questionItemId': item_id, 'question': title, 'answer': answer}],
            ensure_ascii=False) + '\n</send_user_message_question_reply>\n')
    return {'timestamp': '2026-11-04T16:22:53Z', 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
        'type': 'UserMessage', 'content': [{'type': 'text', 'text': text}]}}}


def append_lines(path, lines):
    with Path(path).open('a', encoding='utf-8') as handle:
        for line in lines:
            handle.write(json.dumps(line, ensure_ascii=False) + '\n')


class CodexQuestionTests(FakeEnvironment):
    """Codex's option card (`request_user_input_async`): read from the rollout, answered on the PC
    or from the phone, both seen through the reply the card writes (the user asked on 11/5 that
    either place works, since they often sit at the PC)."""

    def test_the_card_is_read_and_its_reply_ends_it(self):
        transcript = h.Transcript(self.sources['codex'].transcript_path(X), h.CodexParser)
        drain(transcript)
        append_lines(transcript.path, codex_question_lines())
        transcript.refresh()
        page = transcript.page(0, '')
        self.assertEqual(page['question'], {'questionId': 'call_q1', 'questions': [
            {'question': '哪一顆行星最靠近太陽？', 'header': None, 'multiSelect': False,
             'options': [{'label': 'A. 金星', 'description': None}, {'label': 'B. 水星', 'description': None},
                         {'label': 'C. 火星', 'description': None}]}]})
        texts = [e['text'] for e in page['events']]
        self.assertNotIn('哪一顆行星最靠近太陽？\n- A. 金星\n- B. 水星\n- C. 火星', texts, 'the card is not a message too')
        self.assertIn('請點選你的答案。', texts)
        # Answered on the PC (or by the worker): the card's reply is a user message with a tag.
        append_lines(transcript.path, [codex_reply_line('call_q1', '哪一顆行星最靠近太陽？', 'B. 水星')])
        transcript.refresh()
        page = transcript.page(0, '')
        self.assertIsNone(page['question'])
        self.assertEqual((page['events'][-1]['kind'], page['events'][-1]['text']), ('status', '已回答選項題：B. 水星'))
        self.assertFalse([e for e in page['events'] if 'send_user_message_question_reply' in e['text']])

    def test_a_question_without_options_takes_words_and_a_plain_message_ends_it(self):
        transcript = h.Transcript(self.sources['codex'].transcript_path(X), h.CodexParser)
        drain(transcript)
        append_lines(transcript.path, codex_question_lines('call_q2', '兩片板子之間的間距是多少 mm？', ()))
        transcript.refresh()
        question = transcript.page(0, '')['question']
        self.assertEqual((question['questionId'], question['questions'][0]['options']), ('call_q2', []))
        # The person typed something else instead: the card is no longer what comes next.
        append_lines(transcript.path, [{'timestamp': '2026-11-04T16:30:00Z', 'type': 'event_msg', 'payload': {
            'type': 'item_completed', 'item': {'type': 'UserMessage', 'content': [{'type': 'text', 'text': '殼上下鎖起來就好'}]}}}])
        transcript.refresh()
        page = transcript.page(0, '')
        self.assertIsNone(page['question'])
        self.assertEqual(page['events'][-1]['text'], '殼上下鎖起來就好')

    def test_an_older_rollout_reads_the_question_from_the_tool_call(self):
        parser = h.CodexParser()
        call = {'type': 'response_item', 'payload': {'type': 'function_call', 'name': 'request_user_input_async',
                'arguments': json.dumps({'questions': [{'title': '要用哪種線材？', 'options': ['PLA', 'PETG']}]}),
                'call_id': 'call_old'}}
        self.assertEqual(parser.feed(call), [], 'a card, not a tool row')
        self.assertEqual([o['label'] for o in parser.question['questions'][0]['options']], ['PLA', 'PETG'])
        out = parser.feed({'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': 'call_old',
                                                                 'output': '{"accepted":true}'}})
        self.assertEqual(out, [], 'the card being up is not a result')
        reply = codex_reply_line('call_old', '要用哪種線材？', 'PETG')['payload']['item']['content'][0]['text']
        out = parser.feed({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': reply}})
        self.assertEqual((out[0]['kind'], out[0]['text'], parser.question), ('status', '已回答選項題：PETG', None))
        self.assertIsNone(h.codex_reply('普通訊息'))
        self.assertEqual(h.codex_reply('<send_user_message_question_reply>\nnot json\n</send_user_message_question_reply>'), [])

    def test_codexs_question_is_answered_from_the_phone(self):
        hub, driver, _, runner = drive(self.fake)
        path = hub.sources['codex'].transcript_path(X)
        append_lines(path, codex_question_lines())
        hub.transcript('codex', X).refresh()
        self.assertEqual(hub.transcript('codex', X).page(0, '')['question']['questionId'], 'call_q1')
        def submit(answers):
            return runner.submit('answer', 'codex', X, {'questionId': 'call_q1', 'answers': answers})
        self.assertEqual(submit([{'labels': ['A. 金星', 'B. 水星']}])[0], 400, 'one pick per Codex question')
        self.assertEqual(submit([{'labels': ['D. 木星']}])[0], 400)
        code, body = submit([{'labels': ['B. 水星']}])
        self.assertEqual(code, 202)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['message']), ('done', '已回答'), status)
        self.assertIn(('answer_question', 'codex', 'call_q1'), driver.calls)
        page = hub.transcript('codex', X).page(0, '')
        self.assertIsNone(page['question'])
        self.assertIn('已回答選項題：B. 水星', [e['text'] for e in page['events']])
        self.assertEqual(submit([{'labels': ['B. 水星']}])[1]['error'], 'question-changed')
        # Words instead of an option go through the same path.
        append_lines(path, codex_question_lines('call_q3', '間距多少？', ()))
        hub.transcript('codex', X).refresh()
        code, body = runner.submit('answer', 'codex', X, {'questionId': 'call_q3', 'answers': [{'labels': [], 'other': '12 mm'}]})
        self.assertEqual(code, 202)
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '已回答')
        self.assertIn('已回答選項題：12 mm', [e['text'] for e in hub.transcript('codex', X).page(0, '')['events']])

    def test_a_new_codex_question_is_notified_once(self):
        sent = []
        hub, _, watcher, _ = drive(self.fake, notify=lambda *a: sent.append(a))
        append_lines(hub.sources['codex'].transcript_path(X), codex_question_lines())
        watcher.check_turns()
        watcher.check_turns()
        self.assertEqual([s[0] for s in sent if s[0].startswith('❓')], ['❓ Codex 在等你選擇'])


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
    watcher.screen_in_use = lambda: False  # not what plays on the PC running the tests
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
        self.assertEqual(driver.calls, [('launch', 'codex', False)])
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
        self.assertEqual(driver.calls, [('launch', 'codex', False)])

    def test_launch_with_no_window_fails_quietly(self):
        class DeadDriver(h.FakeDriver):
            def launch(self, app, again=False):
                self.calls.append(('launch', app, again))
        sent = []
        _, _, _, runner = drive(self.fake, self.closed_presence(), driver_class=DeadDriver,
                                notify=lambda *a: sent.append(a))
        runner.clock = FastClock()
        sent.clear()  # the fixture's waiting permission question was announced when it was seen
        body = runner.submit('launch', 'codex', None, {})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['error'], 'app-not-running')
        self.assertEqual(sent, [])  # the phone asked on its own and shows it
        self.assertEqual(runner.driver.calls, [('launch', 'codex', False), ('launch', 'codex', True)], 'no second try')

    def test_codex_from_the_tray_gets_a_second_try_with_its_exe(self):
        class OldBuildDriver(h.FakeDriver):
            # The Start menu entry does nothing while an older Codex build runs (office 10/29).
            def launch(self, app, again=False):
                self.calls.append(('launch', app, again))
                if again:
                    self.windows()[app] = True
        _, driver, _, runner = drive(self.fake, self.closed_presence(), driver_class=OldBuildDriver)
        runner.clock = FastClock()
        body = runner.submit('launch', 'codex', None, {})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '已在電腦上開啟桌面版')
        self.assertEqual(driver.calls, [('launch', 'codex', False), ('launch', 'codex', True)])

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

    def test_a_new_conversation_starts_with_the_chosen_model_and_effort(self):
        """The phone's new-conversation sheet picks a model and effort first (11/8): both are set
        on the empty page before the first message, and the result names them."""
        _, driver, _, runner = drive(self.fake)
        self.assertEqual(runner.submit('new', 'claude', None, {'text': 'x', 'model': 'GPT-6 Sol'})[0], 400)
        self.assertEqual(runner.submit('new', 'codex', None, {'text': 'x', 'effort': '極限'})[0], 400)
        body = runner.submit('new', 'claude', None, {'text': '看一下 README', 'model': 'Sonnet 5.5', 'effort': '高'})[1]
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertEqual(status['message'], '已開新對話（模型 Sonnet 5.5、推理強度 高）')
        self.assertEqual(driver.calls[-3:], [('new_send', 'claude', '新增'), ('set_model', 'claude', 'Sonnet 5.5'),
                                             ('set_effort', 'claude', '高')])
        body = runner.submit('new', 'codex', None, {'text': 'x', 'effort': '超高'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '已開新對話（推理強度 超高）')
        self.assertEqual(driver.calls[-1], ('set_effort', 'codex', '超高'))

    def test_codexs_effort_is_switched_from_the_phone(self):
        """Codex's effort is a slider in its model menu (11/8): clicked at the effort's tick, and
        reported as taking effect from the next reply, like its model."""
        _, driver, _, runner = drive(self.fake)
        body = runner.submit('effort', 'codex', X, {'effort': '高'})[1]
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertEqual(status['message'], '推理強度已切換為 高（下一則回覆起使用）')
        self.assertIn(('set_effort', 'codex', '高'), driver.calls)
        body = runner.submit('effort', 'codex', X, {'effort': '高'})[1]
        run_all(runner)
        self.assertEqual(runner.status(body['id'])['message'], '本來就是 高')

    def test_questions_are_notified_but_not_what_the_phone_did(self):
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
        self.assertEqual([s[0] for s in sent if s[0].startswith('⚠️')], [], 'the phone shows its own failures (11/02)')
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


class LanTests(FakeEnvironment):
    def test_lan_binding_from_config_or_the_default_route(self):
        base = {'bind_ip': '10.1.2.3', 'port': 18790}
        self.assertIsNone(h.lan_binding(base))
        self.assertIsNone(h.lan_binding(dict(base, lan={'enabled': False, 'bind_ip': '192.168.1.5'})))
        self.assertEqual(h.lan_binding(dict(base, lan={'enabled': True, 'bind_ip': '192.168.1.5'})),
                         ('192.168.1.5', ipaddress.ip_network('192.168.1.0/24')))
        self.assertEqual(h.lan_binding(dict(base, lan={'enabled': True, 'bind_ip': '192.168.1.5', 'prefix': 16})),
                         ('192.168.1.5', ipaddress.ip_network('192.168.0.0/16')))
        self.assertEqual(h.lan_binding(dict(base, lan={'enabled': True}), lan_address=lambda: '192.168.1.7'),
                         ('192.168.1.7', ipaddress.ip_network('192.168.1.0/24')))
        # No default route, the ZeroTier address itself, loopback, 0.0.0.0 and junk: nothing to add.
        for bad in (None, '10.1.2.3', '127.0.0.1', '0.0.0.0', 'nope'):
            with self.subTest(bad=bad):
                self.assertIsNone(h.lan_binding(dict(base, lan={'enabled': True}), lan_address=lambda: bad))

    def test_lan_listener_accepts_that_network_and_state_reports_it(self):
        hub = h.Hub('示範電腦', self.sources, h.FixedPresence(self.fake.cfg['presence']))
        self.assertEqual(hub.state()['pc']['lanHost'], None)
        probe = socket.socket(); probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]; probe.close()
        cfg = {'bind_ip': '10.1.2.3', 'port': port, 'lan': {'enabled': True}}
        # Only the ZeroTier network is allowed on its own; the listener adds the LAN one it sits in.
        thread = h.serve_lan(hub, h.AuthGate(TOKEN), cfg, [ipaddress.ip_network('10.1.0.0/16')], None,
                             ('127.0.0.1', ipaddress.ip_network('127.0.0.0/8')))
        self.assertTrue(thread.ready.wait(5))
        self.assertEqual(hub.lan, ('127.0.0.1', port))
        request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/state', headers={'Authorization': f'Bearer {TOKEN}'})
        with urllib.request.urlopen(request, timeout=10) as response:
            body = json.loads(response.read())
        self.assertEqual((body['pc']['lanHost'], body['pc']['lanPort']), ('127.0.0.1', port))
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=10) as response:
            self.assertEqual(json.loads(response.read()), {'ok': True})


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
        gate = h.AuthGate(TOKEN)
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

    def test_one_connection_serves_several_requests(self):
        """HTTP/1.1 keep-alive (helper 0.5.39): the phone reuses its connection for the next
        long-poll instead of a new TCP handshake per request, which stalled for seconds whenever
        the phone's Wi-Fi was busy (AirPlay, 11/8). Pictures and errors ride the same connection."""
        import http.client
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_address[1], timeout=20)
        self.addCleanup(connection.close)
        for n, (path, token, expected) in enumerate([('/v1/state', TOKEN, 200), ('/v1/state', 'wrong', 401),
                                                     (f'/v1/claude/sessions/{A}/events?after=0', TOKEN, 200),
                                                     ('/v1/claude/sessions', TOKEN, 200), ('/health', None, 200)]):
            connection.request('GET', path, headers={'Authorization': f'Bearer {token}'} if token else {})
            response = connection.getresponse()
            body = response.read()
            self.assertEqual((n, response.status), (n, expected))
            self.assertEqual(response.version, 11)
            self.assertEqual(int(response.getheader('Content-Length')), len(body))
            self.assertNotEqual((response.getheader('Connection') or '').lower(), 'close', f'request {n} closed the connection')
        self.assertIsNotNone(connection.sock, 'the client kept the one connection')
        # A POST on the same connection too (its body is read before the answer).
        connection.request('POST', f'/v1/claude/sessions/{A}/messages', body=json.dumps({'text': 'keep-alive 測試'}).encode(),
                           headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
        response = connection.getresponse()
        response.read()
        self.assertEqual(response.status, 202)

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
        self.assertEqual(self.sources['claude'].context_window('claude-fable-5-1'), 1_000_000)  # the phone showed "52.4 萬" without a % (10/31)
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

    def test_a_per_model_week_on_the_button_does_not_pass_for_the_all_models_week(self):
        # Live 11/2 (Claude 4.29, a Team plan with a Fable week): the button read "每週 · Fable：23%"
        # after the card, and the phone showed 每週 23% in place of the card's 21%.
        t = 1793600000
        rows = [{'label': '5 小時限制', 'percent': 5, 'reset': '於 下午10:30 重設'},
                {'label': '每週 · 所有模型', 'percent': 21, 'reset': '週日上午11:00 重設'},
                {'label': '每週 · Fable', 'percent': 22, 'reset': '週日上午11:00 重設'}]
        button = h.ui_usage('使用量：每週 · Fable：23% 週日上午11:00 重設', '使用量：')
        self.assertEqual(button, {'label': '每週 · Fable', 'percent': 23, 'resetsText': '週日上午11:00 重設'})
        merged = h.merge_claude_usage(None, button, t + 30, t + 60, rows, t)
        self.assertEqual([(w['label'], w['percent']) for w in merged['windows']],
                         [('5 小時', 5), ('每週', 21), ('每週 · Fable', 23)])  # the card's order, Fable's row renewed
        # Read before the card, the button changes nothing.
        older = h.merge_claude_usage(None, button, t - 30, t + 60, rows, t)
        self.assertEqual([(w['label'], w['percent']) for w in older['windows']], [('5 小時', 5), ('每週', 21), ('每週 · Fable', 22)])
        # Without a card, the file's all-models week stays and the button's row is added after it.
        sample = {'windows': [{'label': '每週', 'percent': 40, 'resetsAt': None, 'resetsText': None}], 'sampledAt': h.iso(t)}
        merged = h.merge_claude_usage(sample, button, t + 30, t + 60)
        self.assertEqual([(w['label'], w['percent'], w['resetsText']) for w in merged['windows']],
                         [('每週', 40, None), ('每週 · Fable', 23, '週日上午11:00 重設')])
        self.assertEqual(merged['sampledAt'], h.iso(t))
        # An all-models button still replaces the file's week, as before.
        all_models = h.ui_usage('使用量：每週 · 所有模型：41% 週日上午11:00 重設', '使用量：')
        merged = h.merge_claude_usage(sample, all_models, t + 30, t + 60)
        self.assertEqual([(w['label'], w['percent']) for w in merged['windows']], [('每週', 41)])

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
        # Hands off the keyboard while a video plays (user 11/10: the card blinked over it): the
        # card waits, and is read as soon as the video ends, not five minutes later.
        presence['locked'] = False
        watcher.screen_in_use = lambda: True
        with self.assertLogs(level='INFO') as logs:
            watcher.tick()
            watcher.tick()
        self.assertEqual(reads, ['claude'])
        self.assertEqual(sum('usage card not read' in line for line in logs.output), 1)  # said once
        watcher.screen_in_use = lambda: False
        watcher.tick()
        self.assertEqual(reads, ['claude', 'claude'])
        # Two PCs on one account (asked 11/10): the one idle longest reads the card, the other
        # leaves it, through notes in the shared clipboard folder. 家裡 idle 15 minutes: left to it.
        shared = self.fake.root / 'shared'
        watcher.board = h.IdleBoard(shared, '示範電腦')
        home = h.IdleBoard(shared, '家裡')
        home.note(900, False, False)
        watcher.last_card_check -= 301
        with self.assertLogs(level='INFO') as logs:
            watcher.tick()
        self.assertEqual(reads, ['claude', 'claude'])
        self.assertTrue(any('家裡 is idle longer' in line for line in logs.output), logs.output)
        mine = json.loads((shared / '_idle_示範電腦.json').read_text(encoding='utf-8'))
        self.assertEqual((mine['pc'], mine['idleSeconds'], mine['locked'], mine['busy']), ('示範電腦', 420, False, False))
        # 家裡 in use again (idle 30 s): this PC reads. A note from a PC that is busy with a video,
        # or older than three minutes (off, or not syncing), does not count either.
        home.noted = None
        home.note(30, False, False)
        watcher.tick()
        self.assertEqual(reads, ['claude', 'claude', 'claude'])
        home.noted = None
        home.note(900, False, True)
        watcher.last_card_check -= 301
        watcher.tick()
        self.assertEqual(reads, ['claude'] * 4)
        home.clock = lambda: time.time() - 400
        home.noted = None
        home.note(9000, False, False)
        watcher.last_card_check -= 301
        watcher.tick()
        self.assertEqual(reads, ['claude'] * 5)

    def test_the_last_usage_button_reading_survives_a_restart(self):
        hub, driver, _, _ = drive(self.fake)
        memory = self.fake.root / 'usage_seen.json'
        watcher = h.UiWatcher(hub, driver, memory=memory)
        watcher.screen_in_use = lambda: False
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


class VersionTests(FakeEnvironment):
    """Always the newest desktop apps (asked 10/30): an old Codex restarts when nothing is lost,
    a new Claude is only told about."""

    def version_setup(self, idle=900, **versions):
        sent = []
        presence = dict(self.fake.cfg['presence'], idleSeconds=idle)
        hub, driver, watcher, runner = drive(self.fake, presence, notify=lambda *a: sent.append(a))
        hub.versions = watcher.version_list
        driver.fake_versions = versions
        sent.clear()
        driver.calls.clear()
        watcher.versions_checked = None
        # The fixture keeps one Codex conversation being written: let it be idle here.
        watcher.hub.sources['codex'].list_sessions = lambda limit, now=None: [{'id': X, 'status': 'idle'}]
        return hub, driver, watcher, sent, presence

    def test_an_old_codex_restarts_into_the_installed_one_when_idle(self):
        hub, driver, watcher, sent, _ = self.version_setup(codex=('26.1023.6123.0', '26.1016.6573.0'))
        watcher.check_versions(now=1000)
        self.assertIn(('restart', 'codex'), driver.calls)
        self.assertEqual(sent, [], 'a restart that worked is not news')
        watcher.check_versions(now=1061)
        self.assertEqual(hub.state()['versions']['codex'],
                         {'installed': '26.1023.6123.0', 'running': '26.1023.6123.0', 'update': False, 'pending': None,
                          'downloaded': None, 'notice': None})
        watcher.check_versions(now=1400)
        self.assertEqual(driver.calls.count(('restart', 'codex')), 1)

    def test_codex_waits_while_someone_uses_the_pc_or_a_turn_runs(self):
        _, driver, watcher, _, presence = self.version_setup(idle=30, codex=('26.1023.6123.0', '26.1016.6573.0'))
        watcher.check_versions(now=1000)
        self.assertNotIn(('restart', 'codex'), driver.calls, 'someone is at the PC')
        presence['idleSeconds'] = 900
        watcher.hub.sources['codex'].list_sessions = lambda limit, now=None: [{'id': X, 'status': 'active'}]
        watcher.check_versions(now=1061)
        self.assertNotIn(('restart', 'codex'), driver.calls, 'a reply is being written')
        watcher.hub.sources['codex'].list_sessions = lambda limit, now=None: [{'id': X, 'status': 'idle'}]
        watcher.busy = lambda: True
        watcher.check_versions(now=1122)
        self.assertNotIn(('restart', 'codex'), driver.calls, 'a phone action is queued')
        watcher.busy = lambda: False
        watcher.check_versions(now=1183)
        self.assertIn(('restart', 'codex'), driver.calls)

    def test_a_restart_that_does_not_take_is_not_notified(self):
        _, driver, watcher, sent, _ = self.version_setup(codex=('26.1023.6123.0', '26.1016.6573.0'))
        driver.restart_sticks = True
        for now in (1000, 1100, 1200, 1300):
            watcher.check_versions(now=now)
        self.assertEqual(sent, [], 'nothing waits on an approval (11/02)')
        self.assertEqual(driver.calls.count(('restart', 'codex')), 1, 'tried once per version')

    def test_a_codex_that_does_not_start_again_is_tried_once(self):
        _, driver, watcher, sent, _ = self.version_setup(codex=('26.1023.6123.0', '26.1016.6573.0'))

        def dead(app):
            driver.calls.append(('restart', app))
            raise h.ActionError('restart-failed', 'Codex did not start again')
        driver.restart_app = dead
        watcher.check_versions(now=1000)
        watcher.check_versions(now=1300)
        self.assertEqual(sent, [])
        self.assertEqual(driver.calls.count(('restart', 'codex')), 1)

    def test_a_new_claude_is_only_shown_and_never_restarted(self):
        hub, driver, watcher, sent, _ = self.version_setup(claude=('4.30.0.0', '4.29.0.0'))
        watcher.check_versions(now=1000)
        watcher.check_versions(now=1100)
        self.assertNotIn(('restart', 'claude'), driver.calls)
        self.assertEqual(sent, [], 'shown on the PC page, not notified (11/02)')
        self.assertTrue(hub.state()['versions']['claude']['update'])

    def test_claudes_update_button_is_pressed_only_from_the_phone(self):
        hub, driver, watcher, sent, _ = self.version_setup(claude=('3.6556.2.0', '3.6556.2.0'))
        driver.fake_update = {'claude': '重新啟動以更新 v4.29.0'}
        watcher.look('claude')
        watcher.check_versions(now=1000)
        watcher.check_versions(now=1100)
        self.assertNotIn('press_update', [c[0] for c in driver.calls], 'never pressed on its own')
        self.assertEqual(sent, [])
        shown = hub.state()['versions']['claude']
        self.assertEqual((shown['update'], shown['pending']), (True, '4.29.0'))
        runner = h.ActionRunner(hub, driver, hub.presence, watcher, None, '示範電腦', hub.strings,
                                verify_seconds=3, doc_wait=1, settle_seconds=0)
        self.assertEqual(runner.submit('update', 'codex', None, {})[0], 400, 'Codex updates itself')
        code, body = runner.submit('update', 'claude', None, {})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertIn('4.29.0', status['message'])
        self.assertIn(('press_update', 'claude', '重新啟動以更新 v4.29.0', None), driver.calls)
        watcher.look('claude')
        self.assertEqual(runner.submit('update', 'claude', None, {})[1]['error'], 'no-update')

    def test_claudes_question_about_running_work_is_answered_from_the_phone(self):
        """Claude Code still working: Claude asks before restarting (10/30). The update ends at
        once with a note, the question is a pop-up the phone answers, and no notification goes."""
        hub, driver, watcher, sent, _ = self.version_setup(claude=('3.6556.2.0', '3.6556.2.0'))
        driver.fake_update = {'claude': '重新啟動以更新 v4.29.0'}
        driver.fake_update_guard = True
        watcher.look('claude')
        watcher.check_versions(now=1000)
        sent.clear()
        runner = h.ActionRunner(hub, driver, hub.presence, watcher, None, '示範電腦', hub.strings,
                                verify_seconds=3, doc_wait=1, settle_seconds=0)
        status = self.finish(runner, runner.submit('update', 'claude', None, {}))
        self.assertEqual((status['state'], status['verified']), ('done', False), status)
        self.assertIn('取消', status['message'])
        popups = hub.state()['popups']
        self.assertEqual([p['buttons'] for p in popups], [['取消', '等待 Claude', '仍要更新']], popups)
        watcher.check_popups()
        self.assertEqual(sent, [], 'the phone is already looking at it')
        # 取消: nothing changes and the button stays.
        status = self.finish(runner, runner.submit('popup', None, popups[0]['id'], {'button': '取消'}))
        self.assertEqual(status['state'], 'done', status)
        watcher.look('claude')
        self.assertEqual(driver.versions()['claude']['running'], '3.6556.2.0')
        self.assertEqual(hub.state()['popups'], [])
        # Asked again and told to update anyway: it updates.
        self.finish(runner, runner.submit('update', 'claude', None, {}))
        popup = hub.state()['popups'][0]
        self.finish(runner, runner.submit('popup', None, popup['id'], {'button': '仍要更新'}))
        self.assertEqual(driver.versions()['claude']['running'], '4.29.0')

    def test_a_downloaded_update_without_a_button_is_only_told(self):
        """Office 10/30: the updater swapped the waiting 4.29 for 4.4212 and the button never came
        back. Its log still says what is downloaded: shown after the version, to do it at the PC
        (the user's choice after the phone's close-and-start route proved fiddly); no button."""
        hub, driver, watcher, sent, _ = self.version_setup(claude=('3.6556.2.0', '3.6556.2.0'))
        driver.fake_downloaded = '4.4212.0'
        watcher.look('claude')
        watcher.check_versions(now=1000)
        watcher.versions_checked = None
        watcher.check_versions(now=1100)
        shown = hub.state()['versions']['claude']
        self.assertEqual((shown['update'], shown['pending'], shown['downloaded']), (False, None, '4.4212.0'), shown)
        self.assertEqual(shown['notice'], '新版 4.4212.0 已下載：到電腦上把 Claude 關掉再打開', 'after the version on the phone')
        self.assertEqual(sent, [], 'shown, not notified (11/02)')
        runner = h.ActionRunner(hub, driver, hub.presence, watcher, None, '示範電腦', hub.strings,
                                verify_seconds=3, doc_wait=1, settle_seconds=0)
        self.assertEqual(runner.submit('update', 'claude', None, {})[1]['error'], 'no-update')
        # Done at the PC: nothing more to tell. An older downloaded version (the log is behind) means nothing.
        driver.fake_versions = {'claude': ('4.4212.0.0', '4.4212.0.0')}
        driver.fake_downloaded = '4.29.0'
        watcher.versions_checked = None
        watcher.check_versions(now=2000)
        self.assertEqual(hub.state()['versions']['claude']['downloaded'], None)
        self.assertEqual(sent, [])

    def test_the_downloaded_version_is_read_from_claudes_log(self):
        log = ("2026-10-28 05:04:45 [info] [updater] Update downloaded and ready to install { releaseName: 'Claude 4.29.0' }\n"
               "2026-10-30 13:14:46 [info] [updater] [evt:replacing-staged] Newer version 4.4212.0 available (staged: 4.29.0), replacing staged update\n"
               "2026-10-30 13:14:59 [info] [updater] Update downloaded and ready to install { releaseName: 'Claude 4.4212.0' }\n"
               "2026-10-30 15:24:59 [info] [updater] Staged version 4.4212.0 is still current (latest: 4.4212.0, lastTarget: 4.4212.0)\n")
        self.assertEqual(h.downloaded_version(log), '4.4212.0')
        self.assertIsNone(h.downloaded_version('2026-10-30 [info] [updater] Checking for updates\n'))

    def test_claude_for_chromes_read_permission_is_allowed_by_the_helper(self):
        """The extension asks before reading every site (10/31): the helper presses "Allow this
        action" itself, tells nobody and lists nothing; a card without that button is listed for the phone."""
        hub, driver, watcher, sent, _ = self.version_setup(idle=900)
        driver.fake_popups = [dict(h.FAKE_EXTENSION_READ)]
        self.assertEqual(watcher.check_popups(), [])
        self.assertIn(('press_popup', 'Claude for Chrome', 'Allow this action'), driver.calls)
        self.assertEqual((sent, hub.state()['popups']), ([], []))
        self.assertEqual(driver.fake_popups, [], 'the card was pressed away')
        # Every card of the extension's window is allowed, words drawn or not (some still reached
        # the phone when only the "read page content" wording counted, 10/31 evening).
        for text in ('New permissions required', 'New permissions required\nClaude wants to fill forms on:\ns.example.com'):
            driver.fake_popups = [dict(h.FAKE_EXTENSION_READ, hwnd=4348, text=text)]
            self.assertEqual(watcher.check_popups(), [])
        self.assertEqual(sent, [])
        self.assertEqual(driver.calls.count(('press_popup', 'Claude for Chrome', 'Allow this action')), 3)
        # A window of the extension without the allow button is an ordinary pop-up: listed, not notified.
        driver.fake_popups = [dict(h.FAKE_EXTENSION_READ, hwnd=4349, buttons=['OK'])]
        listed = watcher.check_popups()
        self.assertEqual([p['buttons'] for p in listed], [['OK']])
        self.assertEqual(sent, [])
        # The quick look between full ones (every second or two) presses it too.
        driver.fake_popups = [dict(h.FAKE_EXTENSION_READ, hwnd=4350)]
        watcher.check_extension()
        self.assertEqual(driver.fake_popups, [])
        self.assertEqual(driver.calls.count(('press_popup', 'Claude for Chrome', 'Allow this action')), 4)

    def test_only_a_pop_up_asking_for_permission_is_notified(self):
        # 11/01: property sheets, an error box and the snipping tool all reached the phone; the
        # user asked 11/02 for notifications only when something waits on their approval.
        _, driver, watcher, sent, presence = self.version_setup(idle=900)
        driver.fake_popups = [dict(h.FAKE_QUIT_GUARD),
                              {'hwnd': 5001, 'title': 'game.exe - 內容', 'process': 'explorer', 'text': '檔案類型:',
                               'buttons': ['確定', '取消', '套用(&A)']}]
        self.assertEqual(len(watcher.check_popups()), 2, 'still listed for the phone')
        self.assertEqual(sent, [])
        driver.fake_popups = [dict(h.FAKE_POPUP)]
        watcher.check_popups()
        self.assertEqual([s[0] for s in sent], ['🪟 電腦跳出視窗在等你允許：Windows 安全性'])

    def test_a_permission_question_inside_an_apps_page_is_told_only_when_nobody_is_at_the_pc(self):
        _, driver, watcher, sent, presence = self.version_setup(idle=30)
        asks = dict(h.FAKE_POPUP, page=True)
        driver.fake_popups = [asks]
        watcher.check_popups()
        self.assertEqual(sent, [], 'the person at the PC sees it (or opened it)')
        self.assertTrue(watcher.popup_list(), 'still listed for the phone')
        presence['idleSeconds'] = 900
        driver.fake_popups = [dict(asks, hwnd=4344)]
        watcher.check_popups()
        self.assertEqual(len(sent), 1, sent)

    def finish(self, runner, submitted):
        code, body = submitted
        self.assertEqual(code, 202, body)
        run_all(runner)
        return runner.status(body['id'])

    def test_an_administrators_window_is_pressed_by_the_elevated_companion(self):
        # Live 11/5: the FlashPrint installer (past UAC) ignored the phone's 下一步; Windows lets no
        # ordinary program press an administrator's window (UIPI). The companion presses it once
        # the person allows, on the PC's own window or on the phone.
        admin = {'hwnd': 4747, 'title': 'FlashPrint 5 安裝', 'process': 'FlashPrint 5_5.8.7_x64',
                 'text': 'Select the setup language:', 'buttons': ['下一步 (N) >', '取消'], 'elevated': True}
        hub, driver, watcher, runner = drive(self.fake)
        hub.elevate = self.fake.elevate_relay()
        before = len(self.fake.elevator.requests)
        driver.fake_popups = [dict(admin)]
        listed = watcher.check_popups()
        self.assertTrue(listed[0]['elevated'])
        self.assertTrue(watcher.popup_list()[0]['text'].endswith(h.ELEVATED_HINT), 'the phone is told')
        status = self.finish(runner, runner.submit('popup', None, listed[0]['id'], {'button': '下一步 (N) >'}))
        self.assertEqual((status['state'], status['verified']), ('done', False), status)
        self.assertIn('提權夥伴代按「下一步 (N) >」', status['message'])
        self.assertFalse([c for c in driver.calls if c[0] == 'press_popup'], 'not pressed by this user')
        asked = [r for r in self.fake.elevator.requests.values() if r['name'] == '按「下一步 (N) >」：FlashPrint 5 安裝']
        self.assertEqual((len(self.fake.elevator.requests) - before, len(asked)), (1, 1))
        self.assertEqual(asked[0]['kind'], 'script')
        self.assertIn("[IntPtr][int64]4747", asked[0]['content'])
        self.assertIn("'下一步 (N) >'", asked[0]['content'])
        self.assertIn('EnumChildWindows', asked[0]['content'])
        self.assertIn('InvokePattern', asked[0]['content'], 'UI Automation as the fallback')
        # Without the companion there is nothing to hand it to: the person presses on the PC.
        hub.elevate = None
        driver.fake_popups = [dict(admin, hwnd=4748)]
        listed = watcher.check_popups()
        status = self.finish(runner, runner.submit('popup', None, listed[0]['id'], {'button': '取消'}))
        self.assertEqual((status['state'], status['error']), ('failed', 'elevated-window'), status)
        self.assertIn('沒裝提權夥伴', status['message'])
        # A question inside an app's page is never that, whatever the worker said.
        driver.fake_popups = [dict(h.FAKE_QUIT_GUARD, elevated=True)]
        self.assertFalse(watcher.check_popups()[0]['elevated'])

    def test_codexs_queued_message_is_a_card_the_phone_steers_in(self):
        """Codex keeps a message typed while it works in a queue with a 引導 button (home PC 11/6):
        listed as a card without a notification; pressing 引導 hands it in."""
        sent = []
        hub, driver, watcher, runner = drive(self.fake, notify=lambda *a: sent.append(a))
        driver.fake_popups = [dict(h.FAKE_QUEUE)]
        sent.clear()
        watcher.tick()
        self.assertEqual(sent, [], 'a queued message is not a permission question')
        popups = hub.state()['popups']
        self.assertEqual([(p['title'], p['text'], p['buttons']) for p in popups],
                         [(h.CODEX_QUEUE_TITLE, '螢幕也有點閃', ['引導', '刪除'])])
        code, body = runner.submit('popup', None, popups[0]['id'], {'button': '引導'})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertIn('已交給 Codex', status['message'])
        self.assertIn(('press_popup', h.CODEX_QUEUE_TITLE, '引導'), driver.calls)
        self.assertEqual(hub.state()['popups'], [])

    def test_a_message_codex_queues_is_reported_with_the_steer_hint(self):
        class BusyDriver(h.FakeDriver):
            def send(self, app, doc, text, images=None):
                self.calls.append(('send', app, doc))
                self.queued = True
                self.fake_popups = [dict(h.FAKE_QUEUE, text=text)]
                return None
        hub, driver, _, runner = drive(self.fake, driver_class=BusyDriver)
        body = runner.submit('send', 'codex', Y, {'text': '螢幕也有點閃'})[1]
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual((status['state'], status['verified']), ('done', True), status)
        self.assertIn('按對話上方', status['message'])
        self.assertIn('引導', status['message'])
        self.assertEqual([p['text'] for p in hub.state()['popups']], ['螢幕也有點閃'], 'the card is listed at once')

    def test_the_press_script_quotes_the_windows_words(self):
        script = h.elevated_press_script(99, "It's here", "Don't")
        self.assertIn("'It''s here'", script)
        self.assertIn("'Don''t'", script)
        self.assertIn('[IntPtr][int64]99', script)

    def test_codexs_own_update_button_is_pressed_when_idle(self):
        _, driver, watcher, _, presence = self.version_setup(idle=30, codex=('26.1021.3705.0', '26.1021.3705.0'))
        driver.fake_update = {'codex': '更新'}
        watcher.look('codex')
        watcher.check_versions(now=1000)
        self.assertEqual([c for c in driver.calls if c[0] == 'press_update'], [], 'someone is at the PC')
        presence['idleSeconds'] = 900
        watcher.check_versions(now=1061)
        self.assertIn(('press_update', 'codex', '更新', '更新'), driver.calls, 'pressed and confirmed')
        driver.fake_update = {'codex': '更新'}
        watcher.look('codex')
        watcher.check_versions(now=1200)
        self.assertEqual(len([c for c in driver.calls if c[0] == 'press_update']), 1, 'not again within the hour')

    def test_codexs_sidebar_update_is_only_shown_while_it_shows(self):
        # Home PC 11/01: the new layout's "update available" (bottom left) was not recognised, so
        # the phone heard nothing. It is shown after the version (not notified since 11/02),
        # never pressed (updates are done at the PC, 10/30).
        _, driver, watcher, sent, _ = self.version_setup(codex=('26.1027.3384.0', '26.1027.3384.0'))
        driver.fake_update = {'codex': '有可用的更新'}
        watcher.look('codex')
        watcher.check_versions(now=1000)
        self.assertEqual([c for c in driver.calls if c[0] == 'press_update'], [], 'never pressed on its own')
        self.assertIn('有可用的更新', watcher.hub.state()['versions']['codex']['notice'], 'after the version on the phone')
        watcher.check_versions(now=1100)
        driver.fake_update = {}
        watcher.look('codex')
        watcher.check_versions(now=1200)
        self.assertIsNone(watcher.hub.state()['versions']['codex']['notice'], 'gone with the button')
        driver.fake_update = {'codex': '有可用的更新'}
        watcher.look('codex')
        watcher.check_versions(now=1300)
        self.assertIn('有可用的更新', watcher.hub.state()['versions']['codex']['notice'], 'a later one is shown again')
        self.assertEqual(sent, [])

    def test_versions_read_from_package_paths(self):
        path = r'C:\Program Files\WindowsApps\OpenAI.Codex_26.1016.6573.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
        self.assertEqual(h.package_version(path, 'OpenAI.Codex'), '26.1016.6573.0')
        self.assertIsNone(h.package_version(path, 'Claude'))
        self.assertLess(h.version_key('26.1016.6573.0'), h.version_key('26.1023.6123.0'))
        self.assertLess(h.version_key('3.6556.2.0'), h.version_key('4.29.0.0'))


class UacTests(FakeEnvironment):
    """A UAC prompt left on the PC (asked 10/29): sending says so and the phone is told once."""

    def uac_setup(self):
        sent = []
        presence = dict(self.fake.cfg['presence'], locked=True, uac=True)
        hub, driver, watcher, runner = drive(self.fake, presence, notify=lambda *a: sent.append(a))
        sent.clear()
        watcher.uac_since = None  # drive()'s first look started the clock on the real time
        return hub, watcher, runner, sent, presence

    def test_sending_is_refused_naming_the_uac_prompt(self):
        hub, _, runner, _, _ = self.uac_setup()
        code, body = runner.submit('send', 'claude', A, {'text': 'hi', 'force': True})
        self.assertEqual((code, body['error']), (423, 'uac'))
        self.assertIn('UAC', body['message'])
        self.assertIn('到電腦前按', body['message'])
        self.assertTrue(hub.state()['presence']['uac'])

    def test_the_phone_is_told_once_when_nobody_answers_it(self):
        _, watcher, _, sent, presence = self.uac_setup()
        watcher.check_uac(now=100)
        watcher.check_uac(now=110)
        self.assertEqual(sent, [], 'someone at the PC gets a moment to answer it')
        watcher.check_uac(now=121)
        watcher.check_uac(now=200)
        self.assertEqual(len(sent), 1, sent)
        self.assertIn('UAC', sent[0][0])
        self.assertIn('到電腦前按', sent[0][1])
        presence.update(locked=False, uac=False)
        watcher.check_uac(now=210)
        presence.update(locked=True, uac=True)
        watcher.check_uac(now=220)
        watcher.check_uac(now=241)
        self.assertEqual(len(sent), 2, 'a new prompt is told again')

    def test_a_plain_lock_stays_a_lock(self):
        presence = dict(self.fake.cfg['presence'], locked=True, uac=False)
        hub, _, _, runner = drive(self.fake, presence)
        self.assertEqual(runner.submit('send', 'claude', A, {'text': 'hi', 'force': True})[1]['error'], 'locked')
        self.assertFalse(hub.state()['presence']['uac'])


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
        self.assertFalse([s for s in sent if s[0].startswith('⚠️')], 'the phone shows its own failure (11/02)')

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
        self.assertEqual(runner.submit('effort', 'codex', X, {'effort': '極限'})[0], 400)
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

    def test_unsent_text_in_the_box_is_replaced_by_the_phones_message(self):
        """The phone's message always wins (the user's rule 10/31): leftover text in the PC's box
        is cleared first, and the result says how much was replaced (never what)."""
        _, driver, _, runner = drive(self.fake)
        driver.fake_box_text = '還沒送出的半句話'
        code, body = runner.submit('send', 'claude', A, {'text': '手機來的', 'clientMsgId': 'r1'})
        self.assertEqual(code, 202, body)
        run_all(runner)
        status = runner.status(body['id'])
        self.assertEqual(status['state'], 'done', status)
        self.assertIn('覆蓋了電腦輸入框裡原本沒送出的 8 個字', status['message'])
        self.assertNotIn('半句話', status['message'])

    def test_the_task_list_and_the_next_step_recap_reach_the_phone(self):
        """update_plan calls become the task list (no tool row), advanced step by step; the
        wrap-up checks it off and carries its recap (asked 11/1, like the desktop)."""
        transcript = h.Transcript(self.fake.root / 'nowhere.jsonl', h.ClaudeParser)
        def use(name, data):
            for event in transcript.parser.feed({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                    {'type': 'tool_use', 'id': 'x', 'name': name, 'input': data}]}}):
                transcript.add(event)
        use('mcp__ccd_turn__update_plan', {'items': [{'content': '讀設定', 'status': 'in_progress'},
                                                      {'content': '改程式', 'status': 'pending'},
                                                      {'content': '跑測試', 'status': 'pending'}], 'scope': 'first_task'})
        self.assertEqual(transcript.page(0, '')['events'], [], 'the plan is not a tool row')
        self.assertEqual([i['status'] for i in transcript.page(0, '')['plan']], ['in_progress', 'pending', 'pending'])
        use('mcp__ccd_turn__update_plan', {'advance': True})
        self.assertEqual([i['status'] for i in transcript.parser.plan], ['completed', 'in_progress', 'pending'])
        use('mcp__ccd_turn__update_plan', {'done': [2], 'start': 3})
        self.assertEqual([i['status'] for i in transcript.parser.plan], ['completed', 'completed', 'in_progress'])
        use('mcp__ccd_turn__wrap_up', {'recap': '都改好了，還沒發布。', 'ask': '要發布嗎？',
                                       'actions': [{'label': '發布'}, {'label': '先不發'}]})
        page = transcript.page(0, '')
        self.assertEqual([i['status'] for i in page['plan']], ['completed'] * 3)
        self.assertEqual(page['suggestions'], {'ask': '要發布嗎？', 'recap': '都改好了，還沒發布。',
                                               'replies': [{'label': '發布', 'message': '發布'}, {'label': '先不發', 'message': '先不發'}]})
        # A wrap-up with a recap but no reply buttons still shows its recap.
        self.assertEqual(h.suggestions_from({'recap': '完成了。'}), {'ask': None, 'replies': [], 'recap': '完成了。'})
        self.assertIsNone(h.suggestions_from({'actions': [{'label': 'x', 'action': 'commit'}]}))

    def test_pictures_in_the_transcript_are_kept_for_the_phone(self):
        """A photo the person sent and a screenshot a tool returned (10/31: the phone showed only
        "[圖片]") travel as image ids on the events; the bytes come from the images endpoint."""
        transcript = h.Transcript(self.fake.root / 'nowhere.jsonl', h.ClaudeParser)
        png = h.FAKE_PNG
        for obj in [
            {'type': 'user', 'message': {'role': 'user', 'content': [
                {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': png}},
                {'type': 'text', 'text': '這張是什麼'}]}},
            {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': 'tu1', 'name': 'screenshot', 'input': {}}]}},
            {'type': 'user', 'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': 'tu1', 'content': [
                    {'type': 'text', 'text': 'shot taken'},
                    {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': png}}]}]}},
        ]:
            for event in transcript.parser.feed(obj):
                transcript.add(event)
        events = transcript.page(0, '')['events']
        photo = next(e for e in events if e['kind'] == 'user' and e['text'] == '[圖片]')
        shot = next(e for e in events if e['kind'] == 'tool_result')
        self.assertEqual((photo['images'], shot['images']), (['g1-0'], ['g4-0']))
        self.assertNotIn('images', next(e for e in events if e['text'] == '這張是什麼'))
        media, data = transcript.image('g1-0')
        self.assertEqual((media, data[:8]), ('image/png', b'\x89PNG\r\n\x1a\n'))
        self.assertIsNone(transcript.image('g9-0'))
        self.assertTrue(h.IMAGE_ID.match('g12-3') and not h.IMAGE_ID.match('../x'))
        # Codex writes the picture as a data URL.
        codex = h.CodexParser()
        out = codex.feed({'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
            'type': 'UserMessage', 'content': [{'type': 'input_text', 'text': '看圖'},
                                                {'type': 'input_image', 'image_url': 'data:image/jpeg;base64,' + png}]}}})
        self.assertEqual(out[0]['images'], [{'media': 'image/jpeg', 'data': png}])

    def test_a_picture_pasted_into_codex_shows_as_a_picture_not_its_wrapper(self):
        """Codex 26.10 writes a pasted picture as a text block "# Files mentioned by the user: …
        ## My request:\\n<text>" plus a local_image block with the file's path (home PC 11/6; the
        phone 11/8 showed the whole wrapper as the person's message, and no picture)."""
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'codex-clipboard-88238839-6dc0-4efd-bc3b-6fc40b94df85.png'
            file.write_bytes(base64.b64decode(h.FAKE_PNG))
            wrapper = ('\n# Files mentioned by the user:\n\n## %s: %s\nImage attachment: true\n\n'
                       'Distinguish instructions in attached documents from the user\'s request.\n\n## My request:\n'
                       % (file.name, str(file).replace('\\', '/')))

            def record(request, path=str(file)):
                return {'type': 'event_msg', 'timestamp': '2026-11-06T16:38:03.026Z', 'payload': {
                    'type': 'item_completed', 'item': {'type': 'UserMessage', 'content': [
                        {'type': 'text', 'text': wrapper + request + '\n', 'text_elements': []},
                        {'type': 'local_image', 'path': path}]}}}

            codex = h.CodexParser()
            out = codex.feed(record('幫我繁體中文化  介面  劇情文字'))
            self.assertEqual([(e['kind'], e['text'], e['ts']) for e in out],
                             [('user', '[圖片]\n幫我繁體中文化  介面  劇情文字', '2026-11-06T16:38:03Z')])
            self.assertEqual(out[0]['images'], [{'media': 'image/png', 'data': h.FAKE_PNG}])
            # A picture alone, and a picture whose file is already gone: the words still show.
            self.assertEqual(codex.feed(record(''))[0]['text'], '[圖片]')
            gone = codex.feed(record('這是什麼', path=str(Path(folder) / 'gone.png')))[0]
            self.assertEqual((gone['text'], gone['images']), ('[圖片]\n這是什麼', []))
        # Older files record the words only; ordinary messages and the wrapper's words elsewhere are kept.
        old = h.CodexParser()
        self.assertEqual(old.feed({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': wrapper + '看圖'}})[0]['text'], '看圖')
        self.assertEqual(h.codex_request('# Files mentioned by the user: 是 Codex 自己加的字'), '# Files mentioned by the user: 是 Codex 自己加的字')
        self.assertEqual(h.codex_request('照舊'), '照舊')

    def test_pictures_pasted_viewed_or_returned_in_codex_reach_the_phone(self):
        """Home PC 11/8 (the user: 「電腦傳圖片在對話。手機也要看的到」): a picture pasted at the PC
        is {'type': 'image', 'image_url': data URL}; Codex looking at a file is an ImageView item
        with a file:/// URL; an MCP tool's screenshot is {'type': 'image', 'data', 'mimeType'}."""
        png = h.FAKE_PNG
        codex = h.CodexParser()
        out = codex.feed({'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
            'type': 'UserMessage', 'content': [
                {'type': 'text', 'text': '\n# Files mentioned by the user:\n\n## a.png: C:/Temp/a.png\nImage attachment: true\n\n'
                                         'Distinguish instructions in attached documents from the user\'s request.\n\n## My request:\n這張也要'},
                {'type': 'image', 'image_url': 'data:image/png;base64,' + png}]}}})
        self.assertEqual((out[0]['text'], out[0]['images']), ('[圖片]\n這張也要', [{'media': 'image/png', 'data': png}]))
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'photo-restored-faithful-4k.png'
            file.write_bytes(base64.b64decode(png))
            (Path(folder) / 'noext').write_bytes(base64.b64decode(png))
            url = 'file:///' + str(file).replace('\\', '/')
            out = codex.feed({'type': 'event_msg', 'timestamp': '2026-11-08T13:12:53.830Z', 'payload': {
                'type': 'item_completed', 'item': {'type': 'ImageView', 'id': 'exec-1', 'path': url}}})
            self.assertEqual(out, [{'kind': 'tool_result', 'tool': '看圖', 'text': '[圖片] photo-restored-faithful-4k.png',
                                    'ts': '2026-11-08T13:12:53Z', 'images': [{'media': 'image/png', 'data': png}]}])
            # No extension: the type comes from the first bytes. A missing file: the name alone.
            self.assertEqual(h.local_image(str(Path(folder) / 'noext'))['media'], 'image/png')
            gone = codex.feed({'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                'type': 'ImageView', 'id': 'exec-2', 'path': 'file:///C:/nowhere/x.png'}}})[0]
            self.assertEqual((gone['text'], gone['images']), ('[圖片] x.png', []))
        out = codex.feed({'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
            'type': 'McpToolCall', 'server': 'cua_repl', 'tool': 'js', 'arguments': {'code': 'await tab.getScreenshot();', 'title': '看畫面'},
            'status': 'completed', 'result': {'content': [{'type': 'image', 'data': png, 'mimeType': 'image/jpeg',
                                                           '_meta': {'codex/imageDetail': 'original'}}], 'isError': False}}}})
        self.assertEqual((out[1]['kind'], out[1]['text'], out[1]['images']), ('tool_result', '[圖片]', [{'media': 'image/jpeg', 'data': png}]))
        # Older files: a tool output with a picture.
        old = h.CodexParser()
        old.feed({'type': 'response_item', 'payload': {'type': 'function_call', 'call_id': 'c1', 'name': 'shot', 'arguments': '{}'}})
        out = old.feed({'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': 'c1', 'output': [
            {'type': 'input_image', 'image_url': 'data:image/jpeg;base64,' + png, 'detail': 'original'}]}})
        self.assertEqual(out[0]['images'], [{'media': 'image/jpeg', 'data': png}])
        self.assertEqual(h.local_image_path('file:///C:/Users/u/a%20b.png'), Path('C:/Users/u/a b.png'))

    def test_large_pictures_are_shrunk_for_the_phone(self):
        """A 4K picture pasted at the PC is 2-5 MB and the phone decodes it to 33 MB (home PC 11/8:
        with AirPlay on the same Wi-Fi the remote stalled): sent at most 1600 px on the long side
        as JPEG, PNG when transparent; small pictures and GIFs as they are; without Pillow all."""
        if h.PIL_IMAGE is None:
            self.skipTest('Pillow is not installed here')
        import io

        def encoded(mode, size):
            buffer = io.BytesIO()
            h.PIL_IMAGE.frombytes(mode, size, os.urandom(size[0] * size[1] * len(mode))).save(buffer, 'PNG')
            return base64.b64encode(buffer.getvalue()).decode('ascii')

        def size_of(data):
            with h.PIL_IMAGE.open(io.BytesIO(base64.b64decode(data))) as image:
                return image.size

        big = encoded('RGB', (1800, 1200))
        media, out = h.shrink_picture('image/png', big)
        self.assertEqual((media, size_of(out)), ('image/jpeg', (1600, 1067)))
        self.assertLess(len(out), len(big) // 4)
        clear = encoded('RGBA', (1800, 1200))
        media, out = h.shrink_picture('image/png', clear)
        self.assertEqual((media, size_of(out)), ('image/png', (1600, 1067)), 'transparency is kept')
        self.assertEqual(h.shrink_picture('image/png', h.FAKE_PNG), ('image/png', h.FAKE_PNG), 'small ones go as they are')
        self.assertEqual(h.shrink_picture('image/gif', big), ('image/gif', big))
        self.assertEqual(h.shrink_picture('image/png', 'not-a-picture' * 50000), ('image/png', 'not-a-picture' * 50000))
        transcript = h.Transcript(self.fake.root / 'nowhere.jsonl', h.ClaudeParser)
        transcript.add({'kind': 'user', 'text': '[圖片]', 'images': [{'media': 'image/png', 'data': big}]})
        self.assertEqual(transcript.image('g1-0')[0], 'image/jpeg')
        self.assertLess(transcript.image_bytes, len(big) // 4)
        with mock.patch.object(h, 'PIL_IMAGE', None):
            self.assertEqual(h.shrink_picture('image/png', big), ('image/png', big))

    def test_an_interrupted_turn_ends_as_a_status_not_a_message(self):
        parser = h.ClaudeParser()
        parser.feed({'type': 'user', 'message': {'role': 'user', 'content': '請寫長文'}})
        self.assertEqual(parser.status, 'working')
        out = parser.feed({'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'text', 'text': '[Request interrupted by user]'}]}})
        self.assertEqual((out, parser.status), ([{'kind': 'status', 'text': '已中止', 'ts': None}], 'idle'))
        out = parser.feed({'type': 'user', 'message': {'role': 'user', 'content': '[Request interrupted by user for tool use]'}})
        self.assertEqual(out[0]['kind'], 'status')

    def test_a_squeezed_conversation_shows_one_line_not_its_summary(self):
        parser = h.ClaudeParser()
        parser.feed({'type': 'user', 'message': {'role': 'user', 'content': '第一則'}})
        # As Claude writes it (live 10/30): a user message of 13-23k characters, flagged.
        out = parser.feed({'type': 'user', 'isCompactSummary': True, 'isVisibleInTranscriptOnly': True,
                           'timestamp': '2026-10-30T05:00:00.000Z', 'message': {'role': 'user', 'content':
                               'This session is being continued from a previous conversation ' + 'x' * 15000}})
        self.assertEqual(out, [{'kind': 'status', 'text': '對話已壓縮', 'ts': '2026-10-30T05:00:00Z'}])
        self.assertEqual(parser.feed({'type': 'user', 'message': {'role': 'user', 'content': '第二則'}})[0]['text'], '第二則')
        # Codex marks it with a line of its own and shows nothing for it.
        codex = h.CodexParser()
        self.assertEqual(codex.feed({'type': 'compacted', 'timestamp': '2026-10-21T02:05:20.105Z',
                                     'payload': {'message': '', 'replacement_history': []}}),
                         [{'kind': 'status', 'text': '對話已壓縮', 'ts': '2026-10-21T02:05:20Z'}])

    def test_a_message_sent_during_a_turn_stays_in_the_conversation(self):
        parser = h.ClaudeParser()
        # As Claude 2.1.308 writes it (live 10/28): a queued_command attachment, not a user message.
        out = parser.feed({'type': 'attachment', 'timestamp': '2026-10-28T16:30:30.461Z', 'attachment': {
            'type': 'queued_command', 'commandMode': 'prompt', 'origin': {'kind': 'human'}, 'humanTurn': True,
            'timestamp': '2026-10-28T16:30:30.461Z', 'prompt': [
                {'type': 'text', 'text': '<system-reminder>\nLinked sessions now\n</system-reminder>'},
                {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AAAA'}},
                {'type': 'text', 'text': 'app要更新嗎'}]}})
        self.assertEqual(out, [{'kind': 'user', 'text': '[圖片]', 'ts': '2026-10-28T16:30:30Z',
                                'images': [{'media': 'image/png', 'data': 'AAAA'}]},
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

    def test_limits_and_context_are_not_notified(self):
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
        self.assertFalse([s for s in sent if s[0].startswith('⚠️')], 'shown on the phone, nothing to approve (11/02)')

    def test_state_lists_what_the_phone_may_pick(self):
        hub, _, _, _ = drive(self.fake)
        hub.capabilities = hub.capabilities + ['effort', 'mode', 'stop']
        state = hub.state()
        self.assertEqual(state['efforts'], {'claude': ['低', '中', '高', '超高', '最高', 'Ultracode'],
                                            'codex': ['低', '中', '高', '超高']})
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


class MemoryWatchTests(unittest.TestCase):
    """Asked 11/01 after Steam's handle leak filled the commit charge and the home PC's screen flashed."""
    GB = 2 ** 30

    def make(self, used, found, worker=None):
        self.closed = []
        self.used = [used]

        def steam(processes):
            self.closed.append(len(processes()))
            self.used[0] = 30 * self.GB
            return 'shut-down'
        return h.MemoryWatch('家用電腦', worker=worker,
                             charge=lambda: (self.used[0], 178 * self.GB), processes=lambda: found, steam=steam,
                             wall=lambda: h.datetime(2026, 11, 1, 23, 0, tzinfo=h.UTC))

    def wait_closed(self, watch):
        deadline = time.monotonic() + 5
        while watch.closing and time.monotonic() < deadline:
            time.sleep(0.02)

    def test_a_leaking_steam_is_closed(self):
        found = [{'pid': 7, 'name': 'steam', 'path': 'steam.exe', 'bytes': self.GB, 'handles': 2_470_000},
                 {'pid': 8, 'name': 'game', 'path': 'game.exe', 'bytes': 12 * self.GB, 'handles': 900}]
        watch = self.make(170 * self.GB, found)
        watch.step(now=0)
        self.wait_closed(watch)
        self.assertEqual(len(self.closed), 1)
        shown = watch.snapshot()
        self.assertIn('Steam', shown['action'])
        self.assertIn('2,470,000', shown['action'])
        self.assertIn('17%', shown['action'], 'what the memory came back to')
        watch.step(now=30)
        self.assertEqual(len(self.closed), 1, 'once a minute at most')

    def test_nothing_safe_to_close_names_the_biggest_on_the_phone_only(self):
        found = [{'pid': 7, 'name': 'steam', 'path': 'steam.exe', 'bytes': self.GB, 'handles': 3000},
                 {'pid': 8, 'name': 'game', 'path': 'game.exe', 'bytes': 120 * self.GB, 'handles': 900}]
        watch = self.make(160 * self.GB, found)
        with self.assertLogs(level='WARNING') as logs:
            watch.step(now=0)
            self.assertEqual(self.closed, [], 'a normal Steam (it may be running the game) is left alone')
            shown = watch.snapshot()
            self.assertEqual((shown['percent'], shown['high']), (90, True))
            self.assertEqual(shown['top'][0]['name'], 'game')
            watch.step(now=61)
            self.used[0] = 140 * self.GB  # 79%: between the two lines
            watch.step(now=122)
            self.assertEqual(watch.snapshot()['top'], [], 'no list below 85%')
            self.used[0] = 160 * self.GB
            watch.step(now=183)
            self.used[0] = 120 * self.GB
            watch.step(now=244)
            self.used[0] = 160 * self.GB
            watch.step(now=305)
        told = [r.getMessage() for r in logs.records if 'nothing safe' in r.getMessage()]
        self.assertEqual(len(told), 2, 'logged once per episode (below 75% starts a new one)')
        self.assertIn('game 120.0 GB', told[0])

    def test_the_screen_worker_is_recycled_when_it_has_grown(self):
        class Worker:
            def __init__(self):
                self.limits = []

            def recycle_if_big(self, max_bytes, max_handles):
                self.limits.append((max_bytes, max_handles))
                return (1900 * 2 ** 20, 29_000)
        worker = Worker()
        watch = self.make(20 * self.GB, [], worker=worker)
        watch.step(now=0)
        self.assertEqual(worker.limits, [(600 * 2 ** 20, 15_000)])
        self.assertIn('1900 MB', watch.snapshot()['action'])

    def test_recycle_only_between_requests_and_past_a_limit(self):
        worker = h.UiaWorker()

        class Process:
            pid = 42

            def poll(self):
                return None

            def kill(self):
                pass
        worker.process = Process()
        self.assertIsNone(worker.recycle_if_big(600, 100, size=lambda pid: (500, 50)))
        self.assertIsNotNone(worker.process)
        with worker.lock:
            done = []
            threading.Thread(target=lambda: done.append(worker.recycle_if_big(600, 100, size=lambda pid: (900, 50)))).start()
            time.sleep(0.2)
        self.assertEqual(done, [None], 'a request is running: left alone')
        self.assertEqual(worker.recycle_if_big(600, 100, size=lambda pid: (100, 150)), (100, 150))
        self.assertIsNone(worker.process)

    def test_the_helper_on_disk_is_read_from_its_version_line(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'helper.py'
            path.write_text("import x\nVERSION = '0.5.31'\n", encoding='utf-8')
            self.assertEqual(h.helper_on_disk(path), '0.5.31')
            self.assertIsNone(h.helper_on_disk(Path(folder) / 'missing.py'))


class HelperRestartTests(HttpTests):
    def test_a_newer_helper_on_disk_is_offered_and_restarted_into(self):
        disk, restarted = ['9.9.9'], []
        self.hub.disk_version = lambda: disk[0]
        code, body = self.get('/v1/state')
        self.assertEqual(body['pc']['helperUpdate'], '9.9.9')
        self.assertNotIn('restart', body['capabilities'], 'no restart hook: not offered')
        self.assertEqual(self.get('/v1/helper/restart', method='POST', body={})[0], 404)
        self.hub.restart = lambda: restarted.append(True)
        self.assertIn('restart', self.get('/v1/state')[1]['capabilities'])
        code, body = self.get('/v1/helper/restart', method='POST', body={})
        self.assertEqual(code, 202, body)
        self.assertIn('重新啟動', body['message'])
        deadline = time.monotonic() + 5
        while not restarted and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(restarted, [True], 'restarted after the answer went out')
        disk[0] = h.VERSION
        self.assertIsNone(self.get('/v1/state')[1]['pc']['helperUpdate'], 'the same version: nothing newer')


class ClipboardTests(unittest.TestCase):
    """The shared clipboard folder (0.5.40): one file per copied item, both PCs and the phone."""

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix='desk-clip-'))
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.now = [1_700_000_000.0]
        self.store = h.ClipboardStore(self.folder / '剪貼簿', '辦公室 PC', keep=3, clock=lambda: self.now[0])

    def test_items_are_files_named_by_time_and_source_newest_first_and_pruned(self):
        self.assertTrue(self.store.available(), 'made under the existing cloud folder')
        self.assertEqual(self.store.tag, '辦公室_PC')
        first = self.store.put_text('第一段', '辦公室 PC')
        self.assertEqual(first, '1700000000000_辦公室_PC')
        self.assertTrue((self.folder / '剪貼簿' / '1700000000000_辦公室_PC.txt').is_file())
        second = self.store.put_text('第二段', '辦公室 PC')
        self.assertEqual(second, '1700000000001_辦公室_PC', 'the same millisecond: one later, never the same name')
        self.now[0] += 5
        picture = self.store.put_image(base64.b64decode(h.FAKE_PNG), 'image/png', '手機')
        self.assertTrue((self.folder / '剪貼簿' / f'{picture}.png').is_file())
        items = self.store.items()
        self.assertEqual([i['id'] for i in items], [picture, second, first], 'newest first')
        self.assertEqual(items[0], {'id': picture, 'kind': 'image', 'source': '手機', 'at': '2023-11-14T22:13:25Z',
                                    'bytes': 981, 'media': 'image/png'})
        self.assertEqual(items[2]['text'], '第一段')
        self.assertEqual(self.store.image(picture)[0], 'image/png')
        self.assertIsNone(self.store.text(picture), 'a picture has no text')
        self.assertIsNone(self.store.image(second), 'a text is not a picture')
        self.assertIsNone(self.store.find('../../etc/passwd'))
        self.assertIsNone(self.store.find('1700000000000_辦公室_PC/x'))
        # Other files in the folder (desktop.ini, half-written parts) are not items.
        (self.folder / '剪貼簿' / 'desktop.ini').write_text('x')
        (self.folder / '剪貼簿' / '~1700000009999_x.txt.part').write_text('x')
        (self.folder / '剪貼簿' / 'notes.txt').write_text('x')
        self.assertEqual(len(self.store.items()), 3)
        # A long text comes as a preview with the list; keep=3 drops the oldest.
        self.now[0] += 5
        long_id = self.store.put_text('很長' * 3000, '家裡')
        items = self.store.items()
        self.assertEqual([i['id'] for i in items], [long_id, picture, second], 'the oldest was pruned')
        self.assertEqual(items[0]['truncated'], True)
        self.assertEqual(len(items[0]['text']), h.CLIPBOARD_PREVIEW)
        self.assertEqual(len(self.store.text(long_id)), 6000)
        self.assertEqual(self.store.items(limit=1), items[:1])
        missing = h.ClipboardStore(self.folder / 'nowhere' / '剪貼簿', 'pc')
        self.assertFalse(missing.available(), 'no cloud folder: not made')
        self.assertEqual(missing.items(), [])

    def test_a_copy_on_this_pc_goes_to_the_folder_and_an_arrival_into_its_clipboard(self):
        clipboard = h.FakeClipboard()
        sync = h.ClipboardSync(self.store, clipboard, '辦公室 PC', clock=lambda: self.now[0])
        sync.once()
        self.assertEqual(self.store.items(), [], 'nothing copied yet')
        clipboard.copy('text', '複製的字')
        sync.once()
        items = self.store.items()
        self.assertEqual([(i['text'], i['source']) for i in items], [('複製的字', '辦公室_PC')])
        sync.once()
        self.assertEqual(len(self.store.items()), 1, 'the same sequence number: not published again')
        clipboard.copy('text', '   \n')
        clipboard.copy('skip', None)
        sync.once()
        self.assertEqual(len(self.store.items()), 1, 'blank text and content marked not to be watched stay out')
        clipboard.copy('image', base64.b64decode(h.FAKE_PNG))
        sync.once()
        self.assertEqual(self.store.items()[0]['kind'], 'image')
        # A picture file copied in Explorer goes as a picture.
        shot = self.folder / 'shot.png'
        shot.write_bytes(base64.b64decode(h.FAKE_PNG) + b'\x00')  # not the picture just copied
        clipboard.copy('file', str(shot))
        sync.once()
        self.assertEqual(self.store.items()[0]['kind'], 'image')
        self.assertEqual(len(self.store.items()), 3)
        # The other PC's item arrives (the cloud synced it): into this clipboard, once.
        self.now[0] += 1
        other = h.ClipboardStore(self.folder / '剪貼簿', '家裡', clock=lambda: self.now[0])
        other.put_text('家裡複製的', '家裡')
        sync.once()
        self.assertEqual(clipboard.read(), ('text', '家裡複製的'))
        count = len(self.store.items())
        sync.once()
        sync.once()
        self.assertEqual(len(self.store.items()), count, 'what was put into the clipboard is not published back')
        self.now[0] += 1
        other.put_image(base64.b64decode(h.FAKE_PNG), 'image/png', '家裡')
        sync.once()
        self.assertEqual(clipboard.read(), ('image', base64.b64decode(h.FAKE_PNG)))
        # Windows' own cloud clipboard brought the other PC's copy here before the cloud drive did:
        # the same text is the newest item already, so it is not stored a second time.
        self.now[0] += 1
        other.put_text('兩邊同時有', '家裡')
        clipboard.copy('text', '兩邊同時有')
        sync.once()
        self.assertEqual([i['source'] for i in self.store.items() if i.get('text') == '兩邊同時有'], ['家裡'])
        sync.once()
        self.assertEqual(clipboard.read(), ('text', '兩邊同時有'), 'and not pasted again either')
        # An old arrival (this PC was off while it synced) is listed but not pasted over the clipboard.
        clipboard.copy('text', '現在的')
        sync.once()
        stale = h.ClipboardStore(self.folder / '剪貼簿', '家裡', clock=lambda: self.now[0] + 1)
        stale.put_text('很久以前', '家裡')
        self.now[0] += h.CLIPBOARD_FRESH + 60
        sync.once()
        self.assertEqual(clipboard.read(), ('text', '現在的'))
        # The phone's text: stored under its name and pasted here; store=False only pastes.
        self.now[0] += 1
        item = sync.from_phone('text', '手機送的')
        self.assertEqual((item['source'], item['text']), ('手機', '手機送的'))
        self.assertEqual(clipboard.read(), ('text', '手機送的'))
        self.assertIsNone(sync.from_phone('text', '另一台已存', store=False))
        self.assertEqual(clipboard.read(), ('text', '另一台已存'))
        self.assertEqual(self.store.items()[0]['text'], '手機送的', 'nothing stored twice')
        sync.once()
        self.assertEqual(self.store.items()[0]['text'], '手機送的', 'and the phone\'s paste is not published as a copy')
        # Apply by id, and an unknown id.
        self.assertTrue(sync.apply_id(item['id']))
        self.assertEqual(clipboard.read(), ('text', '手機送的'))
        self.assertFalse(sync.apply_id('1700000000000_nobody'))
        # apply=False: arrivals are listed only.
        quiet = h.ClipboardSync(self.store, h.FakeClipboard(), '辦公室 PC', apply=False, clock=lambda: self.now[0])
        self.now[0] += 1
        other.put_text('只列不貼', '家裡')
        quiet.once()
        self.assertIsNone(quiet.clipboard.read())
        # A sync over a folder the cloud has not mounted does nothing and refuses the phone's item.
        gone = h.ClipboardSync(h.ClipboardStore(self.folder / 'nowhere' / 'x', 'pc'), h.FakeClipboard(), 'pc')
        gone.clipboard.copy('text', 'x')
        gone.once()
        with self.assertRaises(h.ActionError):
            gone.from_phone('text', 'x')
        self.assertEqual(h.clipboard_tag('家裡/桌機: A*B'), '家裡_桌機_A_B')
        self.assertIsNone(h.clipboard_sync_from_config({}, 'pc'), 'no clipboard section: off')

    @unittest.skipIf(h.PIL_IMAGE is None, 'Pillow not installed')
    def test_a_windows_bitmap_turns_into_png_and_back(self):
        png = base64.b64decode(h.FAKE_PNG)
        dib = h.png_to_dib(png)
        self.assertEqual(int.from_bytes(dib[:4], 'little'), 40, 'a BITMAPINFOHEADER without the file header')
        back = h.dib_to_png(dib)
        self.assertTrue(back.startswith(b'\x89PNG'))
        import io
        with h.PIL_IMAGE.open(io.BytesIO(back)) as image:
            self.assertEqual(image.size, (24, 24))
        self.assertIsNone(h.dib_to_png(b'short'))
        self.assertIsNone(h.png_to_dib(b'not a png'))
        self.assertEqual(h.ClipboardSync.digest('text', 'a'), h.ClipboardSync.digest('text', 'a'))
        self.assertNotEqual(h.ClipboardSync.digest('text', 'a'), h.ClipboardSync.digest('image', b'a'))


class ClipboardHttpTests(FakeEnvironment):
    def test_the_phone_lists_copies_and_sends_through_the_helper(self):
        hub = h.Hub('示範電腦', self.sources, h.FixedPresence(self.fake.cfg['presence']))
        server = ThreadingHTTPServer(('127.0.0.1', 0), h.handler_for(hub, h.AuthGate(TOKEN), [ipaddress.ip_network('127.0.0.0/8')]))
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f'http://127.0.0.1:{server.server_address[1]}'

        def call(path, method='GET', body=None, token=TOKEN):
            data = json.dumps(body).encode('utf-8') if body is not None else None
            request = urllib.request.Request(base + path, method=method, data=data, headers={'Authorization': f'Bearer {token}'})
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    raw = response.read()
                    kind = response.headers.get('Content-Type') or ''
                    return response.status, (json.loads(raw) if kind.startswith('application/json') else (kind, raw))
            except urllib.error.HTTPError as exc:
                return exc.code, json.loads(exc.read())

        self.assertNotIn('clipboard', call('/v1/state')[1]['capabilities'])
        self.assertEqual(call('/v1/clipboard')[0], 404, 'no shared clipboard configured')
        hub.clipboard = self.fake.clipboard_sync()
        self.assertIn('clipboard', call('/v1/state')[1]['capabilities'])
        code, body = call('/v1/clipboard')
        self.assertEqual(code, 200)
        self.assertEqual(body['pc'], '示範電腦')
        self.assertEqual([(i['kind'], i['source']) for i in body['items']],
                         [('text', '手機'), ('image', '示範電腦'), ('text', '家裡')], 'the fixture items, newest first')
        self.assertEqual(body['items'][0]['text'], 'https://example.com/tn12/weekly-report')
        self.assertEqual(call('/v1/clipboard?limit=1')[1]['items'], body['items'][:1])
        picture = body['items'][1]['id']
        code, (kind, raw) = call(f'/v1/clipboard/images/{urllib.parse.quote(picture)}')
        self.assertEqual((code, kind, raw), (200, 'image/png', base64.b64decode(h.FAKE_PNG)))
        self.assertEqual(call(f'/v1/clipboard/images/{urllib.parse.quote(picture)}?small=1')[0], 200)
        code, body = call(f'/v1/clipboard/items/{urllib.parse.quote(body["items"][2]["id"])}')
        self.assertEqual((code, body['text']), (200, '會議室 Wi-Fi：demo-guest／密碼 4821（示範用）'))
        self.assertEqual(call(f'/v1/clipboard/items/{urllib.parse.quote(picture)}')[0], 404, 'a picture has no text')
        self.assertEqual(call('/v1/clipboard/items/nope')[0], 404)
        self.assertEqual(call('/v1/clipboard', token='wrong')[0], 401)
        # The phone sends text: stored as the phone's and put into this PC's clipboard.
        code, body = call('/v1/clipboard', 'POST', {'text': '從手機來的'})
        self.assertEqual(code, 200, body)
        self.assertEqual((body['item']['source'], body['item']['text']), ('手機', '從手機來的'))
        self.assertEqual(hub.clipboard.clipboard.read(), ('text', '從手機來的'))
        self.assertEqual(call('/v1/clipboard')[1]['items'][0]['id'], body['item']['id'])
        # A second PC gets the same with store=false: only its clipboard changes.
        code, body = call('/v1/clipboard', 'POST', {'text': '從手機來的', 'store': False})
        self.assertEqual((code, body['item']), (200, None))
        self.assertEqual(call('/v1/clipboard')[1]['items'][0]['text'], '從手機來的')
        self.assertEqual(len([i for i in call('/v1/clipboard')[1]['items'] if i.get('text') == '從手機來的']), 1)
        # A picture from the phone (JPEG), named by the phone.
        code, body = call('/v1/clipboard', 'POST', {'image': base64.b64encode(JPEG).decode('ascii'), 'source': 'iPhone'})
        self.assertEqual(code, 200, body)
        self.assertEqual((body['item']['kind'], body['item']['source'], body['item']['media']), ('image', 'iPhone', 'image/jpeg'))
        self.assertEqual(call(f'/v1/clipboard/images/{urllib.parse.quote(body["item"]["id"])}')[1], ('image/jpeg', JPEG))
        self.assertEqual(call('/v1/clipboard', 'POST', {'text': '  '})[0], 400)
        self.assertEqual(call('/v1/clipboard', 'POST', {'image': 'bm90IGFuIGltYWdl'})[0], 400)
        self.assertEqual(call('/v1/clipboard', 'POST', {})[0], 400)
        # The phone asks this PC to take an older item into its clipboard.
        old = call('/v1/clipboard')[1]['items'][-1]['id']
        self.assertEqual(call(f'/v1/clipboard/items/{urllib.parse.quote(old)}/apply', 'POST', {})[0], 200)
        self.assertEqual(hub.clipboard.clipboard.read(), ('text', '會議室 Wi-Fi：demo-guest／密碼 4821（示範用）'))
        self.assertEqual(call('/v1/clipboard/items/1700000000000_nobody/apply', 'POST', {})[0], 404)
        self.assertEqual(call('/v1/clipboard/other', 'POST', {})[0], 404)
        # The cloud folder gone: the list says so instead of showing nothing.
        hub.clipboard.store.folder = hub.clipboard.store.folder.parent / 'unmounted' / 'clipboard'
        self.assertEqual(call('/v1/clipboard')[0], 503)
        self.assertEqual(call('/v1/clipboard', 'POST', {'text': 'x'})[0], 503)


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


class CountingCamera:
    """A device for CameraFeed tests: every frame is different, and it remembers being closed."""

    def __init__(self, fail_after=None):
        self.grabbed = 0
        self.closed = 0
        self.fail_after = fail_after
        self.profiles = []

    def grab_jpeg(self, profile='low'):
        self.profiles.append(profile)
        if self.fail_after is not None and self.grabbed >= self.fail_after:
            return None
        self.grabbed += 1
        time.sleep(0.02)
        return b'\xff\xd8\xff' + str(self.grabbed).encode()

    def close(self):
        self.closed += 1


def frame_number(data):
    """The CountingCamera frame a JPEG came from."""
    return int(data[3:])


class CameraFeedTests(unittest.TestCase):
    """The webcam page (0.5.41): the camera opens on the first frame asked for, stays open while
    frames keep being asked for, and closes a few seconds after the last one (user 11/10:
    「有打開才啟動」). A request gets the newest frame, which on a quick machine (CI's Mac) may be
    a few frames on from the one before: the numbers are checked to rise, not to be consecutive."""

    def test_opens_on_demand_hands_out_newer_frames_and_closes_when_nobody_asks(self):
        devices = []

        def open_device():
            devices.append(CountingCamera())
            return devices[-1]
        feed = h.CameraFeed(open_device, idle=0.3)
        self.assertFalse(feed.on())
        self.assertEqual(devices, [], 'opened before anyone asked')
        first, why = feed.frame_bytes()
        self.assertIsNone(why)
        self.assertTrue(first.startswith(b'\xff\xd8\xff'))
        self.assertTrue(feed.on())
        second, _ = feed.frame_bytes()
        third, _ = feed.frame_bytes()
        self.assertGreater(frame_number(second), frame_number(first), 'a request got an old frame again')
        self.assertGreater(frame_number(third), frame_number(second), 'a request got an old frame again')
        self.assertEqual(len(devices), 1)
        self.assertEqual(set(devices[0].profiles), {'low'}, 'the data saver is not the default')
        clear, _ = feed.frame_bytes(profile='high')
        self.assertGreater(frame_number(clear), frame_number(third))
        feed.frame_bytes(profile='high')
        self.assertEqual(devices[0].profiles[-1], 'high', 'the clear picture was not asked of the camera')
        time.sleep(0.8)
        self.assertFalse(feed.on(), 'still open with nobody asking')
        self.assertEqual(devices[0].closed, 1, 'the camera was not released')
        again, why = feed.frame_bytes()
        self.assertIsNone(why)
        self.assertLessEqual(frame_number(again), 3, 'the reopened camera did not start afresh')
        self.assertEqual((len(devices), feed.opened), (2, 2))
        time.sleep(0.8)
        self.assertEqual(devices[1].closed, 1)

    def test_a_camera_that_cannot_open_or_read_says_why_and_is_tried_again_later(self):
        calls = []

        def open_device():
            calls.append(1)
            raise RuntimeError('沒有鏡頭，或被其他程式占用')
        feed = h.CameraFeed(open_device, idle=0.3)
        data, why = feed.frame_bytes()
        self.assertIsNone(data)
        self.assertEqual(why, '鏡頭打不開（沒有鏡頭，或被其他程式占用）')
        self.assertFalse(feed.on())
        time.sleep(0.1)
        self.assertIsNone(feed.frame_bytes()[0])
        self.assertEqual(len(calls), 2, 'a later request did not try the camera again')
        device = CountingCamera(fail_after=1)
        feed = h.CameraFeed(lambda: device, idle=0.3)
        self.assertEqual(feed.frame_bytes(), (b'\xff\xd8\xff1', None))
        deadline = time.monotonic() + 2
        while feed.on() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(device.closed, 1, 'a camera that stopped giving frames was not released')
        data, why = feed.frame_bytes()  # tried again: the same device, which fails at once
        self.assertEqual((data, why), (None, '鏡頭讀不到畫面'))
        # The answer goes out before the camera thread's clean-up: wait for the thread to end.
        deadline = time.monotonic() + 2
        while feed.thread is not None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(device.closed, 2)

    def test_a_slow_camera_answers_with_a_timeout_message_instead_of_hanging(self):
        class Stuck:
            def grab_jpeg(self, profile='low'):
                time.sleep(5)
                return None

            def close(self):
                pass
        feed = h.CameraFeed(Stuck, idle=0.3)
        started = time.monotonic()
        data, why = feed.frame_bytes(wait=0.3)
        self.assertEqual((data, why), (None, '鏡頭還沒給出畫面'))
        self.assertLess(time.monotonic() - started, 2)

    def test_config_decides_whether_the_phone_gets_a_camera(self):
        with mock.patch.dict(sys.modules, {'cv2': mock.MagicMock()}):
            self.assertIsNone(h.camera_from_config({'camera': False}, names=['USB2.0 FHD UVC WebCam']))
            self.assertIsNone(h.camera_from_config({}, names=[]), 'no camera listed, yet a page')
            feed = h.camera_from_config({'camera': {'idle_seconds': 9}}, names=['USB2.0 FHD UVC WebCam'])
            self.assertIsInstance(feed, h.CameraFeed)
            self.assertEqual(feed.idle, 9)
        with mock.patch.dict(sys.modules, {'cv2': None}):
            self.assertIsNone(h.camera_from_config({}, names=['USB2.0 FHD UVC WebCam']), 'no OpenCV, yet a page')

    def test_the_fake_camera_serves_the_fixture_picture(self):
        camera = h.FakeCamera(FIXTURES / 'camera.jpg')
        self.assertTrue(camera.grab_jpeg().startswith(b'\xff\xd8\xff'))
        camera.close()
        self.assertTrue(camera.closed)


class NotifierTests(unittest.TestCase):
    """ntfy as before, and (0.5.46) LINE Messaging API pushes beside it, only for the tags asked."""

    def test_line_gets_the_tagged_notifications_beside_ntfy(self):
        sent = []

        class Answer:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self, n=-1):
                return b'{}'

        def urlopen(request, timeout=10):
            sent.append((request.full_url, request.get_header('Authorization'), json.loads(request.data.decode('utf-8'))))
            return Answer()
        cfg = {'notify': {'server': 'https://ntfy.example/', 'topic': 'topic-1',
                          'line': {'channel_access_token': 'line-token', 'to': 'Uabc', 'tags': ['bulb']}}}
        notifier = h.Notifier(cfg, urlopen=urlopen)
        notifier.post('示範電腦：玻璃門亮了', '09:02 亮度 175', tags=['bulb'])
        notifier.post('示範電腦：權限詢問', '要不要允許', tags=['question'])
        self.assertEqual([url for url, _, _ in sent], ['https://ntfy.example/', h.Notifier.LINE_PUSH, 'https://ntfy.example/'])
        self.assertEqual(sent[1][1], 'Bearer line-token')
        self.assertEqual(sent[1][2], {'to': 'Uabc', 'messages': [{'type': 'text', 'text': '示範電腦：玻璃門亮了\n09:02 亮度 175'}]})
        self.assertEqual(sent[0][2]['topic'], 'topic-1')
        # Without tags every notification goes to LINE; without ntfy settings only LINE is used.
        notifier = h.Notifier({'notify': {'line': {'channel_access_token': 't', 'to': 'U1'}}}, urlopen=urlopen)
        notifier.post('標題', '內容')
        self.assertEqual(sent[-1][0], h.Notifier.LINE_PUSH)
        self.assertEqual(len(sent), 4)
        # Several recipients (0.5.54, the user's friend): one multicast with the list.
        notifier = h.Notifier({'notify': {'line': {'channel_access_token': 't', 'to': ['U1', 'U2']}}}, urlopen=urlopen)
        notifier.post('標題', '內容')
        self.assertEqual(sent[-1][0], h.Notifier.LINE_MULTICAST)
        self.assertEqual(sent[-1][2]['to'], ['U1', 'U2'])
        self.assertEqual(sent[-1][2]['messages'][0]['text'], '標題\n內容')
        del sent[-1]

        # A picture rides along (0.5.48): PUT to the topic as the ntfy attachment, its URL as a
        # LINE image message in the same push.
        class Attached(Answer):
            def read(self, n=-1):
                return b'{"id":"x","attachment":{"name":"light.jpg","url":"https://ntfy.example/file/abc.jpg"}}'

        def urlopen_attach(request, timeout=10):
            sent.append((request.full_url, request.get_method(), dict(request.header_items()), request.data))
            return Attached()
        sent.clear()
        notifier = h.Notifier(cfg, urlopen=urlopen_attach)
        notifier.post('示範電腦：玻璃門亮了', '09:02 亮度 175', tags=['bulb'], picture=b'\xff\xd8\xffjpeg', picture_name='light.jpg')
        self.assertEqual([(url, method) for url, method, _, _ in sent],
                         [('https://ntfy.example/topic-1', 'PUT'), (h.Notifier.LINE_PUSH, 'POST')])
        headers = sent[0][2]
        self.assertEqual(sent[0][3], b'\xff\xd8\xffjpeg')
        self.assertEqual((headers['Filename'], headers['Tags'], headers['Priority']), ('light.jpg', 'bulb', '3'))
        self.assertTrue(headers['Title'].startswith('=?UTF-8?B?') and headers['Title'].endswith('?='))
        self.assertEqual(h.Notifier.header('plain'), 'plain')
        line = json.loads(sent[1][3].decode('utf-8'))
        self.assertEqual(line['messages'][1], {'type': 'image', 'originalContentUrl': 'https://ntfy.example/file/abc.jpg',
                                               'previewImageUrl': 'https://ntfy.example/file/abc.jpg'})
        self.assertEqual(line['messages'][0]['type'], 'text')

        def refuse(request, timeout=10):
            raise urllib.error.HTTPError(request.full_url, 401, 'Unauthorized', {}, __import__('io').BytesIO(b'{"message":"invalid token"}'))
        with self.assertRaisesRegex(OSError, 'LINE answered 401'):
            h.Notifier({'notify': {'line': {'channel_access_token': 'bad', 'to': 'U1'}}}, urlopen=refuse).post('a', 'b')


class LightWatchTests(unittest.TestCase):
    """A region of the camera picture watched for a light (0.5.45; the user 11/11): on above one
    threshold, off below another, a change needs two samples in a row, every change goes to the
    log and turning on to ntfy; the watch runs only on workdays 08-18 when so configured."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='light-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.levels = []
        self.notes = []
        self.now = [time.mktime((2026, 11, 11, 9, 0, 0, 2, 315, -1))]  # Wednesday 09:00
        self.feed = h.CameraFeed(CountingCamera, idle=0.3)
        self.watch = h.LightWatch(self.feed, (0.75, 0.4, 0.05, 0.18), self.root / 'light_log.csv',
                                  notify=lambda title, message, **kw: self.notes.append((title, message, kw)),
                                  pc_name='示範電腦', name='玻璃門', interval=30, on_above=130, off_below=90, settle=0,
                                  hours=(8, 18), weekdays_only=True,
                                  measure=lambda jpeg: self.levels.pop(0), clock=lambda: self.now[0], sleep=lambda s: None)

    def tick(self, level, minutes=0.5):
        self.levels.append(level)
        self.now[0] += minutes * 60
        return self.watch.sample()

    def test_changes_need_two_samples_go_to_the_log_and_turning_on_is_notified(self):
        self.assertEqual(self.tick(55), 55)
        self.assertIsNone(self.watch.on, 'one look decided the first state (0.5.49: it takes two)')
        self.tick(54)
        self.assertEqual((self.watch.on, self.notes), (False, []), 'a dark first look was not recorded as off')
        self.tick(170)
        self.assertFalse(self.watch.on, 'one bright sample flipped the light')
        self.tick(100)  # between the thresholds: the flicker is forgotten
        self.tick(170)
        self.assertFalse(self.watch.on)
        self.tick(175)
        self.assertTrue(self.watch.on, 'two bright samples in a row did not turn it on')
        self.assertEqual(len(self.notes), 1)
        self.assertEqual(self.notes[0][0], '示範電腦：玻璃門亮了')
        self.assertIn('亮度 175', self.notes[0][1])
        self.tick(60)
        self.tick(58)
        self.assertFalse(self.watch.on)
        self.assertEqual(len(self.notes), 2, 'turning off was not notified')
        self.assertEqual(self.notes[1][0], '示範電腦：玻璃門暗了')
        self.assertEqual(self.notes[1][2].get('tags'), ['bulb'])
        self.assertTrue(self.notes[1][2].get('picture', b'').startswith(b'\xff\xd8\xff'), 'the camera frame did not ride along')
        self.assertEqual(self.notes[1][2].get('picture_name'), 'light.jpg')
        lines = (self.root / 'light_log.csv').read_text(encoding='utf-8').splitlines()
        self.assertEqual(lines[0], 'date,time,state,level,note')
        self.assertEqual([l.split(',')[2:] for l in lines[1:]], [['off', '54.0', 'start'], ['on', '175.0'], ['off', '58.0']])
        self.assertTrue(all(l.startswith('2026-11-11,') for l in lines[1:]))
        snap = self.watch.snapshot()
        self.assertEqual((snap['name'], snap['on'], snap['level'], snap['watching'], snap['hours'], snap['weekdaysOnly']),
                         ('玻璃門', False, 58.0, True, [8, 18], True))
        self.assertTrue(snap['since'].startswith('2026-11-11T09:0'))
        days = self.watch.history(2)
        self.assertEqual([d['date'] for d in days], ['2026-11-11', '2026-11-10'])
        self.assertEqual([(c['time'][:5], c['on'], c['start']) for c in days[0]['changes']],
                         [('09:01', False, True), ('09:03', True, False), ('09:04', False, False)])
        self.assertEqual(days[1]['changes'], [])
        self.assertEqual(len(self.watch.recent()), 8)
        samples = (self.root / 'light_samples.csv').read_text(encoding='utf-8').splitlines()
        self.assertEqual(samples[0], 'date,time,level,score')
        self.assertEqual([l.split(',')[2:] for l in samples[1:]],
                         [[v, ''] for v in ('55.0', '54.0', '170.0', '100.0', '170.0', '175.0', '60.0', '58.0')],
                         'not every look was kept for the calibration')
        self.assertEqual(self.feed.opened, 1, 'every sample reopened the camera although the feed was still open')

    def test_outside_workdays_and_hours_nothing_is_watched_and_the_window_starts_afresh(self):
        self.assertTrue(self.watch.active())
        self.now[0] += 9 * 3600  # 18:00
        self.assertFalse(self.watch.active())
        self.now[0] += 14 * 3600  # Thursday 08:00
        self.assertTrue(self.watch.active())
        self.now[0] += 2 * 24 * 3600  # Saturday
        self.assertFalse(self.watch.active())
        self.watch.weekdays_only = False
        self.assertTrue(self.watch.active())
        # A bright start inside the window is recorded as 'start' and notified once, after two
        # bright looks: 11/12 08:00 one washed-out first frame said the dark room was lit.
        self.tick(137)
        self.tick(53)
        self.tick(52)
        self.assertEqual((self.watch.on, self.notes), (False, []), 'a washed-out first frame and a dark one decided the state')
        self.watch.on = self.watch.pending = None
        self.tick(180)
        self.assertIsNone(self.watch.on)
        self.tick(182)
        self.assertTrue(self.watch.on)
        self.assertEqual(self.notes[-1][0], '示範電腦：玻璃門亮了（小幫手啟動時已亮）')
        # Restarted the same day with the light still on (0.5.51): the log already ends 'on', so
        # nothing is logged or sent again; a new day is a fresh start.
        sent = len(self.notes)
        rows = len((self.root / 'light_log.csv').read_text(encoding='utf-8').splitlines())
        self.watch.on = self.watch.pending = None
        self.tick(180)
        self.tick(181)
        self.assertTrue(self.watch.on)
        self.assertEqual((len(self.notes), len((self.root / 'light_log.csv').read_text(encoding='utf-8').splitlines())),
                         (sent, rows), 'a restart in the same state was announced again')
        self.watch.on = self.watch.pending = None
        self.now[0] += 24 * 3600
        self.tick(180)
        self.tick(181)
        self.assertEqual(len(self.notes), sent + 1, 'the next day\'s bright start was not announced')
        # The exposure after opening: frames are taken until the whole picture holds still.
        self.watch.settle = 1
        means = [250, 190, 141, 139]
        self.watch.whole = lambda jpeg: means.pop(0)
        calls = []
        real = self.feed.frame_bytes
        self.feed.frame_bytes = lambda **kw: calls.append(1) or real(**kw)
        self.tick(181)
        self.assertEqual(len(calls), 4, 'the washed-out frames were not waited out')
        self.assertEqual(means, [], 'measuring started before the picture held still')
        self.watch.settle = 0
        # A picture that cannot be read keeps the state and says why.
        self.watch.measure = lambda jpeg: 1 / 0
        self.assertIsNone(self.watch.sample())
        self.assertTrue(self.watch.on)
        self.assertIn('畫面讀不出來', self.watch.snapshot()['error'])

    def test_config_builds_the_watch_only_with_a_camera_and_checks_the_region(self):
        self.assertIsNone(h.light_watch_from_config({}, self.feed, None, 'PC', self.root))
        self.assertIsNone(h.light_watch_from_config({'light_watch': {'region': [0.7, 0.4, 0.05, 0.2]}}, None, None, 'PC', self.root))
        watch = h.light_watch_from_config({'light_watch': {'region': [0.7, 0.4, 0.05, 0.2], 'name': '會議室', 'hours': [8, 18],
                                                           'weekdays_only': True, 'interval_seconds': 20,
                                                           'on_above': 140, 'off_below': 100}}, self.feed, None, 'PC', self.root)
        self.assertEqual((watch.name, watch.hours, watch.weekdays_only, watch.interval, watch.on_above, watch.off_below),
                         ('會議室', (8, 18), True, 20.0, 140.0, 100.0))
        self.assertEqual(watch.log_path, self.root / 'light_log.csv')
        for bad in ({'region': [0.9, 0.4, 0.2, 0.2]}, {'region': 'x'}, {'region': [0.1, 0.1, 0.1, 0.1], 'hours': [9, 9]},
                    {'region': [0.1, 0.1, 0.1, 0.1], 'on_above': 100, 'off_below': 100}):
            with self.assertRaises(ValueError, msg=bad):
                h.light_watch_from_config({'light_watch': bad}, self.feed, None, 'PC', self.root)

    def test_the_region_follows_the_door_frame_when_the_picture_shifts(self):
        try:
            import cv2
            import numpy
        except ImportError:
            self.skipTest('OpenCV is not installed')
        rng = numpy.random.default_rng(7)
        scene = rng.integers(0, 256, (120, 200), dtype=numpy.uint8)   # a textured wall
        scene[40:90, 100:130] = 30                                    # the dark doorway (the region)
        scene[40:90, 96:100] = 240                                    # its white frame
        scene[40:90, 130:134] = 240

        def jpeg(picture):
            return cv2.imencode('.jpg', picture, [cv2.IMWRITE_JPEG_QUALITY, 95])[1].tobytes()
        region = (0.5, 1 / 3, 0.15, 5 / 12)                           # x 100-130, y 40-90
        anchor = (0.45, 0.3, 0.25, 0.5)                               # the frame and some wall: x 90-140, y 36-96
        aim = h.RegionAim(jpeg(scene), anchor, region, min_score=0.6)
        level, used = aim.measure(jpeg(scene))
        self.assertLess(level, 60)
        self.assertEqual(aim.offset, (0, 0))
        # The camera is nudged: the scene moves 12 px right and 6 px down. A fixed region would now
        # see the bright frame; the aim moves with it.
        shifted = numpy.roll(numpy.roll(scene, 12, axis=1), 6, axis=0)
        self.assertGreater(h.gray_region_mean(shifted, region), 60, 'the test scene did not move enough')
        level, used = aim.measure(jpeg(shifted))
        self.assertEqual(aim.offset, (12, 6))
        self.assertLess(level, 60, 'the region did not follow the frame')
        self.assertAlmostEqual(used[0], 0.5 + 12 / 200, places=3)
        self.assertFalse(aim.lost)
        # The room light comes on (the doorway turns bright): the frame is still found, the level rises.
        lit = shifted.copy()
        lit[46:96, 112:142] = 230
        level, _ = aim.measure(jpeg(lit))
        self.assertEqual(aim.offset, (12, 6))
        self.assertGreater(level, 200)
        # Nothing like the frame in the picture: the last position is kept and `lost` is set.
        aim.measure(jpeg(rng.integers(0, 256, (120, 200), dtype=numpy.uint8)))
        self.assertTrue(aim.lost)
        self.assertEqual(aim.offset, (12, 6))
        # From config: the reference picture next to the log, a bad anchor refused.
        (self.root / 'ref.jpg').write_bytes(jpeg(scene))
        watch = h.light_watch_from_config({'light_watch': {'region': list(region), 'reference': 'ref.jpg', 'anchor': list(anchor)}},
                                          self.feed, None, 'PC', self.root)
        self.assertIsNotNone(watch.aim)
        self.assertIn('aim', watch.snapshot())
        with self.assertRaises(ValueError):
            h.light_watch_from_config({'light_watch': {'region': list(region), 'reference': 'missing.jpg', 'anchor': list(anchor)}},
                                      self.feed, None, 'PC', self.root)

    def test_region_brightness_reads_the_part_of_the_picture(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest('Pillow is not installed')
        import io
        picture = Image.new('L', (100, 50), 20)
        picture.paste(220, (50, 0, 100, 50))  # the right half is bright
        buffer = io.BytesIO()
        picture.save(buffer, 'JPEG', quality=95)
        jpeg = buffer.getvalue()
        self.assertLess(h.region_brightness(jpeg, (0.0, 0.0, 0.5, 1.0)), 40)
        self.assertGreater(h.region_brightness(jpeg, (0.5, 0.0, 0.5, 1.0)), 200)
        self.assertGreater(h.region_brightness(jpeg, (0.99, 0.99, 0.01, 0.01)), 200)


class CameraHttpTests(FakeEnvironment):
    def fetch(self, server, path, token=TOKEN):
        request = urllib.request.Request(f'http://127.0.0.1:{server.server_address[1]}{path}',
                                         headers={'Authorization': f'Bearer {token}'})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.headers.get('Content-Type'), response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.headers.get('Content-Type'), exc.read()

    def test_frames_are_jpegs_behind_the_token_and_the_state_says_when_the_camera_is_on(self):
        hub = h.Hub('示範電腦', self.sources, h.FixedPresence(self.fake.cfg['presence']))
        server = ThreadingHTTPServer(('127.0.0.1', 0), h.handler_for(hub, h.AuthGate(TOKEN), [ipaddress.ip_network('127.0.0.0/8')]))
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.assertEqual(self.fetch(server, '/v1/camera/frame')[0], 404, 'no camera, yet not 404')
        state = json.loads(self.fetch(server, '/v1/state')[2])
        self.assertNotIn('camera', state['capabilities'])
        self.assertIsNone(state['camera'])
        device = CountingCamera()
        hub.camera = h.CameraFeed(lambda: device, idle=0.5)
        state = json.loads(self.fetch(server, '/v1/state')[2])
        self.assertIn('camera', state['capabilities'])
        self.assertEqual(state['camera'], {'on': False})
        self.assertEqual(self.fetch(server, '/v1/camera/frame', token='wrong')[0], 401)
        code, media, first = self.fetch(server, '/v1/camera/frame')
        self.assertEqual((code, media, first[:3]), (200, 'image/jpeg', b'\xff\xd8\xff'))
        second = self.fetch(server, '/v1/camera/frame')[2]
        self.assertGreater(frame_number(second), frame_number(first))
        self.assertEqual(self.fetch(server, '/v1/light')[0], 404, 'no light watch, yet not 404')
        self.assertNotIn('light', state['capabilities'])
        hub.light = self.fake.light_watch(hub.camera)
        hub.light.sample()
        state = json.loads(self.fetch(server, '/v1/state')[2])
        self.assertIn('light', state['capabilities'])
        self.assertEqual((state['light']['name'], state['light']['on'], state['light']['level']), ('玻璃門', True, 183.0))
        code, media, body = self.fetch(server, '/v1/light?days=2')
        light = json.loads(body)
        self.assertEqual((code, light['ok'], light['on'], len(light['days'])), (200, True, True, 2))
        self.assertEqual([c['time'] for c in light['days'][0]['changes']], ['08:05:17', '12:01:48'] + [c['time'] for c in light['days'][0]['changes']][2:])
        self.assertEqual(light['days'][0]['changes'][-1]['start'], True)
        self.assertEqual(len(light['days'][1]['changes']), 4)
        self.assertEqual(light['samples'][-1]['level'], 183.0)
        self.assertEqual(self.fetch(server, '/v1/light', token='wrong')[0], 401)
        clear = self.fetch(server, '/v1/camera/frame?clear=1')[2]
        self.assertGreater(frame_number(clear), frame_number(second))
        self.fetch(server, '/v1/camera/frame?clear=1')
        self.assertEqual((device.profiles[0], device.profiles[-1]), ('low', 'high'))
        status = json.loads(self.fetch(server, '/v1/camera')[2])
        self.assertEqual((status['on'], status['frames'] >= 2), (True, True))
        self.assertEqual(json.loads(self.fetch(server, '/v1/state')[2])['camera'], {'on': True})
        self.assertEqual(self.fetch(server, '/v1/camera/other')[0], 404)
        time.sleep(1.2)
        self.assertEqual(device.closed, 1, 'the camera stayed on after the phone stopped asking')
        self.assertEqual(json.loads(self.fetch(server, '/v1/state')[2])['camera'], {'on': False})
        hub.camera = h.CameraFeed(lambda: CountingCamera(fail_after=0), idle=0.5)
        code, _, body = self.fetch(server, '/v1/camera/frame')
        self.assertEqual((code, json.loads(body)['error']), (503, 'camera-failed'))


class PictureStoreTests(unittest.TestCase):
    """0.5.52: the light's picture for LINE is served from this PC (through a tunnel) instead of
    ntfy's attachment, which the PC's LINE never showed (no Content-Type on HEAD, no Range) and
    which expires after three hours."""

    JPEG = b'\xff\xd8\xff\xe0' + bytes(range(256)) * 4 + b'\xff\xd9'

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix='pictures-'))
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.now = [1_700_000_000.0]
        self.store = h.PictureStore(self.folder / 'pictures', 'https://pic.example.com/', keep_days=7, clock=lambda: self.now[0])

    def listen(self):
        thread = self.store.serve('127.0.0.1', 0)
        self.addCleanup(thread.server.server_close)
        self.addCleanup(thread.server.shutdown)
        return thread.server.server_address[1]

    def fetch(self, port, path, method='GET', headers=None):
        request = urllib.request.Request(f'http://127.0.0.1:{port}{path}', method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def test_a_kept_picture_is_served_with_type_head_and_range(self):
        url = self.store.put(self.JPEG)
        name = url.rsplit('/', 1)[1]
        self.assertRegex(url, r'^https://pic\.example\.com/p/[A-Za-z0-9_-]{32}\.jpg$')
        self.assertNotEqual(self.store.put(self.JPEG), url, 'two pictures, two names')
        port = self.listen()
        code, headers, body = self.fetch(port, f'/p/{name}')
        self.assertEqual((code, body), (200, self.JPEG))
        self.assertEqual(headers['Content-Type'], 'image/jpeg')
        self.assertEqual(headers['Accept-Ranges'], 'bytes')
        self.assertEqual(int(headers['Content-Length']), len(self.JPEG))
        self.assertIn('max-age', headers['Cache-Control'])
        # HEAD: the same headers, no body (LINE's desktop client probes first).
        code, headers, body = self.fetch(port, f'/p/{name}', 'HEAD')
        self.assertEqual((code, body, headers['Content-Type'], int(headers['Content-Length'])), (200, b'', 'image/jpeg', len(self.JPEG)))
        # Ranges: the first bytes, an open end, the last bytes, and one past the end.
        size = len(self.JPEG)
        code, headers, body = self.fetch(port, f'/p/{name}', headers={'Range': 'bytes=0-3'})
        self.assertEqual((code, body, headers['Content-Range']), (206, b'\xff\xd8\xff\xe0', f'bytes 0-3/{size}'))
        code, headers, body = self.fetch(port, f'/p/{name}', headers={'Range': f'bytes={size - 2}-'})
        self.assertEqual((code, body, headers['Content-Range']), (206, b'\xff\xd9', f'bytes {size - 2}-{size - 1}/{size}'))
        code, headers, body = self.fetch(port, f'/p/{name}', headers={'Range': 'bytes=-2'})
        self.assertEqual((code, body), (206, b'\xff\xd9'))
        code, headers, body = self.fetch(port, f'/p/{name}', headers={'Range': f'bytes={size}-'})
        self.assertEqual((code, headers['Content-Range']), (416, f'bytes */{size}'))
        self.assertEqual(self.fetch(port, f'/p/{name}', 'HEAD', {'Range': 'bytes=0-3'})[0], 206)
        self.assertEqual(self.fetch(port, '/health')[0:3:2], (200, b'ok'))

    def test_only_pictures_with_their_random_name_are_reachable(self):
        (self.folder / 'pictures').mkdir()
        (self.folder / 'pictures' / 'notes.txt').write_text('private')
        (self.folder / 'secret.jpg').write_bytes(self.JPEG)
        url = self.store.put(self.JPEG)
        name = url.rsplit('/', 1)[1]
        port = self.listen()
        self.assertEqual(self.fetch(port, '/p/notes.txt')[0], 404)
        self.assertEqual(self.fetch(port, '/p/../secret.jpg')[0], 404)
        self.assertEqual(self.fetch(port, '/p/%2e%2e/secret.jpg')[0], 404)
        self.assertEqual(self.fetch(port, '/p/')[0], 404)
        self.assertEqual(self.fetch(port, '/p')[0], 404)
        self.assertEqual(self.fetch(port, '/')[0], 404)
        self.assertEqual(self.fetch(port, '/v1/state')[0], 404, 'the helper API must not be behind the tunnel')
        self.assertEqual(self.fetch(port, f'/p/{name[:-4]}.png')[0], 404)
        self.assertEqual(self.fetch(port, f'/p/{name}')[0], 200)
        self.assertEqual(self.fetch(port, f'/p/{name}', 'POST')[0], 501)

    def test_pictures_expire_after_keep_days(self):
        old = self.store.put(self.JPEG).rsplit('/', 1)[1]
        os.utime(self.folder / 'pictures' / old, (self.now[0] - 8 * 86400, self.now[0] - 8 * 86400))
        (self.folder / 'pictures' / 'keep.me').write_text('not a picture')
        os.utime(self.folder / 'pictures' / 'keep.me', (self.now[0] - 30 * 86400, self.now[0] - 30 * 86400))
        self.assertEqual(self.store.sweep(), 1)
        self.assertFalse((self.folder / 'pictures' / old).exists())
        self.assertTrue((self.folder / 'pictures' / 'keep.me').exists(), 'only pictures are swept')
        fresh = self.store.put(self.JPEG).rsplit('/', 1)[1]
        self.now[0] += 6 * 86400
        self.assertEqual(self.store.sweep(), 0)
        self.now[0] += 2 * 86400
        self.store.put(self.JPEG)  # putting one sweeps too
        self.assertFalse((self.folder / 'pictures' / fresh).exists())
        self.assertEqual(len([p for p in (self.folder / 'pictures').iterdir() if p.suffix == '.jpg']), 1)
        self.assertEqual(h.PictureStore(self.folder / 'nowhere', 'https://x').sweep(), 0, 'no folder yet is fine')

    def test_line_gets_the_stored_url_and_ntfy_its_attachment(self):
        calls = []

        class Answer:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, n=-1):
                return self.body

        def urlopen(request, timeout=None):
            calls.append((request.full_url, request.method, dict(request.headers), request.data))
            if request.method == 'PUT':
                return Answer(b'{"attachment": {"url": "https://ntfy.sh/file/abc.jpg"}}')
            return Answer(b'{}')

        cfg = {'notify': {'server': 'https://ntfy.sh', 'topic': 't0pic',
                          'line': {'channel_access_token': 'tok', 'to': 'U1', 'tags': ['bulb'], 'url': 'https://line.example/push'}}}
        h.Notifier(cfg, urlopen, pictures=self.store).post('燈', '亮', tags=['bulb'], picture=self.JPEG, picture_name='light.jpg')
        self.assertEqual([c[1] for c in calls], ['PUT', 'POST'])
        self.assertEqual(calls[0][0], 'https://ntfy.sh/t0pic')
        self.assertEqual(calls[0][3], self.JPEG, 'ntfy still gets the attachment')
        line = json.loads(calls[1][3])
        self.assertEqual(line['to'], 'U1')
        self.assertRegex(line['messages'][1]['originalContentUrl'], r'^https://pic\.example\.com/p/[A-Za-z0-9_-]{32}\.jpg$')
        self.assertEqual(line['messages'][1]['previewImageUrl'], line['messages'][1]['originalContentUrl'])
        name = line['messages'][1]['originalContentUrl'].rsplit('/', 1)[1]
        self.assertEqual((self.folder / 'pictures' / name).read_bytes(), self.JPEG)
        # Without a store (or when it fails) LINE gets ntfy's URL, as before.
        calls.clear()
        h.Notifier(cfg, urlopen).post('燈', '亮', tags=['bulb'], picture=self.JPEG)
        self.assertEqual(json.loads(calls[1][3])['messages'][1]['originalContentUrl'], 'https://ntfy.sh/file/abc.jpg')
        calls.clear()
        broken = h.PictureStore(self.folder / 'pictures' / 'keep.me' / 'x', 'https://pic.example.com')
        (self.folder / 'pictures' / 'keep.me').write_text('a file, not a folder')
        with self.assertLogs(level='WARNING'):
            h.Notifier(cfg, urlopen, pictures=broken).post('燈', '亮', tags=['bulb'], picture=self.JPEG)
        self.assertEqual(json.loads(calls[1][3])['messages'][1]['originalContentUrl'], 'https://ntfy.sh/file/abc.jpg')

    def test_the_store_comes_from_notify_pictures(self):
        self.assertEqual(h.pictures_from_config({'notify': {'topic': 't'}}, self.folder), (None, None))
        store, tunnel = h.pictures_from_config({'notify': {'pictures': {'base_url': 'https://pic.example.com/', 'keep_days': 3}}}, self.folder)
        self.assertEqual((store.folder, store.base_url, store.keep, tunnel), (self.folder / 'pictures', 'https://pic.example.com', 3 * 86400, None))
        store, _ = h.pictures_from_config({'notify': {'pictures': {'base_url': 'https://pic.example.com', 'dir': str(self.folder / 'elsewhere')}}}, self.folder)
        self.assertEqual((store.folder, store.keep), (self.folder / 'elsewhere', 7 * 86400))
        for bad in ({'base_url': 'http://pic.example.com'}, {'keep_days': 3}, {'cloudflared': str(self.folder / 'missing.exe')}):
            with self.assertRaises(ValueError, msg=bad):
                h.pictures_from_config({'notify': {'pictures': bad}}, self.folder)
        exe = self.folder / 'cloudflared.exe'
        exe.write_bytes(b'')
        store, tunnel = h.pictures_from_config({'notify': {'pictures': {'cloudflared': str(exe), 'port': 18795}}}, self.folder)
        self.assertEqual((tunnel.target, tunnel.command()[:3]), ('http://127.0.0.1:18795', [str(exe), 'tunnel', '--url']))
        self.assertIsNone(store.base_url, 'an address before the tunnel is up')
        self.assertIsNone(store.put(self.JPEG), 'a picture was kept with nowhere to serve it from')
        self.assertFalse((self.folder / 'pictures').exists())
        self.assertIsNone(h.parse_byte_range('bytes=', 10))
        self.assertIsNone(h.parse_byte_range('items=0-1', 10))
        self.assertIsNone(h.parse_byte_range('bytes=5-2', 10))
        self.assertIsNone(h.parse_byte_range('bytes=-0', 10))
        self.assertEqual(h.parse_byte_range('bytes=0-100', 10), (0, 9))
        self.assertEqual(h.parse_byte_range('bytes=-100', 10), (0, 9))
        self.assertEqual(h.parse_byte_range('bytes=0-1, 5-6', 10), (0, 1))

    def test_the_quick_tunnel_follows_cloudflared_and_restarts_it(self):
        """A fake cloudflared prints a fresh trycloudflare address each time it starts; the
        store's addresses follow it, and none is given while it is down."""
        import subprocess
        fake = self.folder / 'fake_cloudflared.py'
        fake.write_text('\n'.join([
            'import secrets, sys, time',
            'lines = ["2026-11-12T01:20:24Z INF Requesting new quick Tunnel on trycloudflare.com...",',
            '         "2026-11-12T01:20:29Z INF |  https://" + secrets.token_hex(4) + "-" + sys.argv[1].split(":")[-1] + ".trycloudflare.com   |",',
            '         "2026-11-12T01:20:29Z INF ICMP proxy will use 192.168.1.9 as source for IPv4",',
            '         "2026-11-12T01:20:30Z ERR Failed to dial a quic connection error=timeout connIndex=1"]',
            'sys.stderr.write("".join(line + chr(10) for line in lines))',
            'sys.stderr.flush()',
            'time.sleep(60)', '']), encoding='utf-8')

        def popen(command):
            self.assertEqual(command[1:3], ['tunnel', '--url'])
            return subprocess.Popen([sys.executable, str(fake), command[3]], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        tunnel = h.QuickTunnel(self.folder / 'cloudflared.exe', 'http://127.0.0.1:18795', popen=popen, restart_after=0.2)
        tunnel.end_leftovers = lambda: None
        store = h.PictureStore(self.folder / 'pictures', tunnel.current, keep_days=7, clock=lambda: self.now[0])
        self.assertIsNone(store.put(self.JPEG))
        with self.assertLogs(level='INFO') as logs:
            threading.Thread(target=tunnel.run_forever, daemon=True).start()
            self.addCleanup(tunnel.stop)
            self.assertTrue(tunnel.ready.wait(10), 'no address within 10 s')
            first = tunnel.current()
            self.assertRegex(first, r'^https://[0-9a-f]{8}-18795\.trycloudflare\.com$')
            self.assertEqual(store.base_url, first)
            self.assertTrue(store.put(self.JPEG).startswith(first + '/p/'))
            time.sleep(0.3)  # the ERR line is read
        self.assertTrue(any('tunnel: up at ' + first in line for line in logs.output))
        self.assertTrue(any('Failed to dial' in line and 'WARNING' in line for line in logs.output), 'the error line was not logged')
        self.assertFalse(any('192.168.1.9' in line for line in logs.output), "cloudflared's other lines went to the log")
        self.assertTrue(h.keep_child_with_us(tunnel.process) if os.name == 'nt' else True, 'the job object failed')
        tunnel.process.kill()
        deadline = time.monotonic() + 10
        while tunnel.current() in (None, first) and time.monotonic() < deadline:
            time.sleep(0.05)
        second = tunnel.current()
        self.assertTrue(second and second != first, f'no new address after a restart: {second}')
        self.assertEqual(tunnel.starts, 2)
        tunnel.stop()
        self.assertIsNotNone(tunnel.process.wait(5))
        # cloudflared missing: no address, nothing kept, cloudflared is tried again.
        slept = []
        gone = h.QuickTunnel(self.folder / 'nope.exe', 'http://127.0.0.1:1', popen=lambda c: (_ for _ in ()).throw(OSError('no such file')),
                             restart_after=0.01, sleep=lambda s: slept.append(s) or (len(slept) > 2 and setattr(gone, 'stopped', True)))
        gone.end_leftovers = lambda: None
        with self.assertLogs(level='WARNING'):
            gone.run_forever()
        self.assertEqual((gone.current(), gone.starts), (None, 3))


class GitPicturesTests(unittest.TestCase):
    """0.5.53: pictures for LINE committed to a branch of a public repository (a local bare
    repository stands in for GitHub); expired ones are dropped and the branch rewritten."""

    JPEG = b'\xff\xd8\xff\xe0' + bytes(range(256)) + b'\xff\xd9'

    def setUp(self):
        import subprocess
        if shutil.which('git') is None:
            self.skipTest('git is not installed')
        self.root = Path(tempfile.mkdtemp(prefix='gitpictures-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bare = self.root / 'origin.git'
        git = lambda *args, cwd=self.root: subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@x', *args], cwd=str(cwd), check=True, capture_output=True)
        git('init', '-q', '--bare', str(self.bare))
        seed = self.root / 'seed'
        git('init', '-q', str(seed))
        git('checkout', '-q', '--orphan', 'pictures', cwd=seed)
        (seed / 'README.md').write_text('pictures\n')
        git('add', 'README.md', cwd=seed)
        git('commit', '-q', '-m', 'seed', cwd=seed)
        git('push', '-q', str(self.bare), 'pictures:pictures', cwd=seed)
        self.git = git
        self.now = [1_762_900_000.0]  # 2025-11-11T...Z
        self.store = h.GitPictures(self.root / 'clone', str(self.bare), branch='pictures', raw_base='https://raw.example/o/r/pictures/',
                                   keep_days=7, clock=lambda: self.now[0])

    def on_origin(self, *args):
        return self.git(*args, cwd=self.bare).stdout.decode('utf-8', 'replace')

    def test_pictures_are_pushed_under_random_names_and_old_ones_drop_off_with_their_history(self):
        url = self.store.put(self.JPEG)
        self.assertRegex(url, r'^https://raw\.example/o/r/pictures/\d{8}T\d{6}Z-[A-Za-z0-9_-]{16}\.jpg$')
        first = url.rsplit('/', 1)[1]
        self.assertTrue(first.startswith('20251111T'))
        self.assertEqual(self.git('show', f'pictures:{first}', cwd=self.bare).stdout, self.JPEG, 'the picture did not reach origin')
        self.assertNotEqual(self.store.put(self.JPEG).rsplit('/', 1)[1], first)
        self.assertEqual(self.on_origin('rev-list', '--count', 'pictures').strip(), '3')
        # Someone else pushed to the branch meanwhile: the next picture still goes up.
        seed = self.root / 'seed'
        self.git('pull', '-q', str(self.bare), 'pictures', cwd=seed)
        (seed / 'NOTE.md').write_text('elsewhere\n')
        self.git('add', 'NOTE.md', cwd=seed)
        self.git('commit', '-q', '-m', 'elsewhere', cwd=seed)
        self.git('push', '-q', str(self.bare), 'pictures:pictures', cwd=seed)
        self.store.put(self.JPEG)
        self.assertIn('NOTE.md', self.on_origin('ls-tree', '--name-only', 'pictures').split())
        self.assertEqual(self.on_origin('rev-list', '--count', 'pictures').strip(), '5')
        self.assertEqual(self.store.sweep(force=True), 0, 'a fresh picture was swept')
        # Eight days on: the two old pictures go, the branch starts over with what is left.
        self.now[0] += 8 * 86400
        third = self.store.put(self.JPEG).rsplit('/', 1)[1]
        files = sorted(self.on_origin('ls-tree', '--name-only', 'pictures').split())
        self.assertEqual(files, sorted(['NOTE.md', 'README.md', third]))
        self.assertEqual(self.on_origin('rev-list', '--count', 'pictures').strip(), '1', 'the history still holds the old pictures')
        self.assertEqual(self.store.sweep(force=True), 0)
        # The next day's put does not sweep again until a day has passed.
        self.store.swept = self.now[0]
        self.now[0] += 3600
        self.store.put(self.JPEG)
        self.assertEqual(self.on_origin('rev-list', '--count', 'pictures').strip(), '2')

    def test_failures_leave_line_with_the_ntfy_picture(self):
        calls = []

        class Answer:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, n=-1):
                return b'{"attachment": {"url": "https://ntfy.sh/file/abc.jpg"}}'

        def urlopen(request, timeout=None):
            calls.append(json.loads(request.data) if request.method == 'POST' else None)
            return Answer()
        broken = h.GitPictures(self.root / 'clone2', str(self.root / 'nowhere.git'), raw_base='https://raw.example/x', clock=lambda: self.now[0])
        with self.assertRaises(OSError):
            broken.ensure()
        cfg = {'notify': {'server': 'https://ntfy.sh', 'topic': 't', 'line': {'channel_access_token': 'tok', 'to': 'U1', 'url': 'https://line.example/push'}}}
        with self.assertLogs(level='WARNING'):
            h.Notifier(cfg, urlopen, pictures=broken).post('燈', '亮', picture=self.JPEG)
        self.assertEqual(calls[-1]['messages'][1]['originalContentUrl'], 'https://ntfy.sh/file/abc.jpg')
        # github.com addresses give raw.githubusercontent.com; others need raw_base.
        self.assertEqual(h.GitPictures.github_raw('https://github.com/me/repo.git', 'pictures'), 'https://raw.githubusercontent.com/me/repo/pictures')
        self.assertEqual(h.GitPictures.github_raw('https://github.com/me/repo', 'p'), 'https://raw.githubusercontent.com/me/repo/p')
        with self.assertRaises(ValueError):
            h.GitPictures.github_raw('https://gitlab.com/me/repo.git', 'pictures')
        store, tunnel = h.pictures_from_config({'notify': {'pictures': {'git': {'url': 'https://github.com/me/repo.git'}, 'keep_days': 3}}}, self.root)
        self.assertEqual((type(store), tunnel, store.folder, store.raw_base, store.keep, store.branch),
                         (h.GitPictures, None, self.root / 'pictures-git', 'https://raw.githubusercontent.com/me/repo/pictures', 3 * 86400, 'pictures'))
        with self.assertRaises(ValueError):
            h.pictures_from_config({'notify': {'pictures': {'git': {'branch': 'x'}}}}, self.root)


if __name__ == '__main__':
    unittest.main()


