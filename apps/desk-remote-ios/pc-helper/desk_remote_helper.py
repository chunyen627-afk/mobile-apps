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
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from logging.handlers import RotatingFileHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # elevate.py sits next to this file, also under -I
import elevate  # noqa: E402

VERSION = '0.3.0'
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

    def feed(self, obj):
        kind = obj.get('type')
        if kind == 'queue-operation':
            content = obj.get('content')
            if obj.get('operation') == 'enqueue' and isinstance(content, str):
                self.queued.append(content)
            elif obj.get('operation') in ('dequeue', 'remove') and self.queued:
                self.queued.pop(0)
            return []
        if kind not in ('user', 'assistant') or obj.get('isSidechain') or obj.get('isMeta'):
            return []
        message = obj.get('message') or {}
        content = message.get('content')
        ts = iso(obj.get('timestamp'))
        out = []
        if kind == 'user':
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

    def feed(self, obj):
        kind = obj.get('type')
        payload = obj.get('payload') or {}
        ts = iso(obj.get('timestamp'))
        ptype = payload.get('type')
        if kind == 'event_msg':
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

    PERMISSION_LABELS = {'default': '手動核准', 'acceptEdits': '自動接受編輯', 'plan': '規劃模式',
                         'auto': '自動', 'bypassPermissions': '略過權限', 'dontAsk': '不詢問'}
    id_pattern = CLAUDE_ID
    parser = ClaudeParser

    def __init__(self, data_root, projects_dir):
        self.data_root = Path(data_root)
        self.projects_dir = Path(projects_dir)
        self.cache = {}       # file path -> (mtime, parsed metadata)
        self.paths = {}       # cliSessionId -> transcript path
        self.warning = None

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
                        'folder': folder_name(data.get('cwd')), 'updatedAt': iso(data.get('lastActivityAt')),
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

    def __init__(self, home):
        self.home = Path(home)
        self.warning = None

    def available(self):
        return (self.home / 'sessions').is_dir()

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
        """Title (the sidebar name, which is also the page title) and deep link of one thread."""
        if not CODEX_ID.match(thread_id):
            return None
        for row in self.list_sessions(100):
            if row['id'] == thread_id:
                return {'id': thread_id, 'title': row['title'], 'link': f'codex://threads/{thread_id}',
                        'doc': row['title']}
        return None

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
                        'folder': folder_name(row.get('cwd')), 'updatedAt': iso(row['ms']), 'status': status,
                        'permission': None, 'hasTranscript': path is not None})
        return out


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


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
        self.real_before = self.last_input()
        self.own = (self.ticks(), None)

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
        return {'idleSeconds': self.idle_seconds(), 'locked': self.locked(), 'windows': self.cache['windows']}


def own_adjusted_idle(last, now, own, real_before, grace_ms=1500):
    """Idle seconds from tick counts (32-bit, wrapping). Input inside the helper's own window
    [start, end + grace] counts from the real input before it instead."""
    def since(tick):
        return ((now - tick) & 0xFFFFFFFF)
    if own and real_before is not None:
        start, end = own
        after_start = since(start) >= since(last)                   # last input is not before start
        before_end = end is None or since(last) + grace_ms >= since(end)  # not later than end + grace
        if after_start and before_end:
            last = real_before
    return since(last) // 1000


