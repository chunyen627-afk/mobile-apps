"""Desk remote helper: lets the iPhone app use the Claude and Codex desktop apps on this PC.

It lists the desktop apps' conversations from their own files and serves each conversation's
transcript as events, over HTTP bound to one ZeroTier address only, with a Bearer token (five
wrong tokens lock it for ten minutes, sent to ntfy). It never writes to the desktop apps' files.
Sending a message, answering a permission question and starting a conversation go through the
apps' own windows (UI Automation, uia_worker.ps1), only while nobody is using the PC.

Run at login in the user's interactive session:  pythonw desk_remote_helper.py [--config PATH]
Simulator tests:  python3 desk_remote_helper.py --fake ../fixtures/fake-helper
"""
import argparse
import ctypes
import glob
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import secrets
import shutil
import sqlite3
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from logging.handlers import RotatingFileHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # elevate.py sits next to this file, also under -I
import elevate  # noqa: E402

VERSION = '0.5.26'
APPS = ('claude', 'codex')
UTC = timezone.utc

TAIL_BYTES = 3 * 1024 * 1024      # first read of a transcript starts this far from its end
MAX_EVENTS = 800                   # events kept per transcript
FIRST_PAGE = 150                   # events sent when the app opens a conversation
MAX_PAGE = 300
MAX_WAIT = 25                      # long-poll seconds
ACTIVE_SECONDS = 90                # a transcript written this recently counts as active
ITEM_LIMIT = 256 * 1024            # full text kept for an expanded tool output
TEXT_LIMITS = {'user': 12000, 'assistant': 12000, 'tool_call': 600, 'tool_result': 1500, 'status': 600}

CLAUDE_ID = re.compile(r'^local_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
CODEX_ID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
ITEM_ID = re.compile(r'^i[0-9]{1,9}$')
# Text the desktop app injects as a user turn but the user never typed.
NOISE_PREFIXES = ('<command-name>', '<command-message>', '<local-command-', '<system-reminder>',
                  '<task-notification>', '<side-sessions-event>', '<ci-monitor-event>',
                  '# AGENTS.md instructions', '<environment_context>', '<user_instructions>',
                  '<external_codex', '<turn_aborted>', '<heartbeat>')


def iso(value):
    """RFC 3339 UTC text from epoch milliseconds, epoch seconds or an ISO string; None if unusable."""
    if value is None:
        return None
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC).strftime('%Y-%m-%dT%H:%M:%SZ')
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        seconds = value / 1000 if value > 1e11 else value
        return datetime.fromtimestamp(seconds, UTC).strftime('%Y-%m-%dT%H:%M:%SZ')
    return None


def folder_name(cwd):
    """Only the last folder name goes to the phone, never the full path."""
    if not cwd:
        return None
    text = str(cwd)
    if text.startswith('file:///'):
        text = urllib.parse.unquote(text[8:])
    return re.split(r'[\\/]', text.rstrip('\\/'))[-1] or text


def is_noise(text):
    return text.lstrip().startswith(NOISE_PREFIXES)


# Claude for Chrome's permission card (the worker lists it under this title, photo 10/31).
EXTENSION_TITLE = 'Claude for Chrome'
EXTENSION_ALLOW = 'Allow this action'
EXTENSION_READ = 'read page content'


EFFORT_LABELS = {'low': '低', 'medium': '中', 'high': '高', 'xhigh': '超高', 'max': '最高'}
# Context window sizes the desktop app itself reported (Claude 10/27: Opus 5.5 has 1M) or that
# the transcripts prove (10/31: Fable 5.1 and Opus 4.8 conversations reached 967K and 949K tokens
# of input, so 1M). Models not listed show tokens used without a percentage rather than a guessed
# size; more can be added under "claude": {"context_windows": {"<model id prefix>": size}} in
# config.json.
CONTEXT_WINDOWS = {'claude-opus-5': 1_000_000, 'claude-fable-5': 1_000_000, 'claude-opus-4-8': 1_000_000}


def model_label(model_id):
    """The name the desktop apps show: 'claude-opus-5-5' -> 'Opus 5.5', 'gpt-6.1-sol' ->
    'GPT-6.1 Sol'. Other shapes are returned as they are."""
    if not model_id:
        return None
    text = re.sub(r'\[[^\]]*\]$', '', str(model_id))
    match = re.fullmatch(r'claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?', text)
    if match:
        return f'{match.group(1).capitalize()} {match.group(2)}' + (f'.{match.group(3)}' if match.group(3) else '')
    match = re.fullmatch(r'gpt-([\d.]+)(?:-([a-z]+))?', text)
    if match:
        return f'GPT-{match.group(1)}' + (f' {match.group(2).capitalize()}' if match.group(2) else '')
    return text


def context_info(used, window):
    """{used, window, percent} for the phone; window and percent stay None when unknown."""
    if not isinstance(used, int) or used <= 0:
        return None
    if not isinstance(window, int) or window <= 0:
        return {'used': used, 'window': None, 'percent': None}
    return {'used': used, 'window': window, 'percent': min(100, round(100 * used / window))}


def window_label(minutes):
    if minutes == 300:
        return '5 小時'
    if minutes == 10080:
        return '每週'
    if isinstance(minutes, int) and minutes > 0:
        return f'{minutes // 1440} 天' if minutes % 1440 == 0 else f'{round(minutes / 60)} 小時'
    return '用量'


def ui_usage(name, prefix):
    """The Claude composer's usage button, e.g. '使用量：每週 · 所有模型：46% 週日上午11:00 重設'
    -> {label, percent, resetsText}; None when it does not read that way."""
    if not name or not prefix or not name.startswith(prefix):
        return None
    match = re.fullmatch(r'(.+?)[：:]\s*(\d{1,3})%\s*(.*)', name[len(prefix):].strip())
    if not match:
        return None
    return {'label': match.group(1).strip(), 'percent': int(match.group(2)), 'resetsText': match.group(3).strip() or None}


def account_mark(app, raw):
    """A short one-way mark of the signed-in account, so the phone can tell that two PCs share
    one plan (and show the newer limits on both) without learning the account's id."""
    return hashlib.sha256(f'{app}:{raw}'.encode('utf-8')).hexdigest()[:16] if raw else None


# The usage card's row names differ by version (live 10/28: 3.6556 "工作階段限制" and "每週 · 所有
# 模型", 4.29 "5 小時限制", "每週" and "每週 · Fable"): the phone shows them without "限制".
CARD_LABELS = {'每週 · 所有模型': '每週'}
WEEKDAYS = '一二三四五六日'


def card_label(name):
    name = (name or '').strip()
    return CARD_LABELS.get(name) or name.removesuffix('限制').strip() or '用量'


def clock_reset(text, read_at):
    """'週四上午2:20 重設' read at `read_at` -> the next such local time's epoch seconds, or None."""
    match = re.fullmatch(r'週([一二三四五六日])\s*(上午|下午)?\s*(\d{1,2}):(\d{2})\s*重設', (text or '').strip())
    if not match:
        return None
    day, half, hour, minute = WEEKDAYS.index(match.group(1)), match.group(2), int(match.group(3)), int(match.group(4))
    if half == '下午' and hour < 12:
        hour += 12
    elif half == '上午' and hour == 12:
        hour = 0
    start = datetime.fromtimestamp(read_at)
    for ahead in range(8):
        candidate = (start + timedelta(days=ahead)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        if candidate.weekday() == day and candidate.timestamp() > read_at - 60:
            return candidate.timestamp()
    return None


def relative_reset(text, read_at):
    """'2 小時 56 分後重設' read at `read_at` -> the reset's epoch seconds; None for other wording
    (the weekly row says '週日上午11:00 重設', which stays text)."""
    match = re.fullmatch(r'(?:(\d+)\s*天\s*)?(?:(\d+)\s*小時\s*)?(?:(\d+)\s*分(?:鐘)?\s*)?後重設', (text or '').strip())
    if not match or not any(match.groups()):
        return None
    days, hours, minutes = (int(part or 0) for part in match.groups())
    return read_at + days * 86400 + hours * 3600 + minutes * 60


def card_windows(rows, read_at, now):
    """The usage card's rows as windows; a row whose reset has passed since it was read is left out."""
    windows = []
    for row in rows or []:
        if not isinstance(row, dict) or not isinstance(row.get('percent'), (int, float)):
            continue
        reset = row.get('reset') or None
        resets_at = relative_reset(reset, read_at)  # "2 小時 56 分後重設" goes stale: shown as a time
        expires = resets_at if resets_at is not None else clock_reset(reset, read_at)  # "週四上午2:20 重設" stays text
        if expires is not None and expires <= now:
            continue
        windows.append({'label': card_label(row.get('label')), 'percent': round(row['percent']),
                        'resetsAt': iso(resets_at) if resets_at is not None else None,
                        'resetsText': None if resets_at is not None else reset})
    return windows


def merge_claude_usage(from_file, button, button_at, now, card=None, card_at=None):
    """Claude's limits from the freshest of three readings. The usage card (the button expanded,
    read every few minutes while nobody uses the PC) is the only one with the session limit; the
    button shows the week; the history file stopped for days (live 10/28: the office's 3.6556
    since 10/27 17:49, the home PC's 4.29 since its update). The weekly percent comes from the
    button whenever it was read after the card or the file; a 5-hour figure from the file older
    than five hours is left out (that window has reset since). `sampledAt` is the oldest time
    behind what is shown."""
    file_at = datetime.fromisoformat(from_file['sampledAt'].replace('Z', '+00:00')).timestamp() if from_file else None
    weekly = button if button and button_at and button['label'].startswith('每週') else None
    if card and card_at and (file_at is None or card_at > file_at):
        windows = card_windows(card, card_at, now)
        if windows:
            times = [card_at]
            if weekly and button_at > card_at:
                week = {'label': '每週', 'percent': weekly['percent'], 'resetsAt': None, 'resetsText': weekly['resetsText']}
                windows = [w for w in windows if w['label'] != '每週'] + [week]
            return {'windows': windows, 'sampledAt': iso(min(times))}
    fresher = weekly is not None and (file_at is None or button_at > file_at)
    windows, times = [], []
    for window in (from_file or {}).get('windows') or []:
        if window['label'] == '5 小時' and now - file_at < 5 * 3600:
            windows.append(window)
            times.append(file_at)
        elif window['label'] == '每週' and not fresher:
            windows.append(dict(window, resetsText=weekly['resetsText'] if weekly else None))
            times.append(file_at)
    if fresher:
        windows.append({'label': '每週', 'percent': weekly['percent'], 'resetsAt': None, 'resetsText': weekly['resetsText']})
        times.append(button_at)
    return {'windows': windows, 'sampledAt': iso(min(times))} if windows else None


def ui_model(name, strip):
    """A composer's model button -> (model, effort): Claude's '模型：Opus 5.5 高' (strip '模型：')
    -> ('Opus 5.5', '高'), Codex's 'GPT-6.1 Sol 高' (nothing to strip) -> ('GPT-6.1 Sol', '高')."""
    if not name or strip is None or not name.startswith(strip):
        return None, None
    rest = name[len(strip):].strip()
    head, _, last = rest.rpartition(' ')
    if head and (last in EFFORT_LABELS.values() or last == 'Ultracode'):
        return head, last
    return rest or None, None


# Codex's approvals_reviewer in turn_context -> the permission menu's wording.
CODEX_MODES = {'user': '要求核准', 'auto_review': '代我核准'}
IMPORTED_NOTE = '匯入的舊對話，回覆一次後才有資料'


def open_link(pc_name, app=None, session_id=None, title=None, elevate=False):
    """The phone app's link a notification opens: straight to the conversation (or the
    administrator requests) on this PC."""
    query = {'pc': pc_name}
    if elevate:
        query['elevate'] = '1'
    if app and session_id:
        query.update({'app': app, 'session': session_id, 'title': title or ''})
    return 'deskremote://open?' + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)


def flatten(content):
    """Text of a tool result or message body that may be a string or a list of blocks."""
    if content is None:
        return ''
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                if block.get('type') in ('image', 'input_image'):
                    parts.append('[圖片]')
                elif isinstance(block.get('text'), str):
                    parts.append(block['text'])
        return '\n'.join(parts)
    if isinstance(content, dict) and isinstance(content.get('text'), str):
        return content['text']
    return json.dumps(content, ensure_ascii=False)[:2000]


def summarize_input(name, data):
    """One line that says what a tool call does: the command, file or pattern."""
    if not isinstance(data, dict):
        return str(data)[:600]
    if isinstance(data.get('command'), list):
        return ' '.join(str(part) for part in data['command'])
    for key in ('command', 'file_path', 'notebook_path', 'pattern', 'url', 'query', 'description', 'prompt'):
        if isinstance(data.get(key), str) and data[key].strip():
            return data[key]
    return json.dumps(data, ensure_ascii=False)


# ---------------------------------------------------------------------------------------------
# Transcript parsers: one JSON line in, zero or more raw events out.
# A raw event is {kind, text, ts, tool?, isError?}.


QUESTION_TOOL = 'AskUserQuestion'
INTERRUPTED = '[Request interrupted by user'
COMPACTED = '對話已壓縮'  # the app squeezed the earlier part into a summary; the messages stay


def is_wrap_up(name):
    """The desktop app's next-step box (its reply buttons are just messages to send)."""
    return name == 'wrap_up' or name.endswith('__wrap_up')


def question_from(tool_id, data):
    """A pending option question in the shape the phone shows, or None if it is not one."""
    if not isinstance(data, dict) or not isinstance(data.get('questions'), list):
        return None
    questions = []
    for item in data['questions']:
        if not isinstance(item, dict) or not isinstance(item.get('options'), list):
            return None
        options = [{'label': str(o.get('label') or ''), 'description': o.get('description') or None}
                   for o in item['options'] if isinstance(o, dict) and o.get('label')]
        questions.append({'question': str(item.get('question') or ''), 'header': item.get('header') or None,
                          'multiSelect': bool(item.get('multiSelect')), 'options': options})
    return {'questionId': tool_id, 'questions': questions} if questions else None


def suggestions_from(data):
    """Reply buttons of the next-step box: only those that send words, not app actions."""
    if not isinstance(data, dict):
        return None
    replies = []
    for action in data.get('actions') or []:
        if not isinstance(action, dict) or action.get('action') or not action.get('label'):
            continue
        replies.append({'label': str(action['label']), 'message': str(action.get('message') or action['label'])})
    return {'ask': data.get('ask') or None, 'replies': replies} if replies else None


