"""Desk remote helper: lets the iPhone app read the Claude and Codex desktop apps on this PC.

Phase 1 is read-only. It lists the desktop apps' conversations from their own files and serves
each conversation's transcript as events, over HTTP bound to one ZeroTier address only, with a
Bearer token (five wrong tokens lock it for ten minutes, sent to ntfy). It never writes to the
desktop apps' files and does not touch their windows yet.

Run at login in the user's interactive session:  pythonw desk_remote_helper.py [--config PATH]
Simulator tests:  python3 desk_remote_helper.py --fake ../fixtures/fake-helper
"""
import argparse
import ctypes
import glob
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

VERSION = '0.1.0'
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
                  '<external_codex', '<turn_aborted>')


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


class ClaudeParser:
    """`~/.claude/projects/*/<cliSessionId>.jsonl` written by the Claude desktop app (Code tab)."""

    def __init__(self):
        self.tool_names = {}
        self.status = 'idle'

    def feed(self, obj):
        kind = obj.get('type')
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
                return out
            for block in content or []:
                if not isinstance(block, dict):
                    continue
                if block.get('type') == 'text' and block.get('text', '').strip() and not is_noise(block['text']):
                    out.append({'kind': 'user', 'text': block['text'], 'ts': ts})
                    self.status = 'working'
                elif block.get('type') == 'image':
                    out.append({'kind': 'user', 'text': '[圖片]', 'ts': ts})
                elif block.get('type') == 'tool_result':
                    out.append({'kind': 'tool_result', 'text': flatten(block.get('content')), 'ts': ts,
                                'tool': self.tool_names.get(block.get('tool_use_id'), ''),
                                'isError': bool(block.get('is_error'))})
            return out
        for block in content or []:
            if not isinstance(block, dict):
                continue
            if block.get('type') == 'text' and block.get('text', '').strip():
                out.append({'kind': 'assistant', 'text': block['text'], 'ts': ts})
            elif block.get('type') == 'tool_use':
                name = block.get('name') or ''
                self.tool_names[block.get('id')] = name
                out.append({'kind': 'tool_call', 'tool': name, 'text': summarize_input(name, block.get('input')), 'ts': ts})
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
            text = flatten(item.get('content'))
            return [{'kind': 'assistant', 'text': text, 'ts': ts}] if text.strip() else []
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
            if epoch != self.epoch or after <= 0 or after > self.seq:
                events = self.events[-FIRST_PAGE:]
                earlier = self.earlier or len(self.events) > len(events)
                return {'epoch': self.epoch, 'reset': True, 'events': events, 'earlier': earlier,
                        'cursor': self.seq, 'status': self.parser.status}
            events = [event for event in self.events if event['seq'] > after][:MAX_PAGE]
            cursor = events[-1]['seq'] if events else after
            return {'epoch': self.epoch, 'reset': False, 'events': events, 'earlier': False,
                    'cursor': cursor, 'status': self.parser.status}

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
    reviews (`source` is a JSON subagent description) and `codex exec` runs are not listed."""

    APPROVAL_LABELS = {'never': '代我核准', 'on-request': '需要時詢問', 'untrusted': '不信任時詢問',
                       'on-failure': '失敗時詢問'}
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
            query = (f'SELECT id, {name}, {recency}, rollout_path, cwd, approval_mode, source FROM threads '
                     'WHERE archived = 0 AND (source IS NULL OR (source NOT LIKE \'{%\' AND source != \'exec\')) '
                     f'ORDER BY {recency} DESC LIMIT ?')
            return [{'id': r[0], 'title': r[1], 'ms': r[2], 'rollout': r[3], 'cwd': r[4], 'approval': r[5]}
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
                 'cwd': None, 'approval': None} for i in latest.values()]
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
                        'permission': self.APPROVAL_LABELS.get(row.get('approval'), row.get('approval')),
                        'hasTranscript': path is not None})
        return out


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


# ---------------------------------------------------------------------------------------------
# This PC: who is at the keyboard, whether it is locked, whether the desktop apps are open.


class WindowsPresence:
    def __init__(self):
        self.cache, self.cached_at = None, 0.0

    @staticmethod
    def idle_seconds():
        class LastInput(ctypes.Structure):
            _fields_ = [('cbSize', ctypes.c_uint), ('dwTime', ctypes.c_uint)]
        info = LastInput()
        info.cbSize = ctypes.sizeof(info)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
            return None
        return max(0, (ctypes.windll.kernel32.GetTickCount() - info.dwTime) & 0xFFFFFFFF) // 1000

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
            self.cache, self.cached_at = {'idleSeconds': self.idle_seconds(), 'locked': self.locked(),
                                          'windows': windows}, now
        return self.cache


class FixedPresence:
    def __init__(self, values):
        self.values = values

    def snapshot(self):
        return self.values


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
        return {'ok': True, 'pc': {'name': self.pc_name, 'helperVersion': VERSION}, 'capabilities': ['read'],
                'apps': apps, 'presence': {'idleSeconds': presence.get('idleSeconds'), 'locked': presence.get('locked')},
                'warnings': warnings}

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

    def events(self, app, session_id, after, epoch, wait, known_prompt='', stop=None):
        """Waits up to `wait` seconds for new events or a permission prompt other than the one
        the app already shows (`known_prompt`, its promptId)."""
        transcript = self.transcript(app, session_id)
        if transcript is None:
            return None
        self.on_events(app, session_id)
        deadline = time.monotonic() + max(0, min(wait, MAX_WAIT))
        while True:
            transcript.refresh()
            page = transcript.page(after, epoch)
            prompt = self.prompts(app, session_id)
            changed = (prompt or {}).get('promptId', '') != known_prompt
            if page['events'] or page['reset'] or changed or time.monotonic() >= deadline or (stop and stop()):
                page.update({'ok': True, 'prompt': prompt})
                return page
            time.sleep(1)

    def item(self, app, session_id, item_id):
        transcript = self.transcript(app, session_id)
        return transcript.item(item_id) if transcript is not None and ITEM_ID.match(item_id) else None


# ---------------------------------------------------------------------------------------------
# HTTP.


def handler_for(hub, gate, networks):
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
            self.send_response(code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def allowed(self):
            try:
                peer = ipaddress.ip_address(self.client_address[0])
            except ValueError:
                return False
            return any(peer in network for network in networks)

        def do_GET(self):
            if not self.allowed():
                return self.send_json(403, error('forbidden', '不在允許的網路'))
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            parts = [urllib.parse.unquote(p) for p in url.path.strip('/').split('/')]
            if parts == ['health']:
                return self.send_json(200, {'ok': True})
            if not parts or parts[0] != 'v1':
                return self.send_json(404, error('not-found', '沒有這個路徑'))
            denied = gate.check(self.headers.get('Authorization'))
            if denied:
                return self.send_json(*denied)
            try:
                return self.route(parts[1:], query)
            except Exception:
                logging.exception('request failed')
                return self.send_json(500, error('internal', '電腦端發生錯誤'))

        def route(self, parts, query):
            def number(name, default):
                try:
                    return int(query.get(name, [default])[0])
                except ValueError:
                    return default
            if parts == ['state']:
                return self.send_json(200, hub.state())
            if len(parts) >= 2 and parts[0] in APPS and parts[1] == 'sessions':
                app = parts[0]
                if len(parts) == 2:
                    return self.send_json(200, hub.sessions(app, max(1, min(number('limit', 50), 100))))
                if len(parts) == 4 and parts[3] == 'events':
                    page = hub.events(app, parts[2], number('after', 0), query.get('epoch', [''])[0],
                                      number('wait', 0), query.get('prompt', [''])[0])
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
            self.send_json(405, error('read-only', '這一版只能讀取'))

        do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = denied

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

    def prompts(self, app, session_id):
        return self.prompts_data.get(f'{app}/{session_id}')


def serve(hub, gate, cfg, networks):
    while True:
        try:
            server = ThreadingHTTPServer((cfg['bind_ip'], cfg['port']), handler_for(hub, gate, networks))
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


def main(argv=None):
    parser = argparse.ArgumentParser(description='Desk remote helper (read-only phase)')
    parser.add_argument('--config', type=Path, default=None)
    parser.add_argument('--fake', type=Path, default=None, help='serve hand-written fixtures (simulator tests)')
    args = parser.parse_args(argv)
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    if args.fake:
        logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
        fake = FakeSetup(args.fake)
        cfg = fake.cfg
        networks = [ipaddress.ip_network(item) for item in cfg['allowed_networks']]
        hub = Hub(cfg['pc_name'], fake.sources(), FixedPresence(cfg['presence']), fake.prompts, fake.on_events)
        gate = AuthGate(cfg['token'], None, cfg['pc_name'])
        return serve(hub, gate, cfg, networks)
    path = args.config or default_config_path()
    cfg, networks = load_config(path)
    log = RotatingFileHandler(path.parent / 'helper.log', maxBytes=1048576, backupCount=3, encoding='utf-8')
    log.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s', '%Y-%m-%d %H:%M:%S'))
    logger.addHandler(log)
    notifier = Notifier(cfg)
    pc_name = cfg.get('pc_name') or os.environ.get('COMPUTERNAME', 'PC')
    hub = Hub(pc_name, real_sources(cfg), WindowsPresence())
    gate = AuthGate(cfg['token'], notifier.post, pc_name)
    return serve(hub, gate, cfg, networks)


if __name__ == '__main__':
    main()