class FixedPresence:
    def __init__(self, values):
        self.values = values

    def snapshot(self):
        return self.values

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

    def post(self, title, message, priority=3, tags=None):
        if not self.cfg.get('topic') or not self.cfg.get('server'):
            return
        body = json.dumps({'topic': self.cfg['topic'], 'title': title, 'message': message,
                           'priority': priority, 'tags': tags or []}, ensure_ascii=False).encode('utf-8')
        request = urllib.request.Request(self.cfg['server'], data=body, method='POST',
                                         headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read(4096)


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
        return {'ok': True, 'pc': {'name': self.pc_name, 'helperVersion': VERSION},
                'capabilities': self.capabilities + (['elevate'] if self.elevate is not None else []),
                'apps': apps, 'presence': {'idleSeconds': presence.get('idleSeconds'), 'locked': presence.get('locked')},
                'warnings': warnings, 'elevate': elevate}

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
            if page['events'] or page['reset'] or changed or time.monotonic() >= deadline or (stop and stop()):
                page.update({'ok': True, 'prompt': prompt})
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
        self.info_cache[key] = (now, value)
        return value


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
        os.startfile(info['link'])  # Each desktop app opens its own conversation link.

    def invoke(self, app, name, doc=None):
        self.ask(app, cmd='invoke', name=name, doc=doc)

    def send(self, app, doc, text):
        self.ask(app, cmd='send', doc=doc, text=text)

    def new_send(self, app, button, text):
        self.ask(app, cmd='new_send', name=button, text=text)

    def answer(self, app, doc, decision, expect):
        return self.ask(app, cmd='answer', doc=doc, decision=decision, expect=expect).get('how')

    def answer_question(self, app, doc, question, answers):
        """Turns on each chosen option (and 其他 with its text) in the question's card, then 提交."""
        if app != 'claude':
            raise ActionError('not-supported', 'option questions are only read from Claude')
        items = [{'question': q['question'], 'labels': a.get('labels') or [], 'other': a.get('other') or ''}
                 for q, a in zip(question['questions'], answers)]
        return self.ask(app, cmd='choose', doc=doc, questions=items).get('how')


def prompt_id(app, doc, text):
    return hashlib.sha256(f'{app}\n{doc}\n{text}'.encode('utf-8')).hexdigest()[:16]


class UiWatcher:
    """Looks at each desktop app every few seconds: which conversation is open and whether it is
    asking for permission. Sends ntfy when a question appears and when a turn finishes."""

    def __init__(self, hub, driver, notify=None, pc_name='', interval=4):
        self.hub, self.driver, self.notify, self.pc_name, self.interval = hub, driver, notify, pc_name, interval
        self.state = {}         # app -> {'docs': [...], 'prompt': {...} or None}
        self.turns = {}         # (app, id) -> last parser status
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
            old = (self.state.get(app) or {}).get('prompt')
            self.state[app] = {'docs': docs, 'prompt': prompt, 'window': answer.get('window')}
        if prompt and (not old or old['promptId'] != prompt['promptId']):
            title = prompt['doc'].removesuffix(' - Claude Code')
            self.send(f'🔔 {APP_NAMES[app]} 在等你核准', f'{self.pc_name}・「{title}」：{prompt["text"][:120]}', 4, ['bell'])

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

    def check_turns(self):
        """A conversation that was working and is now idle has finished a turn."""
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
                if self.turns.get(key) == 'working' and status == 'idle':
                    self.send(f'✅ {APP_NAMES[app]} 完成一輪', f'{self.pc_name}・「{row["title"]}」', 3, ['white_check_mark'])
                self.turns[key] = status

    def send(self, title, message, priority, tags):
        if self.notify:
            try:
                self.notify(title, message, priority, tags)
            except OSError:
                logging.exception('notification failed')

    def tick(self):
        for app in APPS:
            self.look(app)
        if time.monotonic() - self.last_turn_check > 15:
            self.last_turn_check = time.monotonic()
            self.check_turns()

    def run_forever(self):
        while True:
            try:
                self.tick()
            except Exception:
                logging.exception('watcher failed')
            time.sleep(self.interval)


APP_NAMES = {'claude': 'Claude', 'codex': 'Codex'}


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

    def __init__(self, hub, driver, presence, watcher, notify=None, pc_name='', strings=None,
                 idle_seconds=60, verify_seconds=20, doc_wait=8, settle_seconds=2.0, clock=time.monotonic):
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
        if kind in ('send', 'new'):
            if not isinstance(text, str) or not text.strip():
                return 400, error('bad-request', '訊息是空的')
            if len(text) > self.MAX_TEXT:
                return 400, error('bad-request', f'訊息太長（上限 {self.MAX_TEXT} 字）')
        info = None
        if kind in ('send', 'open', 'permission', 'answer'):
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
                      'project': payload.get('project'), 'force': force, 'state': 'queued', 'message': '排隊中',
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
                   'open': self.do_open, 'answer': self.do_answer}[action['kind']]
        try:
            handler(action)
        except ActionError as exc:
            logging.warning('%s %s failed: %s %s', action['kind'], action['app'], exc.code, exc.message)
            self.update(action, state='failed', error=exc.code, message=FAILURE_TEXT.get(exc.code, exc.message or exc.code))
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
        if not self.notify:
            return
        verb = {'send': '送出訊息', 'permission': '回覆權限', 'new': '開新對話', 'open': '打開對話',
                'answer': '回答選項題'}[action['kind']]
        if action['kind'] == 'permission' and not failed:
            verb = '允許一次' if action['decision'] == 'allow_once' else '拒絕'
        title = (action.get('info') or {}).get('title') or action.get('title') or ''
        head = f"{'⚠️ 手機' + verb + '失敗' if failed else '📱 手機' + verb}：{APP_NAMES[action['app']]}"
        body = f"{self.pc_name}・「{title}」" + (f"：{action['message']}" if failed else '')
        try:
            self.notify(head, body, 4 if failed else 3, ['iphone'])
        except OSError:
            logging.exception('action notification failed')

    def recheck(self, action, needs_front=True):
        denied = self.gate(action['force'], needs_front)
        if denied:
            raise ActionError(denied[1]['error'], denied[1]['message'])

    def wait_doc(self, app, doc):
        deadline = self.clock() + self.doc_wait
        while True:
            docs = self.driver.docs(app)
            if docs is None:
                raise ActionError('app-not-running', '')
            if docs.count(doc) == 1:
                return True
            if self.clock() >= deadline:
                return False
            time.sleep(0.25)

    def open_conversation(self, action):
        app, info = action['app'], action['info']
        docs = self.driver.docs(app)
        if docs is None:
            raise ActionError('app-not-running', '')
        if docs.count(info['doc']) == 1:
            return
        self.recheck(action)
        self.presence.begin_own()
        self.driver.open(app, info)
        if self.wait_doc(app, info['doc']):
            # The title changes before the new page is ready to type into (found live: a
            # message sent right after the switch was lost), so let it settle.
            time.sleep(self.settle_seconds)
            return
        if app == 'codex':
            # Fallback: the sidebar button with this title, only when the title is unique.
            titles = [row['title'] for row in self.hub.sources['codex'].list_sessions(100)]
            if titles.count(info['title']) != 1:
                raise ActionError('duplicate-title', '')
            self.driver.invoke(app, info['title'])
            if self.wait_doc(app, info['doc']):
                return
        raise ActionError('title-mismatch', '')

    def do_open(self, action):
        self.open_conversation(action)
        self.update(action, state='done', message='已在電腦上打開')

    def do_send(self, action):
        app, info, text = action['app'], action['info'], action['text']
        transcript = self.hub.transcript(app, action['sessionId'])
        if transcript is not None:
            transcript.refresh()
        mark = transcript.seq if transcript is not None else 0
        self.open_conversation(action)
        self.recheck(action)
        self.presence.begin_own()
        self.driver.send(app, info['doc'], text)
        self.presence.end_own()
        self.update(action, message='已送出，確認中')
        verified = self.verify(transcript, mark, text)
        message = {True: '已送出', 'queued': '已送出，排在等待中的權限詢問之後'}.get(
            verified, f'已送出，但 {self.verify_seconds} 秒內還沒在對話紀錄看到')
        self.update(action, state='done', verified=bool(verified), message=message)

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
            if any(normalized(e['text']).startswith(want) for e in fresh):
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
        self.seen, self.reported = set(), set()
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
            done = [r for r in self.recent if r['id'] not in self.reported]
            first, self.started = not self.started, True
            self.seen.update(r['id'] for r in self.pending)
            self.reported.update(r['id'] for r in self.recent)
        if first:
            return  # Nothing to announce for what was already there when the helper started.
        for _ in fresh:
            self.send('🔐 需要管理員權限', f'{self.pc_name}：有指令在等你核准，打開桌面遙控查看', 5, ['closed_lock_with_key'])
        for r in done:
            text = {'done': f"已執行，結束碼 {r.get('exitCode')}", 'denied': '已拒絕', 'expired': '逾時未核准',
                    'timeout': '執行超過時間上限，已停止'}.get(r.get('state'), r.get('state'))
            self.send('🔐 管理員指令', f'{self.pc_name}：{text}', 3, ['closed_lock_with_key'])

    def send(self, title, message, priority, tags):
        if self.notify:
            try:
                self.notify(title, message, priority, tags)
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
    'box-not-empty': '電腦上的輸入框裡已經有沒送出的字，為免混在一起已中止',
    'paste-failed': '貼上後輸入框沒有出現這段文字，已清掉並中止（沒有送出）',
    'prompt-changed': '權限詢問已經不一樣了',
    'menu-failed': '打不開「允許一次」選單',
    'still-asking': '按了之後電腦上仍在詢問，可能沒有按到',
    'question-changed': '這個選項題已經回答過或換了一題',
    'toggle-failed': '選項按了沒有反應',
    'not-supported': '這台電腦的小幫手還不支援這個動作',
    'not-found': '畫面上找不到需要的按鈕',
    'not-invokable': '按鈕按不下去',
    'timeout': '畫面操作逾時',
    'worker-error': '畫面操作程式出錯',
}