class ClaudeParser:
    """`~/.claude/projects/*/<cliSessionId>.jsonl` written by the Claude desktop app (Code tab).

    Besides events it keeps what is waiting for the person now: an unanswered option question
    (AskUserQuestion without its result yet) and the latest next-step box's reply buttons,
    which last until the person sends the next message."""

    def __init__(self):
        self.tool_names = {}
        self.status = 'idle'
        self.queued = []  # messages Claude accepted but holds, e.g. while a question is pending
        self.question = None
        self.suggestions = None
        self.model = None
        self.context = None  # tokens the last reply was given: its input plus cache reads and writes

    def feed(self, obj):
        kind = obj.get('type')
        if kind == 'queue-operation':
            content = obj.get('content')
            if obj.get('operation') == 'enqueue' and isinstance(content, str):
                self.queued.append(content)
            elif obj.get('operation') in ('dequeue', 'remove') and self.queued:
                self.queued.pop(0)
            return []
        if kind == 'attachment' and not obj.get('isSidechain'):
            # A message the person sent while a turn was running is not a user message: Claude
            # hands it to the running turn as a queued_command attachment (seen live 10/28), so the
            # phone lost it once the pending bubble was gone.
            attachment = obj.get('attachment') or {}
            origin = attachment.get('origin') or {}
            if attachment.get('type') != 'queued_command' or (isinstance(origin, dict) and origin.get('kind') not in (None, 'human')):
                return []
            prompt = attachment.get('prompt')
            obj = {'type': 'user', 'timestamp': attachment.get('timestamp') or obj.get('timestamp'),
                   'message': {'role': 'user', 'content': prompt if isinstance(prompt, (str, list)) else []}}
            kind = 'user'
        if kind == 'user' and obj.get('isCompactSummary') and not obj.get('isSidechain'):
            # A long conversation squeezed into a summary is written as a 13-23k-character user
            # message (seen live 10/30): on the phone it was a huge bubble the person never typed.
            return [{'kind': 'status', 'text': COMPACTED, 'ts': iso(obj.get('timestamp'))}]
        if kind not in ('user', 'assistant') or obj.get('isSidechain') or obj.get('isMeta'):
            return []
        message = obj.get('message') or {}
        content = message.get('content')
        ts = iso(obj.get('timestamp'))
        out = []
        if kind == 'user':
            # A stopped turn is written as a user message "[Request interrupted by user…]" (seen live
            # 10/27): it ends the turn, it is not something the person typed.
            texts = [content] if isinstance(content, str) else \
                [b.get('text', '') for b in content or [] if isinstance(b, dict) and b.get('type') == 'text']
            if texts and all(t.strip().startswith(INTERRUPTED) for t in texts):
                self.status = 'idle'
                return [{'kind': 'status', 'text': '已中止', 'ts': ts}]
            if isinstance(content, str):
                if content.strip() and not is_noise(content):
                    out.append({'kind': 'user', 'text': content, 'ts': ts})
                    self.status = 'working'
                    self.suggestions = None
                return out
            for block in content or []:
                if not isinstance(block, dict):
                    continue
                if block.get('type') == 'text' and block.get('text', '').strip() and not is_noise(block['text']):
                    out.append({'kind': 'user', 'text': block['text'], 'ts': ts})
                    self.status = 'working'
                    self.suggestions = None
                elif block.get('type') == 'image':
                    out.append({'kind': 'user', 'text': '[圖片]', 'ts': ts})
                    self.status = 'working'
                    self.suggestions = None
                elif block.get('type') == 'tool_result':
                    tool = self.tool_names.get(block.get('tool_use_id'), '')
                    if tool == QUESTION_TOOL:
                        if self.question and self.question['questionId'] == block.get('tool_use_id'):
                            self.question = None
                        out.append({'kind': 'status', 'text': '已回答選項題', 'ts': ts})
                    elif not is_wrap_up(tool):
                        out.append({'kind': 'tool_result', 'text': flatten(block.get('content')), 'ts': ts,
                                    'tool': tool, 'isError': bool(block.get('is_error'))})
            return out
        usage = message.get('usage')
        if isinstance(usage, dict):
            parts = [usage.get(k) for k in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')]
            total = sum(p for p in parts if isinstance(p, int))
            if total > 0:
                self.context = total
        if isinstance(message.get('model'), str) and message['model'].startswith('claude-'):
            self.model = message['model']  # not '<synthetic>' (local notices)
        for block in content or []:
            if not isinstance(block, dict):
                continue
            if block.get('type') == 'text' and block.get('text', '').strip():
                out.append({'kind': 'assistant', 'text': block['text'], 'ts': ts})
            elif block.get('type') == 'tool_use':
                name = block.get('name') or ''
                self.tool_names[block.get('id')] = name
                if name == QUESTION_TOOL:
                    self.question = question_from(block.get('id'), block.get('input'))
                elif is_wrap_up(name):
                    self.suggestions = suggestions_from(block.get('input'))
                else:
                    out.append({'kind': 'tool_call', 'tool': name, 'text': summarize_input(name, block.get('input')),
                                'ts': ts})
        if message.get('stop_reason') == 'end_turn':
            self.status = 'idle'
        return out


class CodexParser:
    """`~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl` written by the Codex desktop app.

    Newer files describe each turn with `item_completed` events; older ones with `user_message`
    and `agent_message` events plus `response_item` tool calls. Once a file shows the newer form,
    the older events are ignored so nothing is shown twice.
    """

    def __init__(self):
        self.modern = False
        self.calls = {}
        self.status = 'idle'
        self.model = self.effort = self.mode = None
        self.turn_ts = None  # when the last turn_context (model, effort, mode) was written
        self.context = self.window = None
        self.rate_limits = self.rate_ts = None

    def feed(self, obj):
        kind = obj.get('type')
        payload = obj.get('payload') or {}
        ts = iso(obj.get('timestamp'))
        ptype = payload.get('type')
        if kind == 'turn_context':
            self.model = payload.get('model') or self.model
            self.effort = payload.get('effort') or self.effort
            self.mode = CODEX_MODES.get(payload.get('approvals_reviewer'), self.mode)
            self.turn_ts = ts or self.turn_ts
            return []
        if kind == 'event_msg':
            if ptype == 'token_count':
                info = payload.get('info') or {}
                last = info.get('last_token_usage') or {}
                if isinstance(last.get('input_tokens'), int):
                    self.context = last['input_tokens']  # includes the cached part
                if isinstance(info.get('model_context_window'), int):
                    self.window = info['model_context_window']
                if isinstance(payload.get('rate_limits'), dict):
                    self.rate_limits, self.rate_ts = payload['rate_limits'], ts
                return []
            if ptype == 'task_started':
                self.status = 'working'
                return []
            if ptype in ('task_complete', 'turn_aborted'):
                self.status = 'idle'
                return [{'kind': 'status', 'text': '已中止' if ptype == 'turn_aborted' else '完成', 'ts': ts}]
            if ptype == 'item_completed':
                self.modern = True
                return self.item(payload.get('item') or {}, ts)
            if not self.modern and ptype in ('user_message', 'agent_message'):
                text = payload.get('message') or ''
                if text.strip() and not is_noise(text):
                    return [{'kind': 'user' if ptype == 'user_message' else 'assistant', 'text': text, 'ts': ts}]
            return []
        if kind == 'compacted':
            return [{'kind': 'status', 'text': COMPACTED, 'ts': ts}]
        if kind == 'response_item' and not self.modern:
            if ptype in ('function_call', 'custom_tool_call'):
                name = payload.get('name') or ''
                self.calls[payload.get('call_id')] = name
                raw = payload.get('arguments') if ptype == 'function_call' else payload.get('input')
                try:
                    data = json.loads(raw) if isinstance(raw, str) else raw
                except ValueError:
                    data = raw
                text = summarize_input(name, data) if isinstance(data, dict) else str(raw or '')
                return [{'kind': 'tool_call', 'tool': name, 'text': text, 'ts': ts}]
            if ptype in ('function_call_output', 'custom_tool_call_output'):
                output = payload.get('output')
                if isinstance(output, dict):
                    output = output.get('content', output)
                return [{'kind': 'tool_result', 'tool': self.calls.get(payload.get('call_id'), ''),
                         'text': flatten(output), 'ts': ts}]
        return []

    def item(self, item, ts):
        itype = item.get('type')
        if itype == 'UserMessage':
            text = flatten(item.get('content'))
            return [{'kind': 'user', 'text': text, 'ts': ts}] if text.strip() and not is_noise(text) else []
        if itype == 'AgentMessage':
            text = flatten(item.get('content'))  # Automation heartbeats are echoed back; hide those too.
            return [{'kind': 'assistant', 'text': text, 'ts': ts}] if text.strip() and not is_noise(text) else []
        if itype == 'CommandExecution':
            parsed = item.get('parsed_cmd') or []
            command = parsed[0].get('cmd') if parsed and isinstance(parsed[0], dict) else None
            if not command:
                cmd = item.get('command')
                command = ' '.join(cmd[2:] if isinstance(cmd, list) and len(cmd) > 2 else cmd or []) \
                    if isinstance(cmd, list) else str(cmd or '')
            out = [{'kind': 'tool_call', 'tool': '指令', 'text': command, 'ts': ts}]
            exit_code = item.get('exit_code')
            output = item.get('aggregated_output') or ''
            if exit_code not in (None, 0):
                output = f'結束碼 {exit_code}\n{output}'
            out.append({'kind': 'tool_result', 'tool': '指令', 'text': output, 'ts': ts,
                        'isError': exit_code not in (None, 0)})
            return out
        if itype == 'FileChange':
            changes = item.get('changes') or {}
            files = '\n'.join(f"{(value or {}).get('type', '')} {name}" for name, value in changes.items()) \
                if isinstance(changes, dict) else str(changes)
            return [{'kind': 'tool_call', 'tool': '檔案變更', 'text': files, 'ts': ts},
                    {'kind': 'tool_result', 'tool': '檔案變更', 'text': item.get('stdout') or item.get('stderr') or '',
                     'ts': ts, 'isError': item.get('status') == 'failed'}]
        if itype == 'McpToolCall':
            name = f"{item.get('server', '')}.{item.get('tool', '')}"
            result = item.get('result')
            text = flatten(result.get('content')) if isinstance(result, dict) else flatten(result)
            return [{'kind': 'tool_call', 'tool': name, 'text': summarize_input(name, item.get('arguments')), 'ts': ts},
                    {'kind': 'tool_result', 'tool': name, 'text': text, 'ts': ts,
                     'isError': item.get('status') == 'failed'}]
        return []


# ---------------------------------------------------------------------------------------------
# Transcript: reads only the new complete lines of one JSONL file and keeps numbered events.


class Transcript:
    def __init__(self, path, parser_factory):
        self.path = Path(path)
        self.parser_factory = parser_factory
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        self.epoch = secrets.token_hex(4)
        self.parser = self.parser_factory()
        self.offset = None
        self.events = []
        self.items = {}
        self.seq = 0
        self.earlier = False
        self.skipped = 0

    def refresh(self):
        with self.lock:
            try:
                size = self.path.stat().st_size
            except OSError:
                return
            if self.offset is not None and size < self.offset:
                self.reset()  # Rewritten or truncated: start over under a new epoch.
            start = self.offset
            if start is None:
                start = max(0, size - TAIL_BYTES)
                self.earlier = start > 0
            if size == start:
                self.offset = start
                return
            with self.path.open('rb') as handle:
                handle.seek(start)
                data = handle.read(size - start)
            if self.offset is None and start > 0:
                cut = data.find(b'\n')  # The first line read from the middle is partial.
                data, start = (data[cut + 1:], start + cut + 1) if cut >= 0 else (b'', size)
            end = data.rfind(b'\n')
            if end < 0:
                self.offset = start
                return
            self.offset = start + end + 1
            for raw in data[:end].split(b'\n'):
                if not raw.strip():
                    continue
                try:
                    obj = json.loads(raw.decode('utf-8'))
                except (ValueError, UnicodeDecodeError):
                    self.skipped += 1
                    continue
                if not isinstance(obj, dict):
                    continue
                try:
                    produced = self.parser.feed(obj)
                except (AttributeError, TypeError, KeyError, IndexError):
                    self.skipped += 1
                    continue
                for event in produced:
                    self.add(event)

    def add(self, raw):
        self.seq += 1
        event = {'seq': self.seq, 'ts': raw.get('ts'), 'kind': raw['kind'], 'text': raw.get('text') or ''}
        if raw.get('tool'):
            event['tool'] = raw['tool']
        if raw.get('isError'):
            event['isError'] = True
        limit = TEXT_LIMITS.get(raw['kind'], 2000)
        if len(event['text']) > limit:
            item_id = f'i{self.seq}'
            self.items[item_id] = event['text'][:ITEM_LIMIT]
            event['text'] = event['text'][:limit]
            event['truncated'] = True
            event['itemId'] = item_id
        self.events.append(event)
        if len(self.events) > MAX_EVENTS:
            dropped = self.events[:-MAX_EVENTS]
            self.events = self.events[-MAX_EVENTS:]
            self.earlier = True
            for old in dropped:
                self.items.pop(old.get('itemId'), None)

    def page(self, after, epoch):
        """Events after `after` in the same epoch, or the latest page with reset=True."""
        with self.lock:
            waiting = {'question': getattr(self.parser, 'question', None),
                       'suggestions': getattr(self.parser, 'suggestions', None)}
            if epoch != self.epoch or after <= 0 or after > self.seq:
                events = self.events[-FIRST_PAGE:]
                earlier = self.earlier or len(self.events) > len(events)
                return dict(waiting, epoch=self.epoch, reset=True, events=events, earlier=earlier,
                            cursor=self.seq, status=self.parser.status)
            events = [event for event in self.events if event['seq'] > after][:MAX_PAGE]
            cursor = events[-1]['seq'] if events else after
            return dict(waiting, epoch=self.epoch, reset=False, events=events, earlier=False,
                        cursor=cursor, status=self.parser.status)

    def waiting_key(self):
        """Changes whenever the pending question or reply buttons change."""
        with self.lock:
            question = getattr(self.parser, 'question', None)
            suggestions = getattr(self.parser, 'suggestions', None)
            return ((question or {}).get('questionId'), json.dumps(suggestions, sort_keys=True, ensure_ascii=False))

    def item(self, item_id):
        with self.lock:
            return self.items.get(item_id)


# ---------------------------------------------------------------------------------------------
# Conversation lists, read from each desktop app's own files.


class ClaudeSource:
    """Claude desktop keeps one JSON per Code conversation under
    %LOCALAPPDATA%/Claude-Data/claude_<package>/claude-code-sessions/<account>/<org>/local_<id>.json.
    This is an internal format: anything unexpected is skipped and counted, never guessed."""

    # The desktop app's own names for the modes (its permission mode menu, read 10/27).
    PERMISSION_LABELS = {'default': '手動', 'acceptEdits': '接受編輯', 'plan': '計畫',
                         'auto': '自動', 'bypassPermissions': '略過權限確認', 'dontAsk': '不詢問'}
    id_pattern = CLAUDE_ID
    parser = ClaudeParser

    def __init__(self, data_root, projects_dir, context_windows=None):
        self.data_root = Path(data_root)
        self.projects_dir = Path(projects_dir)
        self.context_windows = dict(CONTEXT_WINDOWS, **(context_windows or {}))
        self.cache = {}       # file path -> (mtime, parsed metadata)
        self.paths = {}       # cliSessionId -> transcript path
        self.warning = None

    def account(self):
        """The signed-in organisation (the folder holding its conversations), as a mark."""
        folder = self.sessions_dir()
        return account_mark('claude', Path(folder).name) if folder else None

    def sessions_dir(self):
        """The account folder written most recently: the one signed in to the desktop app now."""
        best, newest = None, -1.0
        for folder in glob.glob(str(self.data_root / 'claude_*' / 'claude-code-sessions' / '*' / '*')):
            for name in glob.glob(os.path.join(folder, 'local_*.json')):
                try:
                    mtime = os.path.getmtime(name)
                except OSError:
                    continue
                if mtime > newest:
                    best, newest = folder, mtime
        return best

    def available(self):
        return self.sessions_dir() is not None

    def metadata(self, path):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            return None
        cached = self.cache.get(path)
        if cached and cached[0] == mtime:
            return cached[1]
        try:
            data = json.loads(Path(path).read_text(encoding='utf-8'))
        except (OSError, ValueError, UnicodeDecodeError):
            return None
        if not isinstance(data, dict) or not CLAUDE_ID.match(str(data.get('sessionId', ''))):
            return None
        self.cache[path] = (mtime, data)
        return data

    def transcript_path(self, session_id):
        folder = self.sessions_dir()
        if not folder or not CLAUDE_ID.match(session_id):
            return None
        data = self.metadata(os.path.join(folder, f'{session_id}.json'))
        cli = str((data or {}).get('cliSessionId') or '')
        if not CODEX_ID.match(cli):  # same UUID shape
            return None
        known = self.paths.get(cli)
        if known and known.exists():
            return known
        found = glob.glob(str(self.projects_dir / '*' / f'{cli}.jsonl'))
        if not found:
            return None
        path = Path(max(found, key=os.path.getmtime))
        self.paths[cli] = path
        return path

    def info(self, session_id):
        """Title, deep link and the page title the desktop app shows for this conversation."""
        folder = self.sessions_dir()
        if not folder or not CLAUDE_ID.match(session_id):
            return None
        data = self.metadata(os.path.join(folder, f'{session_id}.json'))
        if data is None:
            return None
        title = (data.get('title') or '').strip()
        return {'id': session_id, 'title': title, 'link': f'claude://claude.ai/epitaxy/{session_id}',
                'doc': f'{title} - Claude Code'}

    def context_window(self, model_id):
        if not model_id:
            return None
        if '[1m]' in model_id:
            return 1_000_000
        hits = [prefix for prefix in self.context_windows if model_id.startswith(prefix)]
        return self.context_windows[max(hits, key=len)] if hits else None

    def meta(self, session_id, parser):
        """Model, effort and context use of one conversation. The conversation file holds the
        model chosen now (it changes when the model is switched); the transcript the last one used."""
        folder = self.sessions_dir()
        data = self.metadata(os.path.join(folder, f'{session_id}.json')) if folder and CLAUDE_ID.match(session_id) else None
        model_id = (data or {}).get('model') or parser.model
        effort = (data or {}).get('effort')
        mode = (data or {}).get('permissionMode')
        return {'model': model_label(model_id), 'modelId': model_id, 'effort': EFFORT_LABELS.get(effort, effort),
                'context': context_info(parser.context, self.context_window(model_id)),
                'permission': self.PERMISSION_LABELS.get(mode, mode)}

    def usage(self):
        """Plan limits the desktop app last read, from its plan-usage-history.json: the newest
        sample of the signed-in organisation (the folder name under the account). `fh` is the
        5-hour window and `sd` the weekly one, in percent; reset times are not in the file."""
        folder = self.sessions_dir()
        if not folder:
            return None
        org = Path(folder).name
        try:
            data = json.loads((Path(folder).parents[2] / 'plan-usage-history.json').read_text(encoding='utf-8'))
        except (OSError, ValueError, UnicodeDecodeError):
            return None
        samples = [s for s in (data.get('samples') or []) if isinstance(s, dict) and s.get('org') == org
                   and isinstance(s.get('u'), dict) and isinstance(s.get('t'), (int, float))]
        if not samples:
            return None
        latest = max(samples, key=lambda s: s['t'])
        windows = [{'label': label, 'percent': latest['u'][key], 'resetsAt': None, 'resetsText': None}
                   for key, label in (('fh', '5 小時'), ('sd', '每週'))
                   if isinstance(latest['u'].get(key), (int, float))]
        return {'windows': windows, 'sampledAt': iso(latest['t'])} if windows else None

    def list_sessions(self, limit, now=None):
        now = now or time.time()
        folder = self.sessions_dir()
        if not folder:
            return []
        rows, bad = [], 0
        for name in glob.glob(os.path.join(folder, 'local_*.json')):
            data = self.metadata(name)
            if data is None:
                bad += 1
                continue
            if data.get('isArchived'):
                continue
            rows.append(data)
        self.warning = f'Claude 對話清單有 {bad} 個檔案無法解析' if bad else None
        rows.sort(key=lambda d: d.get('lastActivityAt') or 0, reverse=True)
        out = []
        for data in rows[:limit]:
            path = self.transcript_path(data['sessionId'])
            status = 'idle'
            if data.get('interruptedAwaitingPerson') or (data.get('postTurnSummary') or {}).get('needs_action'):
                status = 'needs-action'
            elif path is not None and now - _mtime(path) < ACTIVE_SECONDS:
                status = 'active'
            mode = data.get('permissionMode')
            out.append({'id': data['sessionId'], 'title': (data.get('title') or '').strip() or '（未命名）',
                        'folder': folder_name(data.get('cwd')), 'updatedAt': later_time(data.get('lastActivityAt'), path),
                        'status': status, 'permission': self.PERMISSION_LABELS.get(mode, mode),
                        'hasTranscript': path is not None})
        return out


class CodexSource:
    """Codex desktop keeps its threads in ~/.codex/state_5.sqlite (`threads`), with
    ~/.codex/session_index.jsonl as an older, simpler index. Sub-threads such as approval
    reviews (`source` is a JSON subagent description) and `codex exec` runs are not listed.
    No permission label: the stored approval_mode reads "on-request" even under 代我核准, so it
    would mislead."""

    id_pattern = CODEX_ID
    parser = CodexParser

    def __init__(self, home, live=None):
        self.home = Path(home)
        self.live = live
        self.warning = None
        self.recorded_cache = {}
        self.imports = (None, {})

    def fast(self):
        """Whether fast mode (the lightning toggle) is on: the desktop app writes its pick to
        config.toml as service_tier ("default" when off, "priority" when on: the home PC's, 10/29), under the
        active profile when there is one. None when the file cannot be read."""
        try:
            text = (self.home / 'config.toml').read_text(encoding='utf-8')
        except OSError:
            return None
        section, values = '', {}
        for line in text.splitlines():
            line = line.strip()
            heading = re.fullmatch(r'\[([^\]]+)\]', line)
            if heading:
                section = heading.group(1).strip()
                continue
            found = re.fullmatch(r'(profile|service_tier)\s*=\s*"([^"]*)"\s*(#.*)?', line)
            if found:
                values[(section, found.group(1))] = found.group(2)
        profile = values.get(('', 'profile'))
        tier = values.get((f'profiles.{profile}', 'service_tier')) if profile else None
        tier = tier or values.get(('', 'service_tier'))
        return tier not in (None, '', 'default', 'standard')

    def account(self):
        """The signed-in ChatGPT account (only its id is read from auth.json), as a mark."""
        try:
            data = json.loads((self.home / 'auth.json').read_text(encoding='utf-8'))
        except (OSError, ValueError, UnicodeDecodeError):
            return None
        tokens = data.get('tokens') if isinstance(data, dict) else None
        raw = tokens.get('account_id') if isinstance(tokens, dict) else None
        return account_mark('codex', raw) if isinstance(raw, str) else None

    def available(self):
        return (self.home / 'sessions').is_dir()

    def import_titles(self):
        """Thread id -> the title Codex gave a conversation it imported from another agent
        (Claude Code sessions, listed in external_agent_session_imports.json). Its sidebar and
        page may show that title rather than the database's (read 10/28)."""
        path = self.home / 'external_agent_session_imports.json'
        try:
            stamp = path.stat().st_mtime
        except OSError:
            return {}
        if self.imports[0] == stamp:
            return self.imports[1]
        titles = {}
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
            for record in (data.get('records') if isinstance(data, dict) else None) or []:
                if isinstance(record, dict) and isinstance(record.get('imported_thread_id'), str) \
                        and isinstance(record.get('title'), str) and record['title'].strip():
                    titles[record['imported_thread_id']] = record['title'].strip()
        except (OSError, ValueError):
            titles = {}
        self.imports = (stamp, titles)
        return titles

    def recorded(self, thread_id):
        """(model, effort) the Codex database holds for a thread, cached for a few seconds; None
        when it cannot tell. A thread Codex imported from Claude Code has (None, None) there, and
        no turn_context in its rollout, until it replies in Codex (read 10/28)."""
        now = time.monotonic()
        cached = self.recorded_cache.get(thread_id)
        if cached and now - cached[0] < 10:
            return cached[1]
        value = None
        try:
            connection = self.database()
            if connection is not None:
                try:
                    columns = {row[1] for row in connection.execute('PRAGMA table_info(threads)')}
                    if {'model', 'reasoning_effort'} <= columns:
                        row = connection.execute('SELECT model, reasoning_effort FROM threads WHERE id = ?',
                                                 (thread_id,)).fetchone()
                        value = (row[0] or None, row[1] or None) if row else None
                finally:
                    connection.close()
        except sqlite3.Error:
            pass
        self.recorded_cache[thread_id] = (now, value)
        return value

    def database(self):
        path = self.home / 'state_5.sqlite'
        if not path.exists():
            return None
        uri = 'file:' + urllib.parse.quote(str(path).replace('\\', '/')) + '?mode=ro'
        return sqlite3.connect(uri, uri=True, timeout=2)

    def rows_from_database(self, limit):
        connection = self.database()
        if connection is None:
            return None
        try:
            columns = {row[1] for row in connection.execute('PRAGMA table_info(threads)')}
            name = 'COALESCE(NULLIF(name, \'\'), title)' if 'name' in columns else 'title'
            recency = 'COALESCE(recency_at_ms, updated_at_ms)' if 'recency_at_ms' in columns else 'updated_at * 1000'
            query = (f'SELECT id, {name}, {recency}, rollout_path, cwd FROM threads '
                     'WHERE archived = 0 AND (source IS NULL OR (source NOT LIKE \'{%\' AND source != \'exec\')) '
                     f'ORDER BY {recency} DESC LIMIT ?')
            return [{'id': r[0], 'title': r[1], 'ms': r[2], 'rollout': r[3], 'cwd': r[4]}
                    for r in connection.execute(query, (limit,))]
        finally:
            connection.close()

    def rows_from_index(self, limit):
        latest = {}
        path = self.home / 'session_index.jsonl'
        if not path.exists():
            return []
        for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict) and CODEX_ID.match(str(item.get('id', ''))) \
                    and item.get('thread_name') != 'Guardian review':
                latest[item['id']] = item
        rows = [{'id': i['id'], 'title': i.get('thread_name'), 'ms': i.get('updated_at'), 'rollout': None,
                 'cwd': None} for i in latest.values()]
        rows.sort(key=lambda r: iso(r['ms']) or '', reverse=True)
        return rows[:limit]

    def transcript_path(self, thread_id):
        if not CODEX_ID.match(thread_id):
            return None
        try:
            connection = self.database()
            if connection is not None:
                try:
                    row = connection.execute('SELECT rollout_path FROM threads WHERE id = ?', (thread_id,)).fetchone()
                finally:
                    connection.close()
                if row and row[0] and Path(row[0]).exists():
                    return Path(row[0])
        except sqlite3.Error:
            pass
        found = glob.glob(str(self.home / 'sessions' / '*' / '*' / '*' / f'rollout-*-{thread_id}.jsonl'))
        return Path(found[0]) if found else None

    def info(self, thread_id):
        """Title (the sidebar name, which is also the page title) and deep link of one thread;
        `aliases` are other names its page may carry (an imported thread's import title)."""
        if not CODEX_ID.match(thread_id):
            return None
        for row in self.list_sessions(100):
            if row['id'] == thread_id:
                imported = self.import_titles().get(thread_id)
                return {'id': thread_id, 'title': row['title'], 'link': f'codex://threads/{thread_id}',
                        'doc': row['title'], 'aliases': [imported] if imported and imported != row['title'] else []}
        return None

    def names(self, limit=100):
        """thread id -> every name a listed thread's page may carry."""
        imports = self.import_titles()
        return {row['id']: {row['title'], imports.get(row['id'])} - {None} for row in self.list_sessions(limit)}

    def meta(self, thread_id, parser):
        """From the rollout; the database fills in a model the read part of it does not name.
        With neither, the thread has had no turn in Codex yet: the phone says so."""
        model, effort, note = parser.model, parser.effort, None
        if model is None:
            recorded = self.recorded(thread_id)
            if recorded is not None:
                model, effort = recorded[0], effort or recorded[1]
                if model is None:
                    note = IMPORTED_NOTE
        return {'model': model_label(model), 'modelId': model, 'effort': EFFORT_LABELS.get(effort, effort),
                'context': context_info(parser.context, parser.window), 'permission': parser.mode, 'note': note}

    def usage(self):
        """Plan limits from the newest `token_count` event that carries them, in the most recent
        threads' rollout files (each reply's event repeats the account's limits), or what Codex
        itself answered more recently (CodexLiveLimits)."""
        best = None
        for row in self.list_sessions(5):
            path = self.transcript_path(row['id'])
            found = latest_rate_limits(path) if path else None
            if found and (best is None or found[0] > best[0]):
                best = found
        live = self.live.latest if self.live else None
        if live and (not best or iso(live[0]) > iso(best[0])):
            best = (iso(live[0]), live[1])
        if not best:
            return None
        ts, limits = best
        windows = []
        for key in ('primary', 'secondary'):
            item = limits.get(key)
            if isinstance(item, dict) and isinstance(item.get('used_percent'), (int, float)):
                windows.append({'label': window_label(item.get('window_minutes')), 'percent': round(item['used_percent']),
                                'resetsAt': iso(item.get('resets_at')), 'resetsText': None})
        return {'windows': windows, 'sampledAt': ts} if windows else None

    def list_sessions(self, limit, now=None):
        now = now or time.time()
        self.warning = None
        try:
            rows = self.rows_from_database(limit)
        except sqlite3.Error:
            rows = None
        if rows is None:
            self.warning = 'Codex 資料庫讀不到，改用舊索引（清單可能不完整）'
            rows = self.rows_from_index(limit)
        out = []
        for row in rows:
            if not CODEX_ID.match(str(row['id'])):
                continue
            path = Path(row['rollout']) if row.get('rollout') and Path(row['rollout']).exists() else self.transcript_path(row['id'])
            status = 'active' if path is not None and now - _mtime(path) < ACTIVE_SECONDS else 'idle'
            out.append({'id': row['id'], 'title': (row['title'] or '').strip() or '（未命名）',
                        'folder': folder_name(row.get('cwd')), 'updatedAt': later_time(row['ms'], path), 'status': status,
                        'permission': None, 'hasTranscript': path is not None})
        return out


def latest_rate_limits(path, tail=512 * 1024):
    """(timestamp, rate_limits) of the last token_count event near the end of a rollout file."""
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as handle:
            handle.seek(max(0, size - tail))
            data = handle.read()
    except OSError:
        return None
    for raw in reversed(data.split(b'\n')):
        if b'"rate_limits"' not in raw:
            continue
        try:
            obj = json.loads(raw.decode('utf-8'))
        except (ValueError, UnicodeDecodeError):
            continue
        payload = (obj.get('payload') or {}) if isinstance(obj, dict) else {}
        if isinstance(payload, dict) and payload.get('type') == 'token_count' and isinstance(payload.get('rate_limits'), dict):
            return iso(obj.get('timestamp')), payload['rate_limits']
    return None


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def later_time(value, path):
    """The later of an index's time and the transcript's last write, as RFC 3339 text: Codex's
    database lags its rollout by hours (10/29: 16:33 the day before, rollout written at 04:04)."""
    text = iso(value)
    written = _mtime(path) if path is not None else 0.0
    if written and (text is None or written > datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()):
        return iso(written)
    return text


# ---------------------------------------------------------------------------------------------
# This PC: who is at the keyboard, whether it is locked, whether the desktop apps are open.


class WindowsPresence:
    """Idle time leaves out the helper's own keystrokes and clicks: input that lands between
    begin_own() and shortly after end_own() is not a person at the keyboard."""

    def __init__(self):
        self.cache, self.cached_at = None, 0.0
        self.own = None          # (start tick, end tick or None while acting)
        self.real_before = None  # the last real input tick before the helper acted

    @staticmethod
    def ticks():
        return ctypes.windll.kernel32.GetTickCount() & 0xFFFFFFFF

    @staticmethod
    def last_input():
        class LastInput(ctypes.Structure):
            _fields_ = [('cbSize', ctypes.c_uint), ('dwTime', ctypes.c_uint)]
        info = LastInput()
        info.cbSize = ctypes.sizeof(info)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
            return None
        return info.dwTime

    def idle_seconds(self):
        last, now = self.last_input(), self.ticks()
        if last is None:
            return None
        return own_adjusted_idle(last, now, self.own, self.real_before)

    def begin_own(self):
        """When the last input is still the helper's own from the action before, the real input
        before that stays the one to count from (live 10/28: a second phone message 25 s after
        the first was refused, the first one's keystrokes counted as a person)."""
        last, now = self.last_input(), self.ticks()
        if self.real_before is not None and last is not None and own_input(last, now, self.own):
            self.own = (self.own[0], None)  # nobody has touched it since: one window from the first start
            return
        self.real_before = last
        self.own = (now, None)

    def end_own(self):
        if self.own:
            self.own = (self.own[0], self.ticks())

    @staticmethod
    def locked():
        """The input desktop cannot be opened or switched to while the screen is locked."""
        user32 = ctypes.windll.user32
        handle = user32.OpenInputDesktop(0, False, 0x0100)  # DESKTOP_SWITCHDESKTOP
        if not handle:
            return True
        try:
            return not user32.SwitchDesktop(handle)
        finally:
            user32.CloseDesktop(handle)

    @staticmethod
    def app_windows():
        """Visible top-level windows of the Claude desktop app and the Codex desktop app."""
        user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
        found = {'claude': False, 'codex': False}

        def image(pid):
            handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
            if not handle:
                return ''
            try:
                buffer = ctypes.create_unicode_buffer(1024)
                size = ctypes.c_uint(1024)
                if kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                    return buffer.value
                return ''
            finally:
                kernel32.CloseHandle(handle)

        @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        def visit(hwnd, _):
            if user32.IsWindowVisible(hwnd):
                pid = ctypes.c_uint()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                path = image(pid.value).lower()
                if path.endswith('\\claude.exe') and '\\windowsapps\\claude_' in path:
                    found['claude'] = True
                elif path.endswith('\\chatgpt.exe'):
                    found['codex'] = True
            return True

        user32.EnumWindows(visit, 0)
        return found

    def snapshot(self):
        now = time.monotonic()
        if self.cache is None or now - self.cached_at > 5:
            try:
                windows = self.app_windows()
            except OSError:
                windows = {'claude': None, 'codex': None}
            self.cache, self.cached_at = {'windows': windows}, now
        locked = self.locked()
        # A UAC prompt is on the secure desktop, which reads as locked; its consent.exe tells the two apart.
        return {'idleSeconds': self.idle_seconds(), 'locked': locked, 'uac': locked and process_running('consent.exe'),
                'windows': self.cache['windows']}

    def forget_windows(self):
        """The next snapshot looks at the windows again (one was just shown)."""
        self.cache = None


def own_input(last, now, own, grace_ms=1500):
    """True when the input tick `last` lies inside the helper's own window [start, end + grace]."""
    def since(tick):
        return ((now - tick) & 0xFFFFFFFF)
    if not own:
        return False
    start, end = own
    after_start = since(start) >= since(last)                   # last input is not before start
    before_end = end is None or since(last) + grace_ms >= since(end)  # not later than end + grace
    return after_start and before_end


def own_adjusted_idle(last, now, own, real_before, grace_ms=1500):
    """Idle seconds from tick counts (32-bit, wrapping). Input inside the helper's own window
    [start, end + grace] counts from the real input before it instead."""
    if real_before is not None and own_input(last, now, own, grace_ms):
        last = real_before
    return ((now - last) & 0xFFFFFFFF) // 1000


class FixedPresence:
    def __init__(self, values):
        self.values = values

    def snapshot(self):
        return self.values

    def forget_windows(self):
        pass

    def begin_own(self):
        pass

    def end_own(self):
        pass


# ---------------------------------------------------------------------------------------------
# Auth and notifications.


class Notifier:
    """ntfy, like the miner aggregator: titles carry the PC name and the action, never addresses."""

    def __init__(self, cfg):
        self.cfg = cfg.get('notify') or {}

    def post(self, title, message, priority=3, tags=None, click=None):
        """`click` is the phone app's link (open_link): tapping the notification opens it there."""
        if not self.cfg.get('topic') or not self.cfg.get('server'):
            return
        payload = {'topic': self.cfg['topic'], 'title': title, 'message': message, 'priority': priority,
                   'tags': tags or []}
        if click:
            payload['click'] = click
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        request = urllib.request.Request(self.cfg['server'], data=body, method='POST',
                                         headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                response.read(4096)
        except urllib.error.HTTPError as e:  # ntfy says why in its body (a 413 on 10/30)
            reason = e.read(300).decode('utf-8', 'replace')
            raise OSError(f'ntfy answered {e.code}: {reason}') from None


class AuthGate:
    """Shared token, constant-time compare. Five wrong tokens within ten minutes lock every /v1
    request for ten minutes, even with the right token, and send one ntfy message."""

    MAX_FAILURES, LOCK = 5, 600

    def __init__(self, token, notify=None, pc_name='', clock=time.monotonic):
        self.token = token.encode('utf-8')
        self.notify, self.pc_name, self.clock = notify, pc_name, clock
        self.lock = threading.Lock()
        self.failures, self.locked_until = [], 0.0

    def check(self, header):
        """None when allowed, else (HTTP status, error body)."""
        now = self.clock()
        supplied = header[7:] if header and header.startswith('Bearer ') else ''
        with self.lock:
            if now < self.locked_until:
                return 429, error('locked-out', '密碼錯誤太多次，已暫停 10 分鐘')
            if hmac.compare_digest(supplied.encode('utf-8'), self.token):
                return None
            self.failures = [t for t in self.failures if now - t < self.LOCK] + [now]
            locked = len(self.failures) >= self.MAX_FAILURES
            if locked:
                self.locked_until, self.failures = now + self.LOCK, []
        if locked:
            logging.warning('locked after repeated wrong tokens')
            if self.notify:
                threading.Thread(target=self._notify_lock, daemon=True).start()
            return 429, error('locked-out', '密碼錯誤太多次，已暫停 10 分鐘')
        return 401, error('unauthorized', '連線密碼不正確')

    def _notify_lock(self):
        try:
            self.notify(f'🔒 桌面遙控：{self.pc_name} 已鎖定', '連線密碼連續錯誤 5 次，10 分鐘內拒絕所有請求。', 4, ['lock'])
        except OSError:
            logging.exception('lock notification failed')


def error(code, message):
    return {'ok': False, 'error': code, 'message': message}


# ---------------------------------------------------------------------------------------------
# The hub: sources, cached transcripts, state.


class Hub:
    def __init__(self, pc_name, sources, presence, prompts=None, on_events=None):
        self.pc_name = pc_name
        self.sources = sources            # {'claude': ClaudeSource, 'codex': CodexSource}
        self.presence = presence
        self.prompts = prompts or (lambda app, session_id: None)
        self.on_events = on_events or (lambda app, session_id: None)
        self.transcripts = {}             # (app, id) -> Transcript, most recently used last
        self.info_cache = {}
        self.capabilities = ['read']      # plus send, permission, new and open once windows can be driven
        self.elevate = None               # ElevateRelay once the elevated companion is installed
        self.ui = lambda app: {}          # what the watcher last read on each app's screen
        self.popups = lambda: []          # windows on the desktop waiting for an answer
        self.versions = lambda: {}        # each desktop app's installed and running version
        self.strings = {}                 # ui_strings.json, once windows can be driven
        self.usage_cache = (0.0, None)
        self.latest_cache = (0.0, None)
        self.screen = None               # () -> JPEG bytes of the PC's screen, when it can be read
        self.alerts = {'usage_percent': 80, 'context_percent': 80}
        self.chosen_modes = {}            # (app, id) -> (mode, when): a Codex pick its rollout shows only next turn
        self.page_names = {}              # (app, id) -> the page title last seen for it, when its files say otherwise
        self.lock = threading.Lock()

    def state(self):
        presence = self.presence.snapshot()
        windows = presence.get('windows') or {}
        apps = {app: {'running': windows.get(app), 'available': source.available()}
                for app, source in self.sources.items()}
        warnings = [w for w in (getattr(s, 'warning', None) for s in self.sources.values()) if w]
        skipped = sum(t.skipped for t in list(self.transcripts.values()))
        if skipped:
            warnings.append(f'逐字稿有 {skipped} 行無法解析，已略過')
        elevate = None
        if self.elevate is not None:
            with self.elevate.lock:
                elevate = {'available': self.elevate.available, 'pending': len(self.elevate.pending)}
        def choices(capability, key):
            return {app: list(self.strings[app][key]) for app in APPS
                    if capability in self.capabilities and (self.strings.get(app) or {}).get(key)}
        stop = [app for app in APPS if 'stop' in self.capabilities and (self.strings.get(app) or {}).get('stop')]
        fast = {app: source.fast() for app, source in self.sources.items()
                if 'fast' in self.capabilities and (self.strings.get(app) or {}).get('fast_on') and hasattr(source, 'fast')}
        extra = (['elevate'] if self.elevate is not None else []) + (['screen'] if self.screen is not None else [])
        return {'ok': True, 'pc': {'name': self.pc_name, 'helperVersion': VERSION},
                'capabilities': self.capabilities + extra,
                'apps': apps, 'presence': {'idleSeconds': presence.get('idleSeconds'), 'locked': presence.get('locked'),
                                           'uac': bool(presence.get('uac'))},
                'warnings': warnings, 'elevate': elevate, 'usage': self.usage(), 'models': choices('model', 'models'),
                'efforts': choices('effort', 'efforts'), 'modes': choices('mode', 'modes'), 'stop': stop,
                'popups': self.popups(), 'recent': self.recent(), 'fast': fast, 'versions': self.versions()}

    def recent(self, per_app=3):
        """Each app's few most recently written conversations, newest first, for the phone's PC
        list to link straight into (read at most every 10 seconds). Every app gets its share, so
        a quiet one still shows when it was last used."""
        now = time.monotonic()
        stamp, cached = self.latest_cache
        if cached is not None and now - stamp < 10:
            return cached
        out = []
        for app, source in self.sources.items():
            try:
                rows = [row for row in source.list_sessions(10) if row.get('updatedAt')]
            except (OSError, ValueError, sqlite3.Error):
                logging.exception('recent conversations of %s failed', app)
                rows = []
            rows.sort(key=lambda r: r['updatedAt'], reverse=True)
            out += [dict(row, app=app) for row in rows[:per_app]]
        out.sort(key=lambda r: r['updatedAt'], reverse=True)
        self.latest_cache = (now, out)
        return out

    def usage(self):
        """Each app's plan limits (percent used per window), read at most every 30 seconds.
        Claude's file is corrected by its composer's usage button (merge_claude_usage)."""
        now = time.monotonic()
        stamp, cached = self.usage_cache
        if cached is not None and now - stamp < 30:
            return cached
        out = {}
        for app, source in self.sources.items():
            try:
                out[app] = source.usage()
            except (OSError, ValueError, sqlite3.Error):
                logging.exception('usage of %s failed', app)
                out[app] = None
        seen = self.ui('claude')
        button = ui_usage(seen.get('usage'), (self.strings.get('claude') or {}).get('usage_prefix'))
        out['claude'] = merge_claude_usage(out.get('claude'), button, seen.get('usageAt'), time.time(),
                                           seen.get('card'), seen.get('cardAt'))
        for app, source in self.sources.items():
            if out.get(app) and hasattr(source, 'account'):
                try:
                    out[app] = dict(out[app], account=source.account())
                except OSError:
                    logging.exception('account of %s failed', app)
        self.usage_cache = (now, out)
        return out

    def meta(self, app, session_id, transcript):
        """Model, effort and context use. For the conversation open on the app's screen, its
        model button is the freshest answer: Claude writes its conversation file a little later,
        and Codex records a switch only with the next reply."""
        with transcript.lock:
            meta = self.sources[app].meta(session_id, transcript.parser)
            turn_ts = getattr(transcript.parser, 'turn_ts', None)
        chosen = self.chosen_modes.get((app, session_id))
        if chosen and (turn_ts or '') > chosen[1]:
            self.chosen_modes.pop((app, session_id), None)  # a turn since the pick: the rollout knows
        elif chosen:
            meta['permission'], meta['permissionPending'] = chosen[0], True
        seen = self.ui(app)
        info = self.info(app, session_id)
        docs = seen.get('docs') or []
        if info and len(docs) == 1 and docs[0] in [info['doc']] + list(info.get('aliases') or []):
            label, effort = ui_model(seen.get('model'), (self.strings.get(app) or {}).get('model_strip'))
            if label:
                meta['model'], meta['effort'] = label, effort or meta['effort']
            if seen.get('mode'):
                meta['permission'] = seen['mode']
        return meta

    def session_for_doc(self, app, doc):
        """(id, title) of the listed conversation whose page title is `doc`, for notification links."""
        for row in self.sources[app].list_sessions(50):
            info = self.info(app, row['id'])
            if info and info['doc'] == doc:
                return row['id'], row['title']
        return None, None

    def sessions(self, app, limit):
        source = self.sources[app]
        return {'ok': True, 'app': app, 'sessions': source.list_sessions(limit), 'warning': source.warning}

    def transcript(self, app, session_id):
        source = self.sources[app]
        if not source.id_pattern.match(session_id):
            return None
        key = (app, session_id)
        with self.lock:
            existing = self.transcripts.pop(key, None)
            if existing is not None:
                self.transcripts[key] = existing
                return existing
        path = source.transcript_path(session_id)
        if path is None:
            return None
        with self.lock:
            existing = self.transcripts.get(key) or Transcript(path, source.parser)
            self.transcripts.pop(key, None)
            self.transcripts[key] = existing
            while len(self.transcripts) > 8:
                self.transcripts.pop(next(iter(self.transcripts)))
            return existing

    def events(self, app, session_id, after, epoch, wait, known_prompt='', stop=None, known_question=None):
        """Waits up to `wait` seconds for new events, a permission prompt other than the one the
        app already shows (`known_prompt`, its promptId), an option question other than
        `known_question` (its questionId), or changed reply buttons."""
        transcript = self.transcript(app, session_id)
        if transcript is None:
            return None
        self.on_events(app, session_id)
        deadline = time.monotonic() + max(0, min(wait, MAX_WAIT))
        transcript.refresh()
        waiting = transcript.waiting_key()
        meta = self.meta(app, session_id, transcript)
        while True:
            transcript.refresh()
            page = transcript.page(after, epoch)
            prompt = self.prompts(app, session_id)
            changed = (prompt or {}).get('promptId', '') != known_prompt
            now_waiting = transcript.waiting_key()
            if known_question is not None and (now_waiting[0] or '') != known_question:
                changed = True
            if now_waiting != waiting:
                changed = True
            now_meta = self.meta(app, session_id, transcript)
            if any(now_meta.get(k) != meta.get(k) for k in ('model', 'effort', 'permission')):
                changed = True  # a switch made from the phone shows without waiting for a reply
            if page['events'] or page['reset'] or changed or time.monotonic() >= deadline or (stop and stop()):
                page.update({'ok': True, 'prompt': prompt, 'meta': now_meta})
                return page
            time.sleep(1)

    def item(self, app, session_id, item_id):
        transcript = self.transcript(app, session_id)
        return transcript.item(item_id) if transcript is not None and ITEM_ID.match(item_id) else None

    def info(self, app, session_id):
        """Title, link and expected page title, cached for a few seconds (long-polls ask often)."""
        key = (app, session_id)
        now = time.monotonic()
        cached = self.info_cache.get(key)
        if cached and now - cached[0] < 10:
            return cached[1]
        value = self.sources[app].info(session_id)
        seen = self.page_names.get(key)
        if value and seen and seen != value['doc']:
            value = dict(value, doc=seen, aliases=[value['doc']] + [a for a in value.get('aliases') or [] if a != seen])
        self.info_cache[key] = (now, value)
        return value

    def learn_page_name(self, app, session_id, info, doc):
        """The page opened from this conversation's own link is titled `doc`: use that name."""
        if doc != info['doc']:
            logging.info('%s page name differs from its files', app)
            info['aliases'] = [info['doc']] + [a for a in info.get('aliases') or [] if a != doc]
            info['doc'] = doc  # the running action holds this dict
            self.page_names[(app, session_id)] = doc
            self.info_cache.pop((app, session_id), None)


# ---------------------------------------------------------------------------------------------
# Driving the desktop apps' windows (phase 2). The PowerShell worker does the UI Automation;
# everything that decides what is safe to do stays here, where it is unit tested.


class ActionError(Exception):
    def __init__(self, code, message=''):
        super().__init__(f'{code}: {message}')
        self.code, self.message = code, message


def load_strings(path=None):
    path = Path(path or Path(__file__).with_name('ui_strings.json'))
    return json.loads(path.read_text(encoding='utf-8'))


class UiaWorker:
    """One long-lived `uia_worker.ps1`. Requests are serialized; a timeout or crash restarts it."""

    def __init__(self, script=None):
        self.script = Path(script or Path(__file__).with_name('uia_worker.ps1'))
        self.lock = threading.Lock()
        self.process = None
        self.lines = None

    def start(self):
        import queue
        import subprocess
        self.process = subprocess.Popen(
            ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-File', str(self.script)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        self.lines = queue.Queue()
        out = self.process.stdout

        def pump():
            for raw in iter(out.readline, b''):
                self.lines.put(raw)
            self.lines.put(None)
        threading.Thread(target=pump, daemon=True).start()

    def stop(self):
        if self.process is not None:
            try:
                self.process.kill()
            except OSError:
                pass
        self.process = None

    def request(self, command, timeout=25):
        import queue
        with self.lock:
            if self.process is None or self.process.poll() is not None:
                self.start()
            try:
                self.process.stdin.write((json.dumps(command, ensure_ascii=True) + '\n').encode('ascii'))
                self.process.stdin.flush()
                raw = self.lines.get(timeout=timeout)
            except (OSError, queue.Empty):
                self.stop()
                raise ActionError('timeout', '畫面操作逾時')
            if raw is None:
                self.stop()
                raise ActionError('worker-error', '畫面操作程式結束了')
            answer = json.loads(raw.decode('ascii'))
        if not answer.get('ok'):
            raise ActionError(answer.get('error') or 'worker-error', answer.get('message') or '')
        return answer


class WindowsDriver:
    """The real desktop apps, through the worker. `doc` is the page title that must be open."""

    def __init__(self, strings, worker=None):
        self.strings = strings
        self.worker = worker or UiaWorker()

    def ask(self, app, **command):
        command['app'] = app
        command['strings'] = self.strings[app]
        return self.worker.request(command)

    def inspect(self, app):
        return self.ask(app, cmd='inspect')

    def docs(self, app):
        answer = self.ask(app, cmd='docs')
        return answer.get('docs') or [] if answer.get('window') else None

    def open(self, app, info):
        """Each desktop app opens its own conversation link. When Windows cannot activate the
        link (Codex started outside its package after the 0x80070020 container fault, found live
        10/27), start the installed package's ChatGPT.exe with the link the way the package
        does (`--single-argument <link>`): it hands the link to the running instance and exits.
        The running instance's own, older exe could not be started (WinError 14001)."""
        try:
            os.startfile(info['link'])
            return
        except OSError:
            if app != 'codex':
                raise ActionError('app-not-running', 'the conversation link could not be opened')
        if not running_images('chatgpt.exe'):
            raise ActionError('app-not-running', 'Codex is not running')
        exe = codex_package_exe()
        if not exe:
            raise ActionError('app-not-running', 'the Codex package was not found')
        try:
            os.startfile(exe, arguments=f'--single-argument {info["link"]}')
        except OSError as exc:
            raise ActionError('app-not-running', f'Codex could not take the link: {exc}')

    def launch(self, app, again=False):
        """Starts the app through its Start menu entry; when it is already running, closed to the
        tray (both were on the home PC, 10/28), the entry shows its window again. Codex outside its
        package after the 0x80070020 fault, or a second try (`again`) when the entry showed
        nothing: start the package's own exe instead."""
        if not again:
            try:
                os.startfile(f'shell:AppsFolder\\{LAUNCH_IDS[app]}')
                return
            except OSError:
                pass
        if app != 'codex':
            raise ActionError('app-not-running', 'the app could not be started')
        exe = codex_package_exe()
        if not exe:
            raise ActionError('app-not-running', 'the Codex package was not found')
        try:
            os.startfile(exe)
        except OSError as exc:
            raise ActionError('app-not-running', f'Codex could not be started: {exc}')

    def usage_card(self, app):
        """The rows of the usage card ({label, percent, reset}), read with the button expanded."""
        rows = self.ask(app, cmd='usage_card').get('rows') or []
        return [rows] if isinstance(rows, dict) else rows

    def invoke(self, app, name, doc=None):
        self.ask(app, cmd='invoke', name=name, doc=doc)

    def invoke_title(self, app, title):
        """The one sidebar button named `title` or `title` plus a note (not its menu buttons)."""
        self.ask(app, cmd='invoke_title', title=title)

    def send(self, app, doc, text, images=None):
        """Pastes each of `images` (file paths) first, then `text`, then Enter."""
        return self.ask(app, cmd='send', doc=doc, text=text, images=list(images or [])).get('replaced') or None

    def new_send(self, app, button, text):
        self.ask(app, cmd='new_send', name=button, text=text)

    def popups(self):
        """Windows on the desktop waiting for an answer: [{hwnd, title, process, text, buttons}]."""
        found = self.worker.request({'cmd': 'popups'}).get('popups') or []
        return [found] if isinstance(found, dict) else found

    def extension_popups(self):
        """Only Claude for Chrome's permission cards (a cheap look, taken every second or two)."""
        found = self.worker.request({'cmd': 'extension'}, timeout=10).get('popups') or []
        return [found] if isinstance(found, dict) else found

    installed_cache = (0.0, {})

    def versions(self):
        """{app: {'installed', 'running'}}: the installed package's version (asked of Windows at
        most every 10 minutes: one PowerShell call) and the newest one running (None if closed)."""
        import subprocess
        stamp, installed = self.installed_cache
        if not installed or time.monotonic() - stamp > 600:
            names = ','.join(f"'{package}'" for package, _ in APP_PACKAGES.values())
            try:
                done = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                                       f'foreach ($n in {names}) {{ Get-AppxPackage -Name $n | ForEach-Object {{ $_.Name + " " + $_.Version }} }}'],
                                      capture_output=True, timeout=60, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                lines = done.stdout.decode('utf-8', 'replace').split()
                by_package = dict(zip(lines[0::2], lines[1::2]))
                installed = {app: by_package.get(package) for app, (package, _) in APP_PACKAGES.items()}
                self.installed_cache = (time.monotonic(), installed)
            except (OSError, subprocess.TimeoutExpired):
                logging.exception('reading the installed versions failed')
        out = {}
        for app, (package, exe) in APP_PACKAGES.items():
            running = set(package_processes(package, exe).values())
            out[app] = {'installed': installed.get(app),
                        'running': max(running, key=version_key) if running else None,
                        'old': bool(installed.get(app)) and any(version_key(v) < version_key(installed[app]) for v in running)}
        return out

    def downloaded_update(self, app):
        """The version Claude's updater has downloaded (its log's last word on it), or None. Only
        the tail of the log is read, and only that one line is looked for."""
        if app != 'claude':
            return None
        try:
            with open(CLAUDE_LOG, 'rb') as log:
                log.seek(0, os.SEEK_END)
                log.seek(max(0, log.tell() - 2 * 1024 * 1024))
                return downloaded_version(log.read().decode('utf-8', 'replace'))
        except OSError:
            return None

    def restart_app(self, app):
        """Ends every process of the app's package and starts the installed (newest) one. Only
        Codex: ending Claude would end every Claude Code session in it (the user's rule)."""
        if app != 'codex':
            raise ActionError('not-supported', 'only Codex is restarted')
        package, exe = APP_PACKAGES[app]
        kernel32 = ctypes.windll.kernel32
        for pid in package_processes(package, exe):
            handle = kernel32.OpenProcess(0x0001, False, pid)  # PROCESS_TERMINATE
            if handle:
                try:
                    kernel32.TerminateProcess(handle, 0)
                finally:
                    kernel32.CloseHandle(handle)
        deadline = time.monotonic() + 20
        while package_processes(package, exe):
            if time.monotonic() >= deadline:
                raise ActionError('restart-failed', 'the old Codex did not end')
            time.sleep(0.5)
        # The Start menu entry can start nothing at all (office 10/30: Codex stayed closed after
        # the first automatic restart): then the package's own exe.
        for again in (False, True):
            self.launch(app, again=again)
            deadline = time.monotonic() + 20
            while not package_processes(package, exe):
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.5)
            else:
                return
        raise ActionError('restart-failed', 'Codex did not start again')

    def press_popup(self, popup, button):
        """Presses `button` in `popup` while it still has its title; True once it has closed."""
        return bool(self.worker.request({'cmd': 'press_popup', 'hwnd': popup['hwnd'], 'title': popup['title'],
                                         'button': button, 'page': bool(popup.get('page'))}).get('gone'))

    def answer(self, app, doc, decision, expect):
        return self.ask(app, cmd='answer', doc=doc, decision=decision, expect=expect).get('how')

    def answer_question(self, app, doc, question, answers):
        """Turns on each chosen option (and 其他 with its text) in the question's card, then 提交."""
        if app != 'claude':
            raise ActionError('not-supported', 'option questions are only read from Claude')
        items = [{'question': q['question'], 'labels': a.get('labels') or [], 'other': a.get('other') or ''}
                 for q, a in zip(question['questions'], answers)]
        return self.ask(app, cmd='choose', doc=doc, questions=items).get('how')

    def set_model(self, app, doc, label):
        """Picks `label` in the model menu of the open conversation; 'already' if it was chosen."""
        return self.ask(app, cmd='model', doc=doc, model=label).get('how')

    def set_effort(self, app, doc, label):
        if app != 'claude':
            raise ActionError('not-supported', 'only Claude effort can be switched')
        return self.ask(app, cmd='effort', doc=doc, effort=label).get('how')

    def set_mode(self, app, doc, label):
        return self.ask(app, cmd='mode', doc=doc, mode=label).get('how')

    def press_update(self, app, name, confirm=None):
        """Presses the app's own update button `name` (and `confirm` in the dialog that follows)."""
        return self.ask(app, cmd='press_update', name=name, confirm=confirm).get('how')

    def set_fast(self, app, doc, on):
        """Codex's fast mode switch in the model menu; 'already' when it was that way."""
        return self.ask(app, cmd='fast', doc=doc, on=bool(on)).get('how')

    def stop(self, app, doc):
        return self.ask(app, cmd='stop', doc=doc).get('how')