# ---------------------------------------------------------------------------------------------
# HTTP.


MAX_BODY = 64 * 1024


def handler_for(hub, gate, networks, runner=None):
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
            except (BrokenPipeError, ConnectionResetError):
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

        def read_body(self):
            """The JSON object sent with a POST, or None after answering 400/413."""
            try:
                length = int(self.headers.get('Content-Length') or 0)
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY:
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
            body = self.read_body()
            if body is None:
                return None
            if len(parts) >= 2 and parts[0] in APPS and parts[1] == 'sessions':
                app = parts[0]
                if len(parts) == 2:
                    return self.send_json(*runner.submit('new', app, None, body))
                kinds = {'messages': 'send', 'permission': 'permission', 'open': 'open', 'answer': 'answer'}
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
                                   claude.get('projects_dir') or home / '.claude' / 'projects'),
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
        threads = json.loads((home / 'threads.json').read_text(encoding='utf-8'))
        connection = sqlite3.connect(home / 'state_5.sqlite')
        connection.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, name TEXT, '
                           'recency_at_ms INTEGER, updated_at_ms INTEGER, updated_at INTEGER, archived INTEGER, '
                           'cwd TEXT, approval_mode TEXT, source TEXT)')
        for item in threads:
            ms = self.now_ms - int(item.get('minutesAgo', 0) * 60000)
            rollout = home / 'sessions' / item['rollout'] if item.get('rollout') else None
            if rollout is not None and item.get('minutesAgo', 0) > 2:
                old = ms / 1000
                os.utime(rollout, (old, old))
            connection.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                               (item['id'], str(rollout) if rollout else None, item.get('title'), item.get('name'),
                                ms, ms, ms // 1000, item.get('archived', 0), item.get('cwd'),
                                item.get('approval'), item.get('source', 'vscode')))
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
            connection.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                               (session_id, str(path), title, title, now_ms, now_ms, now_ms // 1000, 0,
                                'C:\\work\\demo-app', None, 'vscode'))
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
            info = self.hub.sources[app].info(row['id'])
            if info and info['doc'] == doc:
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
        return {'ok': True, 'window': True, 'docs': [self.open_doc.get(app)], 'edit': prompt is None,
                'prompt': {'text': prompt['text'], 'buttons': ['拒絕', '允許一次']} if prompt else None}

    def docs(self, app):
        return [self.open_doc.get(app)]

    def open(self, app, info):
        self.calls.append(('open', app, info['id']))
        self.open_doc[app] = info['doc']

    def invoke(self, app, name, doc=None):
        self.calls.append(('invoke', app, name))
        for row in self.hub.sources[app].list_sessions(100):
            if row['title'] == name:
                self.open_doc[app] = self.hub.sources[app].info(row['id'])['doc']
                return
        raise ActionError('not-found', '')

    def send(self, app, doc, text):
        self.calls.append(('send', app, doc))
        if self.open_doc.get(app) != doc:
            raise ActionError('title-mismatch', '')
        session_id = self.session_for_doc(app, doc)
        path = self.hub.sources[app].transcript_path(session_id)
        self.write(app, path, 'user', text)
        self.later(app, path, f'（示範）收到：{text[:30]}')

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

    def later(self, app, path, text):
        def reply():
            time.sleep(self.reply_after)
            self.write(app, path, 'assistant', text)
        threading.Thread(target=reply, daemon=True).start()

    def write(self, app, path, role, text):
        ts = datetime.now(UTC).strftime('%Y-%m-%dT%H:%M:%S.000Z')
        if app == 'claude':
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