class CodexLiveLimits:
    """The account's current Codex limits, asked of the installed Codex every few minutes through
    `codex app-server` (JSON-RPC on stdio, `account/rateLimits/read`). Rollout files only carry
    the limits as of each PC's last reply, so a PC whose Codex sat unused showed 14% after the
    week had reset to 0% (live 10/28). Codex signs in by itself: the helper reads no credentials.
    `latest` is (epoch seconds, limits in the rollout files' shape) or None."""

    def __init__(self, command=None, interval=300, timeout=30):
        self.command, self.interval, self.timeout = command, interval, timeout
        self.latest = None

    @staticmethod
    def rollout_shape(answer):
        """`rateLimits` of the answer in the rollout files' snake_case shape, or None."""
        limits = (answer or {}).get('rateLimits')
        if not isinstance(limits, dict):
            return None
        out = {}
        for key in ('primary', 'secondary'):
            item = limits.get(key)
            if isinstance(item, dict) and isinstance(item.get('usedPercent'), (int, float)):
                out[key] = {'used_percent': item['usedPercent'], 'window_minutes': item.get('windowDurationMins'),
                            'resets_at': item.get('resetsAt')}
        return out or None

    def ask(self):
        """One question to a fresh `app-server`; the answer's limits, or None."""
        import subprocess
        if not self.command:
            self.command = codex_cli_command()  # found once; again after an update moved it
        if not self.command:
            return None
        try:
            proc = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        except OSError:
            self.command = None
            return None
        found = []

        def read():
            for line in proc.stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get('id') == 2:
                    found.append(message.get('result'))
                    return
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        try:
            for message in ({'method': 'initialize', 'id': 1, 'params': {'clientInfo': {'name': 'desk-remote-helper', 'version': VERSION}}},
                            {'method': 'initialized'}, {'method': 'account/rateLimits/read', 'id': 2}):
                proc.stdin.write((json.dumps(message) + '\n').encode('utf-8'))
                proc.stdin.flush()
            reader.join(self.timeout)
        except OSError:
            pass
        finally:
            proc.kill()
            proc.wait()
        return self.rollout_shape(found[0]) if found else None

    def refresh(self):
        limits = self.ask()
        if limits:
            self.latest = (time.time(), limits)

    def run_forever(self):
        while True:
            try:
                self.refresh()
            except Exception:
                logging.exception('codex limits failed')
            time.sleep(self.interval)


def codex_cli_command():
    """`codex.exe app-server` from the installed OpenAI.Codex package, or None."""
    exe = codex_package_exe()
    cli = Path(exe).parent / 'resources' / 'codex.exe' if exe else None
    return [str(cli), 'app-server'] if cli and cli.exists() else None


# Start menu (AppsFolder) ids of the two packaged desktop apps, the same on every PC.
LAUNCH_IDS = {'claude': 'Claude_pzs8sxrjxfjjc!Claude', 'codex': 'OpenAI.Codex_2p2nqsd0c76g0!App'}


def codex_package_exe():
    """ChatGPT.exe of the installed OpenAI.Codex package (its folder changes with each update)."""
    import subprocess
    try:
        done = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                               '(Get-AppxPackage -Name OpenAI.Codex).InstallLocation'],
                              capture_output=True, timeout=30, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except (OSError, subprocess.TimeoutExpired):
        return None
    folder = done.stdout.decode('utf-8', 'replace').strip().splitlines()
    exe = Path(folder[-1].strip()) / 'app' / 'ChatGPT.exe' if folder else None
    return str(exe) if exe and exe.exists() else None


def process_running(name):
    """A process named `name` runs, whoever owns it: the process snapshot lists names without
    opening the process, so SYSTEM's consent.exe (the UAC prompt) shows too."""
    class Entry(ctypes.Structure):
        _fields_ = [('dwSize', ctypes.c_uint32), ('cntUsage', ctypes.c_uint32), ('th32ProcessID', ctypes.c_uint32),
                    ('th32DefaultHeapID', ctypes.c_size_t), ('th32ModuleID', ctypes.c_uint32),
                    ('cntThreads', ctypes.c_uint32), ('th32ParentProcessID', ctypes.c_uint32),
                    ('pcPriClassBase', ctypes.c_long), ('dwFlags', ctypes.c_uint32), ('szExeFile', ctypes.c_wchar * 260)]
    kernel32 = ctypes.windll.kernel32
    kernel32.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
    snapshot = kernel32.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
    if not snapshot or snapshot == ctypes.c_void_p(-1).value:
        return False
    try:
        entry = Entry()
        entry.dwSize = ctypes.sizeof(Entry)
        more = kernel32.Process32FirstW(ctypes.c_void_p(snapshot), ctypes.byref(entry))
        while more:
            if entry.szExeFile.lower() == name.lower():
                return True
            more = kernel32.Process32NextW(ctypes.c_void_p(snapshot), ctypes.byref(entry))
        return False
    finally:
        kernel32.CloseHandle(ctypes.c_void_p(snapshot))


# The desktop apps' packages and executables, for their versions (asked 10/30: always the newest).
APP_PACKAGES = {'claude': ('Claude', 'claude.exe'), 'codex': ('OpenAI.Codex', 'chatgpt.exe')}


def package_version(path, package):
    """'26.1016.6573.0' from ...\\WindowsApps\\OpenAI.Codex_26.1016.6573.0_x64__...\\app\\ChatGPT.exe."""
    found = re.search(r'\\windowsapps\\' + re.escape(package.lower()) + r'_(\d+(?:\.\d+){1,3})_', str(path).lower())
    return found.group(1) if found else None


def pending_version(button):
    """'4.29.0' from Claude's button "重新啟動以更新 v4.29.0"; the whole label if it has no version."""
    found = re.search(r'v?(\d+(?:\.\d+)+)\s*$', button)
    return found.group(1) if found else button


# Claude's own log (%LOCALAPPDATA%\Claude\Logs\main.log) when its updater has a version ready.
# Office 10/30: 4.29 waited with its button; the updater then swapped it for 4.4212 and the button
# never came back, so the phone had nothing to press while 4.4212 sat downloaded.
CLAUDE_LOG = Path(os.environ.get('LOCALAPPDATA') or '.') / 'Claude' / 'Logs' / 'main.log'
DOWNLOADED_RE = re.compile(r"\[updater\] Update downloaded and ready to install .*?releaseName: 'Claude (\d+(?:\.\d+)+)'")


def downloaded_version(text):
    """The last version Claude's log says is downloaded and ready to install, or None."""
    found = DOWNLOADED_RE.findall(text)
    return found[-1] if found else None


def version_key(text):
    return tuple(int(part) for part in str(text).split('.') if part.isdigit())


def package_processes(package, exe):
    """{pid: version} of the running processes of `package`'s `exe`."""
    psapi, kernel32 = ctypes.windll.psapi, ctypes.windll.kernel32
    pids = (ctypes.c_uint * 4096)()
    needed = ctypes.c_uint()
    if not psapi.EnumProcesses(ctypes.byref(pids), ctypes.sizeof(pids), ctypes.byref(needed)):
        return {}
    found = {}
    for pid in pids[:needed.value // ctypes.sizeof(ctypes.c_uint)]:
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            continue
        try:
            buffer = ctypes.create_unicode_buffer(1024)
            size = ctypes.c_uint(1024)
            if kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                version = package_version(buffer.value, package)
                if version and buffer.value.lower().endswith('\\' + exe):
                    found[pid] = version
        finally:
            kernel32.CloseHandle(handle)
    return found


def running_images(name):
    """Full paths of running processes whose executable is `name` (case-insensitive)."""
    psapi, kernel32 = ctypes.windll.psapi, ctypes.windll.kernel32
    pids = (ctypes.c_uint * 4096)()
    needed = ctypes.c_uint()
    if not psapi.EnumProcesses(ctypes.byref(pids), ctypes.sizeof(pids), ctypes.byref(needed)):
        return []
    found = []
    for pid in pids[:needed.value // ctypes.sizeof(ctypes.c_uint)]:
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            continue
        try:
            buffer = ctypes.create_unicode_buffer(1024)
            size = ctypes.c_uint(1024)
            if kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                if buffer.value.lower().endswith('\\' + name.lower()) and buffer.value not in found:
                    found.append(buffer.value)
        finally:
            kernel32.CloseHandle(handle)
    return found


def prompt_id(app, doc, text):
    return hashlib.sha256(f'{app}\n{doc}\n{text}'.encode('utf-8')).hexdigest()[:16]


class UiWatcher:
    """Looks at each desktop app every few seconds: which conversation is open and whether it is
    asking for permission. Sends ntfy only when the user has to act or be warned: a permission
    or option question, or context or plan usage past the alert threshold."""

    def __init__(self, hub, driver, notify=None, pc_name='', interval=4, memory=None):
        self.hub, self.driver, self.notify, self.pc_name, self.interval = hub, driver, notify, pc_name, interval
        self.state = {}         # app -> {'docs': [...], 'prompt': {...} or None}
        # The last usage button reading per app survives a restart: the window may stay hidden
        # in the tray for hours, and the history file it would fall back to is days behind.
        self.memory = Path(memory) if memory else None
        try:
            saved = json.loads(self.memory.read_text(encoding='utf-8')) if self.memory else {}
        except (OSError, ValueError, UnicodeDecodeError):
            saved = {}
        for app, seen in (saved.items() if isinstance(saved, dict) else []):
            if app in APPS and isinstance(seen, dict):
                self.state[app] = {key: seen.get(key) for key in ('usage', 'usageAt', 'card', 'cardAt')}
        self.card_every, self.card_idle, self.last_card_check = 300, 60, None
        self.turns = {}         # (app, id) -> last parser status
        self.questions = {}     # (app, id) -> option question waiting at the last look
        self.checked_once = False
        self.context_alerted, self.usage_alerted = set(), set()
        self.popups = []        # pop-up windows on the desktop at the last look, each with an id
        self.quiet_popups_until = 0.0  # no pop-up notifications before then (the phone opened one)
        self.uac_since = self.uac_told = None  # when a UAC prompt was first seen; whether the phone was told
        self.versions, self.versions_checked = {}, None  # each app's installed and running version
        self.update_told, self.restart_tried = set(), {}  # (app, version) told; Codex version -> when restarted
        self.busy = lambda: False                         # a phone action is queued or running
        self.last_usage_check = 0.0
        self.usage_checked_once = False
        self.last_turn_check = 0.0
        self.lock = threading.Lock()

    def look(self, app):
        try:
            answer = self.driver.inspect(app)
        except ActionError:
            return
        prompt = None
        docs = answer.get('docs') or []
        raw = answer.get('prompt')
        if raw and raw.get('text') and len(docs) == 1:
            prompt = {'promptId': prompt_id(app, docs[0], raw['text']), 'text': raw['text'], 'tool': None,
                      'doc': docs[0]}
        with self.lock:
            before = self.state.get(app) or {}
            old = before.get('prompt')
            # The usage button is only there while the window is: keep the last reading and when.
            usage, usage_at = answer.get('usage'), time.time()
            if not usage:
                usage, usage_at = before.get('usage'), before.get('usageAt')
            self.state[app] = {'docs': docs, 'prompt': prompt, 'window': answer.get('window'),
                               'model': answer.get('model'), 'usage': usage, 'usageAt': usage_at,
                               'card': before.get('card'), 'cardAt': before.get('cardAt'),
                               'mode': answer.get('mode'), 'running': answer.get('running'),
                               'update': answer.get('update')}
            if self.memory and answer.get('usage') and answer['usage'] != before.get('usage'):
                self.remember_usage()
        if prompt and (not old or old['promptId'] != prompt['promptId']):
            title = prompt['doc'].removesuffix(' - Claude Code')
            session_id, _ = self.hub.session_for_doc(app, prompt['doc'])
            self.send(f'🔔 {APP_NAMES[app]} 在等你核准', f'{self.pc_name}・「{title}」：{prompt["text"][:120]}', 4, ['bell'],
                      open_link(self.pc_name, app, session_id, title) if session_id else open_link(self.pc_name))

    def prompt_for(self, app, session_id):
        info = self.hub.info(app, session_id)
        with self.lock:
            prompt = (self.state.get(app) or {}).get('prompt')
        if not prompt or not info or prompt['doc'] != info['doc']:
            return None
        return {k: prompt[k] for k in ('promptId', 'text', 'tool')}

    def current(self, app):
        with self.lock:
            return dict(self.state.get(app) or {})

    def check_card(self, app='claude'):
        """Every few minutes while nobody uses the PC: the usage card, the only place the session
        limit shows (the button expanded and closed again; the card shows for a moment, so not
        while someone is at the PC, and never on a locked one)."""
        if not (self.hub.strings.get(app) or {}).get('usage_card') or not hasattr(self.driver, 'usage_card'):
            return
        if self.last_card_check is not None and time.monotonic() - self.last_card_check < self.card_every:
            return
        presence = self.hub.presence.snapshot()
        idle = presence.get('idleSeconds')
        if presence.get('locked') or idle is None or idle < self.card_idle:
            return
        self.last_card_check = time.monotonic()
        try:
            rows = self.driver.usage_card(app)
        except ActionError:
            return
        if rows:
            with self.lock:
                self.state.setdefault(app, {}).update(card=rows, cardAt=time.time())
                if self.memory:
                    self.remember_usage()

    def check_popups(self, notify=True):
        """A window that pops up and waits for an answer (a firewall question, found 10/29) keeps
        the desktop apps from coming to the front, so messages cannot be sent: tell the phone once
        per window, and let it press one of the window's buttons. Returns the windows; `notify`
        False when the phone is already looking (it pressed the button that opened the window)."""
        if not hasattr(self.driver, 'popups'):
            return []
        try:
            found = self.driver.popups()
        except ActionError:
            return []
        listed = []
        for raw in found:
            if not isinstance(raw, dict) or not raw.get('buttons'):
                continue
            if self.allow_extension_read(raw):
                continue
            key = f"{raw.get('hwnd')}\n{raw.get('title')}\n{raw.get('process')}"
            listed.append({'id': hashlib.sha256(key.encode('utf-8')).hexdigest()[:12], 'hwnd': raw.get('hwnd'),
                           'title': str(raw.get('title') or ''), 'process': str(raw.get('process') or ''),
                           'text': str(raw.get('text') or '')[:600],
                           'buttons': [str(b) for b in raw['buttons']][:8], 'page': bool(raw.get('page'))})
        with self.lock:
            known = {p['id'] for p in self.popups}
            self.popups = listed
        # A question inside an app's page may be a menu or a question the person at the PC just
        # opened: told only when nobody is at the PC.
        presence = self.hub.presence.snapshot() if any(p['page'] for p in listed) else {}
        away = presence.get('locked') or (presence.get('idleSeconds') or 0) >= 60
        quiet = not notify or time.monotonic() < self.quiet_popups_until
        for popup in listed:
            if popup['id'] not in known and not quiet and (away or not popup['page']):
                name = popup['title'] or popup['process']
                detail = popup['text'].replace('\n', ' ')[:100] or popup['process']
                self.send(f'🪟 電腦跳出視窗：{name}', f'{self.pc_name}・{detail}；打開桌面遙控選要按的按鈕', 4, ['window'],
                          open_link(self.pc_name))
        return listed

    def allow_extension_read(self, raw):
        """Claude for Chrome's permission card ("Claude wants to ... on <site>") is allowed by the
        helper itself (the user's choice 10/31: it came up on every site while Claude Code browsed,
        and answering each one from the phone was a chore). Every card of the extension's window
        with its allow button: at first only the "read page content" wording was, but some cards
        still reached the phone (10/31 evening; their words are not always drawn, or drawn in
        pieces), and the extension itself never buys, signs up or passes captchas. What it asked
        is logged. True when it was pressed (so it is not listed)."""
        if str(raw.get('title') or '') != EXTENSION_TITLE or EXTENSION_ALLOW not in [str(b) for b in raw['buttons']]:
            return False
        lines = [line.strip() for line in str(raw.get('text') or '').splitlines() if line.strip()]
        asked = next((line for line in lines if 'wants to' in line), lines[0] if lines else '(no words yet)')
        site = next((line for line in lines if re.fullmatch(r'[a-z0-9.-]+\.[a-z]{2,}', line.lower())), '?')
        try:
            gone = self.driver.press_popup(raw, EXTENSION_ALLOW)
        except ActionError as exc:
            logging.warning('chrome extension: allowing "%s" on %s failed: %s %s', asked[:80], site, exc.code, exc.message)
            return False
        logging.info('chrome extension: allowed "%s" on %s (%s)', asked[:80], site, 'card gone' if gone else 'card still there')
        return True

    def popup_list(self):
        """The pop-ups for the phone (without the window handle)."""
        with self.lock:
            return [{k: p[k] for k in ('id', 'title', 'process', 'text', 'buttons')} for p in self.popups]

    def popup(self, popup_id):
        with self.lock:
            return next((dict(p) for p in self.popups if p['id'] == popup_id), None)

    def remember_usage(self):
        """Saves each app's last usage button and card readings (called with the lock held)."""
        seen = {app: {key: s.get(key) for key in ('usage', 'usageAt', 'card', 'cardAt')}
                for app, s in self.state.items() if s.get('usage') or s.get('card')}
        try:
            self.memory.write_text(json.dumps(seen, ensure_ascii=False), encoding='utf-8')
        except OSError:
            logging.exception('saving the usage reading failed')

    def check_turns(self):
        """A conversation that starts waiting on an option question needs an answer: ntfy once.
        Working conversations are followed so that one stays watched until it is idle again."""
        for app, source in self.hub.sources.items():
            for row in source.list_sessions(15):
                key = (app, row['id'])
                if row['status'] != 'active' and key not in self.turns:
                    continue
                transcript = self.hub.transcript(app, row['id'])
                if transcript is None:
                    continue
                transcript.refresh()
                status = transcript.parser.status
                question = (getattr(transcript.parser, 'question', None) or {}).get('questionId')
                link = open_link(self.pc_name, app, row['id'], row['title'])
                # Questions already waiting when the helper started are not news. A finished turn
                # is not sent: the phone shows it (the user asked on 10/28 for notifications only
                # when they need to act).
                if question and self.checked_once and question != self.questions.get(key):
                    self.send(f'❓ {APP_NAMES[app]} 在等你選擇', f'{self.pc_name}・「{row["title"]}」', 4, ['question'], link)
                self.turns[key] = status
                self.questions[key] = question
                self.check_context(app, row, transcript, link)
        self.checked_once = True
        if time.monotonic() - self.last_usage_check > 300:
            self.last_usage_check = time.monotonic()
            self.check_usage()

    def check_context(self, app, row, transcript, link):
        """Once per conversation when its context passes the threshold (again after it drops,
        e.g. compacted)."""
        key = (app, row['id'])
        context = self.hub.meta(app, row['id'], transcript).get('context') or {}
        percent, limit = context.get('percent'), self.hub.alerts['context_percent']
        if percent is None or percent < limit:
            self.context_alerted.discard(key)
            return
        if key not in self.context_alerted:
            self.context_alerted.add(key)
            if self.checked_once:  # already past it when the helper started: not news
                self.send(f'⚠️ {APP_NAMES[app]} 上下文快滿了', f'{self.pc_name}・「{row["title"]}」已用 {percent}%', 4,
                          ['warning'], link)

    def check_usage(self):
        """Once per window when a plan limit passes the threshold (again after it resets)."""
        limit = self.hub.alerts['usage_percent']
        for app, usage in (self.hub.usage() or {}).items():
            for window in (usage or {}).get('windows') or []:
                key = (app, window['label'])
                if window['percent'] < limit:
                    self.usage_alerted.discard(key)
                elif key not in self.usage_alerted:
                    self.usage_alerted.add(key)
                    if not self.usage_checked_once:
                        continue  # already past it when the helper started: not news
                    reset = window.get('resetsText') or ''
                    self.send(f'⚠️ {APP_NAMES[app]} 額度已用 {window["percent"]}%',
                              f'{self.pc_name}・{window["label"]}{"・" + reset if reset else ""}', 4, ['warning'],
                              open_link(self.pc_name))
        self.usage_checked_once = True

    def send(self, title, message, priority, tags, click=None):
        if self.notify:
            try:
                self.notify(title, message, priority, tags, click)
            except OSError:
                logging.exception('notification failed: %s', title)

    RESTART_IDLE = 600  # seconds nobody has touched the PC before Codex is restarted into a new version

    def check_versions(self, now=None):
        """Always the newest desktop apps (asked 10/30). Windows installs a new Codex in the
        background while the old one keeps running (office 10/29: 26.1023 installed, 26.1016
        running, and its window would not come back from the tray): restart it once nothing is
        lost by it. Claude is only told: restarting it ends every Claude Code session in it."""
        if not hasattr(self.driver, 'versions'):
            return
        now = time.monotonic() if now is None else now
        if self.versions_checked is not None and now - self.versions_checked < 60:
            return
        self.versions_checked = now
        try:
            found = self.driver.versions()
        except (ActionError, OSError):
            return
        # Claude downloads its own updates and shows "重新啟動以更新 v4.29.0" (office 10/30: 3.6556
        # running with 4.29 waiting): that button is the update, pressed only from the phone.
        button = (self.current('claude') or {}).get('update')
        if button:
            found['claude'] = dict(found.get('claude') or {}, pending=pending_version(button))
        else:
            # Downloaded without a button (its log says so; office 10/30, after the updater swapped
            # 4.29 for 4.4212): only told, to be done at the PC (the user's choice 10/30 after the
            # phone's close-and-start route proved fiddly).
            running = (found.get('claude') or {}).get('running')
            downloaded = self.driver.downloaded_update('claude') if hasattr(self.driver, 'downloaded_update') else None
            if downloaded and running and version_key(downloaded)[:3] > version_key(running)[:3]:
                found['claude'] = dict(found.get('claude') or {}, downloaded=downloaded)
        with self.lock:
            self.versions = found
        claude = found.get('claude') or {}
        new = claude.get('pending') or claude.get('downloaded') or (claude['installed'] if claude.get('old') else None)
        if new and ('claude', new) not in self.update_told:
            self.update_told.add(('claude', new))
            how = ('到電腦上按 Claude 畫面裡的「重新啟動以更新」（或在手機的電腦頁按）' if claude.get('pending')
                   else '到電腦上把 Claude 關掉再打開就會換成新版（它沒有顯示更新按鈕）')
            self.send('🆕 Claude 桌面版有新版', f"{self.pc_name}・新版 {new}，目前跑的是 {claude.get('running')}；{how}"
                      '（會關掉裡面的 Claude Code 工作，所以不自動做）', 3, ['new'], open_link(self.pc_name))
        codex = found.get('codex') or {}
        codex_button = (self.current('codex') or {}).get('update')
        if codex_button and not codex.get('old'):
            # Codex's own updater (its header "更新"), when the Store has not brought the new one
            # yet: press it once nothing is lost; again at most once an hour while it stays.
            tried = self.restart_tried.get('codex-button')
            if (tried is None or now - tried > 3600) and self.codex_restartable():
                self.restart_tried['codex-button'] = now
                strings = self.hub.strings.get('codex') or {}
                logging.info('codex shows its update button: pressing it')
                try:
                    self.driver.press_update('codex', codex_button, strings.get('update_confirm'))
                except ActionError as exc:
                    logging.warning('codex update button failed: %s %s', exc.code, exc.message)
            return
        if not codex.get('old'):
            return
        version = codex['installed']
        tried = self.restart_tried.get(version)
        if tried is None and self.codex_restartable():
            self.restart_tried[version] = now
            logging.info('restarting codex %s into %s', codex['running'], version)
            try:
                self.driver.restart_app('codex')
            except ActionError as exc:
                logging.warning('restarting codex failed: %s %s', exc.code, exc.message)
                self.update_told.add(('codex', version))
                self.send('⚠️ Codex 換新版時沒能重新開起來', f'{self.pc_name}・新版 {version}；請在電腦上打開 Codex'
                          '（或在手機點進 Codex 的對話清單，會試著叫出來）', 4, ['warning'], open_link(self.pc_name))
        elif tried is not None and now - tried > 180 and ('codex', version) not in self.update_told:
            self.update_told.add(('codex', version))
            self.send('⚠️ Codex 沒能重開成新版', f"{self.pc_name}・新版 {version} 已裝好，但還在跑 {codex['running']}；"
                      '可在電腦上結束 Codex 再打開', 4, ['warning'], open_link(self.pc_name))

    def codex_restartable(self):
        """Nothing is lost by ending Codex now: nobody at the PC for RESTART_IDLE seconds, no
        phone action queued, no conversation being written or waiting on an answer."""
        presence = self.hub.presence.snapshot()
        idle = presence.get('idleSeconds')
        if presence.get('uac'):
            return False
        if not presence.get('locked') and (idle is None or idle < self.RESTART_IDLE):  # locked: nobody on it
            return False
        if self.busy() or (self.state.get('codex') or {}).get('prompt'):
            return False
        try:
            rows = self.hub.sources['codex'].list_sessions(15)
        except (OSError, ValueError, sqlite3.Error):
            return False
        return not any(row['status'] in ('active', 'needs-action') for row in rows)

    def version_list(self):
        with self.lock:
            return {app: {'installed': info.get('installed'), 'running': info.get('running'),
                          'update': bool(info.get('old') or info.get('pending')), 'pending': info.get('pending'),
                          'downloaded': info.get('downloaded')}  # ready in Claude's log, no button: done at the PC
                    for app, info in self.versions.items()}

    def update_target(self, app):
        """What the phone's update presses for `app`: {'button': its label, 'version'}, or None
        when the app shows no update button."""
        button = self.current(app).get('update')
        return {'button': button, 'version': pending_version(button)} if button else None

    UAC_GRACE = 20  # seconds: someone at the PC answers their own UAC prompt before this

    def check_uac(self, now=None):
        """A UAC prompt left waiting blocks everything and cannot be pressed from the phone: tell
        the phone once per prompt, when nobody has answered it for UAC_GRACE seconds (asked 10/29)."""
        now = time.monotonic() if now is None else now
        if not self.hub.presence.snapshot().get('uac'):
            self.uac_since = self.uac_told = None
            return
        if self.uac_since is None:
            self.uac_since = now
        if not self.uac_told and now - self.uac_since >= self.UAC_GRACE:
            self.uac_told = True
            self.send('🛡️ 電腦跳出系統管理員確認（UAC）', f'{self.pc_name}・手機無法代按，請到電腦前按（或用 Google 遠端桌面）；'
                      '按掉之前訊息送不出去', 4, ['shield'], open_link(self.pc_name))

    def tick(self):
        self.check_uac()
        for app in APPS:
            self.look(app)
        self.check_versions()  # after the looks: Claude's update button is read there
        self.check_popups()
        self.check_card()
        if time.monotonic() - self.last_turn_check > 15:
            self.last_turn_check = time.monotonic()
            self.check_turns()

    def check_extension(self):
        """Claude for Chrome's card, allowed within a second or two of showing: the full look
        every `interval` seconds (and a phone action holding the worker) left it waiting long
        enough for the request to be cancelled (10/31)."""
        if not hasattr(self.driver, 'extension_popups'):
            return
        try:
            found = self.driver.extension_popups()
        except ActionError:
            return
        for raw in found:
            if isinstance(raw, dict) and raw.get('buttons'):
                self.allow_extension_read(raw)

    def run_forever(self):
        while True:
            try:
                self.tick()
            except Exception:
                logging.exception('watcher failed')
            # Between full looks, the extension's card is checked about every 1.3 s.
            for _ in range(3):
                time.sleep(self.interval / 3)
                try:
                    self.check_extension()
                except Exception:
                    logging.exception('extension check failed')


APP_NAMES = {'claude': 'Claude', 'codex': 'Codex'}


def decode_image(value, limit=8 * 1024 * 1024):
    """Bytes of a base64 JPEG or PNG from the phone, or None when it is not one or too big."""
    import base64
    import binascii
    if not isinstance(value, str) or len(value) > limit * 4 // 3 + 8:
        return None
    try:
        data = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        return None
    if len(data) > limit or not (data.startswith(b'\xff\xd8\xff') or data.startswith(b'\x89PNG\r\n\x1a\n')):
        return None
    return data


def normalized(text):
    return re.sub(r'\s+', ' ', text or '').strip()


class ActionRunner:
    """Every action that touches a window runs here, one at a time.

    Before anything that needs the foreground (sending, opening, a new conversation, Claude's
    allow-once dropdown) the PC must be unlocked and idle for `idle_seconds`, unless the phone
    confirmed "send anyway". The conversation is opened through its own link and its page title
    checked before any keystroke; afterwards the sent text must show up in that conversation's
    transcript. Each action is logged and sent to ntfy (titles only, never the message text).
    """

    KEEP = 1800        # seconds an action's result stays readable
    MAX_QUEUED = 5
    MAX_TEXT = 20000
    MAX_IMAGE = 8 * 1024 * 1024   # a photo from the phone, after decoding
    MAX_IMAGES = 10               # photos in one message

    def __init__(self, hub, driver, presence, watcher, notify=None, pc_name='', strings=None,
                 idle_seconds=60, verify_seconds=20, doc_wait=15, settle_seconds=2.0, clock=time.monotonic):
        self.hub, self.driver, self.presence, self.watcher = hub, driver, presence, watcher
        self.settle_seconds = settle_seconds
        self.notify, self.pc_name, self.strings = notify, pc_name, strings or {}
        self.idle_seconds, self.verify_seconds, self.doc_wait, self.clock = idle_seconds, verify_seconds, doc_wait, clock
        self.actions = {}
        self.client_ids = {}
        self.queue = []
        self.lock = threading.Condition()

    # -- submitting (HTTP thread) --------------------------------------------------------------

    def gate(self, force, needs_front=True):
        """None when the PC may be driven now, else (status, body)."""
        presence = self.presence.snapshot()
        if presence.get('uac'):
            return 423, error('uac', UAC_TEXT)
        if presence.get('locked'):
            return 423, error('locked', '電腦已鎖定，請先解鎖（可用 Google 遠端桌面）')
        idle = presence.get('idleSeconds')
        if needs_front and not force and idle is not None and idle < self.idle_seconds:
            body = error('busy-user', f'電腦有人在用（{idle} 秒前有操作）')
            body['idleSeconds'] = idle
            return 409, body
        return None

    def submit(self, kind, app, session_id, payload):
        force = bool(payload.get('force'))
        text = payload.get('text')
        images = []
        if kind == 'send' and (payload.get('image') is not None or payload.get('images') is not None):
            # One photo as `image` (App 0.5.5 and earlier), several as `images` (asked on 10/29).
            raw = payload.get('images') if payload.get('images') is not None else [payload.get('image')]
            if not isinstance(raw, list) or not 1 <= len(raw) <= self.MAX_IMAGES:
                return 400, error('bad-request', f'一次最多 {self.MAX_IMAGES} 張照片')
            images = [decode_image(value) for value in raw]
            if any(image is None for image in images):
                return 400, error('bad-request', f'照片要是 JPEG 或 PNG，每張最大 {self.MAX_IMAGE // 1048576} MB')
            text = text or ''
        if kind == 'popup':
            popup = self.watcher.popup(session_id)
            if popup is None:
                return 404, error('popup-gone', '這個視窗已經關掉了，請重新整理')
            if payload.get('button') not in popup['buttons']:
                return 400, error('bad-request', '這個視窗沒有這個按鈕')
        if kind in ('send', 'new'):
            if not isinstance(text, str) or (not text.strip() and not images):
                return 400, error('bad-request', '訊息是空的')
            if len(text) > self.MAX_TEXT:
                return 400, error('bad-request', f'訊息太長（上限 {self.MAX_TEXT} 字）')
        strings = self.strings.get(app) or {}
        choice_keys = {'model': ('models', '模型'), 'effort': ('efforts', '推理強度'), 'mode': ('modes', '權限模式')}
        if kind in choice_keys:
            key, what = choice_keys[kind]
            if not strings.get(key):
                return 400, error('not-supported', f'這個 App 還不能從手機切換{what}')
            if payload.get(kind) not in strings[key]:
                return 400, error('bad-request', f'沒有這個{what}')
        if kind == 'stop' and not strings.get('stop'):
            return 400, error('not-supported', '這個 App 還不能從手機停止')
        if kind == 'update':
            if app != 'claude':
                return 400, error('not-supported', 'Codex 會在電腦閒置時自己更新')
            if not self.watcher.update_target(app):
                return 409, error('no-update', 'Claude 桌面版沒有等著安裝的新版')
        if kind == 'fast':
            if not strings.get('fast_on'):
                return 400, error('not-supported', '這個 App 沒有快速模式')
            if not isinstance(payload.get('fast'), bool):
                return 400, error('bad-request', '要說開或關')
        info = None
        if kind in ('send', 'open', 'permission', 'answer', 'model', 'effort', 'mode', 'stop', 'fast'):
            info = self.hub.info(app, session_id)
            if info is None:
                return 404, error('not-found', '找不到這個對話')
        if kind == 'answer':
            problem = self.check_answers(app, session_id, payload)
            if problem:
                return problem
        if kind == 'permission':
            decision = payload.get('decision')
            if decision not in ('allow_once', 'deny'):
                return 400, error('bad-request', '只能選允許一次或拒絕')
            current = self.watcher.prompt_for(app, session_id)
            if not current or current['promptId'] != payload.get('promptId'):
                return 409, error('prompt-changed', '電腦上的權限詢問已經不一樣了，請重新整理')
            needs_front = app == 'claude' and decision == 'allow_once'
        elif kind in ('stop', 'popup', 'fast', 'update') or (app == 'codex' and kind in ('model', 'mode')):
            # Pressed through UI Automation alone; opening another conversation still checks.
            needs_front = False
        else:
            needs_front = True
        denied = self.gate(force, needs_front)
        if denied:
            return denied
        with self.lock:
            client_id = payload.get('clientMsgId')
            if isinstance(client_id, str) and client_id in self.client_ids:
                existing = self.actions.get(self.client_ids[client_id])
                if existing:
                    return 202, self.public(existing)
            if len(self.queue) >= self.MAX_QUEUED:
                return 429, error('busy', '電腦端還有動作在排隊，請稍後再試')
            action = {'id': secrets.token_hex(6), 'kind': kind, 'app': app, 'sessionId': session_id, 'info': info,
                      'text': text, 'decision': payload.get('decision'), 'promptId': payload.get('promptId'),
                      'questionId': payload.get('questionId'), 'answers': payload.get('answers'),
                      'project': payload.get('project'), 'model': payload.get('model'), 'effort': payload.get('effort'),
                      'mode': payload.get('mode'), 'images': images, 'button': payload.get('button'),
                      'fast': payload.get('fast'),
                      'needsFront': needs_front, 'force': force, 'state': 'queued', 'message': '排隊中',
                      'error': None, 'verified': None, 'created': self.clock()}
            self.actions[action['id']] = action
            if isinstance(client_id, str) and len(client_id) <= 100:
                self.client_ids[client_id] = action['id']
            self.queue.append(action['id'])
            self.prune()
            self.lock.notify()
        return 202, self.public(action)

    def pending_question(self, app, session_id):
        transcript = self.hub.transcript(app, session_id)
        if transcript is None:
            return None, None
        transcript.refresh()
        with transcript.lock:
            return transcript, getattr(transcript.parser, 'question', None)

    def check_answers(self, app, session_id, payload):
        """(status, body) when the answers do not fit the question waiting now, else None."""
        _, question = self.pending_question(app, session_id)
        if not question or question['questionId'] != payload.get('questionId'):
            return 409, error('question-changed', '這個選項題已經回答過或換了一題，請重新整理')
        answers = payload.get('answers')
        if not isinstance(answers, list) or len(answers) != len(question['questions']):
            return 400, error('bad-request', '每一題都要回答')
        for item, answer in zip(question['questions'], answers):
            if not isinstance(answer, dict):
                return 400, error('bad-request', '答案格式不對')
            labels = answer.get('labels') or []
            other = answer.get('other')
            known = {o['label'] for o in item['options']}
            if not isinstance(labels, list) or any(label not in known for label in labels):
                return 400, error('bad-request', '選了不存在的選項')
            if not item['multiSelect'] and len(labels) > 1:
                return 400, error('bad-request', '這一題只能選一個')
            if other is not None and (not isinstance(other, str) or len(other) > 2000):
                return 400, error('bad-request', '「其他」的內容不對')
            if not labels and not (other or '').strip():
                return 400, error('bad-request', '每一題都要回答')
        return None

    def prune(self):
        now = self.clock()
        for action_id in [k for k, v in self.actions.items() if now - v['created'] > self.KEEP]:
            self.actions.pop(action_id, None)
        self.client_ids = {k: v for k, v in self.client_ids.items() if v in self.actions}

    @staticmethod
    def public(action):
        keys = ('id', 'kind', 'app', 'sessionId', 'state', 'message', 'error', 'verified')
        out = {k: action[k] for k in keys}
        out['app'] = out['app'] or ''  # a pop-up belongs to no app; the phone reads a string
        out['ok'] = action['state'] != 'failed'
        if action.get('title'):
            out['title'] = action['title']
        return out

    def status(self, action_id):
        with self.lock:
            action = self.actions.get(action_id)
            return self.public(action) if action else None

    # -- running (one worker thread) -----------------------------------------------------------

    def run_forever(self):
        while True:
            with self.lock:
                while not self.queue:
                    self.lock.wait()
                action = self.actions.get(self.queue[0])
            if action is not None:
                self.run(action)
            with self.lock:
                self.queue.pop(0)

    def update(self, action, **fields):
        with self.lock:
            action.update(fields)

    def run(self, action):
        self.update(action, state='running', message='處理中')
        handler = {'send': self.do_send, 'permission': self.do_permission, 'new': self.do_new,
                   'open': self.do_open, 'answer': self.do_answer, 'model': self.do_model,
                   'effort': self.do_effort, 'mode': self.do_mode, 'stop': self.do_stop,
                   'launch': self.do_launch, 'popup': self.do_popup, 'fast': self.do_fast,
                   'update': self.do_update}[action['kind']]
        try:
            handler(action)
        except ActionError as exc:
            logging.warning('%s %s failed: %s %s', action['kind'], action['app'], exc.code, exc.message)
            message = failure_text(exc.code, exc.message)
            if exc.code != 'uac' and self.presence.snapshot().get('uac'):
                message += '；' + UAC_TEXT  # a prompt that came up while this ran
            elif exc.code in ('focus-failed', 'paste-failed', 'no-prompt-box') and self.watcher.popup_list():
                message += '；電腦上有跳出的視窗擋著，可在電腦頁按掉後再送'
            self.update(action, state='failed', error=exc.code, message=message)
            self.tell(action, failed=True)
        except Exception:
            logging.exception('action failed')
            self.update(action, state='failed', error='internal', message='電腦端發生錯誤')
            self.tell(action, failed=True)
        else:
            self.tell(action)
        finally:
            self.presence.end_own()

    def tell(self, action, failed=False):
        """Only a failure goes to ntfy: the phone that asked already shows each success (the user
        asked on 10/27 not to be notified of what they did themselves). Opening the desktop app
        is asked for by the phone on its own, which shows how it went."""
        if not self.notify or not failed or action['kind'] == 'launch':
            return
        verb = {'send': '送出訊息', 'permission': '回覆權限', 'new': '開新對話', 'open': '打開對話',
                'answer': '回答選項題', 'model': '切換模型', 'effort': '切換推理強度', 'mode': '切換權限模式',
                'stop': '停止', 'popup': '按電腦上的視窗', 'fast': '切換快速模式', 'update': '更新桌面版'}[action['kind']]
        title = (action.get('info') or {}).get('title') or action.get('title') or ''
        head = f"⚠️ 手機{verb}失敗" + (f"：{APP_NAMES[action['app']]}" if action['app'] in APP_NAMES else '')
        body = f"{self.pc_name}・「{title}」：{action['message']}"
        session_id = action.get('sessionId')
        try:
            self.notify(head, body, 4, ['iphone'],
                        open_link(self.pc_name, action['app'], session_id, title) if session_id else open_link(self.pc_name))
        except OSError:
            logging.exception('action notification failed')

    def recheck(self, action, needs_front=True):
        denied = self.gate(action['force'], needs_front)
        if denied:
            raise ActionError(denied[1]['error'], denied[1]['message'])

    @staticmethod
    def page_of(docs, info):
        """The one open page that carries one of this conversation's names, else None."""
        names = [info['doc']] + list(info.get('aliases') or [])
        hits = [doc for doc in docs or [] if doc in names]
        return hits[0] if len(hits) == 1 else None

    def wait_doc(self, app, info):
        """The page title once exactly one page has one of the conversation's names, else None.
        A missing window counts as not yet: the link may still be bringing the app up from the tray."""
        deadline = self.clock() + self.doc_wait
        while True:
            docs = self.driver.docs(app)
            page = self.page_of(docs, info)
            if page is not None:
                return page
            if self.clock() >= deadline:
                if docs is None:
                    raise ActionError('app-not-running', '')
                return None
            time.sleep(0.25)

    def unclaimed(self, app, session_id, doc):
        """True when no other listed conversation goes by this page title."""
        names = self.hub.sources[app].names() if hasattr(self.hub.sources[app], 'names') else {}
        return not any(doc in found for other, found in names.items() if other != session_id)

    def adopt_linked_page(self, action, before):
        """Codex may title an imported thread's page with neither its database title nor its
        import title (live 10/28: "測試:A1 回覆" showed as "測試 回覆"). The page its own link
        has just switched to is it, unless another conversation goes by that title. When that
        page was already on screen the switch cannot be seen, so step to another conversation
        and follow the link again."""
        app, info, session_id = action['app'], action['info'], action['sessionId']
        now = self.driver.docs(app)
        if not now or len(now) != 1 or not self.unclaimed(app, session_id, now[0]):
            return False
        if now == before:
            rows = self.hub.sources[app].list_sessions(10)
            other = next((self.hub.info(app, row['id']) for row in rows if row['id'] != session_id), None)
            if other is None or self.wait_doc_after_open(app, other) is None:
                return False
            before = self.driver.docs(app)
            self.driver.open(app, info)
            now = self.wait_change(app, before)
            if not now or len(now) != 1 or not self.unclaimed(app, session_id, now[0]):
                return False
        self.hub.learn_page_name(app, session_id, info, self.page_of(now, info) or now[0])
        return True

    def wait_doc_after_open(self, app, info):
        self.driver.open(app, info)
        return self.wait_doc(app, info)

    def wait_change(self, app, before):
        """The open pages once they differ from `before` and hold still for a moment, else None."""
        deadline = self.clock() + self.doc_wait
        while self.clock() < deadline:
            docs = self.driver.docs(app)
            if docs and docs != before:
                time.sleep(min(1.0, self.settle_seconds))  # the title may still change once
                return self.driver.docs(app)
            time.sleep(0.25)
        return None

    def open_conversation(self, action):
        """Opens the conversation by its own link. The app may be closed to the tray (Codex was,
        live 10/27): the link brings its window back, so no window is not a reason to stop yet."""
        app, info = action['app'], action['info']
        docs = self.driver.docs(app)
        page = self.page_of(docs, info)
        if page is not None:
            self.hub.learn_page_name(app, action['sessionId'], info, page)
            if action.get('needsFront', True):
                # Windows lets a link activation take the foreground but refuses this helper's own
                # SetForegroundWindow while another app is in front (live 10/27), so the open
                # conversation's own link brings its window up.
                self.recheck(action)
                self.presence.begin_own()
                self.driver.open(app, info)
                time.sleep(min(1.0, self.settle_seconds))
            return
        self.recheck(action)
        self.presence.begin_own()
        self.driver.open(app, info)
        page = self.wait_doc(app, info)
        if page is not None:
            self.hub.learn_page_name(app, action['sessionId'], info, page)
            # The title changes before the new page is ready to type into (found live: a
            # message sent right after the switch was lost), so let it settle.
            time.sleep(self.settle_seconds)
            return
        if app == 'codex' and self.adopt_linked_page(action, docs):
            time.sleep(self.settle_seconds)
            return
        # Fallback: the sidebar entry with this title, only when the title is unique. Codex names
        # the entry by the title; Claude adds a note ("<title> 由 Claude 從「…」啟動"). Claude
        # once stopped following its links altogether (live 10/27) while its sidebar still worked.
        titles = [row['title'] for row in self.hub.sources[app].list_sessions(100)]
        if titles.count(info['title']) > 1:
            raise ActionError('duplicate-title', '')
        if titles.count(info['title']) == 0:
            raise ActionError('title-mismatch', '')
        if app == 'codex':
            self.driver.invoke(app, info['title'])
        else:
            self.driver.invoke_title(app, info['title'])
        page = self.wait_doc(app, info)
        if page is not None:
            self.hub.learn_page_name(app, action['sessionId'], info, page)
            time.sleep(self.settle_seconds)
            return
        raise ActionError('title-mismatch', '')

    def do_open(self, action):
        self.open_conversation(action)
        self.update(action, state='done', message='已在電腦上打開')

    def window_shown(self, app):
        self.presence.forget_windows()
        return bool((self.presence.snapshot().get('windows') or {}).get(app))

    def do_launch(self, action):
        """Shows the desktop app's window: starts the app, or brings it back from the tray."""
        app = action['app']
        if self.window_shown(app):
            self.update(action, state='done', verified=True, message='桌面版已經開著')
            return
        self.recheck(action)
        self.presence.begin_own()
        self.driver.launch(app)
        if not self.wait_shown(app, self.verify_seconds) and app == 'codex':
            # The Start menu entry reports success and shows nothing while the running Codex is an
            # older build than the installed package (office 10/29); the package's exe shows it.
            logging.info('codex window did not show from the Start menu entry; starting its exe')
            self.driver.launch(app, again=True)
        if not self.wait_shown(app, self.verify_seconds * 2):  # a cold start takes longer than a switch
            raise ActionError('app-not-running', 'no window showed up')
        self.update(action, state='done', verified=True, message='已在電腦上開啟桌面版')

    def wait_shown(self, app, seconds):
        deadline = self.clock() + seconds
        while not self.window_shown(app):
            if self.clock() >= deadline:
                return False
            time.sleep(0.5)
        return True

    def do_send(self, action):
        app, info, text = action['app'], action['info'], action['text']
        transcript = self.hub.transcript(app, action['sessionId'])
        if transcript is not None:
            transcript.refresh()
        mark = transcript.seq if transcript is not None else 0
        self.open_conversation(action)
        self.recheck(action)
        paths = []
        try:
            # The worker pastes each photo from a file only this user can read; removed right after.
            for image in action.get('images') or []:
                handle, path = tempfile.mkstemp(prefix='desk-remote-photo-', suffix='.img')
                paths.append(path)
                with os.fdopen(handle, 'wb') as out:
                    out.write(image)
            self.presence.begin_own()
            replaced = self.driver.send(app, info['doc'], text, paths)
        finally:
            self.presence.end_own()
            for path in paths:
                try:
                    os.remove(path)
                except OSError:
                    logging.warning('could not remove the photo file')
            action['images'] = []
        if replaced:
            # The phone's message always wins over unsent text in the box (the user's rule 10/31);
            # only its length is logged, never the text.
            logging.info('send %s replaced %d unsent characters in the box', app, len(replaced))
        self.update(action, message='已送出，確認中')
        verified = self.verify(transcript, mark, text if text.strip() else '[圖片]')
        message = {True: '已送出', 'queued': '已送出，排在等待中的權限詢問之後'}.get(
            verified, f'已送出，但 {self.verify_seconds} 秒內還沒在對話紀錄看到')
        if replaced:
            message += f'（覆蓋了電腦輸入框裡原本沒送出的 {len(replaced)} 個字）'
        self.update(action, state='done', verified=bool(verified), message=message)

    def do_popup(self, action):
        """Presses the phone's pick in a window that popped up on the desktop."""
        popup = self.watcher.popup(action['sessionId'])
        if popup is None:
            raise ActionError('popup-gone', '')
        button = action['button']
        self.update(action, title=popup['title'] or popup['process'])
        self.presence.begin_own()  # a window without UI Automation buttons is clicked
        gone = self.driver.press_popup(popup, button)
        self.watcher.check_popups()
        if self.presence.snapshot().get('locked'):
            # A secure-desktop prompt (UAC) reads as locked; nothing on it can be pressed from here.
            message = f'已按「{button}」，接著跳出系統管理員確認（UAC），手機無法代按，請到電腦上按'
        elif gone:
            message = f'已在電腦上按「{button}」，視窗已關閉'
        else:
            message = f'已按「{button}」，但視窗還在（可能要管理員權限，或還有下一步）'
        self.update(action, state='done', verified=bool(gone), message=message)

    def verify(self, transcript, mark, text):
        """True when the transcript has the message, 'queued' when Claude accepted it into its
        queue (a question is pending; found live), else False after verify_seconds."""
        if transcript is None:
            return False
        want = normalized(text)[:40]
        deadline = self.clock() + self.verify_seconds
        while True:
            transcript.refresh()
            with transcript.lock:
                fresh = [e for e in transcript.events if e['seq'] > mark and e['kind'] == 'user']
                queued = list(getattr(transcript.parser, 'queued', []))
            # Codex records a photo and its caption as one message: "[圖片]\n<caption>".
            if any(normalized(e['text']).startswith(want) or ('[圖片]' in e['text'] and want in normalized(e['text']))
                   for e in fresh):
                return True
            if any(normalized(q).startswith(want) for q in queued):
                return 'queued'
            if self.clock() >= deadline:
                return False
            time.sleep(0.5)

    def do_permission(self, action):
        app, info = action['app'], action['info']
        current = self.watcher.prompt_for(app, action['sessionId'])
        if not current or current['promptId'] != action['promptId']:
            raise ActionError('prompt-changed', '')
        needs_front = app == 'claude' and action['decision'] == 'allow_once'
        if needs_front:
            self.recheck(action)
            self.presence.begin_own()
        how = self.driver.answer(app, info['doc'], action['decision'], current['text'])
        logging.info('permission %s %s answered by %s', action['decision'], app, how)
        self.presence.end_own()
        # Only a question that goes away counts as answered (a button once reported success live
        # without doing anything).
        deadline = self.clock() + 8
        while True:
            self.watcher.look(app)
            if not self.watcher.prompt_for(app, action['sessionId']):
                break
            if self.clock() >= deadline:
                raise ActionError('still-asking', '')
            time.sleep(0.5)
        self.update(action, state='done', message='已允許一次' if action['decision'] == 'allow_once' else '已拒絕')

    def do_answer(self, action):
        """Picks the options on the PC; done only once the transcript has the question's result."""
        app, info = action['app'], action['info']
        transcript, question = self.pending_question(app, action['sessionId'])
        if not question or question['questionId'] != action['questionId']:
            raise ActionError('question-changed', '')
        self.open_conversation(action)
        self.recheck(action)
        self.presence.begin_own()
        self.driver.answer_question(app, info['doc'], question, action['answers'])
        self.presence.end_own()
        self.update(action, message='已選好，確認中')
        deadline = self.clock() + self.verify_seconds
        while True:
            transcript.refresh()
            with transcript.lock:
                still = getattr(transcript.parser, 'question', None)
            if not still or still['questionId'] != action['questionId']:
                self.update(action, state='done', verified=True, message='已回答')
                return
            if self.clock() >= deadline:
                raise ActionError('still-asking', '')
            time.sleep(0.5)

    def do_model(self, action):
        """Picks the model in the conversation's own menu. The worker checks the model button
        afterwards; the conversation file then has to show the new model too."""
        app, info, label = action['app'], action['info'], action['model']
        self.open_conversation(action)
        self.recheck(action, action['needsFront'])
        self.presence.begin_own()
        how = self.driver.set_model(app, info['doc'], label)
        self.presence.end_own()
        logging.info('model %s %s by %s', app, label, how)
        if how == 'already':
            self.update(action, state='done', verified=True, message=f'本來就是 {label}')
            return
        if app == 'codex':
            # Codex writes the model to its rollout only with the next reply; the worker has
            # already seen the model button name it.
            self.update(action, state='done', verified=True, message=f'已切換為 {label}（下一則回覆起使用）')
            return
        self.update(action, message='已切換，確認中')
        source = self.hub.sources[app]
        deadline = self.clock() + self.verify_seconds
        while True:
            folder = source.sessions_dir()
            data = source.metadata(os.path.join(folder, f"{action['sessionId']}.json")) if folder else None
            if model_label((data or {}).get('model')) == label:
                self.update(action, state='done', verified=True, message=f'已切換為 {label}')
                return
            if self.clock() >= deadline:
                self.update(action, state='done', verified=False,
                            message=f'畫面上已是 {label}，但電腦端紀錄 {self.verify_seconds} 秒內還沒更新')
                return
            time.sleep(0.5)

    def do_effort(self, action):
        """Claude's effort, in the model menu's effort submenu; the worker checks the model button."""
        app, info, label = action['app'], action['info'], action['effort']
        self.open_conversation(action)
        self.recheck(action, action['needsFront'])
        self.presence.begin_own()
        how = self.driver.set_effort(app, info['doc'], label)
        self.presence.end_own()
        logging.info('effort %s %s by %s', app, label, how)
        self.update(action, state='done', verified=True,
                    message=f'本來就是 {label}' if how == 'already' else f'推理強度已切換為 {label}')

    def do_mode(self, action):
        """The permission mode. Claude's mode button names the mode, so the worker checks it;
        Codex's does not, so its pick shows only from the next turn on."""
        app, info, label = action['app'], action['info'], action['mode']
        self.open_conversation(action)
        self.recheck(action, action['needsFront'])
        self.presence.begin_own()
        how = self.driver.set_mode(app, info['doc'], label)
        self.presence.end_own()
        logging.info('mode %s %s by %s', app, label, how)
        if app == 'codex':
            self.hub.chosen_modes[(app, action['sessionId'])] = (label, iso(time.time()))
        if how == 'already':
            self.update(action, state='done', verified=True, message=f'本來就是 {label}')
        elif app == 'codex':
            self.update(action, state='done', verified=False, message=f'已選「{label}」（下一則回覆起生效）')
        else:
            self.update(action, state='done', verified=True, message=f'權限模式已切換為 {label}')

    def do_update(self, action):
        """Claude's "重新啟動以更新" pressed for the phone (asked 10/30: only when the user presses
        it there, since it ends every Claude Code session in the app); done once the new one runs."""
        app = action['app']
        wanted = self.watcher.update_target(app)
        if not wanted:
            raise ActionError('no-update', 'no update waiting')
        button, target = wanted['button'], wanted['version']
        self.recheck(action, False)
        self.update(action, message=f'正在按「{button}」…')
        self.watcher.quiet_popups_until = time.monotonic() + 60  # its question goes to the phone looking
        self.driver.press_update(app, button)
        logging.info('update %s: pressed %s', app, button)
        self.update(action, message='Claude 桌面版重新啟動中…')
        start = self.clock()
        deadline = start + 240
        while True:
            running = (self.driver.versions().get(app) or {}).get('running')
            if running and version_key(running)[:3] >= version_key(target)[:3]:
                self.update(action, state='done', verified=True, message=f'Claude 桌面版已更新為 {running}')
                return
            # With Claude Code still working, Claude asks first, in a window of its own (10/30);
            # the phone answers it like any other pop-up.
            if self.clock() - start < 20 and any(p['process'].lower() == 'claude'
                                                 for p in self.watcher.check_popups(notify=False)):
                logging.info('update %s: it asks whether to interrupt the running work', app)
                self.update(action, state='done', verified=False, message=QUIT_GUARD_TEXT)
                return
            if self.clock() >= deadline:
                self.update(action, state='done', verified=False,
                            message=f'已按下更新，但 4 分鐘內還沒看到新版在跑（現在是 {running or "沒有在跑"}）')
                return
            time.sleep(2)

    def do_fast(self, action):
        """Codex's fast mode switch; config.toml then has to say the same."""
        app, info, on = action['app'], action['info'], action['fast']
        self.open_conversation(action)
        self.recheck(action, action['needsFront'])
        self.presence.begin_own()
        how = self.driver.set_fast(app, info['doc'], on)
        self.presence.end_own()
        logging.info('fast %s %s by %s', app, on, how)
        name = '快速模式' if on else '標準模式'
        if how == 'already':
            self.update(action, state='done', verified=True, message=f'本來就是{name}')
            return
        deadline = self.clock() + self.verify_seconds
        while self.hub.sources[app].fast() != on:
            if self.clock() >= deadline:
                self.update(action, state='done', verified=False,
                            message=f'畫面上已切到{name}，但設定檔 {self.verify_seconds} 秒內還沒更新')
                return
            time.sleep(0.5)
        self.update(action, state='done', verified=True, message=f'已切換為{name}')

    def do_stop(self, action):
        """Presses the stop button of the running turn; done once the turn is no longer running."""
        app, info = action['app'], action['info']
        transcript = self.hub.transcript(app, action['sessionId'])
        self.open_conversation(action)
        self.driver.stop(app, info['doc'])
        deadline = self.clock() + self.verify_seconds
        while True:
            self.watcher.look(app)
            if transcript is not None:
                transcript.refresh()
            running = self.watcher.current(app).get('running')
            if not running or (transcript is not None and transcript.parser.status == 'idle'):
                self.update(action, state='done', verified=True, message='已停止')
                return
            if self.clock() >= deadline:
                self.update(action, state='done', verified=False, message='已按停止，但畫面上仍在執行')
                return
            time.sleep(0.5)

    def do_new(self, action):
        app, text, project = action['app'], action['text'], action.get('project')
        source = self.hub.sources[app]
        before = {row['id'] for row in source.list_sessions(50)}
        strings = self.strings.get(app) or {}
        button = strings.get('new', '')
        if project and app == 'codex':
            button = strings.get('new_in_project', '{project}').format(project=project)
        self.recheck(action)
        self.presence.begin_own()
        if self.driver.docs(app) is None:
            # Closed to the tray (Codex, live 10/27): no window has the new-conversation button.
            # A conversation link brings the window back, the way opening a conversation does.
            rows = source.list_sessions(1)
            info = self.hub.info(app, rows[0]['id']) if rows else None
            if info is None:
                raise ActionError('app-not-running', '')
            self.driver.open(app, info)
            self.wait_doc(app, info)
            time.sleep(self.settle_seconds)
        self.driver.new_send(app, button, text)
        self.presence.end_own()
        self.update(action, message='已送出，等待新對話出現')
        deadline = self.clock() + self.verify_seconds
        while True:
            fresh = [row for row in source.list_sessions(50) if row['id'] not in before]
            if fresh:
                row = fresh[0]
                self.update(action, state='done', verified=True, sessionId=row['id'], title=row['title'],
                            message='已開新對話')
                return
            if self.clock() >= deadline:
                self.update(action, state='done', verified=False,
                            message=f'已送出，但 {self.verify_seconds} 秒內清單還沒出現新對話')
                return
            time.sleep(0.5)


class ElevateRelay:
    """Passes administrator requests between the elevated companion and the phone (phase 3).

    The helper can list requests and forward the phone's decision, but it holds no approval key:
    the companion checks the phone's HMAC itself. New requests and finished ones go to ntfy
    (PC name only, never the command). `request(message)` talks to the companion."""

    def __init__(self, request, notify=None, pc_name=''):
        self.request, self.notify, self.pc_name = request, notify, pc_name
        self.lock = threading.Lock()
        self.pending, self.recent, self.available = [], [], False
        self.seen = set()
        self.started = False

    def poll(self):
        try:
            answer = self.request({'op': 'list'})
        except (OSError, ValueError):
            answer = None
        with self.lock:
            self.available = bool(answer and answer.get('ok'))
            if not self.available:
                return
            self.pending, self.recent = answer.get('pending') or [], answer.get('recent') or []
            fresh = [r for r in self.pending if r['id'] not in self.seen]
            first, self.started = not self.started, True
            self.seen.update(r['id'] for r in self.pending)
        if first:
            return  # Nothing to announce for what was already there when the helper started.
        # Only what needs the person: a request to approve. Results are not sent (the user asked on
        # 10/27 to be told only about things that need them); the phone shows them.
        for _ in fresh:
            self.send('🔐 需要管理員權限', f'{self.pc_name}：有指令在等你核准，打開桌面遙控查看', 5, ['closed_lock_with_key'],
                      open_link(self.pc_name, elevate=True))

    def send(self, title, message, priority, tags, click=None):
        if self.notify:
            try:
                self.notify(title, message, priority, tags, click)
            except OSError:
                logging.exception('elevate notification failed')

    def snapshot(self):
        self.poll()
        with self.lock:
            return {'ok': True, 'available': self.available, 'pending': list(self.pending), 'recent': list(self.recent)}

    def decide(self, request_id, decision, signature):
        """(status, body) for the phone's decision; the companion verifies the signature."""
        if decision not in ('allow', 'deny'):
            return 400, error('bad-request', '只能允許或拒絕')
        if decision == 'allow' and not re.fullmatch(r'[0-9a-f]{64}', str(signature or '')):
            return 400, error('bad-request', '缺少手機的核准簽章')
        try:
            answer = self.request({'op': 'decide', 'id': request_id, 'decision': decision, 'hmac': signature or ''})
        except (OSError, ValueError):
            return 503, error('elevate-unavailable', '提權夥伴沒有在執行')
        if answer.get('ok'):
            self.poll()
            return 200, {'ok': True, 'state': answer.get('state')}
        code = {'bad-signature': 403, 'not-found': 404, 'expired': 410}.get(answer.get('error'), 400)
        text = {'bad-signature': '核准簽章不對（手機上的管理員核准金鑰可能不是這台電腦的）',
                'not-found': '這個請求已經處理過或不存在', 'expired': '這個請求已經逾時'}.get(answer.get('error'), '請求被拒絕')
        logging.warning('elevate decision %s refused: %s', decision, answer.get('error'))
        return code, error(answer.get('error') or 'refused', text)

    def run_forever(self, interval=3):
        while True:
            self.poll()
            time.sleep(interval)


FAILURE_TEXT = {
    'locked': '電腦已鎖定',
    'busy-user': '電腦有人在用，已取消',
    'app-not-running': '桌面版沒有開著',
    'title-mismatch': '打開的不是這個對話，已中止（沒有送出任何字）',
    'duplicate-title': '有同名的對話，無法確定是哪一個；請在電腦上改名',
    'no-prompt-box': '找不到輸入框（可能正在詢問權限）',
    'focus-failed': '無法把視窗切到前面，已中止（沒有送出任何字）',
    'clipboard-unsafe': '剪貼簿裡的內容無法安全保存，已中止',
    'box-not-empty': '電腦輸入框裡沒送出的字清不掉，已中止（沒有送出）',
    'paste-failed': '貼上後輸入框沒有出現這段文字，已清掉並中止（沒有送出）',
    'prompt-changed': '權限詢問已經不一樣了',
    'menu-failed': '打不開「允許一次」選單',
    'still-asking': '按了之後電腦上仍在詢問，可能沒有按到',
    'question-changed': '這個選項題已經回答過或換了一題',
    'toggle-failed': '選項按了沒有反應',
    'model-failed': '選單沒有照預期切換，電腦上的設定沒有變',
    'not-running': '這個對話現在沒有在執行，不用停止',
    'not-supported': '這台電腦的小幫手還不支援這個動作',
    'not-found': '畫面上找不到需要的按鈕',
    'not-invokable': '按鈕按不下去',
    'timeout': '畫面操作逾時',
    'worker-error': '畫面操作程式出錯',
    'popup-gone': '這個視窗已經關掉了',
    'press-failed': '按不下去（這個視窗可能要以管理員身分才能按）',
    'uac': '電腦跳出系統管理員確認（UAC）擋著，要到電腦前按',
}

QUIT_GUARD_TEXT = ('Claude 還有工作在跑，電腦跳出「Claude 仍在處理中」確認視窗（開著時桌面版收不到訊息）：'
                   '在這頁上方選「取消」就不更新、「等待 Claude」等工作做完再更新、「仍要更新」立刻更新（會中斷工作）')
UAC_TEXT = '電腦跳出系統管理員確認（UAC）擋著，手機無法代按；請到電腦前按（或用 Google 遠端桌面），按掉前訊息送不出去'

# What the worker found in front when it could not take the foreground ("in front: <process>").
FRONT_NAMES = {
    'same-app': '桌面版自己開著的選單或對話框',
    'none': '沒有視窗（可能是鎖定或切換使用者畫面）',
    'explorer': '檔案總管或工作列',
    'Taskmgr': '工作管理員',
    'LockApp': '鎖定畫面',
    'consent': '系統管理員權限確認（UAC）',
    'remoting_desktop': 'Google 遠端桌面',
}


def failure_text(code, message):
    """The phone's text for a failed action, naming the window in front when the worker said."""
    text = FAILURE_TEXT.get(code, message or code)
    front = re.search(r'in front: (\S+)$', message or '')
    if front:
        name = front.group(1)
        text += f'；擋在前面的是：{FRONT_NAMES.get(name, name)}'
    return text


# ---------------------------------------------------------------------------------------------
# HTTP.


MAX_BODY = 64 * 1024
PHOTO_BODY = 40 * 1024 * 1024      # a message with up to 10 photos (base64) from the phone


def capture_screen(timeout=20):
    """JPEG bytes of this PC's whole desktop from screen_capture.ps1 (its own DPI-aware
    process), passed through a pipe so the picture is never written to disk; None when the
    screen cannot be read (locked) or the capture failed."""
    import base64
    import binascii
    import subprocess
    try:
        done = subprocess.run(
            ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
             str(Path(__file__).with_name('screen_capture.ps1'))],
            capture_output=True, timeout=timeout, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    try:
        data = base64.b64decode(done.stdout.strip(), validate=True)
    except (binascii.Error, ValueError):
        return None
    return data if data.startswith(b'\xff\xd8\xff') else None


def handler_for(hub, gate, networks, runner=None):
    screen_lock = threading.Lock()  # one capture at a time

    class Handler(BaseHTTPRequestHandler):
        server_version = 'DeskRemoteHelper'
        sys_version = ''
        protocol_version = 'HTTP/1.0'

        def setup(self):
            super().setup()
            self.connection.settimeout(MAX_WAIT + 10)

        def log_message(self, *args):
            pass

        def send_json(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False, allow_nan=False).encode('utf-8')
            try:
                self.send_response(code)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass  # The phone left (for example a long-poll cancelled when the app went to the background).

        def allowed(self):
            try:
                peer = ipaddress.ip_address(self.client_address[0])
            except ValueError:
                return False
            return any(peer in network for network in networks)

        def do_GET(self):
            self.dispatch(self.route)

        def do_POST(self):
            self.dispatch(self.route_post)

        def dispatch(self, route):
            if not self.allowed():
                return self.send_json(403, error('forbidden', '不在允許的網路'))
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query, keep_blank_values=True)  # "question=" means none known
            parts = [urllib.parse.unquote(p) for p in url.path.strip('/').split('/')]
            if parts == ['health'] and route == self.route:
                return self.send_json(200, {'ok': True})
            if not parts or parts[0] != 'v1':
                return self.send_json(404, error('not-found', '沒有這個路徑'))
            denied = gate.check(self.headers.get('Authorization'))
            if denied:
                return self.send_json(*denied)
            try:
                return route(parts[1:], query)
            except Exception:
                logging.exception('request failed')
                return self.send_json(500, error('internal', '電腦端發生錯誤'))

        def send_jpeg(self, data):
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

        def read_body(self, limit=MAX_BODY):
            """The JSON object sent with a POST, or None after answering 400/413."""
            try:
                length = int(self.headers.get('Content-Length') or 0)
            except ValueError:
                length = -1
            if length < 0 or length > limit:
                # Read (up to 1 MB of) what was sent first, so the sender gets the answer instead of
                # a reset connection.
                left = min(max(length, 0), 1024 * 1024)
                while left > 0:
                    chunk = self.rfile.read(min(65536, left))
                    if not chunk:
                        break
                    left -= len(chunk)
                self.send_json(413, error('too-large', '內容太大'))
                return None
            try:
                body = json.loads(self.rfile.read(length).decode('utf-8')) if length else {}
            except (ValueError, UnicodeDecodeError):
                body = None
            if not isinstance(body, dict):
                self.send_json(400, error('bad-request', '內容格式不對'))
                return None
            return body

        def route_post(self, parts, query):
            if parts and parts[0] == 'elevate':
                if hub.elevate is None or len(parts) != 2 or not re.fullmatch(r'[0-9a-f]{16}', parts[1]):
                    return self.send_json(404, error('not-found', '沒有這個請求' if hub.elevate else '這台電腦沒有安裝提權夥伴'))
                body = self.read_body()
                if body is None:
                    return None
                return self.send_json(*hub.elevate.decide(parts[1], body.get('decision'), body.get('hmac')))
            if runner is None:
                return self.send_json(405, error('read-only', '這一版只能讀取'))
            body = self.read_body(PHOTO_BODY if parts[-1:] == ['messages'] else MAX_BODY)
            if body is None:
                return None
            if parts[1:] == ['launch'] and parts[0] in APPS:
                return self.send_json(*runner.submit('launch', parts[0], None, body))
            if parts[1:] == ['update'] and parts[0] in APPS:
                return self.send_json(*runner.submit('update', parts[0], None, body))
            if len(parts) == 3 and parts[0] == 'popups' and parts[2] == 'press' and re.fullmatch(r'[0-9a-f]{12}', parts[1]):
                return self.send_json(*runner.submit('popup', None, parts[1], body))
            if len(parts) >= 2 and parts[0] in APPS and parts[1] == 'sessions':
                app = parts[0]
                if len(parts) == 2:
                    return self.send_json(*runner.submit('new', app, None, body))
                kinds = {'messages': 'send', 'permission': 'permission', 'open': 'open', 'answer': 'answer',
                         'model': 'model', 'effort': 'effort', 'mode': 'mode', 'stop': 'stop', 'fast': 'fast'}
                if len(parts) == 4 and parts[3] in kinds and hub.sources[app].id_pattern.match(parts[2]):
                    return self.send_json(*runner.submit(kinds[parts[3]], app, parts[2], body))
            return self.send_json(404, error('not-found', '沒有這個路徑'))

        def route(self, parts, query):
            def number(name, default):
                try:
                    return int(query.get(name, [default])[0])
                except ValueError:
                    return default
            if parts == ['state']:
                return self.send_json(200, hub.state())
            if parts == ['screen']:
                if hub.screen is None:
                    return self.send_json(404, error('not-found', '這台電腦的小幫手不提供畫面'))
                if hub.presence.snapshot().get('locked'):
                    return self.send_json(423, error('locked', '電腦已鎖定，看不到畫面'))
                with screen_lock:
                    data = hub.screen()
                if not data:
                    return self.send_json(503, error('screen-failed', '讀不到電腦畫面（可能已鎖定或沒有登入）'))
                return self.send_jpeg(data)
            if parts == ['elevate']:
                if hub.elevate is None:
                    return self.send_json(404, error('not-found', '這台電腦沒有安裝提權夥伴'))
                return self.send_json(200, hub.elevate.snapshot())
            if len(parts) == 2 and parts[0] == 'actions' and runner is not None:
                status = runner.status(parts[1])
                if status is None:
                    return self.send_json(404, error('not-found', '找不到這個動作（可能已過期）'))
                return self.send_json(200, status)
            if len(parts) >= 2 and parts[0] in APPS and parts[1] == 'sessions':
                app = parts[0]
                if len(parts) == 2:
                    return self.send_json(200, hub.sessions(app, max(1, min(number('limit', 50), 100))))
                if len(parts) == 4 and parts[3] == 'events':
                    page = hub.events(app, parts[2], number('after', 0), query.get('epoch', [''])[0],
                                      number('wait', 0), query.get('prompt', [''])[0],
                                      known_question=query.get('question', [None])[0])
                    if page is None:
                        return self.send_json(404, error('not-found', '找不到這個對話的逐字稿'))
                    return self.send_json(200, page)
                if len(parts) == 5 and parts[3] == 'items':
                    text = hub.item(app, parts[2], parts[4])
                    if text is None:
                        return self.send_json(404, error('not-found', '這段內容已不在電腦端快取'))
                    return self.send_json(200, {'ok': True, 'text': text})
            return self.send_json(404, error('not-found', '沒有這個路徑'))

        def denied(self):
            self.send_json(405, error('method-not-allowed', '不支援這個方法'))

        do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = denied

    return Handler


def load_config(path):
    cfg = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    networks = [ipaddress.ip_network(item) for item in cfg['allowed_networks']]
    bind = ipaddress.ip_address(cfg['bind_ip'])
    if bind.is_unspecified or not any(bind in network for network in networks):
        raise RuntimeError('bind_ip must be a specific address inside allowed_networks (no 0.0.0.0)')
    if len(cfg.get('token') or '') < 32:
        raise RuntimeError('token must be at least 32 characters')
    return cfg, networks


def default_config_path():
    return Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'DeskRemote' / 'config.json'


def real_sources(cfg):
    home = Path.home()
    local = Path(os.environ.get('LOCALAPPDATA', home / 'AppData' / 'Local'))
    claude = cfg.get('claude') or {}
    codex = cfg.get('codex') or {}
    return {'claude': ClaudeSource(claude.get('data_root') or local / 'Claude-Data',
                                   claude.get('projects_dir') or home / '.claude' / 'projects',
                                   claude.get('context_windows')),
            'codex': CodexSource(codex.get('home') or home / '.codex')}


# ---------------------------------------------------------------------------------------------
# Fake mode for the simulator UI tests: the real HTTP, auth and file parsers over a copy of
# hand-written fixtures. A scripted conversation gains lines while the app watches it.


class FakeSetup:
    def __init__(self, fixture_dir):
        self.fixtures = Path(fixture_dir).resolve()
        self.root = Path(tempfile.mkdtemp(prefix='desk-remote-fake-'))
        shutil.copytree(self.fixtures / 'pc', self.root / 'pc')
        for path in (self.root / 'pc').rglob('*'):
            if path.is_file():
                os.utime(path)  # Fresh copies; age_claude and the database set the old ones.
        self.cfg = json.loads((self.fixtures / 'fake-config.json').read_text(encoding='utf-8'))
        self.now_ms = int(time.time() * 1000)
        self.fresh = []
        self.age_claude()
        threading.Thread(target=self.keep_fresh, daemon=True).start()
        self.build_codex_database()
        self.live = json.loads((self.fixtures / 'live.json').read_text(encoding='utf-8'))
        self.prompts_data = json.loads((self.fixtures / 'prompts.json').read_text(encoding='utf-8'))
        self.started = {}
        self.lock = threading.Lock()

    def age_claude(self):
        """Fixture conversations say how many minutes ago they were active; make that real."""
        for path in (self.root / 'pc').glob('claude-data/claude_*/claude-code-sessions/*/*/local_*.json'):
            try:
                data = json.loads(path.read_text(encoding='utf-8'))
            except ValueError:
                continue  # The deliberately broken fixture stays broken.
            minutes = data.pop('_minutesAgo', 0)
            data['lastActivityAt'] = self.now_ms - int(minutes * 60000)
            path.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
            for transcript in (self.root / 'pc' / 'claude-projects').glob(f"*/{data.get('cliSessionId')}.jsonl"):
                if minutes > 2:
                    old = time.time() - minutes * 60
                    os.utime(transcript, (old, old))
                else:
                    self.fresh.append(transcript)

    def keep_fresh(self):
        """Conversations meant to look active keep being written, as a running one would be."""
        while True:
            time.sleep(20)
            for path in self.fresh:
                try:
                    os.utime(path)
                except OSError:
                    return  # The fixture copy was removed (a test finished).

    def build_codex_database(self):
        home = self.root / 'pc' / 'codex'
        (home / 'config.toml').write_text('service_tier = "default"\n', encoding='utf-8')  # fast mode off
        threads = json.loads((home / 'threads.json').read_text(encoding='utf-8'))
        connection = sqlite3.connect(home / 'state_5.sqlite')
        connection.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, name TEXT, '
                           'recency_at_ms INTEGER, updated_at_ms INTEGER, updated_at INTEGER, archived INTEGER, '
                           'cwd TEXT, approval_mode TEXT, source TEXT, model TEXT, reasoning_effort TEXT)')
        for item in threads:
            ms = self.now_ms - int(item.get('minutesAgo', 0) * 60000)
            rollout = home / 'sessions' / item['rollout'] if item.get('rollout') else None
            if rollout is not None and item.get('minutesAgo', 0) > 2:
                old = ms / 1000
                os.utime(rollout, (old, old))
            connection.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                               (item['id'], str(rollout) if rollout else None, item.get('title'), item.get('name'),
                                ms, ms, ms // 1000, item.get('archived', 0), item.get('cwd'),
                                item.get('approval'), item.get('source', 'vscode'), item.get('model'), item.get('effort')))
        connection.commit()
        connection.close()

    def sources(self):
        pc = self.root / 'pc'
        return {'claude': ClaudeSource(pc / 'claude-data', pc / 'claude-projects'),
                'codex': CodexSource(pc / 'codex')}

    def elevate_relay(self):
        """The companion's Python twin with a test key and one waiting request (fixture data)."""
        key = bytes.fromhex(self.cfg['elevate_key'])
        token = 'fake-submit-token'
        # Three hours, not ten minutes: the simulator tests reach these requests well after startup.
        self.elevator = elevate.ElevatorLogic(key, token, ttl=3 * 3600)
        for item in json.loads((self.fixtures / 'elevate.json').read_text(encoding='utf-8')):
            self.elevator.handle(dict(item, op='request', token=token))
        return ElevateRelay(lambda message: self.elevator.handle(dict(message, token=token)))

    def create_session(self, app, title):
        """A new conversation in each app's own layout; returns (id, transcript path)."""
        import uuid
        pc = self.root / 'pc'
        now_ms = int(time.time() * 1000)
        if app == 'claude':
            session_id, cli = f'local_{uuid.uuid4()}', str(uuid.uuid4())
            folder = next(pc.glob('claude-data/claude_*/claude-code-sessions/*/*'))
            (folder / f'{session_id}.json').write_text(json.dumps({
                'sessionId': session_id, 'cliSessionId': cli, 'cwd': 'C:\\work\\demo-app', 'title': title,
                'lastActivityAt': now_ms, 'isArchived': False, 'permissionMode': 'auto'}, ensure_ascii=False),
                encoding='utf-8')
            path = next(pc.glob('claude-projects/*')) / f'{cli}.jsonl'
        else:
            session_id = str(uuid.uuid4())
            path = pc / 'codex' / 'sessions' / '2026' / '10' / '26' / f'rollout-2026-10-26T12-00-00-{session_id}.jsonl'
            connection = sqlite3.connect(pc / 'codex' / 'state_5.sqlite')
            connection.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                               (session_id, str(path), title, title, now_ms, now_ms, now_ms // 1000, 0,
                                'C:\\work\\demo-app', None, 'vscode', 'gpt-6.1-sol', 'high'))
            connection.commit()
            connection.close()
        path.write_text('', encoding='utf-8')
        return session_id, path

    def on_events(self, app, session_id):
        """The first time the app opens a scripted conversation, start appending its lines."""
        key = f'{app}/{session_id}'
        with self.lock:
            if key not in self.live or key in self.started:
                return
            self.started[key] = time.monotonic()
        threading.Thread(target=self.append_live, args=(app, session_id, self.live[key]), daemon=True).start()

    def append_live(self, app, session_id, script):
        source = self.sources()[app]
        path = source.transcript_path(session_id)
        for step in script:
            time.sleep(step.get('afterSeconds', 2))
            try:
                with path.open('a', encoding='utf-8') as handle:
                    for line in step['lines']:
                        handle.write(json.dumps(line, ensure_ascii=False) + '\n')
            except OSError:
                return  # The fixture copy was removed (a test finished).