def build_driving(hub, driver, notify, pc_name, cfg, interval, verify_seconds):
    """Watcher and action runner over `driver`, both on their own threads."""
    watcher = UiWatcher(hub, driver, notify, pc_name, interval=interval)
    hub.prompts = watcher.prompt_for
    runner = ActionRunner(hub, driver, hub.presence, watcher, notify, pc_name, load_strings(),
                          idle_seconds=int(cfg.get('idle_seconds', 60)), verify_seconds=verify_seconds)
    hub.capabilities = ['read', 'send', 'permission', 'new', 'open', 'question']
    threading.Thread(target=watcher.run_forever, daemon=True).start()
    threading.Thread(target=runner.run_forever, daemon=True).start()
    return runner


def main(argv=None):
    parser = argparse.ArgumentParser(description='Desk remote helper')
    parser.add_argument('--config', type=Path, default=None)
    parser.add_argument('--fake', type=Path, default=None, help='serve hand-written fixtures (simulator tests)')
    parser.add_argument('--fake-port', type=int, default=None, help='fake mode: listen on this port instead')
    parser.add_argument('--fake-idle', type=int, default=None, help='fake mode: report this many idle seconds')
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
        if args.fake_port:
            cfg['port'] = args.fake_port
        networks = [ipaddress.ip_network(item) for item in cfg['allowed_networks']]
        hub = Hub(cfg['pc_name'], fake.sources(), FixedPresence(presence), on_events=fake.on_events)
        runner = build_driving(hub, FakeDriver(fake, hub), None, cfg['pc_name'], cfg, interval=1, verify_seconds=10)
        hub.elevate = fake.elevate_relay()
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
    runner = None
    if cfg.get('drive_windows', True):
        runner = build_driving(hub, WindowsDriver(load_strings()), notify, pc_name, cfg, interval=4, verify_seconds=20)
    submit = Path((cfg.get('elevate') or {}).get('submit_file') or elevate.submit_file())
    if submit.exists():  # written by install-elevated.ps1 (run once as administrator)
        port, token = elevate.load_submit(submit)
        hub.elevate = ElevateRelay(lambda message: elevate.call(port, dict(message, token=token)), notify, pc_name)
        threading.Thread(target=hub.elevate.run_forever, daemon=True).start()
    gate = AuthGate(cfg['token'], notify, pc_name)
    return serve(hub, gate, cfg, networks, runner)


if __name__ == '__main__':
    main()