class FakeDriver:
    """Stands in for the desktop windows in fake mode: one open conversation per app, a
    permission question from prompts.json while its conversation is open, and transcripts that
    gain the sent message and a scripted reply, written in each app's own file format."""

    def __init__(self, setup, hub, reply_after=2.0):
        self.setup, self.hub, self.reply_after = setup, hub, reply_after
        self.lock = threading.Lock()
        self.answered = set()
        self.calls = []
        self.open_doc = {}
        self.codex_models = {}  # page title -> model picked on the phone
        self.running = set()    # page titles whose turn is running (a stop button shows)
        self.page_titles = {}   # id -> the title its page shows, where tests make it differ
        self.fake_popups = []   # windows that popped up on the desktop (--fake-popup)
        for key in setup.prompts_data:
            app, session_id = key.split('/', 1)
            info = hub.info(app, session_id)
            if info and app not in self.open_doc:
                self.open_doc[app] = info['doc']
        for app in APPS:
            if app not in self.open_doc:
                rows = hub.sources[app].list_sessions(1)
                if rows:
                    self.open_doc[app] = hub.info(app, rows[0]['id'])['doc']

    def session_for_doc(self, app, doc):
        for row in self.hub.sources[app].list_sessions(100):
            info = self.hub.info(app, row['id'])
            if info and doc in [info['doc']] + list(info.get('aliases') or []) + [self.page_titles.get(row['id'])]:
                return row['id']
        return None

    def pending_prompt(self, app):
        session_id = self.session_for_doc(app, self.open_doc.get(app))
        key = f'{app}/{session_id}'
        if session_id and key in self.setup.prompts_data and key not in self.answered:
            return key, self.setup.prompts_data[key]
        return None, None

    def inspect(self, app):
        _, prompt = self.pending_prompt(app)
        answer = {'ok': True, 'window': True, 'docs': [self.open_doc.get(app)], 'edit': prompt is None,
                  'prompt': {'text': prompt['text'], 'buttons': ['拒絕', '允許一次']} if prompt else None}
        strings = self.hub.strings.get(app) or {}
        if app == 'claude' and strings.get('model_prefix'):
            data = self.session_file(app, self.open_doc.get(app))[1] or {}
            answer['model'] = (f"{strings['model_strip']}{model_label(data.get('model')) or 'Opus 5.5'} "
                               f"{EFFORT_LABELS.get(data.get('effort'), '高')}")
            answer['usage'] = f"{strings['usage_prefix']}每週 · 所有模型：46% 週日上午11:00 重設"
        elif app == 'codex' and strings.get('model_prefix'):
            answer['model'] = f"{self.codex_models.get(self.open_doc.get(app), 'GPT-6.1 Sol')} 高"
        if app == 'claude':
            data = self.session_file(app, self.open_doc.get(app))[1] or {}
            answer['mode'] = ClaudeSource.PERMISSION_LABELS.get(data.get('permissionMode'), data.get('permissionMode'))
            answer['running'] = self.open_doc.get(app) in self.running
        answer['update'] = (getattr(self, 'fake_update', None) or {}).get(app)
        return answer

    def set_effort(self, app, doc, label):
        self.calls.append(('set_effort', app, label))
        if app != 'claude':
            raise ActionError('not-supported', '')
        path, data = self.session_file(app, doc)
        ids = {v: k for k, v in EFFORT_LABELS.items()}
        if EFFORT_LABELS.get(data.get('effort')) == label:
            return 'already'
        data['effort'] = ids.get(label, label.lower())
        with self.lock:
            path.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        return 'fake'

    def set_fast(self, app, doc, on):
        """Writes service_tier to the fake Codex's config.toml, as the desktop app does."""
        self.calls.append(('set_fast', app, on))
        if self.open_doc.get(app) != doc:
            raise ActionError('title-mismatch', '')
        source = self.hub.sources[app]
        if source.fast() == on:
            return 'already'
        with self.lock:
            (source.home / 'config.toml').write_text(f'service_tier = "{"priority" if on else "default"}"\n', encoding='utf-8')
        return 'fake'

    def set_mode(self, app, doc, label):
        self.calls.append(('set_mode', app, label))
        if self.open_doc.get(app) != doc:
            raise ActionError('title-mismatch', '')
        if app == 'codex':
            return 'fake'
        path, data = self.session_file(app, doc)
        ids = {v: k for k, v in ClaudeSource.PERMISSION_LABELS.items()}
        if ClaudeSource.PERMISSION_LABELS.get(data.get('permissionMode')) == label:
            return 'already'
        data['permissionMode'] = ids[label]
        with self.lock:
            path.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        return 'fake'

    def stop(self, app, doc):
        self.calls.append(('stop', app))
        if doc not in self.running:
            raise ActionError('not-running', '')
        self.running.discard(doc)
        session_id = self.session_for_doc(app, doc)
        self.write(app, self.hub.sources[app].transcript_path(session_id), 'assistant', '（已停止）')
        return 'fake'

    def session_file(self, app, doc):
        """(path, data) of the Claude conversation file behind the page `doc`."""
        session_id = self.session_for_doc(app, doc)
        folder = self.hub.sources[app].sessions_dir() if app == 'claude' and session_id else None
        if not folder:
            return None, None
        path = Path(folder) / f'{session_id}.json'
        return path, json.loads(path.read_text(encoding='utf-8'))

    def set_model(self, app, doc, label):
        self.calls.append(('set_model', app, label))
        if self.open_doc.get(app) != doc:
            raise ActionError('title-mismatch', '')
        if app == 'codex':  # Codex keeps the choice on screen until the next reply
            if self.codex_models.get(doc, 'GPT-6.1 Sol') == label:
                return 'already'
            self.codex_models[doc] = label
            return 'fake'
        path, data = self.session_file(app, doc)
        if model_label(data.get('model')) == label:
            return 'already'
        data['model'] = 'claude-' + label.lower().replace(' ', '-').replace('.', '-')
        with self.lock:
            path.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        return 'fake'

    def windows(self):
        """The fake presence's window flags: an app started closed (--fake-closed) has none."""
        return self.hub.presence.snapshot().setdefault('windows', {})

    def docs(self, app):
        return None if self.windows().get(app) is False else [self.open_doc.get(app)]

    def launch(self, app, again=False):
        self.calls.append(('launch', app, again))
        self.windows()[app] = True

    def downloaded_update(self, app):
        """As WindowsDriver.downloaded_update; `fake_downloaded` is Claude's downloaded version."""
        return getattr(self, 'fake_downloaded', None) if app == 'claude' else None

    def extension_popups(self):
        self.calls.append(('extension',))
        return [dict(p) for p in self.fake_popups if p.get('title') == EXTENSION_TITLE]

    def versions(self):
        """As WindowsDriver.versions; `fake_versions` sets {app: (installed, running)}."""
        found = getattr(self, 'fake_versions', None) or {'claude': ('4.29.0.0', '4.29.0.0'),
                                                         'codex': ('26.1023.6123.0', '26.1023.6123.0')}
        return {app: {'installed': installed, 'running': running,
                      'old': bool(running) and version_key(running) < version_key(installed)}
                for app, (installed, running) in found.items()}

    def press_update(self, app, name, confirm=None):
        """Claude's button restarts it into the version it names; the button then goes. With
        `fake_update_guard` it first asks, as Claude does while Claude Code is working."""
        self.calls.append(('press_update', app, name, confirm))
        if getattr(self, 'fake_update_guard', False):
            self.fake_popups = self.fake_popups + [dict(FAKE_QUIT_GUARD, update=(app, name))]
            return 'invoke'
        return self.apply_update(app, name, confirm)

    def apply_update(self, app, name, confirm=None):
        updates = dict(getattr(self, 'fake_update', None) or {})
        updates.pop(app, None)
        self.fake_update = updates
        versions = dict(getattr(self, 'fake_versions', None) or {})
        if app in versions:
            version = pending_version(name)
            versions[app] = (version, version)
            self.fake_versions = versions
        return 'confirmed' if confirm else 'invoke'

    def restart_app(self, app):
        self.calls.append(('restart', app))
        if app != 'codex':
            raise ActionError('not-supported', '')
        versions = dict(getattr(self, 'fake_versions', None) or {})
        if app in versions and not getattr(self, 'restart_sticks', False):
            versions[app] = (versions[app][0], versions[app][0])
            self.fake_versions = versions

    def usage_card(self, app):
        if app != 'claude':
            raise ActionError('not-found', '')
        return [{'label': '工作階段限制', 'percent': 5, 'reset': '2 小時 56 分後重設'},
                {'label': '每週 · 所有模型', 'percent': 46, 'reset': '週日上午11:00 重設'}]

    def open(self, app, info):
        self.calls.append(('open', app, info['id']))
        if self.windows().get(app) is False:
            self.windows()[app] = True  # the link shows the window again
        shown = self.page_titles.get(info['id'])
        if shown is None and app == 'codex':
            shown = self.hub.sources[app].import_titles().get(info['id'])  # as Codex does (live 10/28)
        self.open_doc[app] = shown or info['doc']

    def invoke_title(self, app, title):
        self.invoke(app, title)

    def invoke(self, app, name, doc=None):
        self.calls.append(('invoke', app, name))
        for row in self.hub.sources[app].list_sessions(100):
            if row['title'] == name:
                self.open_doc[app] = self.hub.sources[app].info(row['id'])['doc']
                return
        raise ActionError('not-found', '')

    def popups(self):
        return [dict(p) for p in self.fake_popups]

    def press_popup(self, popup, button):
        self.calls.append(('press_popup', popup['title'], button))
        pressed = next((p for p in self.fake_popups if p['hwnd'] == popup['hwnd']), {})
        self.fake_popups = [p for p in self.fake_popups if p['hwnd'] != popup['hwnd']]
        if pressed.get('update') and button != '取消':  # restarting now, or once Claude is done
            self.apply_update(*pressed['update'])
        return True

    def send(self, app, doc, text, images=None):
        self.calls.append(('send', app, doc) + tuple(('image', Path(path).stat().st_size) for path in images or []))
        if self.open_doc.get(app) != doc:
            raise ActionError('title-mismatch', '')
        replaced = getattr(self, 'fake_box_text', None)  # unsent text in the box is replaced, as the worker does
        self.fake_box_text = None
        session_id = self.session_for_doc(app, doc)
        path = self.hub.sources[app].transcript_path(session_id)
        if images:
            self.write(app, path, 'user-image', text, len(images))
        else:
            self.write(app, path, 'user', text)
        # "長任務" keeps the turn running for a while, so the phone can stop it.
        self.running.add(doc)
        delay = 60 if '長任務' in text else self.reply_after
        reply = f'（示範）收到：{text[:30] or "照片"}'
        if '表格' in text:  # a reply with a Markdown table, as the desktop apps write them
            reply += FAKE_TABLE
        self.later(app, path, reply, delay, doc)
        return replaced

    def new_send(self, app, button, text):
        self.calls.append(('new_send', app, button))
        session_id, path = self.setup.create_session(app, text[:24])
        self.open_doc[app] = self.hub.sources[app].info(session_id)['doc']
        self.write(app, path, 'user', text)
        self.later(app, path, f'（示範）新對話收到：{text[:30]}')

    def answer(self, app, doc, decision, expect):
        self.calls.append(('answer', app, decision))
        key, prompt = self.pending_prompt(app)
        if self.open_doc.get(app) != doc or not prompt or prompt['text'] != expect:
            raise ActionError('prompt-changed', '')
        self.answered.add(key)
        path = self.hub.sources[app].transcript_path(key.split('/', 1)[1])
        self.write(app, path, 'assistant', '已補上分號並存檔（示範）' if decision == 'allow_once' else '好的，先不修改。')
        return 'fake'

    def answer_question(self, app, doc, question, answers):
        self.calls.append(('answer_question', app, question['questionId']))
        if self.open_doc.get(app) != doc:
            raise ActionError('title-mismatch', '')
        session_id = self.session_for_doc(app, doc)
        path = self.hub.sources[app].transcript_path(session_id)
        chosen = ['、'.join(a.get('labels') or []) or (a.get('other') or '') for a in answers]
        pairs = ', '.join(f'"{q["question"]}"="{c}"' for q, c in zip(question['questions'], chosen))
        line = {'type': 'user', 'timestamp': datetime.now(UTC).strftime('%Y-%m-%dT%H:%M:%S.000Z'),
                'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': question['questionId'],
                                                         'content': f'User has answered your questions: {pairs}.'}]}}
        with self.lock:
            with Path(path).open('a', encoding='utf-8') as handle:
                handle.write(json.dumps(line, ensure_ascii=False) + '\n')
        self.later(app, path, f'（示範）收到選擇：{"／".join(chosen)}')

    def later(self, app, path, text, delay=None, doc=None):
        def reply():
            time.sleep(self.reply_after if delay is None else delay)
            if doc is not None:
                if doc not in self.running:
                    return  # stopped from the phone
                self.running.discard(doc)
            self.write(app, path, 'assistant', text)
        threading.Thread(target=reply, daemon=True).start()

    def write(self, app, path, role, text, photos=1):
        ts = datetime.now(UTC).strftime('%Y-%m-%dT%H:%M:%S.000Z')
        if role == 'user-image':  # pasted photos and an optional caption, as each app records them
            blocks = [{'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': ''}}] * photos
            if text.strip():
                blocks.append({'type': 'text', 'text': text})
            if app == 'claude':
                lines = [{'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': blocks}}]
            else:
                lines = [{'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'task_started'}},
                         {'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                             'type': 'UserMessage', 'content': [{'type': 'input_image'}] * photos + blocks[photos:]}}}]
        elif app == 'claude':
            if role == 'user':
                lines = [{'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': text}}]
            else:
                lines = [{'type': 'assistant', 'timestamp': ts, 'message': {
                    'role': 'assistant', 'content': [{'type': 'text', 'text': text}], 'stop_reason': 'end_turn'}}]
        elif role == 'user':
            lines = [{'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'task_started'}},
                     {'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                         'type': 'UserMessage', 'content': [{'type': 'text', 'text': text}]}}}]
        else:
            lines = [{'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                'type': 'AgentMessage', 'content': [{'type': 'Text', 'text': text}]}}},
                {'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'task_complete'}}]
        with self.lock:
            try:
                with Path(path).open('a', encoding='utf-8') as handle:
                    for line in lines:
                        handle.write(json.dumps(line, ensure_ascii=False) + '\n')
            except OSError:
                pass  # The fixture copy was removed (a test finished).


def serve(hub, gate, cfg, networks, runner=None):
    while True:
        try:
            server = ThreadingHTTPServer((cfg['bind_ip'], cfg['port']), handler_for(hub, gate, networks, runner))
            break
        except OSError as exc:
            if getattr(exc, 'winerror', None) != 10049:
                raise
            time.sleep(10)  # Wait for ZeroTier; never fall back to another interface.
    server.daemon_threads = True
    logging.info('listening on the configured address')
    if sys.stdout:
        print(f"Listening on {cfg['bind_ip']}:{cfg['port']}.", flush=True)
    server.serve_forever(poll_interval=1)


def build_driving(hub, driver, notify, pc_name, cfg, interval, verify_seconds, memory=None):
    """Watcher and action runner over `driver`, both on their own threads."""
    watcher = UiWatcher(hub, driver, notify, pc_name, interval=interval, memory=memory)
    hub.prompts = watcher.prompt_for
    hub.ui = watcher.current
    hub.popups = watcher.popup_list
    hub.versions = watcher.version_list
    hub.strings = load_strings()
    runner = ActionRunner(hub, driver, hub.presence, watcher, notify, pc_name, hub.strings,
                          idle_seconds=int(cfg.get('idle_seconds', 60)), verify_seconds=verify_seconds)
    watcher.busy = lambda: bool(runner.queue)
    hub.capabilities = ['read', 'send', 'permission', 'new', 'open', 'question', 'model', 'effort', 'mode', 'stop',
                        'photo', 'launch', 'photos', 'popups', 'fast', 'update']
    hub.alerts = dict(hub.alerts, **(cfg.get('alerts') or {}))
    threading.Thread(target=watcher.run_forever, daemon=True).start()
    threading.Thread(target=runner.run_forever, daemon=True).start()
    return runner


FAKE_TABLE = '''

## 各卡現況

| 卡 | 現在 | 達成率 | 還能多多少（推估） |
| --- | --- | --- | --- |
| RTX 5080 | 192 TH/s、187 W | 89% | **+15～25 TH/s**，只要改設定 |
| 中間 3060 | 38.4 TH/s | 82% | +6～8，要拉出來或加大夾扇 |

- 先改設定
- 再看溫度'''

# The window that blocked sending on 10/29, as fake mode shows it (a made-up program name).
FAKE_POPUP = {'hwnd': 4242, 'title': 'Windows 安全性', 'process': 'SecurityHealthHost',
              'text': '是否要允許公開和私人網路存取此應用程式?\nWindows 防火牆已封鎖所有公用和私人網路上 示範程式 的部分功能。\n示範程式',
              'buttons': ['允許', '取消']}
# Claude's question, drawn inside its page, when told to restart to update while Claude Code works
# (read live 10/30).
FAKE_QUIT_GUARD = {'hwnd': 4343, 'title': 'Claude 仍在處理中', 'process': 'claude', 'page': True,
                   'text': 'Claude 仍在處理中\nClaude 正在 1 個工作階段中執行作業。立即重新啟動將會中斷該作業。',
                   'buttons': ['取消', '等待 Claude', '仍要更新']}
# Claude for Chrome's card before reading a site (photo 10/31).
FAKE_EXTENSION_READ = {'hwnd': 4346, 'title': 'Claude for Chrome', 'process': 'chrome', 'page': True,
                       'text': 'New permissions required\nClaude wants to read page content on:\ns.example.com\n'
                               'Site-level permissions are disabled for this site.',
                       'buttons': ['Allow this action', 'Decline']}


def fake_fresh_usage(read, app, percent):
    """Fake mode's limits with `app` at `percent`, read just now: another PC on the same plan
    whose desktop app read its limits later."""
    def usage():
        out = dict(read())
        if out.get(app):
            windows = [dict(window, percent=int(percent)) for window in out[app]['windows']]
            out[app] = dict(out[app], windows=windows, sampledAt=iso(time.time()))
        return out
    return usage


def main(argv=None):
    parser = argparse.ArgumentParser(description='Desk remote helper')
    parser.add_argument('--config', type=Path, default=None)
    parser.add_argument('--fake', type=Path, default=None, help='serve hand-written fixtures (simulator tests)')
    parser.add_argument('--fake-port', type=int, default=None, help='fake mode: listen on this port instead')
    parser.add_argument('--fake-idle', type=int, default=None, help='fake mode: report this many idle seconds')
    parser.add_argument('--fake-closed', default='', help='fake mode: these apps (comma-separated) start with no window')
    parser.add_argument('--fake-usage', default='', help='fake mode: app=percent, limits read just now')
    parser.add_argument('--fake-popup', action='store_true', help='fake mode: a firewall question is waiting on the desktop')
    parser.add_argument('--fake-update', action='store_true', help="fake mode: Claude has a downloaded update waiting (and asks before interrupting work)")
    args = parser.parse_args(argv)
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    if args.fake:
        logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
        fake = FakeSetup(args.fake)
        cfg = dict(fake.cfg)
        presence = dict(cfg['presence'])
        if args.fake_idle is not None:
            presence['idleSeconds'] = args.fake_idle
        presence['windows'] = dict(presence.get('windows') or {})
        for app in filter(None, args.fake_closed.split(',')):
            presence['windows'][app] = False
        if args.fake_port:
            cfg['port'] = args.fake_port
        networks = [ipaddress.ip_network(item) for item in cfg['allowed_networks']]
        hub = Hub(cfg['pc_name'], fake.sources(), FixedPresence(presence), on_events=fake.on_events)
        hub.strings = load_strings()  # FakeDriver reads the model button's prefix before build_driving
        if args.fake_usage:
            hub.usage = fake_fresh_usage(hub.usage, *args.fake_usage.split('=', 1))
        driver = FakeDriver(fake, hub)
        if args.fake_popup:
            driver.fake_popups = [dict(FAKE_POPUP)]
        if args.fake_update:
            driver.fake_update = {'claude': '重新啟動以更新 v4.30.0'}
            driver.fake_update_guard = True  # Claude Code is "working": Claude asks first
            driver.fake_versions = {'claude': ('3.6556.2.0', '3.6556.2.0'), 'codex': ('26.1023.6123.0', '26.1023.6123.0')}
        runner = build_driving(hub, driver, None, cfg['pc_name'], cfg, interval=1, verify_seconds=10)
        hub.elevate = fake.elevate_relay()
        hub.screen = lambda: (fake.fixtures / 'screen.jpg').read_bytes()
        gate = AuthGate(cfg['token'], None, cfg['pc_name'])
        return serve(hub, gate, cfg, networks, runner)
    path = args.config or default_config_path()
    cfg, networks = load_config(path)
    log = RotatingFileHandler(path.parent / 'helper.log', maxBytes=1048576, backupCount=3, encoding='utf-8')
    log.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s', '%Y-%m-%d %H:%M:%S'))
    logger.addHandler(log)
    notifier = Notifier(cfg)
    notify = notifier.post if (cfg.get('notify') or {}).get('topic') else None
    pc_name = cfg.get('pc_name') or os.environ.get('COMPUTERNAME', 'PC')
    hub = Hub(pc_name, real_sources(cfg), WindowsPresence())
    if cfg.get('codex_live_limits', True):
        live = CodexLiveLimits()
        hub.sources['codex'].live = live
        threading.Thread(target=live.run_forever, daemon=True).start()
    if cfg.get('screen', True):
        hub.screen = capture_screen
    runner = None
    if cfg.get('drive_windows', True):
        runner = build_driving(hub, WindowsDriver(load_strings()), notify, pc_name, cfg, interval=4, verify_seconds=20,
                               memory=path.parent / 'usage_seen.json')
    submit = Path((cfg.get('elevate') or {}).get('submit_file') or elevate.submit_file())
    if submit.exists():  # written by install-elevated.ps1 (run once as administrator)
        port, token = elevate.load_submit(submit)
        hub.elevate = ElevateRelay(lambda message: elevate.call(port, dict(message, token=token)), notify, pc_name)
        threading.Thread(target=hub.elevate.run_forever, daemon=True).start()
    gate = AuthGate(cfg['token'], notify, pc_name)
    return serve(hub, gate, cfg, networks, runner)


if __name__ == '__main__':
    main()
