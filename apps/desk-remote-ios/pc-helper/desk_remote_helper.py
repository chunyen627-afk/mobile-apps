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
import base64
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
import socket
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

VERSION = '0.5.63'
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
IMAGE_ID = re.compile(r'^g[0-9]{1,9}-[0-7]$')
IMAGE_BYTES = 48 * 1024 * 1024    # base64 of a conversation's pictures kept for the phone
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


def screen_in_use():
    """True while something keeps the display on (a video playing in a browser or a player asks
    Windows for ES_DISPLAY_REQUIRED) or a full-screen app, game or presentation is in front:
    the usage card expanding over it would be seen (user 11/10: watching a video on the PC, the
    screen blinked every few minutes). Neither call needs a window of its own."""
    if sys.platform != 'win32':
        return False
    try:
        state = ctypes.c_ulong()
        # SystemExecutionState (16): the execution state every process has asked for, combined.
        if ctypes.windll.powrprof.CallNtPowerInformation(16, None, 0, ctypes.byref(state), ctypes.sizeof(state)) == 0 \
                and state.value & 0x2:  # ES_DISPLAY_REQUIRED
            return True
        quns = ctypes.c_int()
        # QUNS_BUSY 2 (a full-screen window in front), QUNS_RUNNING_D3D_FULL_SCREEN 3, QUNS_PRESENTATION_MODE 4.
        if ctypes.windll.shell32.SHQueryUserNotificationState(ctypes.byref(quns)) == 0 and quns.value in (2, 3, 4):
            return True
    except (AttributeError, OSError):
        pass
    return False


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


def with_reset_times(usage):
    """`usage` with every window whose reset is only words ("週五上午11:00 重設") also given
    `resetsAt`, the next such moment after `sampledAt` (0.5.59: the phone's first screen counts
    down to it, the user 11/12: 「首頁也順便提醒離 reset 還剩幾天幾小時」). The words stay."""
    if not usage or not usage.get('sampledAt'):
        return usage
    try:
        read_at = datetime.fromisoformat(usage['sampledAt'].replace('Z', '+00:00')).timestamp()
    except ValueError:
        return usage
    windows = []
    for window in usage.get('windows') or []:
        if not window.get('resetsAt') and window.get('resetsText'):
            at = clock_reset(window['resetsText'], read_at)
            if at is not None:
                window = dict(window, resetsAt=iso(at))
        windows.append(window)
    return dict(usage, windows=windows)


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
    button shows one weekly row; the history file stopped for days (live 10/28: the office's
    3.6556 since 10/27 17:49, the home PC's 4.29 since its update). The button's row replaces the
    row of the same name whenever it was read after the card or the file: the button says "每週 ·
    所有模型" or, since Claude 4.29 on a plan with a per-model week, "每週 · Fable" (live 11/2: that
    one was taken for the all-models week, so the phone showed Fable's 23% twice and never the
    21%). A 5-hour figure from the file older than five hours is left out (that window has reset
    since). `sampledAt` is the oldest time behind what is shown."""
    file_at = datetime.fromisoformat(from_file['sampledAt'].replace('Z', '+00:00')).timestamp() if from_file else None
    weekly = None
    if button and button_at and button['label'].startswith('每週'):
        weekly = {'label': card_label(button['label']), 'percent': button['percent'], 'resetsAt': None,
                  'resetsText': button['resetsText']}
    if card and card_at and (file_at is None or card_at > file_at):
        windows = card_windows(card, card_at, now)
        if windows:
            if weekly and button_at > card_at:
                windows = replace_window(windows, weekly)
            return {'windows': windows, 'sampledAt': iso(card_at)}
    fresher = weekly is not None and (file_at is None or button_at > file_at)
    same_week = weekly is not None and weekly['label'] == '每週'  # the file only knows the all-models week
    windows, times = [], []
    for window in (from_file or {}).get('windows') or []:
        if window['label'] == '5 小時' and now - file_at < 5 * 3600:
            windows.append(window)
            times.append(file_at)
        elif window['label'] == '每週' and not (fresher and same_week):
            windows.append(dict(window, resetsText=weekly['resetsText'] if same_week else None))
            times.append(file_at)
    if fresher:
        windows.append(weekly)
        times.append(button_at)
    return {'windows': windows, 'sampledAt': iso(min(times))} if windows else None


def replace_window(windows, window):
    """`windows` with `window` in place of the row of the same name, or added at the end."""
    if not any(w['label'] == window['label'] for w in windows):
        return windows + [window]
    return [window if w['label'] == window['label'] else w for w in windows]


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


def images_of(content):
    """The pictures in a message body or tool result: [{'media': 'image/png', 'data': <base64>}].
    Claude writes {'type': 'image', 'source': {'type': 'base64', 'media_type', 'data'}}; Codex
    {'type': 'input_image', 'image_url': 'data:image/png;base64,...'}."""
    found = []
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get('type') == 'image' and isinstance(block.get('source'), dict):
            source = block['source']
            if source.get('type') == 'base64' and isinstance(source.get('data'), str) and source['data']:
                found.append({'media': str(source.get('media_type') or 'image/jpeg'), 'data': source['data']})
        elif block.get('type') == 'image' and isinstance(block.get('data'), str) and block['data']:
            # An MCP tool's picture (Codex's browser screenshots): {'type': 'image', 'data', 'mimeType'}.
            found.append({'media': str(block.get('mimeType') or 'image/jpeg'), 'data': block['data']})
        elif block.get('type') in ('input_image', 'image') and isinstance(block.get('image_url'), str):
            # Codex 26.10 writes a picture pasted at the PC as {'type': 'image', 'image_url': data URL}
            # (home PC 11/8); older files and tool outputs as 'input_image'.
            match = re.match(r'data:(image/[a-z0-9.+-]+);base64,(.+)$', block['image_url'], re.S)
            if match:
                found.append({'media': match.group(1), 'data': match.group(2)})
        elif block.get('type') == 'local_image' and isinstance(block.get('path'), str):
            # Codex 26.10 keeps a pasted picture as a file in Temp and writes only its path
            # (home PC 11/6): the bytes are read while the file is still there.
            picture = local_image(block['path'])
            if picture:
                found.append(picture)
    return found


try:
    from PIL import Image as PIL_IMAGE  # Pillow: pictures are shrunk for the phone when it is installed
except ImportError:
    PIL_IMAGE = None

PICTURE_MAX_SIDE = 1600          # pixels on the long side of a picture sent to the phone
PICTURE_QUALITY = 82             # JPEG quality of a shrunk picture
PICTURE_SHRINK_FROM = 400 * 1024  # bytes; smaller pictures go as they are


def shrink_picture(media, data):
    """A picture for the phone: a 4K screenshot pasted at the PC is 2-5 MB and the phone decodes
    it to 33 MB, so with AirPlay on the same Wi-Fi the conversation stalled (the user 11/8). When
    Pillow is installed and the picture is large, it is scaled to PICTURE_MAX_SIDE on its long
    side and re-encoded (JPEG; PNG when it has transparency). Otherwise it goes as it is.
    Returns (media type, base64)."""
    if PIL_IMAGE is None or media == 'image/gif' or len(data) < PICTURE_SHRINK_FROM * 4 // 3:
        return media, data
    try:
        import io
        raw = base64.b64decode(data, validate=False)
        with PIL_IMAGE.open(io.BytesIO(raw)) as opened:
            opened.load()
            image = opened
            width, height = image.size
            scale = PICTURE_MAX_SIDE / max(width, height, 1)
            if scale < 1:
                image = image.resize((max(1, round(width * scale)), max(1, round(height * scale))), PIL_IMAGE.LANCZOS)
            transparent = image.mode in ('RGBA', 'LA') and image.getextrema()[-1][0] < 255 or \
                (image.mode == 'P' and 'transparency' in image.info)
            out = io.BytesIO()
            if transparent:
                image.save(out, 'PNG', optimize=True)
                kind = 'image/png'
            else:
                image.convert('RGB').save(out, 'JPEG', quality=PICTURE_QUALITY, optimize=True)
                kind = 'image/jpeg'
        if out.tell() >= len(raw):
            return media, data
        return kind, base64.b64encode(out.getvalue()).decode('ascii')
    except (OSError, ValueError, TypeError) as exc:
        logging.info('picture left at full size: %s', exc)
        return media, data


LOCAL_IMAGE_BYTES = 12 * 1024 * 1024
LOCAL_IMAGE_TYPES = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
                     '.webp': 'image/webp'}


LOCAL_IMAGE_MAGIC = ((b'\x89PNG', 'image/png'), (b'\xff\xd8\xff', 'image/jpeg'), (b'GIF8', 'image/gif'),
                     (b'RIFF', 'image/webp'))


def local_image_path(path):
    """A transcript's picture path as a Path: plain, or a file:/// URL (Codex's ImageView items)."""
    if path.startswith('file:'):
        parsed = urllib.parse.urlparse(path)
        path = urllib.parse.unquote(parsed.path)
        if re.match(r'^/[A-Za-z]:', path):
            path = path[1:]  # file:///C:/x -> C:/x
        elif parsed.netloc:
            path = f'//{parsed.netloc}{path}'
    return Path(path)


def local_image(path):
    """The picture file a Codex transcript points at, as {'media', 'data'}; None when it is gone,
    too big or not a picture (the type comes from the extension, else the first bytes)."""
    try:
        file = local_image_path(path)
        if not file.is_file() or file.stat().st_size > LOCAL_IMAGE_BYTES:
            return None
        raw = file.read_bytes()
        media = LOCAL_IMAGE_TYPES.get(file.suffix.lower()) or \
            next((kind for magic, kind in LOCAL_IMAGE_MAGIC if raw.startswith(magic)), None)
        if media is None:
            return None
        return {'media': media, 'data': base64.b64encode(raw).decode('ascii')}
    except (OSError, ValueError):
        return None


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
                if block.get('type') in ('image', 'input_image', 'local_image'):
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
CODEX_QUESTION_TOOL = 'request_user_input_async'
CODEX_REPLY_TAG = 'send_user_message_question_reply'  # wraps the answer Codex's card sends as a user message
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


def codex_question_from(call_id, data):
    """Codex's `request_user_input_async` ({"questions": [{"title", "options": [str]?}]}) in the
    phone's shape: one choice per question, a question without options takes words only."""
    if not isinstance(data, dict) or not isinstance(data.get('questions'), list) or not call_id:
        return None
    questions = []
    for item in data['questions']:
        if not isinstance(item, dict) or not str(item.get('title') or '').strip():
            continue
        options = [{'label': str(o), 'description': None} for o in (item.get('options') or []) if str(o or '').strip()] \
            if isinstance(item.get('options'), list) else []
        questions.append({'question': str(item['title']), 'header': None, 'multiSelect': False, 'options': options})
    return {'questionId': str(call_id), 'questions': questions} if questions else None


CODEX_IMAGE_VIEW = '看圖'  # the tool name shown for Codex's ImageView items
CODEX_FILES_HEAD = '# Files mentioned by the user:'
CODEX_REQUEST_HEAD = '## My request:'


def codex_request(text):
    """What the person typed, out of the wrapper Codex 26.10 puts around a message with a pasted
    picture ("# Files mentioned by the user: … Image attachment: true … ## My request:\\n<text>";
    phone 11/8: the whole wrapper showed as the person's message). Other text is returned as is."""
    if not isinstance(text, str) or CODEX_FILES_HEAD not in text:
        return text
    head, sep, request = text.partition(CODEX_REQUEST_HEAD)
    if not sep or head.lstrip().split('\n', 1)[0].strip() != CODEX_FILES_HEAD:
        return text
    return request.strip()


def codex_user_text(content):
    """A Codex user message's words for the phone: the pictures first ("[圖片]" each, as the phone
    sent them), then what was typed, without the wrapper of a pasted picture."""
    if isinstance(content, str):
        return codex_request(content)
    if not isinstance(content, list):
        return flatten(content)
    pictures, texts = [], []
    for block in content:
        if isinstance(block, str):
            texts.append(block)
        elif isinstance(block, dict):
            if block.get('type') in ('image', 'input_image', 'local_image'):
                pictures.append('[圖片]')
            elif isinstance(block.get('text'), str):
                text = codex_request(block['text'])
                if text.strip():
                    texts.append(text)
    return '\n'.join(pictures + texts)


def codex_reply(text):
    """The answers in a `<send_user_message_question_reply>` message: [(call id, answer)], or None
    when `text` is not one. The card writes `questionItemId` as '["request_user_input_async","call_x",0]'."""
    if not isinstance(text, str) or f'<{CODEX_REPLY_TAG}>' not in text:
        return None
    body = text.split(f'<{CODEX_REPLY_TAG}>', 1)[1].split(f'</{CODEX_REPLY_TAG}>', 1)[0]
    try:
        items = json.loads(body)
    except ValueError:
        return []
    out = []
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        try:
            parts = json.loads(item.get('questionItemId') or '')
        except ValueError:
            parts = []
        call_id = next((p for p in parts if isinstance(p, str) and p.startswith('call_')), None) \
            if isinstance(parts, list) else None
        out.append((call_id, str(item.get('answer') or '')))
    return out


def suggestions_from(data):
    """The next-step box: its recap (shown since 11/1, as the desktop does), its question and
    the reply buttons that send words (not app actions). None when it has none of those."""
    if not isinstance(data, dict):
        return None
    replies = []
    for action in data.get('actions') or []:
        if not isinstance(action, dict) or action.get('action') or not action.get('label'):
            continue
        replies.append({'label': str(action['label']), 'message': str(action.get('message') or action['label'])})
    recap = data.get('recap') if isinstance(data.get('recap'), str) and data.get('recap').strip() else None
    if not replies and not recap:
        return None
    return {'ask': data.get('ask') or None, 'replies': replies, 'recap': recap}


def is_plan(name):
    """The desktop app's task list under the latest message (update_plan)."""
    return name == 'update_plan' or name.endswith('__update_plan')


def plan_apply(plan, data):
    """The task list after one update_plan call: `items` replaces it; `advance` completes the
    step in progress and starts the next pending one; `done` (1-based) completes steps and
    `start` starts one. Items are [{'content', 'status'}]; None when there is no list."""
    if not isinstance(data, dict):
        return plan
    if isinstance(data.get('items'), list):
        plan = [{'content': str(item.get('content') or ''), 'status': str(item.get('status') or 'pending')}
                for item in data['items'] if isinstance(item, dict) and item.get('content')]
        return plan or None
    if not plan:
        return plan
    plan = [dict(item) for item in plan]
    if data.get('advance'):
        current = next((i for i, item in enumerate(plan) if item['status'] == 'in_progress'), None)
        if current is not None:
            plan[current]['status'] = 'completed'
        following = next((i for i, item in enumerate(plan) if item['status'] == 'pending'), None)
        if following is not None:
            plan[following]['status'] = 'in_progress'
    for index in data.get('done') or []:
        if isinstance(index, int) and 1 <= index <= len(plan):
            plan[index - 1]['status'] = 'completed'
    start = data.get('start')
    if isinstance(start, int) and 1 <= start <= len(plan):
        plan[start - 1]['status'] = 'in_progress'
    return plan


def plan_finished(plan):
    """The task list once the turn's wrap-up checks it off."""
    return [dict(item, status='completed') for item in plan] if plan else plan


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
        self.plan = None  # the task list under the latest message: [{'content', 'status'}]
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
                    # The picture itself goes along (phones from 0.6.2 show it; older ones the words).
                    out.append({'kind': 'user', 'text': '[圖片]', 'ts': ts, 'images': images_of([block])})
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
                                    'tool': tool, 'isError': bool(block.get('is_error')),
                                    'images': images_of(block.get('content'))})  # e.g. a browser screenshot
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
                    self.plan = plan_finished(self.plan)  # the wrap-up checks the list off
                elif is_plan(name):
                    self.plan = plan_apply(self.plan, block.get('input'))  # shown as a card, not a tool row
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
        self.question = None  # the card above the composer: one option per question, or words
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
                if ptype == 'user_message':
                    text = codex_request(text)
                if ptype == 'user_message' and codex_reply(text) is not None:
                    return self.answered(codex_reply(text), ts)
                if text.strip() and not is_noise(text):
                    if ptype == 'user_message':
                        self.question = None  # the person moved on; the card is no longer the next thing
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
                if name == CODEX_QUESTION_TOOL:
                    self.question = codex_question_from(payload.get('call_id'), data) or self.question
                    return []  # a card on the phone, not a tool row
                text = summarize_input(name, data) if isinstance(data, dict) else str(raw or '')
                return [{'kind': 'tool_call', 'tool': name, 'text': text, 'ts': ts}]
            if ptype in ('function_call_output', 'custom_tool_call_output'):
                if self.calls.get(payload.get('call_id')) == CODEX_QUESTION_TOOL:
                    return []  # '{"accepted":true}': the card is up, nothing was answered yet
                output = payload.get('output')
                if isinstance(output, dict):
                    output = output.get('content', output)
                return [{'kind': 'tool_result', 'tool': self.calls.get(payload.get('call_id'), ''),
                         'text': flatten(output), 'ts': ts, 'images': images_of(output)}]
        return []

    def answered(self, answers, ts):
        """The card's reply (from the PC or the phone): the question is done, shown as a status."""
        if self.question and any(call_id == self.question['questionId'] for call_id, _ in answers):
            self.question = None
        chosen = '、'.join(answer for _, answer in answers if answer.strip())
        return [{'kind': 'status', 'text': f'已回答選項題：{chosen}' if chosen else '已回答選項題', 'ts': ts}]

    def item(self, item, ts):
        itype = item.get('type')
        if itype == 'UserMessage':
            text = flatten(item.get('content'))
            if codex_reply(text) is not None:
                return self.answered(codex_reply(text), ts)
            text = codex_user_text(item.get('content'))
            images = images_of(item.get('content'))
            if not (text.strip() and not is_noise(text)):
                return []
            self.question = None  # the person moved on; the card is no longer the next thing
            return [{'kind': 'user', 'text': text, 'ts': ts, 'images': images}]
        if itype == 'AgentMessage':
            if isinstance(item.get('questions'), list):
                # `request_user_input_async`: the message's text repeats the card's words (title and
                # options), so the card alone is shown (live 11/5).
                self.question = codex_question_from(item.get('id'), {'questions': item['questions']}) or self.question
                return []
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
            content = result.get('content') if isinstance(result, dict) else result
            return [{'kind': 'tool_call', 'tool': name, 'text': summarize_input(name, item.get('arguments')), 'ts': ts},
                    {'kind': 'tool_result', 'tool': name, 'text': flatten(content), 'ts': ts,
                     'isError': item.get('status') == 'failed', 'images': images_of(content)}]  # e.g. a browser screenshot
        if itype == 'ImageView' and isinstance(item.get('path'), str):
            # Codex looked at a picture file (its view_image tool; the path is a file:/// URL): the
            # phone gets the picture while the file is there, else its name (home PC 11/8).
            picture = local_image(item['path'])
            name = local_image_path(item['path']).name
            return [{'kind': 'tool_result', 'tool': CODEX_IMAGE_VIEW, 'text': f'[圖片] {name}', 'ts': ts,
                     'images': [picture] if picture else []}]
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
        self.images = {}       # image id -> (media type, base64 data), for the events still kept
        self.image_bytes = 0   # of the base64 kept, capped at IMAGE_BYTES
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
        pictures = [p for p in raw.get('images') or [] if isinstance(p, dict) and p.get('data')]
        if pictures:
            # Kept apart from the event (the phone fetches each by id when it is on screen), the
            # newest IMAGE_BYTES of them.
            event['images'] = []
            for n, picture in enumerate(pictures[:8]):
                image_id = f'g{self.seq}-{n}'
                media, data = shrink_picture(picture['media'], picture['data'])
                self.images[image_id] = (media, data)
                self.image_bytes += len(data)
                event['images'].append(image_id)
            while self.image_bytes > IMAGE_BYTES and self.images:
                oldest = next(iter(self.images))
                self.image_bytes -= len(self.images.pop(oldest)[1])
        self.events.append(event)
        if len(self.events) > MAX_EVENTS:
            dropped = self.events[:-MAX_EVENTS]
            self.events = self.events[-MAX_EVENTS:]
            self.earlier = True
            for old in dropped:
                self.items.pop(old.get('itemId'), None)
                for image_id in old.get('images') or []:
                    gone = self.images.pop(image_id, None)
                    if gone:
                        self.image_bytes -= len(gone[1])

    def page(self, after, epoch):
        """Events after `after` in the same epoch, or the latest page with reset=True."""
        with self.lock:
            waiting = {'question': getattr(self.parser, 'question', None),
                       'suggestions': getattr(self.parser, 'suggestions', None),
                       'plan': getattr(self.parser, 'plan', None)}
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
            plan = getattr(self.parser, 'plan', None)
            return ((question or {}).get('questionId'), json.dumps(suggestions, sort_keys=True, ensure_ascii=False),
                    json.dumps(plan, sort_keys=True, ensure_ascii=False))

    def item(self, item_id):
        with self.lock:
            return self.items.get(item_id)

    def image(self, image_id):
        """(media type, bytes) of a picture still kept, or None."""
        with self.lock:
            kept = self.images.get(image_id)
        if not kept:
            return None
        try:
            return kept[0], base64.b64decode(kept[1], validate=False)
        except ValueError:  # binascii.Error is one
            return None


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
            if data.get('scheduledTaskId'):
                continue  # a scheduled task's run: one a day per task floods the list (asked 11/1)
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
            # The conversation this one was started from (a side session, or a fork), for the
            # phone to nest it under, as the desktop's sidebar does (asked 11/1).
            spawned = data.get('spawnedFrom') if isinstance(data.get('spawnedFrom'), dict) else {}
            parent = spawned.get('sessionId') or data.get('forkedFromSessionId')
            out.append({'id': data['sessionId'], 'title': (data.get('title') or '').strip() or '（未命名）',
                        'folder': folder_name(data.get('cwd')), 'updatedAt': later_time(data.get('lastActivityAt'), path),
                        'status': status, 'permission': self.PERMISSION_LABELS.get(mode, mode),
                        'hasTranscript': path is not None,
                        'parent': parent if isinstance(parent, str) and CLAUDE_ID.match(parent) else None})
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
    """ntfy, like the miner aggregator: titles carry the PC name and the action, never addresses.
    Optionally LINE as well (0.5.46; the user 11/11 asked for the light on LINE): `notify.line`
    = {"channel_access_token": "<Messaging API long-lived token>", "to": "<the user's U… id>",
    "tags": ["bulb"]} pushes the same title and message through the LINE Messaging API (LINE
    Notify ended in March 2025; an official account's free plan allows 200 pushes a month). With
    `tags` only notifications carrying one of them go to LINE; without it, all of them do.
    A notification may carry a `picture` (JPEG bytes; 0.5.48, the light watch's camera frame, the
    user 11/11): it is published to ntfy as the attachment (PUT, headers RFC 2047 encoded), and
    the attachment's URL (ntfy.sh keeps it about three hours) goes into the same LINE push as an
    image message, since LINE only takes a public HTTPS URL. No ntfy, no picture on LINE.
    0.5.52: with a PictureStore (`notify.pictures`, served through a tunnel on this PC) the LINE
    picture is that store's URL instead: LINE's desktop client never showed ntfy's attachment
    (ntfy.sh answers HEAD without a Content-Type and has no Range), and the store keeps the
    picture for days, not hours. ntfy still gets the attachment as before.
    0.5.54 (the user 11/12 wants a friend to get the light notifications too): `to` may be a
    list of user IDs, sent in one multicast (LINE counts one message per recipient); every
    recipient must have added the official account.
    0.5.55 (the user 11/12: 「要個別用個別的額度」): `notify.line` may also be a list of such
    objects, one per official account (the friend's own token and user ID, so each account
    spends its own 200 a month); each is sent on its own with its own `tags`, a failing one
    does not stop the others (the first error is raised after all were tried), and no token is
    ever logged.
    0.5.56 (the user 11/12: some notifications are his alone): each account may carry "name"
    (for the log) and "owner": true. A notification posted with `shared=True` (the light watch)
    goes to every account whose tags allow it; everything else (approvals, questions, UAC,
    admin requests, usage, clipboard: the desktop and the accounts) goes only to owner accounts.
    A single object without "owner" is the owner."""

    LINE_PUSH = 'https://api.line.me/v2/bot/message/push'
    LINE_MULTICAST = 'https://api.line.me/v2/bot/message/multicast'

    def __init__(self, cfg, urlopen=urllib.request.urlopen, pictures=None):
        self.cfg = cfg.get('notify') or {}
        self.urlopen = urlopen
        self.pictures = pictures  # PictureStore, or None: LINE gets ntfy's attachment URL

    def post(self, title, message, priority=3, tags=None, click=None, picture=None, picture_name='camera.jpg',
             shared=False):
        """`click` is the phone app's link (open_link): tapping the notification opens it there.
        `shared`: may go to LINE accounts that are not the owner's (0.5.56)."""
        picture_url = None
        if self.cfg.get('topic') and self.cfg.get('server'):
            if picture:
                picture_url = self.attach(title, message, priority, tags, click, picture, picture_name)
            else:
                payload = {'topic': self.cfg['topic'], 'title': title, 'message': message, 'priority': priority,
                           'tags': tags or []}
                if click:
                    payload['click'] = click
                self.send(self.cfg['server'], payload, {}, 'ntfy')
        if picture and self.pictures is not None:
            try:
                picture_url = self.pictures.put(picture) or picture_url  # None while the tunnel is down
            except OSError as exc:  # the disk; LINE gets ntfy's URL (the phone still shows it)
                logging.warning('picture could not be kept for LINE: %s', exc)
        accounts = self.cfg.get('line') or []
        single = isinstance(accounts, dict)
        if single:
            accounts = [accounts]
        failed = None
        for number, line in enumerate(accounts, 1):
            if not (isinstance(line, dict) and line.get('channel_access_token') and line.get('to')):
                continue
            owner = bool(line.get('owner', single))
            if not (shared or owner):
                continue  # the desktop's own business stays with the owner
            wanted = line.get('tags')
            if wanted and not set(wanted) & set(tags or []):
                continue
            label = 'LINE' if single else f"LINE {line.get('name') or '#%d' % number}"
            messages = [{'type': 'text', 'text': f'{title}\n{message}'[:5000]}]
            if picture_url:
                messages.append({'type': 'image', 'originalContentUrl': picture_url, 'previewImageUrl': picture_url})
            to = line['to']
            if isinstance(to, (list, tuple)):
                to, url = [str(v) for v in to], line.get('url') or self.LINE_MULTICAST
            else:
                url = line.get('url') or self.LINE_PUSH
            try:
                self.send(url, {'to': to, 'messages': messages},
                          {'Authorization': f"Bearer {line['channel_access_token']}"}, label)
            except OSError as exc:  # the service's answer only, never the token
                logging.warning('%s refused the notification: %s', label, exc)
                failed = failed or exc
        if failed is not None:
            raise failed

    @staticmethod
    def header(text):
        """A header value for ntfy: ASCII as is, anything else RFC 2047 (UTF-8, base64)."""
        text = str(text)
        if text.isascii():
            return text
        return '=?UTF-8?B?' + base64.b64encode(text.encode('utf-8')).decode('ascii') + '?='

    def attach(self, title, message, priority, tags, click, picture, name):
        """Publishes the notification with `picture` as its attachment (ntfy: PUT the file to the
        topic, the words in headers) and returns the attachment's URL from ntfy's answer, or None
        when the answer has none."""
        url = self.cfg['server'].rstrip('/') + '/' + self.cfg['topic']
        headers = {'Title': self.header(title), 'Message': self.header(message), 'Priority': str(priority),
                   'Filename': name, 'Content-Type': 'image/jpeg'}
        if tags:
            headers['Tags'] = ','.join(tags)
        if click:
            headers['Click'] = click
        request = urllib.request.Request(url, data=picture, method='PUT', headers=headers)
        try:
            with self.urlopen(request, timeout=30) as response:
                answer = response.read(65536)
        except urllib.error.HTTPError as e:
            reason = e.read(300).decode('utf-8', 'replace')
            raise OSError(f'ntfy answered {e.code}: {reason}') from None
        try:
            return (json.loads(answer.decode('utf-8')).get('attachment') or {}).get('url')
        except (ValueError, AttributeError):
            return None

    def send(self, url, payload, headers, service):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        request = urllib.request.Request(url, data=body, method='POST',
                                         headers=dict(headers, **{'Content-Type': 'application/json'}))
        try:
            with self.urlopen(request, timeout=10) as response:
                response.read(4096)
        except urllib.error.HTTPError as e:  # the service says why in its body (ntfy 413 on 10/30)
            reason = e.read(300).decode('utf-8', 'replace')
            raise OSError(f'{service} answered {e.code}: {reason}') from None


class PictureStore:
    """Pictures LINE can fetch (0.5.52; the user 11/12: the light's picture showed on the phone's
    LINE but never on the PC's). `notify.pictures` = {"base_url": "https://<host the tunnel
    gives this PC>", "keep_days": 7, "port": 18791} and the helper keeps each notified picture
    in `pictures/` next to config.json under an unguessable random name, serves it on its own
    listener (127.0.0.1 only, the tunnel's origin; nothing else is reachable through it) with the
    right Content-Type, HEAD and Range (what LINE's desktop client needs), and deletes it after
    `keep_days`. Everything on this listener is public to whoever has the link: only pictures
    already sent to LINE live here, and the links are 32 random characters.
    `base_url` is a fixed https address or a callable giving the current one (a QuickTunnel's,
    which changes whenever cloudflared restarts) or None while there is none: put() then keeps
    nothing and returns None, and LINE gets ntfy's attachment URL instead."""

    NAME = re.compile(r'[A-Za-z0-9_-]{32}\.jpg')
    CACHE = 'public, max-age=604800'

    def __init__(self, folder, base_url, keep_days=7, clock=time.time):
        self.folder = Path(folder)
        self.base = base_url if callable(base_url) else (lambda: base_url)
        self.keep = float(keep_days) * 86400
        self.clock = clock
        self.lock = threading.Lock()
        self.listening = None  # (ip, port) once the listener is up

    @property
    def base_url(self):
        base = self.base()
        return str(base).rstrip('/') if base else None

    def put(self, data):
        """Keeps `data` (JPEG bytes) and returns its public URL (None when there is no public
        address right now); sweeps what has expired."""
        base = self.base_url
        if not base:
            return None
        self.folder.mkdir(parents=True, exist_ok=True)
        name = secrets.token_urlsafe(24) + '.jpg'  # 32 characters
        path = self.folder / name
        with self.lock:
            path.write_bytes(data)
            now = self.clock()
            os.utime(path, (now, now))  # the age sweep() measures
        self.sweep()
        return f'{base}/p/{name}'

    def path(self, name):
        """The file behind a request's name, or None: only names put() made, inside the folder."""
        if not self.NAME.fullmatch(name or ''):
            return None
        path = self.folder / name
        return path if path.is_file() else None

    def sweep(self, now=None):
        """Deletes pictures older than keep_days; returns how many."""
        now = self.clock() if now is None else now
        gone = 0
        with self.lock:
            try:
                files = list(self.folder.iterdir()) if self.folder.is_dir() else []
            except OSError:
                return 0
            for path in files:
                if not self.NAME.fullmatch(path.name):
                    continue
                try:
                    if now - path.stat().st_mtime > self.keep:
                        path.unlink()
                        gone += 1
                except OSError:
                    pass
        if gone:
            logging.info('pictures: %d expired picture(s) removed', gone)
        return gone

    def run_forever(self, every=3600):
        while True:
            time.sleep(every)
            try:
                self.sweep()
            except Exception:
                logging.exception('picture sweep failed')

    def serve(self, ip='127.0.0.1', port=18791):
        """Starts the listener on its own thread and returns the thread (ready once it binds)."""
        server = ThreadingHTTPServer((ip, port), picture_handler_for(self))
        server.daemon_threads = True
        self.listening = (ip, port)
        logging.info('pictures: serving %s on %s:%s under /p/', self.folder.name, ip, port)
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 1}, daemon=True,
                                  name='picture-listener')
        thread.server = server
        thread.start()
        return thread


class QuickTunnel:
    """A Cloudflare quick tunnel (0.5.52) run by the helper itself: `cloudflared tunnel --url
    http://127.0.0.1:<picture port>` needs no account and no domain (the user 11/12: 「網域我是要
    全免費」, and about the address changing on every restart: 「這個我可以接受啊，因為推播開關燈照片
    我只是要最新的狀態而已」). The https://….trycloudflare.com address is read from cloudflared's
    log; `url` is None until it appears and again whenever cloudflared ends, and cloudflared is
    started again after `restart_after` seconds (a new address). The child is tied to this
    process with a Windows job object, so a helper killed by `schtasks /End` (a restart, an
    upgrade) takes its cloudflared with it; leftovers from before that are ended at start.
    Only the address and cloudflared's errors go to the log (its other lines name this PC's
    addresses)."""

    ADDRESS = re.compile(r'https://[a-z0-9-]+\.trycloudflare\.com')

    def __init__(self, exe, target, popen=None, restart_after=15.0, sleep=time.sleep):
        self.exe, self.target = str(exe), str(target)
        self.popen, self.restart_after, self.sleep = popen or self.start_process, float(restart_after), sleep
        self.lock = threading.Lock()
        self.url = None
        self.process = None
        self.starts = 0
        self.ready = threading.Event()  # set when an address is known, cleared when it is lost
        self.stopped = False

    def command(self):
        return [self.exe, 'tunnel', '--url', self.target, '--no-autoupdate']

    @staticmethod
    def start_process(command):
        import subprocess
        return subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))

    def current(self):
        """The tunnel's https address, or None while there is none (PictureStore's base_url)."""
        with self.lock:
            return self.url

    def run_forever(self):
        self.end_leftovers()
        while not self.stopped:
            self.starts += 1
            try:
                process = self.popen(self.command())
            except OSError as exc:
                logging.warning('tunnel: cloudflared could not start (%s); again in %.0f s', exc, self.restart_after)
                self.sleep(self.restart_after)
                continue
            self.process = process
            keep_child_with_us(process)
            self.watch(process)
            code = process.wait()
            process.stderr.close()
            with self.lock:
                self.url = None
            self.ready.clear()
            if self.stopped:
                break
            logging.warning('tunnel: cloudflared ended (%s); again in %.0f s', code, self.restart_after)
            self.sleep(self.restart_after)

    def watch(self, process):
        """Reads cloudflared's log until it ends: the address once it appears, errors as warnings."""
        for raw in process.stderr:
            line = raw.decode('utf-8', 'replace').rstrip()
            found = self.ADDRESS.search(line)
            if found and not self.current():
                with self.lock:
                    self.url = found.group(0)
                self.ready.set()
                logging.info('tunnel: up at %s', self.url)
            elif ' ERR ' in line:
                logging.warning('tunnel: %s', line.split(' ERR ', 1)[1][:300])

    def stop(self):
        self.stopped = True
        process = self.process
        if process is not None and process.poll() is None:
            process.terminate()

    def end_leftovers(self):
        """Ends cloudflared processes pointed at our target that an earlier helper left behind
        (before the job object there was no tie; also a helper that died in a way the job did not
        cover). Windows only, best effort."""
        if os.name != 'nt':
            return
        import subprocess
        script = ("Get-CimInstance Win32_Process -Filter \"Name='cloudflared.exe'\" | "
                  "Where-Object { $_.CommandLine -like '*--url*' -and $_.CommandLine -like ('*' + $env:TUNNEL_TARGET + '*') } | "
                  "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $_.ProcessId }")
        try:
            done = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                                  capture_output=True, timeout=30, env=dict(os.environ, TUNNEL_TARGET=self.target),
                                  creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            left = done.stdout.decode('utf-8', 'replace').split()
            if left:
                logging.info('tunnel: ended %d leftover cloudflared process(es)', len(left))
        except (OSError, subprocess.SubprocessError) as exc:
            logging.warning('tunnel: could not look for leftover cloudflared: %s', exc)


def keep_child_with_us(process):
    """Puts `process` in a job object that kills it when this process ends (Windows; the handle
    is kept on the process). Returns whether it worked."""
    if os.name != 'nt':
        return False
    try:
        kernel = ctypes.windll.kernel32

        class BasicLimits(ctypes.Structure):
            _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64),
                        ('LimitFlags', ctypes.c_uint32), ('MinimumWorkingSetSize', ctypes.c_size_t),
                        ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', ctypes.c_uint32),
                        ('Affinity', ctypes.c_size_t), ('PriorityClass', ctypes.c_uint32), ('SchedulingClass', ctypes.c_uint32)]

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ('ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount',
                                                              'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [('BasicLimitInformation', BasicLimits), ('IoInfo', IoCounters), ('ProcessMemoryLimit', ctypes.c_size_t),
                        ('JobMemoryLimit', ctypes.c_size_t), ('PeakProcessMemoryUsed', ctypes.c_size_t), ('PeakJobMemoryUsed', ctypes.c_size_t)]

        kernel.CreateJobObjectW.restype = ctypes.c_void_p
        kernel.SetInformationJobObject.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        kernel.AssignProcessToJobObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        job = kernel.CreateJobObjectW(None, None)
        if not job:
            return False
        limits = ExtendedLimits()
        limits.BasicLimitInformation.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):  # JobObjectExtendedLimitInformation
            return False
        if not kernel.AssignProcessToJobObject(job, ctypes.c_void_p(int(process._handle))):
            logging.warning('tunnel: the child could not be tied to this process (error %d)', ctypes.get_last_error() or kernel.GetLastError())
            return False
        process.job = job  # the handle must stay open for as long as we live
        return True
    except (AttributeError, OSError, ValueError) as exc:
        logging.warning('tunnel: job object failed: %s', exc)
        return False


class GitPictures:
    """Pictures for LINE pushed to a branch of a public GitHub repository (0.5.53; the user
    11/12, after the company PC's LINE turned out to fetch nothing through a tunnel, nor from
    Wikimedia, while raw.githubusercontent.com is reachable there and GCS needs a billing
    account): `notify.pictures.git` = {"url": "https://github.com/<owner>/<repo>.git", "branch":
    "pictures", "name": "<committer>", "email": "<committer email>"}. The branch is cloned once
    (shallow, that branch only) next to config.json; each picture is committed under a random
    name and pushed, and LINE gets https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<name>
    (`raw_base` overrides that for another host). git uses this PC's stored GitHub credential
    (Git Credential Manager), so no token lives in config.json. Once a day pictures older than
    `keep_days` are removed, and since git keeps history, the branch is rewritten from scratch
    (an orphan commit holding what is left, pushed with --force): nothing older than keep_days
    stays reachable by branch. Anything that fails raises OSError: LINE then gets ntfy's URL."""

    NAME = re.compile(r'(\d{8}T\d{6}Z)-[A-Za-z0-9_-]{16}\.jpg')

    def __init__(self, folder, url, branch='pictures', raw_base=None, keep_days=7, name='desk-remote-helper',
                 email='desk-remote-helper@localhost', git='git', clock=time.time, run=None):
        self.folder, self.url, self.branch = Path(folder), str(url), str(branch)
        self.keep = float(keep_days) * 86400
        self.name, self.email, self.git, self.clock = name, email, git, clock
        self.raw_base = (raw_base or self.github_raw(self.url, self.branch)).rstrip('/')
        self.run = run or self.run_git
        self.lock = threading.Lock()
        self.swept = 0.0  # when sweep() last looked (at most once a day)

    @staticmethod
    def github_raw(url, branch):
        found = re.fullmatch(r'https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?', url.strip())
        if not found:
            raise ValueError('notify.pictures.git.raw_base is needed for a repository not on github.com')
        return f'https://raw.githubusercontent.com/{found.group(1)}/{found.group(2)}/{branch}'

    def run_git(self, args, cwd):
        """Runs git with `args` in `cwd`; its stdout, or OSError with its stderr."""
        import subprocess
        try:
            done = subprocess.run([self.git, '-c', f'user.name={self.name}', '-c', f'user.email={self.email}'] + list(args),
                                  cwd=str(cwd), capture_output=True, timeout=120,
                                  creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        except (OSError, subprocess.SubprocessError) as exc:
            raise OSError(f'git {args[0]}: {exc}') from None
        if done.returncode != 0:
            raise OSError(f'git {args[0]} failed ({done.returncode}): {done.stderr.decode("utf-8", "replace").strip()[-300:]}')
        return done.stdout.decode('utf-8', 'replace')

    def ensure(self):
        """Clones the branch when the folder is not a clone yet."""
        if (self.folder / '.git').exists():
            return
        self.folder.parent.mkdir(parents=True, exist_ok=True)
        self.run(['clone', '-q', '--branch', self.branch, '--single-branch', '--depth', '1', self.url, str(self.folder)],
                 self.folder.parent)
        logging.info('pictures: cloned the %s branch', self.branch)

    def put(self, data):
        """Commits and pushes `data` (JPEG bytes) under a new random name; returns its raw URL."""
        stamp = datetime.fromtimestamp(self.clock(), UTC).strftime('%Y%m%dT%H%M%SZ')
        name = f'{stamp}-{secrets.token_urlsafe(12)}.jpg'
        with self.lock:
            self.ensure()
            # Start from what origin has (another writer, or a rewrite from elsewhere, would
            # otherwise make the push fail as non-fast-forward).
            self.run(['fetch', '-q', '--depth', '1', 'origin', self.branch], self.folder)
            self.run(['reset', '-q', '--hard', 'FETCH_HEAD'], self.folder)
            (self.folder / name).write_bytes(data)
            self.run(['add', '--', name], self.folder)
            self.run(['commit', '-q', '-m', 'picture'], self.folder)
            self.run(['push', '-q', 'origin', f'HEAD:{self.branch}'], self.folder)
        self.sweep()
        return f'{self.raw_base}/{name}'

    def expired(self, now=None):
        now = self.clock() if now is None else now
        if not self.folder.is_dir():
            return []
        gone = []
        for path in self.folder.iterdir():
            found = self.NAME.fullmatch(path.name)
            if not found:
                continue
            when = datetime.strptime(found.group(1), '%Y%m%dT%H%M%SZ').replace(tzinfo=UTC).timestamp()
            if now - when > self.keep:
                gone.append(path.name)
        return sorted(gone)

    def sweep(self, now=None, force=False):
        """Once a day: removes expired pictures and rewrites the branch without them. Returns how
        many were removed (0 when nothing expired or it is not time yet)."""
        now = self.clock() if now is None else now
        if not force and now - self.swept < 86400:
            return 0
        self.swept = now
        gone = self.expired(now)
        if not gone:
            return 0
        with self.lock:
            for name in gone:
                try:
                    (self.folder / name).unlink()
                except FileNotFoundError:
                    pass
            self.run(['checkout', '-q', '--orphan', 'fresh-pictures'], self.folder)
            self.run(['add', '-A'], self.folder)
            self.run(['commit', '-q', '-m', f'{len(gone)} picture(s) older than {self.keep / 86400:g} days removed'], self.folder)
            self.run(['branch', '-M', self.branch], self.folder)
            self.run(['push', '-q', '--force', 'origin', f'{self.branch}:{self.branch}'], self.folder)
        logging.info('pictures: %d expired picture(s) removed, branch rewritten', len(gone))
        return len(gone)

    def run_forever(self, every=3600):
        while True:
            time.sleep(every)
            try:
                self.sweep()
            except Exception as exc:
                logging.warning('picture sweep failed: %s', exc)


def pictures_from_config(cfg, folder):
    """(PictureStore, QuickTunnel or None) from `notify.pictures`, or (None, None) when it is not
    configured. Either a fixed `base_url` (https) or `cloudflared` (the path to cloudflared.exe:
    a quick tunnel to this PC's picture listener, `port` 18791) must be given; or `git` (see
    GitPictures), which needs no listener: then (GitPictures, None)."""
    settings = (cfg.get('notify') or {}).get('pictures')
    if not settings:
        return None, None
    where = Path(settings['dir']) if settings.get('dir') else Path(folder) / 'pictures'
    keep = float(settings.get('keep_days', 7))
    if settings.get('git'):
        git = settings['git']
        if not git.get('url'):
            raise ValueError('notify.pictures.git.url is needed')
        if not settings.get('dir'):
            where = Path(folder) / 'pictures-git'  # not the listener's folder (0.5.52 left pictures there)
        return GitPictures(where, git['url'], branch=git.get('branch') or 'pictures', raw_base=git.get('raw_base'),
                           keep_days=keep, name=git.get('name') or 'desk-remote-helper',
                           email=git.get('email') or 'desk-remote-helper@localhost', git=git.get('exe') or 'git'), None
    ip, port = str(settings.get('bind_ip') or '127.0.0.1'), int(settings.get('port') or 18791)
    if settings.get('base_url'):
        base = str(settings['base_url'])
        if not base.startswith('https://'):
            raise ValueError('notify.pictures.base_url must be an https:// address (LINE takes no other)')
        return PictureStore(where, base, keep_days=keep), None
    if settings.get('cloudflared'):
        exe = Path(settings['cloudflared'])
        if not exe.is_file():
            raise ValueError(f'notify.pictures.cloudflared is not a file: {exe}')
        tunnel = QuickTunnel(exe, f'http://{ip}:{port}')
        return PictureStore(where, tunnel.current, keep_days=keep), tunnel
    raise ValueError('notify.pictures needs base_url or cloudflared')


def picture_handler_for(store):
    """GET/HEAD /p/<name> with Content-Type, Content-Length, Accept-Ranges and a single byte
    range (206 / 416); /health answers ok; anything else 404. No directory listing, no auth: the
    names are the secret."""

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        server_version, sys_version = 'desk-remote', ''

        def handle(self):
            try:
                super().handle()
            except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, TimeoutError):
                pass

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.answer(True)

        def do_HEAD(self):
            self.answer(False)

        def answer(self, with_body):
            try:
                self.respond(with_body)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            except Exception:
                logging.exception('picture request failed')
                self.plain(500, b'error')

        def log_request(self, code='-', size='-'):
            # Who fetches the pictures (11/12: the PC's LINE showed nothing, the phone's did; this
            # tells whether the PC's client asked at all). Cloudflare adds the real address.
            logging.info('pictures: %s %s -> %s from %s (%s)', self.command, self.path[:48], code,
                         self.headers.get('Cf-Connecting-Ip') or self.client_address[0],
                         (self.headers.get('User-Agent') or '-')[:80])

        def plain(self, code, body, extra=None):
            self.send_response(code)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)

        def respond(self, with_body):
            parts = urllib.parse.urlsplit(self.path).path.strip('/').split('/')
            if parts == ['health']:
                return self.plain(200, b'ok')
            if len(parts) != 2 or parts[0] != 'p':
                return self.plain(404, b'not found')
            path = store.path(urllib.parse.unquote(parts[1]))
            if path is None:
                return self.plain(404, b'not found')
            try:
                data = path.read_bytes()
                stamp = path.stat().st_mtime
            except OSError:
                return self.plain(404, b'not found')
            size = len(data)
            start, end = 0, size - 1
            status = 200
            wanted = self.headers.get('Range')
            if wanted:
                span = parse_byte_range(wanted, size)
                if span is None:
                    return self.plain(416, b'range not satisfiable', {'Content-Range': f'bytes */{size}'})
                start, end = span
                status = 206
            body = data[start:end + 1]
            self.send_response(status)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Cache-Control', store.CACHE)
            self.send_header('Last-Modified', self.date_time_string(stamp))
            self.send_header('X-Content-Type-Options', 'nosniff')
            if status == 206:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            if with_body:
                self.wfile.write(body)

    return Handler


def parse_byte_range(header, size):
    """(first, last) for a single `bytes=` range of a `size`-byte file, or None when the header
    asks for nothing inside it (several ranges count as the first one)."""
    found = re.fullmatch(r'\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*(?:,.*)?', header or '', re.S)
    if not found or size <= 0:
        return None
    first, last = found.group(1), found.group(2)
    if first == '' and last == '':
        return None
    if first == '':                       # the last N bytes
        count = int(last)
        if count == 0:
            return None
        return max(size - count, 0), size - 1
    start = int(first)
    if start >= size:
        return None
    end = size - 1 if last == '' else min(int(last), size - 1)
    if end < start:
        return None
    return start, end


class AuthGate:
    """Shared token, constant-time compare. Five wrong tokens within ten minutes lock every /v1
    request for ten minutes, even with the right token. Logged, not sent to the phone (only what
    waits on the user's approval is, 11/02)."""

    MAX_FAILURES, LOCK = 5, 600

    def __init__(self, token, clock=time.monotonic):
        self.token = token.encode('utf-8')
        self.clock = clock
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
            return 429, error('locked-out', '密碼錯誤太多次，已暫停 10 分鐘')
        return 401, error('unauthorized', '連線密碼不正確')


def error(code, message):
    return {'ok': False, 'error': code, 'message': message}


# ---------------------------------------------------------------------------------------------
# The hub: sources, cached transcripts, state.


_disk_cache = [0.0, None]


def helper_on_disk(path=None, now=None):
    """VERSION in the helper file on disk (read at most once a minute): newer than the running
    one when a new helper was copied in but not started yet (11/01, the phone showed 0.5.29)."""
    now = time.monotonic() if now is None else now
    if path is None and _disk_cache[1] is not None and now - _disk_cache[0] < 60:
        return _disk_cache[1]
    try:
        text = Path(path or __file__).read_text(encoding='utf-8')
    except OSError:
        return None
    found = re.search(r"^VERSION = '([0-9.]+)'", text, re.M)
    version = found.group(1) if found else None
    if path is None:
        _disk_cache[:] = [now, version]
    return version


def restart_helper(worker=None, task='DeskRemoteHelper'):
    """Exits, and starts the helper's logon task again 5 seconds later. The starter is created
    through WMI, so it is not a child of this task and is not ended with it."""
    import base64
    import subprocess
    inner = base64.b64encode(f'Start-Sleep -Seconds 5; Start-ScheduledTask -TaskName {task}'.encode('utf-16-le')).decode('ascii')
    line = f'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {inner}'
    subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                    f"Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{{CommandLine='{line}'}} | Out-Null"],
                   capture_output=True, timeout=30, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    logging.info('restarting into the helper on disk (%s)', helper_on_disk())
    if worker is not None:
        worker.stop()
    os._exit(0)


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
        self.ram = None                   # MemoryWatch: the commit charge and what was freed (0.5.30)
        self.disk_version = helper_on_disk  # the helper version installed on disk, maybe newer than this one
        self.restart = None               # () -> None: start the helper again (it exits), from the phone
        self.clipboard = None             # ClipboardSync when a shared clipboard folder is configured (0.5.40)
        self.camera = None                # CameraFeed: the webcam, open only while the phone's 看鏡頭 page is (0.5.41)
        self.lan = None                   # (ip, port) where the helper also listens on the local network (0.5.44)
        self.light = None                 # LightWatch: a region of the camera picture watched for a light (0.5.45)
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
        extra = ((['elevate'] if self.elevate is not None else []) + (['screen'] if self.screen is not None else [])
                 + (['restart'] if self.restart is not None else [])
                 + (['clipboard'] if self.clipboard is not None else [])
                 + (['camera'] if self.camera is not None else [])
                 + (['light'] if self.light is not None else []))
        disk = self.disk_version()
        newer = disk if disk and version_key(disk) > version_key(VERSION) else None
        lan_host, lan_port = self.lan or (None, None)
        return {'ok': True, 'pc': {'name': self.pc_name, 'helperVersion': VERSION, 'helperUpdate': newer,
                                   'lanHost': lan_host, 'lanPort': lan_port},
                'capabilities': self.capabilities + extra,
                'apps': apps, 'presence': {'idleSeconds': presence.get('idleSeconds'), 'locked': presence.get('locked'),
                                           'uac': bool(presence.get('uac'))},
                'warnings': warnings, 'elevate': elevate, 'usage': self.usage(), 'models': choices('model', 'models'),
                'efforts': choices('effort', 'efforts'), 'modes': choices('mode', 'modes'), 'stop': stop,
                'popups': self.popups(), 'recent': self.recent(), 'fast': fast, 'versions': self.versions(),
                'memory': self.ram.snapshot() if self.ram is not None else None,
                'camera': {'on': self.camera.on()} if self.camera is not None else None,
                'light': self.light.snapshot() if self.light is not None else None}

    def recent(self, limit=6):
        """The most recently written conversations of all apps together, newest first, for the
        phone's PC list to link straight into (read at most every 10 seconds). 0.5.58 (the user
        11/12: 「首頁這邊都留最新對話就好，不一定要 Codex 三個、Claude 三個」): no share per app
        any more, so an app nobody used lately drops off the list."""
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
            out += [dict(row, app=app) for row in rows]
        out.sort(key=lambda r: r['updatedAt'], reverse=True)
        out = out[:limit]
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
        out['claude'] = with_reset_times(merge_claude_usage(out.get('claude'), button, seen.get('usageAt'), time.time(),
                                                            seen.get('card'), seen.get('cardAt')))
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

    def image(self, app, session_id, image_id):
        transcript = self.transcript(app, session_id)
        return transcript.image(image_id) if transcript is not None and IMAGE_ID.match(image_id) else None

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


def _kernel32():
    from ctypes import wintypes
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    k32.GetProcessHandleCount.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    return k32


def commit_charge():
    """(bytes in use, limit) of Windows' commit charge: what a handle leak fills up while no
    process's own memory shows it (Steam 11/01: 175.8 of 177.9 GB, private memory ~15 GB)."""
    from ctypes import wintypes

    class Status(ctypes.Structure):
        _fields_ = [('dwLength', wintypes.DWORD), ('dwMemoryLoad', wintypes.DWORD), ('ullTotalPhys', ctypes.c_uint64),
                    ('ullAvailPhys', ctypes.c_uint64), ('ullTotalPageFile', ctypes.c_uint64),
                    ('ullAvailPageFile', ctypes.c_uint64), ('ullTotalVirtual', ctypes.c_uint64),
                    ('ullAvailVirtual', ctypes.c_uint64), ('ullAvailExtendedVirtual', ctypes.c_uint64)]
    status = Status(dwLength=ctypes.sizeof(Status))
    if not _kernel32().GlobalMemoryStatusEx(ctypes.byref(status)):
        return None
    return status.ullTotalPageFile - status.ullAvailPageFile, status.ullTotalPageFile


class _MemoryCounters(ctypes.Structure):
    _fields_ = [('cb', ctypes.c_uint32), ('PageFaultCount', ctypes.c_uint32)] + [
        (name, ctypes.c_size_t) for name in ('PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage',
                                         'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage',
                                         'PagefileUsage', 'PeakPagefileUsage', 'PrivateUsage')]


def _process_info(k32, pid, name=False):
    """(private bytes, handles[, image path]) of one process, or None when it cannot be opened."""
    from ctypes import wintypes
    handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return None
    try:
        counters = _MemoryCounters(cb=ctypes.sizeof(_MemoryCounters))
        count = wintypes.DWORD()
        psapi = ctypes.WinDLL('psapi')
        psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(_MemoryCounters), wintypes.DWORD]
        if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            return None
        k32.GetProcessHandleCount(handle, ctypes.byref(count))
        if not name:
            return counters.PrivateUsage, count.value
        buffer, size = ctypes.create_unicode_buffer(1024), wintypes.DWORD(1024)
        path = buffer.value if k32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)) else ''
        return counters.PrivateUsage, count.value, path
    finally:
        k32.CloseHandle(handle)


def process_size(pid):
    """(private bytes, handle count) of one process, or None."""
    return _process_info(_kernel32(), pid)


def process_list():
    """[{pid, name, path, bytes, handles}] of every process this user can look at."""
    from ctypes import wintypes
    pids, needed = (wintypes.DWORD * 8192)(), wintypes.DWORD()
    if not ctypes.WinDLL('psapi').EnumProcesses(pids, ctypes.sizeof(pids), ctypes.byref(needed)):
        return []
    k32, out = _kernel32(), []
    for pid in pids[:needed.value // ctypes.sizeof(wintypes.DWORD)]:
        info = _process_info(k32, pid, name=True) if pid else None
        if info:
            out.append({'pid': pid, 'name': Path(info[2]).stem.lower() if info[2] else '', 'path': info[2],
                        'bytes': info[0], 'handles': info[1]})
    return out


def close_steam(processes, wait=60, sleep=time.sleep, run=None, kill=None):
    """Asks Steam to shut down normally, then ends it if it is still there after `wait` seconds;
    it is not started again (the Steam guard on the home PC does the same). Returns how it went."""
    import subprocess
    run = run or (lambda args: subprocess.Popen(args, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)))
    kill = kill or (lambda: subprocess.run(['taskkill', '/F', '/IM', 'steam.exe', '/IM', 'steamwebhelper.exe'],
                                           capture_output=True, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)))
    steam = next((p for p in processes() if p['name'] == 'steam'), None)
    if steam is None:
        return 'gone'
    run([steam['path'], '-shutdown'])
    for _ in range(max(1, wait // 5)):
        sleep(5)
        if not any(p['name'] == 'steam' for p in processes()):
            return 'shut-down'
    kill()
    return 'ended'


class MemoryWatch:
    """Windows' commit charge, once a minute (asked 11/01 after Steam's handle leak filled it and
    the screen flashed). Near the limit it frees what is known to be safe to restart: Steam
    holding a leak's worth of handles (asked to shut down; not started again) and this helper's
    own screen worker. Anything else is only named on the phone's PC page, without a notification
    (11/02: only what waits on the user's approval is sent): the user decides what to close
    (games, the desktop apps and the miners are never ended from here)."""

    HIGH, CLEAR = 85, 75             # percent of the limit: act at HIGH, all clear below CLEAR
    STEAM_HANDLES = 100_000          # Steam normally holds a few thousand; 2.47 million when it leaked
    WORKER_BYTES, WORKER_HANDLES = 600 * 2 ** 20, 15_000

    def __init__(self, pc_name, worker=None, charge=commit_charge, processes=process_list,
                 steam=close_steam, clock=time.monotonic, wall=None):
        self.pc_name, self.worker = pc_name, worker
        self.charge, self.processes, self.steam = charge, processes, steam
        self.clock, self.wall = clock, wall or (lambda: datetime.now(UTC))
        self.checked = None
        self.reading = None              # (used, limit) at the last check
        self.top = []
        self.action = self.action_at = None
        self.told = False
        self.closing = False
        self.lock = threading.Lock()

    def snapshot(self):
        with self.lock:
            if not self.reading:
                return None
            used, limit = self.reading
            percent = round(used * 100 / limit) if limit else 0
            return {'percent': percent, 'usedGB': round(used / 2 ** 30, 1), 'limitGB': round(limit / 2 ** 30, 1),
                    'high': percent >= self.HIGH, 'top': list(self.top) if percent >= self.HIGH else [],
                    'action': self.action, 'actionAt': self.action_at}

    def did(self, text):
        with self.lock:
            self.action, self.action_at = text, self.wall().isoformat(timespec='seconds')
        logging.warning('memory: %s', text)

    def step(self, now=None):
        now = self.clock() if now is None else now
        if self.checked is not None and now - self.checked < 60:
            return
        self.checked = now
        if self.worker is not None:
            grown = self.worker.recycle_if_big(self.WORKER_BYTES, self.WORKER_HANDLES)
            if grown:
                self.did(f'小幫手的畫面讀取程式長到 {grown[0] / 2 ** 20:.0f} MB、{grown[1]:,} 個 handle，已自動重開')
        reading = self.charge()
        if not reading or not reading[1]:
            return
        with self.lock:
            self.reading = reading
        percent = reading[0] * 100 / reading[1]
        if percent < self.CLEAR:
            self.told = False
            with self.lock:
                self.top = []
            return
        if percent < self.HIGH:
            return
        found = self.processes()
        top = sorted(found, key=lambda p: p['bytes'], reverse=True)[:3]
        leaky = sorted(found, key=lambda p: p['handles'], reverse=True)[:2]
        shown = {p['pid']: p for p in top + leaky}.values()
        with self.lock:
            self.top = [{'name': p['name'], 'gb': round(p['bytes'] / 2 ** 30, 1), 'handles': p['handles']} for p in shown]
        steam = next((p for p in found if p['name'] == 'steam'), None)
        if steam and steam['handles'] >= self.STEAM_HANDLES and not self.closing:
            self.closing = True
            handles = steam['handles']

            def run():
                try:
                    how = self.steam(self.processes)
                    after = self.charge()
                    left = f'，記憶體回到 {after[0] * 100 / after[1]:.0f}%' if after and after[1] else ''
                    self.did(f"Steam 握著 {handles:,} 個 handle（漏記憶體），已自動{'關掉' if how == 'shut-down' else '結束'}"
                             f'（不會自己再開）{left}')
                finally:
                    self.closing = False
            threading.Thread(target=run, daemon=True).start()
            return
        if self.closing or self.told:
            return
        self.told = True
        names = '、'.join(f"{p['name']} {p['bytes'] / 2 ** 30:.1f} GB" for p in top)
        logging.warning('memory: %.0f%% used, nothing safe to close; biggest: %s', percent, names)


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

    def recycle_if_big(self, max_bytes, max_handles, size=None):
        """Ends the worker between requests once it has grown past either limit; the next request
        starts a fresh one. It leaked to 1.9 GB and 29,000 handles in six hours (home PC 11/01).
        Returns (bytes, handles) when it was recycled, otherwise None."""
        if not self.lock.acquire(blocking=False):
            return None  # A request is running: next time.
        try:
            if self.process is None or self.process.poll() is not None:
                return None
            found = (size or process_size)(self.process.pid)
            if not found or (found[0] < max_bytes and found[1] < max_handles):
                return None
            self.stop()
            return found
        finally:
            self.lock.release()

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
        answer = self.worker.request(command)
        if isinstance(answer, dict) and answer.get('front'):
            # Windows refused the plain switch (a full-screen game in front, home PC 11/14).
            logging.info('%s %s: took the foreground by %s', command.get('cmd'), app, answer['front'])
        return answer

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
        answer = self.ask(app, cmd='send', doc=doc, text=text, images=list(images or []))
        # Codex at work kept the message in its queue (the card with 引導 follows): read by do_send.
        self.queued = bool(answer.get('queued'))
        return answer.get('replaced') or None

    def new_send(self, app, button, text, model=None, effort=None, images=None):
        """Opens a new conversation, picks `model` and `effort` on its empty page when given,
        then pastes each of `images` (file paths) and sends `text`."""
        self.ask(app, cmd='new_send', name=button, text=text, model=model or '', effort=effort or '',
                 images=list(images or []))

    def popups(self):
        """Windows on the desktop waiting for an answer: [{hwnd, title, process, text, buttons}]."""
        found = self.worker.request({'cmd': 'popups', 'codex': self.strings.get('codex') or {}}).get('popups') or []
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
                                         'button': button, 'page': bool(popup.get('page')), 'queue': bool(popup.get('queue')),
                                         'codex': self.strings.get('codex') or {}}).get('gone'))

    def answer(self, app, doc, decision, expect):
        return self.ask(app, cmd='answer', doc=doc, decision=decision, expect=expect).get('how')

    def answer_question(self, app, doc, question, answers):
        """Claude: turns on each chosen option (and 其他 with its text) in the question's card, then
        提交. Codex: picking the option sends it by itself; words go in the card's box, then 傳送."""
        items = [{'question': q['question'], 'labels': a.get('labels') or [], 'other': a.get('other') or ''}
                 for q, a in zip(question['questions'], answers)]
        return self.ask(app, cmd='choose', doc=doc, questions=items).get('how')

    def set_model(self, app, doc, label):
        """Picks `label` in the model menu of the open conversation; 'already' if it was chosen."""
        return self.ask(app, cmd='model', doc=doc, model=label).get('how')

    def set_effort(self, app, doc, label):
        """Claude: the effort submenu of the model menu. Codex: the slider in its model menu,
        clicked at the effort's tick (helper 0.5.36)."""
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
        self.screen_in_use, self.card_held = screen_in_use, False  # the card waits while a video plays
        self.board = None       # IdleBoard: the PC idle longest reads the card (0.5.43)
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
        while someone is at the PC, and never on a locked one). Hands off the keyboard are not
        always away: a video playing or a full-screen app keeps the card closed too, and it is
        read as soon as that ends (11/10: the card blinked every five minutes over a video)."""
        if not (self.hub.strings.get(app) or {}).get('usage_card') or not hasattr(self.driver, 'usage_card'):
            return
        presence = self.hub.presence.snapshot()
        idle, locked = presence.get('idleSeconds'), presence.get('locked')
        if idle is None:
            return
        busy = not locked and idle >= self.card_idle and self.screen_in_use()
        if self.board is not None:
            self.board.note(idle, locked, busy)
        if self.last_card_check is not None and time.monotonic() - self.last_card_check < self.card_every:
            return
        if locked or idle < self.card_idle:
            return
        if busy:
            self.hold_card('a video plays or a full-screen app is in front')
            return
        other = self.board.idle_longer(idle) if self.board is not None else None
        if other:
            self.hold_card(f'{other} is idle longer and reads it')
            return
        self.card_held = False
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

    def hold_card(self, why):
        """Logs once per spell why the card is left closed."""
        if not self.card_held:
            logging.info('usage card not read: %s', why)
        self.card_held = True

    def check_popups(self, notify=True):
        """A window that pops up and waits for an answer (a firewall question, found 10/29) keeps
        the desktop apps from coming to the front, so messages cannot be sent: list it for the phone
        and let it press one of the window's buttons. Only one asking for permission (a button in
        ui_strings' popups.permission) is sent, once per window (11/02: notifications only for what
        waits on the user's approval). Returns the windows; `notify` False when the phone is
        already looking (it pressed the button that opened the window)."""
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
            elevated = bool(raw.get('elevated')) and not raw.get('page')
            text = str(raw.get('text') or '')[:600]
            if elevated:
                text = (text + '\n' + ELEVATED_HINT).strip()
            listed.append({'id': hashlib.sha256(key.encode('utf-8')).hexdigest()[:12], 'hwnd': raw.get('hwnd'),
                           'title': str(raw.get('title') or ''), 'process': str(raw.get('process') or ''),
                           'text': text, 'buttons': [str(b) for b in raw['buttons']][:8], 'page': bool(raw.get('page')),
                           'elevated': elevated, 'queue': bool(raw.get('queue'))})
        with self.lock:
            known = {p['id'] for p in self.popups}
            self.popups = listed
        # A question inside an app's page may be a menu or a question the person at the PC just
        # opened: told only when nobody is at the PC.
        presence = self.hub.presence.snapshot() if any(p['page'] for p in listed) else {}
        away = presence.get('locked') or (presence.get('idleSeconds') or 0) >= 60
        quiet = not notify or time.monotonic() < self.quiet_popups_until
        asks = (self.hub.strings.get('popups') or {}).get('permission') or []
        for popup in listed:
            permission = any(word in button for button in popup['buttons'] for word in asks)
            if popup['id'] not in known and not quiet and permission and (away or not popup['page']):
                name = popup['title'] or popup['process']
                detail = popup['text'].replace('\n', ' ')[:100] or popup['process']
                self.send(f'🪟 電腦跳出視窗在等你允許：{name}', f'{self.pc_name}・{detail}；打開桌面遙控選要按的按鈕', 4, ['window'],
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
                self.note(f'{APP_NAMES[app]} context at {percent}%', row['title'])

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
                    self.note(f'{APP_NAMES[app]} usage at {window["percent"]}%', f'{window["label"]} {reset}'.strip())
        self.usage_checked_once = True

    def send(self, title, message, priority, tags, click=None):
        """To the phone: only for what waits on the user's approval (a permission prompt, a
        question, UAC, a permission pop-up; asked 11/02). Everything else is shown on the phone's
        pages and goes through note()."""
        if self.notify:
            try:
                self.notify(title, message, priority, tags, click)
            except OSError:
                logging.exception('notification failed: %s', title)

    @staticmethod
    def note(what, detail=''):
        logging.info('not notified: %s %s', what, detail)

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
                found['claude'] = dict(found.get('claude') or {}, downloaded=downloaded,
                                       notice=f'新版 {downloaded} 已下載：到電腦上把 Claude 關掉再打開')
        codex_button = (self.current('codex') or {}).get('update')
        notify_only = (self.hub.strings.get('codex') or {}).get('update_notify') or []
        if codex_button in notify_only:
            # Shown after the version on the phone's PC page too, not only as a notification (11/01).
            found['codex'] = dict(found.get('codex') or {}, notice=f'有新版：到電腦上按 Codex 左下角的「{codex_button}」')
        with self.lock:
            self.versions = found
        claude = found.get('claude') or {}
        new = claude.get('pending') or claude.get('downloaded') or (claude['installed'] if claude.get('old') else None)
        if new and ('claude', new) not in self.update_told:
            self.update_told.add(('claude', new))
            how = 'restart button shown' if claude.get('pending') else 'needs a close and start'
            self.note(f'claude {new} waiting', how)
        codex = found.get('codex') or {}
        if codex_button in notify_only:
            # Codex's sidebar "update available" (home PC 11/01): only shown after the version, to
            # be done at the PC like Claude's (the user's choice 10/30; no notification since 11/02).
            if ('codex', codex_button) not in self.update_told:
                self.update_told.add(('codex', codex_button))
                self.note('codex update waiting', codex.get('running'))
            return
        for name in notify_only:
            self.update_told.discard(('codex', name))  # Gone: the next one is told again.
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
                self.note('codex did not start again after its update', version)
        elif tried is not None and now - tried > 180 and ('codex', version) not in self.update_told:
            self.update_told.add(('codex', version))
            self.note(f"codex still runs {codex['running']}", f'{version} installed')

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
                          'downloaded': info.get('downloaded'),  # ready in Claude's log, no button: done at the PC
                          'notice': info.get('notice')}  # what to do at the PC, shown after the version (0.5.30)
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
        if self.hub.ram is not None:
            self.hub.ram.step()
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
        code, body = self.take(kind, app, session_id, payload)
        if code >= 400 and kind in ('send', 'new'):
            # Refusals never reach the action log otherwise: a phone that only said "failed" left
            # nothing to read on the PC (home PC 11/14).
            logging.info('phone %s %s refused: %s %s', kind, app, code, body.get('error'))
        return code, body

    def take(self, kind, app, session_id, payload):
        force = bool(payload.get('force'))
        text = payload.get('text')
        images = []
        if kind in ('send', 'new') and (payload.get('image') is not None or payload.get('images') is not None):
            # One photo as `image` (App 0.5.5 and earlier), several as `images` (asked on 10/29);
            # a new conversation's first message too (0.5.60, the user 11/14: 「手機開新對話也要加
            # 上傳照片和語音那些功能」).
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
        if kind == 'new':
            # A new conversation may start with a model and effort (the phone's sheet, 11/8).
            for choice in ('model', 'effort'):
                key, what = choice_keys[choice]
                if payload.get(choice) and payload[choice] not in (strings.get(key) or []):
                    return 400, error('bad-request', f'沒有這個{what}')
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
                # The same id is the same message: answered with the first action, unless that one
                # failed. A failed send stopped before Enter, so the phone's 重試 runs it again
                # (until 0.5.62 it got the old failure back and nothing ran, home PC 11/14).
                if existing and existing['state'] != 'failed':
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
            elif exc.code in ('focus-failed', 'paste-failed', 'paste-failed-photos', 'no-prompt-box') and self.watcher.popup_list():
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
        """Logged only: the phone that asked shows how each action went (no notification for
        what the user did themselves, 10/27; none for its failures either since 11/02)."""
        if failed:
            logging.info('phone %s failed: %s', action['kind'], action['message'])

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

    @staticmethod
    def photo_files(action, paths):
        """Writes the action's photos to files only this user can read, appending each path to
        `paths` as it goes (the worker pastes from them)."""
        for image in action.get('images') or []:
            handle, path = tempfile.mkstemp(prefix='desk-remote-photo-', suffix='.img')
            paths.append(path)
            with os.fdopen(handle, 'wb') as out:
                out.write(image)

    @staticmethod
    def drop_photos(action, paths):
        """Removes the photo files right after pasting, and the photos from memory."""
        for path in paths:
            try:
                os.remove(path)
            except OSError:
                logging.warning('could not remove the photo file')
        action['images'] = []

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
            self.photo_files(action, paths)
            self.presence.begin_own()
            replaced = self.driver.send(app, info['doc'], text, paths)
        finally:
            self.presence.end_own()
            self.drop_photos(action, paths)
        if replaced:
            # The phone's message always wins over unsent text in the box (the user's rule 10/31);
            # only its length is logged, never the text.
            logging.info('send %s replaced %d unsent characters in the box', app, len(replaced))
        if getattr(self.driver, 'queued', False):
            # Codex keeps a message typed while it works in a queue until the turn ends (home PC
            # 11/6): the card with its 引導 button is listed at once, so the phone can hand it in now.
            self.watcher.check_popups(notify=False)
            message = f'已送出，但 Codex 正在工作，訊息先排在佇列裡：要馬上插話，按對話上方「{CODEX_QUEUE_TITLE}」卡片的「引導」'
            if replaced:
                message += f'（覆蓋了電腦輸入框裡原本沒送出的 {len(replaced)} 個字）'
            self.update(action, state='done', verified=True, message=message)
            return
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
        if popup.get('elevated'):
            return self.press_elevated(action, popup, button)
        self.presence.begin_own()  # a window without UI Automation buttons is clicked
        gone = self.driver.press_popup(popup, button)
        self.watcher.check_popups()
        if popup.get('queue'):
            what = '排隊的訊息已交給 Codex 目前的工作' if button == '引導' else '排隊的訊息已刪除'
            message = f'已在電腦上按「{button}」，{what}' if gone else f'已按「{button}」，但排隊的訊息還在'
        elif self.presence.snapshot().get('locked'):
            # A secure-desktop prompt (UAC) reads as locked; nothing on it can be pressed from here.
            message = f'已按「{button}」，接著跳出系統管理員確認（UAC），手機無法代按，請到電腦上按'
        elif gone:
            message = f'已在電腦上按「{button}」，視窗已關閉'
        else:
            message = f'已按「{button}」，但視窗還在（可能要管理員權限，或還有下一步）'
        self.update(action, state='done', verified=bool(gone), message=message)

    def press_elevated(self, action, popup, button):
        """An administrator's window (an installer past UAC) refuses this user's press (UIPI): the
        elevated companion presses it instead, once the person approves, on the PC's own approval
        window or on the phone (the user 11/5: at the PC, reaching for the phone is odd)."""
        title = popup['title'] or popup['process']
        if self.hub.elevate is None:
            raise ActionError('elevated-window', '')
        content = elevated_press_script(popup['hwnd'], popup['title'], button)
        try:
            answer = self.hub.elevate.request({'op': 'request', 'kind': 'script', 'name': f'按「{button}」：{title}',
                                               'content': content, 'cwd': '', 'timeout': 60})
        except (OSError, ValueError):
            raise ActionError('elevate-unavailable', '')
        if not answer.get('ok'):
            logging.warning('elevated press of %s refused: %s', button, answer.get('error'))
            raise ActionError('elevate-refused', str(answer.get('error') or ''))
        logging.info('elevated window %s: asked the companion to press %s (%s)', title, button, answer.get('id'))
        self.hub.elevate.poll()
        self.update(action, state='done', verified=False,
                    message=f'這是系統管理員程式的視窗，手機直接按不到；已請提權夥伴代按「{button}」，'
                            '在電腦上跳出的核准視窗按「允許」、或在手機的管理員指令頁核准後就會按')

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
        # Codex writes the effort to its rollout only with the next reply (as the model).
        later = '（下一則回覆起使用）' if app == 'codex' else ''
        self.update(action, state='done', verified=True,
                    message=f'本來就是 {label}' if how == 'already' else f'推理強度已切換為 {label}{later}')

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
        model, effort = action.get('model') or None, action.get('effort') or None
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
        photos = len(action.get('images') or [])
        paths = []
        try:
            self.photo_files(action, paths)
            self.driver.new_send(app, button, text, model, effort, paths)
        finally:
            self.drop_photos(action, paths)
        self.presence.end_own()
        picked = '、'.join(part for part in ((f'模型 {model}' if model else ''), (f'推理強度 {effort}' if effort else '')) if part)
        opened = f'已開新對話（{picked}）' if picked else '已開新對話'
        if photos:
            opened += f'，附 {photos} 張照片'
        self.update(action, message='已送出，等待新對話出現')
        deadline = self.clock() + self.verify_seconds
        while True:
            fresh = [row for row in source.list_sessions(50) if row['id'] not in before]
            if fresh:
                row = fresh[0]
                self.update(action, state='done', verified=True, sessionId=row['id'], title=row['title'],
                            message=opened)
                return
            if self.clock() >= deadline:
                self.update(action, state='done', verified=False,
                            message=f'已送出，但 {self.verify_seconds} 秒內清單還沒出現新對話')
                return
            time.sleep(0.5)


# Codex's queued message, as the phone's card is titled (ui_strings codex.queue_title).
CODEX_QUEUE_TITLE = 'Codex 排隊中的訊息'
ELEVATED_HINT = '（系統管理員程式的視窗：手機按的按鈕會交給提權夥伴代按，在電腦上或手機核准）'


def elevated_press_script(hwnd, title, button):
    """PowerShell the elevated companion runs, as an administrator, to press `button` in the
    window `hwnd` titled `title`: a window of an administrator's process (an installer past UAC,
    FlashPrint 11/5) refuses this user's clicks and UI Automation (UIPI), so the helper's own
    press did nothing. The button is found as a Win32 child window first (its text without the
    & and spaces; the installer's buttons are plain Button controls that UI Automation showed as
    panes, 11/5) and clicked with BM_CLICK, else through UI Automation by name. What the phone
    (or the PC's approval window) shows is exactly this."""
    def quoted(text):
        return "'" + str(text).replace("'", "''") + "'"
    return f"""# 桌面遙控：在系統管理員程式的視窗「{title}」按「{button}」（手機按不到這種視窗）
Add-Type -Namespace DeskPress -Name Win -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
public static string Norm(string s) {{ return s.Replace("&", "").Replace(" ", "").Trim(); }}
public static string Title(IntPtr h) {{ var t = new System.Text.StringBuilder(512); GetWindowText(h, t, 512); return t.ToString(); }}
public static IntPtr Find(IntPtr parent, string wanted) {{
  IntPtr found = IntPtr.Zero; string want = Norm(wanted);
  EnumChildWindows(parent, (h, l) => {{
    var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
    if (found == IntPtr.Zero && IsWindowVisible(h) && IsWindowEnabled(h) && Norm(Title(h)) == want
        && c.ToString().IndexOf("Button", StringComparison.OrdinalIgnoreCase) >= 0) found = h;
    return true; }}, IntPtr.Zero);
  return found;
}}
'@
$h = [IntPtr][int64]{int(hwnd)}
if (-not [DeskPress.Win]::IsWindow($h) -or [DeskPress.Win]::Title($h) -ne {quoted(title)}) {{ Write-Output '視窗已經不在了'; exit 2 }}
$b = [DeskPress.Win]::Find($h, {quoted(button)})
if ($b -ne [IntPtr]::Zero) {{
  [DeskPress.Win]::SendMessage($b, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # BM_CLICK
}} else {{
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $AE = [System.Windows.Automation.AutomationElement]
  $w = $AE::FromHandle($h)
  $e = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, {quoted(button)})))
  $p = $null
  if (-not $e -or -not $e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) {{ Write-Output '視窗裡找不到這個按鈕'; exit 3 }}
  $p.Invoke()
}}
Start-Sleep -Milliseconds 800
$still = [DeskPress.Win]::IsWindow($h) -and [DeskPress.Win]::IsWindowVisible($h) -and ([DeskPress.Win]::Title($h) -eq {quoted(title)})
Write-Output ('已按「{button}」' + $(if ($still) {{ '，視窗還在（可能還有下一步）' }} else {{ '，視窗已關閉' }}))
"""


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
    'paste-failed-photos': '照片貼上了但文字貼不進輸入框，已中止（沒有送出）；照片可能還留在電腦的輸入框裡，請先到電腦上移除再重試，不然會重複',
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
    'elevated-window': '這是系統管理員程式的視窗，手機按不到；這台電腦沒裝提權夥伴，請到電腦上按',
    'elevate-unavailable': '提權夥伴沒有在執行，請到電腦上按',
    'elevate-refused': '提權夥伴拒絕了這個請求（可能太多請求在等核准）',
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


# ---------------------------------------------------------------------------------------------
# Shared clipboard (0.5.40). A folder the cloud drive syncs between the PCs (G:\我的雲端硬碟\剪貼簿)
# holds one file per copied item, newest by name; each PC publishes what is copied on it and puts
# what arrives from elsewhere into its own clipboard, and the phone reads and writes the same
# folder through whichever PC it can reach (asked 11/8: text and pictures, both ways).

CLIPBOARD_KINDS = {'.txt': 'text', '.png': 'image', '.jpg': 'image', '.jpeg': 'image', '.gif': 'image', '.webp': 'image'}
CLIPBOARD_MEDIA = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp'}
CLIPBOARD_EXTENSION = {media: ext for ext, media in CLIPBOARD_MEDIA.items() if ext != '.jpeg'}
CLIPBOARD_PREVIEW = 300            # characters of a long text sent with the list
CLIPBOARD_INLINE = 4000            # a text up to this many characters comes whole with the list
CLIPBOARD_TEXT_LIMIT = 1024 * 1024
CLIPBOARD_IMAGE_LIMIT = 12 * 1024 * 1024
CLIPBOARD_FRESH = 600              # seconds: an older arrival (the PC was off) is listed, not pasted
CLIPBOARD_ID = re.compile(r'(\d{13})_([^\\/\x00-\x1f]{1,60})')
CLIPBOARD_PHONE = '手機'


def clipboard_tag(name):
    """A PC's name as it goes into a file name."""
    return re.sub(r'[\\/:*?"<>|\s\x00-\x1f]+', '_', name or '').strip('_')[:40] or 'pc'


# Which PC reads the usage card (0.5.43; asked 11/10: "the one idle longest"). The PCs share one
# Claude account, and the phone shows the newest reading from any of them, so one reading is
# enough: each helper notes its own idle time in the shared clipboard folder (the cloud drive
# carries it over in seconds), and reads the card only while no other PC is idle longer. The
# notes are files in the folder itself, `_idle_<PC>.json` (the clipboard list only takes names
# that start with 13 digits): a subfolder made by both PCs at once came out twice on the drive
# ("_presence" and "_presence (1)", 11/10).
IDLE_NOTE_EVERY = 30               # seconds between a PC's notes
IDLE_NOTE_FRESH = 180              # seconds: an older note is a PC that is off, or not syncing
IDLE_NOTE_PREFIX = '_idle_'


class IdleBoard:
    def __init__(self, folder, pc_name, clock=time.time):
        self.folder = Path(folder)
        self.name = pc_name
        self.tag = clipboard_tag(pc_name)
        self.clock = clock
        self.noted = None

    def note(self, idle, locked, busy):
        """This PC's note (idle seconds, locked, busy with a video or a full-screen app), at most
        every IDLE_NOTE_EVERY seconds; a folder that is not there is no error."""
        now = time.monotonic()
        if self.noted is not None and now - self.noted < IDLE_NOTE_EVERY:
            return
        self.noted = now
        try:
            self.folder.mkdir(parents=True, exist_ok=True)
            tmp = self.folder / f'{IDLE_NOTE_PREFIX}{self.tag}.json.tmp'
            tmp.write_text(json.dumps({'pc': self.name, 'idleSeconds': idle, 'locked': bool(locked),
                                       'busy': bool(busy), 'at': self.clock()}, ensure_ascii=False), encoding='utf-8')
            tmp.replace(self.folder / f'{IDLE_NOTE_PREFIX}{self.tag}.json')
        except OSError as exc:
            logging.debug('idle note not written: %s', exc)

    def idle_longer(self, idle):
        """The name of another PC whose fresh note says it is idle longer than `idle` seconds and
        can read the card itself (not locked, nothing playing), or None."""
        try:
            files = list(self.folder.glob(f'{IDLE_NOTE_PREFIX}*.json'))
        except OSError:
            return None
        now, best = self.clock(), None
        for file in files:
            if file.stem == f'{IDLE_NOTE_PREFIX}{self.tag}':
                continue
            try:
                note = json.loads(file.read_text(encoding='utf-8'))
            except (OSError, ValueError, UnicodeDecodeError):
                continue
            if not isinstance(note, dict) or note.get('locked') or note.get('busy') or note.get('idleSeconds') is None:
                continue
            try:
                age = now - float(note.get('at') or 0)
                theirs = float(note['idleSeconds']) + age  # idle since the note, if nobody came
            except (TypeError, ValueError):
                continue
            if age < 0 or age > IDLE_NOTE_FRESH or theirs <= idle:
                continue
            if best is None or theirs > best[1]:
                best = (str(note.get('pc') or file.stem), theirs)
        return best[0] if best else None


def dib_to_png(dib):
    """PNG bytes of a CF_DIB clipboard picture, or None when Pillow is missing or the DIB is odd."""
    if PIL_IMAGE is None or len(dib) < 40:
        return None
    import io
    import struct
    try:
        header, = struct.unpack_from('<I', dib, 0)
        bits, = struct.unpack_from('<H', dib, 14)
        compression, = struct.unpack_from('<I', dib, 16)
        colors, = struct.unpack_from('<I', dib, 32)  # biClrUsed
        table = colors * 4 if colors else (4 << bits if bits <= 8 else 0)
        masks = 12 if compression == 3 and header == 40 else 0
        offset = 14 + header + masks + table
        bmp = b'BM' + struct.pack('<IHHI', 14 + len(dib), 0, 0, offset) + dib
        with PIL_IMAGE.open(io.BytesIO(bmp)) as image:
            image.load()
            out = io.BytesIO()
            image.save(out, format='PNG', optimize=True)
            return out.getvalue()
    except (OSError, ValueError, TypeError, struct.error) as exc:
        logging.info('clipboard picture not read: %s', exc)
        return None


def png_to_dib(png):
    """CF_DIB bytes (24-bit, bottom-up) of a PNG, or None."""
    if PIL_IMAGE is None:
        return None
    import io
    try:
        with PIL_IMAGE.open(io.BytesIO(png)) as image:
            image.load()
            out = io.BytesIO()
            image.convert('RGB').save(out, format='BMP')
            return out.getvalue()[14:]
    except (OSError, ValueError, TypeError) as exc:
        logging.info('clipboard picture not written: %s', exc)
        return None


class ClipboardStore:
    """The shared folder: `<epoch ms>_<source>.<ext>` per item, the newest first by name."""

    def __init__(self, folder, pc_name, keep=50, clock=time.time):
        self.folder = Path(folder)
        self.tag = clipboard_tag(pc_name)
        self.keep = keep
        self.clock = clock
        self.lock = threading.Lock()
        self.last_ms = 0

    def available(self):
        """The folder exists, or could be made under an existing cloud folder."""
        if self.folder.is_dir():
            return True
        try:
            if self.folder.parent.is_dir():
                self.folder.mkdir()
                return True
        except OSError:
            pass
        return False

    def entries(self):
        """(ms, id, source, kind, path, size), newest first; other files in the folder are ignored."""
        out = []
        try:
            with os.scandir(self.folder) as it:
                for entry in it:
                    stem, ext = os.path.splitext(entry.name)
                    kind = CLIPBOARD_KINDS.get(ext.lower())
                    match = CLIPBOARD_ID.fullmatch(stem)
                    if kind is None or match is None or entry.name.startswith(('~', '.')):
                        continue
                    try:
                        if not entry.is_file():
                            continue
                        size = entry.stat().st_size
                    except OSError:
                        continue
                    out.append((int(match.group(1)), stem, match.group(2), kind, Path(entry.path), size))
        except OSError:
            return []
        out.sort(key=lambda row: (row[0], row[1]), reverse=True)
        return out

    def newest(self):
        rows = self.entries()
        return rows[0] if rows else None

    def find(self, item_id):
        if not isinstance(item_id, str) or not CLIPBOARD_ID.fullmatch(item_id):
            return None
        for row in self.entries():
            if row[1] == item_id:
                return row
        return None

    def describe(self, row):
        ms, item_id, source, kind, path, size = row
        item = {'id': item_id, 'kind': kind, 'source': source, 'at': iso(ms), 'bytes': size}
        if kind == 'text':
            text = self.text(item_id, row)
            if text is None:
                return None
            if len(text) > CLIPBOARD_INLINE:
                item['text'] = text[:CLIPBOARD_PREVIEW]
                item['truncated'] = True
            else:
                item['text'] = text
        else:
            item['media'] = CLIPBOARD_MEDIA.get(path.suffix.lower(), 'image/png')
        return item

    def items(self, limit=20):
        out = []
        for row in self.entries():
            item = self.describe(row)
            if item is not None:
                out.append(item)
            if len(out) >= limit:
                break
        return out

    def text(self, item_id, row=None):
        row = row or self.find(item_id)
        if row is None or row[3] != 'text':
            return None
        try:
            return row[4].read_text(encoding='utf-8-sig')
        except (OSError, UnicodeDecodeError):
            return None

    def image(self, item_id, row=None):
        """(media, bytes) of a picture item, or None."""
        row = row or self.find(item_id)
        if row is None or row[3] != 'image' or row[5] > CLIPBOARD_IMAGE_LIMIT:
            return None
        try:
            return CLIPBOARD_MEDIA.get(row[4].suffix.lower(), 'image/png'), row[4].read_bytes()
        except OSError:
            return None

    def _write(self, source, ext, data):
        with self.lock:
            ms = max(int(self.clock() * 1000), self.last_ms + 1)
            self.last_ms = ms
            name = f'{ms:013d}_{clipboard_tag(source)}{ext}'
            part = self.folder / f'~{name}.part'
            part.write_bytes(data)
            os.replace(part, self.folder / name)
            self.prune()
        return f'{ms:013d}_{clipboard_tag(source)}'

    def put_text(self, text, source):
        return self._write(source, '.txt', text.encode('utf-8'))

    def put_image(self, data, media, source):
        return self._write(source, CLIPBOARD_EXTENSION.get(media, '.png'), data)

    def prune(self):
        for row in self.entries()[self.keep:]:
            try:
                row[4].unlink()
            except OSError:
                pass  # The other PC may be removing it too.


class WinClipboard:
    """The Windows clipboard through user32: text, a picture, or one copied picture file."""
    CF_UNICODETEXT, CF_DIB, CF_HDROP = 13, 8, 15
    GMEM_MOVEABLE = 0x0002

    def __init__(self):
        from ctypes import wintypes
        self.user32 = user32 = ctypes.WinDLL('user32', use_last_error=True)
        self.kernel32 = kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
        self.shell32 = shell32 = ctypes.WinDLL('shell32', use_last_error=True)
        for name, restype, argtypes in (
                ('OpenClipboard', wintypes.BOOL, [wintypes.HWND]), ('CloseClipboard', wintypes.BOOL, []),
                ('EmptyClipboard', wintypes.BOOL, []), ('GetClipboardSequenceNumber', wintypes.DWORD, []),
                ('IsClipboardFormatAvailable', wintypes.BOOL, [wintypes.UINT]),
                ('GetClipboardData', wintypes.HANDLE, [wintypes.UINT]),
                ('SetClipboardData', wintypes.HANDLE, [wintypes.UINT, wintypes.HANDLE]),
                ('RegisterClipboardFormatW', wintypes.UINT, [wintypes.LPCWSTR])):
            fn = getattr(user32, name)
            fn.restype, fn.argtypes = restype, argtypes
        for name, restype, argtypes in (
                ('GlobalLock', wintypes.LPVOID, [wintypes.HGLOBAL]), ('GlobalUnlock', wintypes.BOOL, [wintypes.HGLOBAL]),
                ('GlobalSize', ctypes.c_size_t, [wintypes.HGLOBAL]), ('GlobalAlloc', wintypes.HGLOBAL, [wintypes.UINT, ctypes.c_size_t]),
                ('GlobalFree', wintypes.HGLOBAL, [wintypes.HGLOBAL])):
            fn = getattr(kernel32, name)
            fn.restype, fn.argtypes = restype, argtypes
        shell32.DragQueryFileW.restype = wintypes.UINT
        shell32.DragQueryFileW.argtypes = [wintypes.HANDLE, wintypes.UINT, wintypes.LPWSTR, wintypes.UINT]
        self.exclude = user32.RegisterClipboardFormatW('ExcludeClipboardContentFromMonitorProcessing')
        self.png = user32.RegisterClipboardFormatW('PNG')

    def sequence(self):
        return self.user32.GetClipboardSequenceNumber()

    def _open(self):
        for _ in range(10):
            if self.user32.OpenClipboard(None):
                return True
            time.sleep(0.05)
        return False

    def _bytes(self, fmt):
        handle = self.user32.GetClipboardData(fmt)
        if not handle:
            return None
        pointer = self.kernel32.GlobalLock(handle)
        if not pointer:
            return None
        try:
            return ctypes.string_at(pointer, self.kernel32.GlobalSize(handle))
        finally:
            self.kernel32.GlobalUnlock(handle)

    def read(self):
        """('text', str) | ('image', png bytes) | ('file', path) | ('skip', None) for content marked
        not to be watched (password managers, the helper's own pastes) | None for anything else."""
        if not self._open():
            return None
        try:
            if self.user32.IsClipboardFormatAvailable(self.exclude):
                return ('skip', None)
            if self.user32.IsClipboardFormatAvailable(self.CF_UNICODETEXT):
                handle = self.user32.GetClipboardData(self.CF_UNICODETEXT)
                pointer = self.kernel32.GlobalLock(handle) if handle else None
                if not pointer:
                    return None
                try:
                    return ('text', ctypes.wstring_at(pointer))
                finally:
                    self.kernel32.GlobalUnlock(handle)
            if self.user32.IsClipboardFormatAvailable(self.png):
                data = self._bytes(self.png)
                return ('image', data) if data and data.startswith(b'\x89PNG') else None
            if self.user32.IsClipboardFormatAvailable(self.CF_DIB):
                data = self._bytes(self.CF_DIB)
                png = dib_to_png(data) if data else None
                return ('image', png) if png else None
            if self.user32.IsClipboardFormatAvailable(self.CF_HDROP):
                handle = self.user32.GetClipboardData(self.CF_HDROP)
                if handle and self.shell32.DragQueryFileW(handle, 0xFFFFFFFF, None, 0) == 1:
                    buffer = ctypes.create_unicode_buffer(32768)
                    if self.shell32.DragQueryFileW(handle, 0, buffer, 32768):
                        return ('file', buffer.value)
            return None
        finally:
            self.user32.CloseClipboard()

    def _put(self, fmt, data):
        handle = self.kernel32.GlobalAlloc(self.GMEM_MOVEABLE, len(data))
        if not handle:
            return False
        pointer = self.kernel32.GlobalLock(handle)
        if not pointer:
            self.kernel32.GlobalFree(handle)
            return False
        ctypes.memmove(pointer, data, len(data))
        self.kernel32.GlobalUnlock(handle)
        if not self.user32.SetClipboardData(fmt, handle):
            self.kernel32.GlobalFree(handle)
            return False
        return True

    def write_text(self, text):
        if not self._open():
            return False
        try:
            self.user32.EmptyClipboard()
            return self._put(self.CF_UNICODETEXT, text.encode('utf-16-le') + b'\x00\x00')
        finally:
            self.user32.CloseClipboard()

    def write_image(self, png):
        """The picture as CF_DIB (every program pastes it) and as PNG (browsers and chat apps keep
        the transparency)."""
        dib = png_to_dib(png)
        if dib is None or not self._open():
            return False
        try:
            self.user32.EmptyClipboard()
            return self._put(self.CF_DIB, dib) and self._put(self.png, png)
        finally:
            self.user32.CloseClipboard()


class ClipboardSync:
    """Publishes what is copied on this PC into the store and puts what arrives from the other
    PC or the phone into this PC's clipboard. What it put there itself is recognised by its digest,
    so a copy never bounces between the PCs."""

    def __init__(self, store, clipboard, pc_name, apply=True, publish=True, fresh=CLIPBOARD_FRESH,
                 clock=time.time, sleep=time.sleep, tick=1.0):
        self.store, self.clipboard, self.pc_name = store, clipboard, pc_name
        self.apply, self.publish, self.fresh = apply, publish, fresh
        self.clock, self.sleep, self.tick = clock, sleep, tick
        self.last_sequence = clipboard.sequence() if clipboard is not None else 0
        newest = store.newest() if store.available() else None
        self.seen_ms = newest[0] if newest else 0     # arrivals up to here were there before the start
        self.applied = None                           # digest of what was last put into or read from the clipboard
        self.failed_at = 0.0
        self.lock = threading.Lock()

    @staticmethod
    def digest(kind, value):
        return hashlib.sha1((kind + ':').encode() + (value.encode('utf-8') if kind == 'text' else value)).hexdigest()

    def once(self):
        with self.lock:
            if self.publish:
                self.publish_change()
            self.apply_arrival()

    def publish_change(self):
        sequence = self.clipboard.sequence()
        if sequence == self.last_sequence:
            return
        self.last_sequence = sequence
        read = self.clipboard.read()
        if not read or read[0] == 'skip':
            return
        kind, value = read
        media = 'image/png'
        if kind == 'file':
            picture = local_image(value)
            if picture is None:
                return
            kind, media, value = 'image', picture['media'], base64.b64decode(picture['data'])
        if kind == 'text' and (not value.strip() or len(value) > CLIPBOARD_TEXT_LIMIT):
            return
        if kind == 'image' and len(value) > CLIPBOARD_IMAGE_LIMIT:
            return
        digest = self.digest(kind, value)
        if digest == self.applied:
            return  # what this PC was just given
        if not self.store.available():
            return
        newest = self.store.newest()
        if newest is not None and self.row_digest(newest) == digest:
            # The same content is the newest item already: Windows' own cloud clipboard carried
            # the other PC's copy here before the cloud drive did (home PC 11/9), so one file.
            self.applied = digest
            self.seen_ms = max(self.seen_ms, newest[0])
            return
        item_id = self.store.put_text(value, self.pc_name) if kind == 'text' else self.store.put_image(value, media, self.pc_name)
        self.applied = digest
        self.seen_ms = max(self.seen_ms, int(item_id[:13]))
        logging.info('clipboard %s published (%d bytes)', kind, len(value) if kind == 'image' else len(value.encode('utf-8')))

    def row_digest(self, row):
        """The digest of a stored item's content as it would be read from the clipboard."""
        if row[3] == 'text':
            text = self.store.text(row[1], row)
            return None if text is None else self.digest('text', text)
        picture = self.store.image(row[1], row)
        if picture is None:
            return None
        data = picture[1] if picture[0] == 'image/png' else self._as_png(picture[1])
        return None if data is None else self.digest('image', data)

    def apply_arrival(self):
        if not self.store.available():
            return
        newest = self.store.newest()
        if newest is None or newest[0] <= self.seen_ms:
            return
        self.seen_ms = newest[0]
        ms, item_id, source, kind, path, size = newest
        if source == self.store.tag or not self.apply or self.clock() - ms / 1000 > self.fresh:
            return
        self.put_item(newest)

    def put_item(self, row):
        """Puts a stored item into this PC's clipboard; False when it is gone or cannot be read."""
        ms, item_id, source, kind, path, size = row
        if kind == 'text':
            value = self.store.text(item_id, row)
            if value is None:
                return False
            return self._set('text', value)
        picture = self.store.image(item_id, row)
        if picture is None:
            return False
        media, data = picture
        if media != 'image/png':
            data = self._as_png(data)
            if data is None:
                return False
        return self._set('image', data)

    def _as_png(self, data):
        if PIL_IMAGE is None:
            return None
        import io
        try:
            with PIL_IMAGE.open(io.BytesIO(data)) as image:
                image.load()
                out = io.BytesIO()
                image.save(out, format='PNG')
                return out.getvalue()
        except (OSError, ValueError, TypeError):
            return None

    def _set(self, kind, value):
        digest = self.digest(kind, value)
        if digest == self.applied:
            return True
        ok = self.clipboard.write_text(value) if kind == 'text' else self.clipboard.write_image(value)
        if ok:
            self.applied = digest
            self.last_sequence = self.clipboard.sequence()
            logging.info('clipboard %s taken from %s', kind, 'the shared folder')
        return ok

    def from_phone(self, kind, value, media='image/png', source=CLIPBOARD_PHONE, store=True):
        """What the phone sent: stored (unless another PC already did) and put into this PC's
        clipboard. Returns the stored item, or None when only the clipboard was set."""
        with self.lock:
            item = None
            if store:
                if not self.store.available():
                    raise ActionError('clipboard-folder', '共用剪貼簿資料夾不在（雲端硬碟沒掛上）')
                item_id = self.store.put_text(value, source) if kind == 'text' else self.store.put_image(value, media, source)
                self.seen_ms = max(self.seen_ms, int(item_id[:13]))
                row = self.store.find(item_id)
                item = self.store.describe(row) if row else None
            if self.apply:
                data = value
                if kind == 'image' and media != 'image/png':
                    data = self._as_png(value)
                if data is not None:
                    self._set(kind, data)
            return item

    def apply_id(self, item_id):
        with self.lock:
            row = self.store.find(item_id)
            return row is not None and self.put_item(row)

    def run_forever(self):
        while True:
            try:
                self.once()
            except Exception:
                if time.monotonic() - self.failed_at > 300:
                    logging.exception('clipboard sync failed')
                    self.failed_at = time.monotonic()
            self.sleep(self.tick)


class FakeClipboard:
    """A clipboard in memory, for tests and the simulator's fake helper."""

    def __init__(self):
        self.content = None   # ('text', str) | ('image', png) | ('skip', None)
        self.seq = 1

    def sequence(self):
        return self.seq

    def copy(self, kind, value):
        self.content = (kind, value)
        self.seq += 1

    def read(self):
        return self.content

    def write_text(self, text):
        self.copy('text', text)
        return True

    def write_image(self, png):
        self.copy('image', png)
        return True


def clipboard_sync_from_config(cfg, pc_name):
    """The shared clipboard the config asks for, or None. `clipboard.folder` is the cloud folder
    both PCs see; `apply` (default on) puts arrivals into this PC's clipboard, `publish` (default
    on) uploads what is copied here."""
    settings = cfg.get('clipboard')
    if not settings or not settings.get('folder'):
        return None
    store = ClipboardStore(settings['folder'], pc_name, keep=int(settings.get('keep', 50)))
    if not store.available():
        logging.warning('shared clipboard folder is not there: %s', settings['folder'])
    try:
        clipboard = WinClipboard()
    except (OSError, AttributeError) as exc:
        logging.warning('clipboard not available: %s', exc)
        return None
    return ClipboardSync(store, clipboard, pc_name, apply=bool(settings.get('apply', True)),
                         publish=bool(settings.get('publish', True)))


def clipboard_post(sync, body):
    """(status, json) for what the phone sent to the shared clipboard: `text`, or `image`
    (base64 JPEG/PNG); `store: false` only puts it into this PC's clipboard (another PC has
    stored it already)."""
    source = body.get('source') if isinstance(body.get('source'), str) and body.get('source').strip() else CLIPBOARD_PHONE
    store = body.get('store', True) is not False
    try:
        if isinstance(body.get('text'), str):
            text = body['text']
            if not text.strip():
                return 400, error('bad-request', '沒有文字')
            if len(text) > CLIPBOARD_TEXT_LIMIT:
                return 413, error('too-large', '文字太長')
            item = sync.from_phone('text', text, source=source, store=store)
        elif isinstance(body.get('image'), str):
            data = decode_image(body['image'], CLIPBOARD_IMAGE_LIMIT)
            if data is None:
                return 400, error('bad-request', '圖片要是 JPEG 或 PNG，且不超過 12 MB')
            media = 'image/png' if data.startswith(b'\x89PNG') else 'image/jpeg'
            item = sync.from_phone('image', data, media=media, source=source, store=store)
        else:
            return 400, error('bad-request', '要有 text 或 image')
    except ActionError as exc:
        return 503, error(exc.code, exc.message)
    return 200, {'ok': True, 'item': item}


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


class CameraFeed:
    """The PC's webcam for the phone's 看鏡頭 page (0.5.41). Nothing is opened until the phone asks
    for a frame; then one thread keeps reading the camera and encoding JPEG frames while frames
    keep being asked for, and releases it (the camera light goes off) once no frame has been asked
    for in `idle` seconds. So the camera is on only while that page is open (the user 11/10:
    「有打開才啟動」)."""

    def __init__(self, open_device, idle=5.0):
        self.open_device = open_device   # () -> device with grab_jpeg() -> bytes|None and close()
        self.idle = idle
        self.lock = threading.Lock()
        self.ready = threading.Condition(self.lock)
        self.thread = None
        self.last_request = 0.0
        self.frame = None
        self.frames = 0                  # frames read since the camera was last opened
        self.error = None
        self.opened = 0                  # how many times the camera has been opened (for tests and the log)
        self.served = 0                  # the frame number last handed out: each request waits for a newer one
        self.profile = 'low'             # 'low' (data saver, the default) or 'high' (clear): what the phone asked for last

    def on(self):
        """Whether the camera is open right now."""
        with self.lock:
            return self.thread is not None and self.error is None

    def frame_bytes(self, wait=3.0, profile='low'):
        """(JPEG bytes, None) of the next frame, opening the camera first when it is off, or
        (None, why) when the camera cannot be read within `wait` seconds. Each call waits for a
        frame newer than the one handed out before, so the phone asking again and again gets the
        camera's own pace (about 10–30 a second) and never the same picture twice."""
        with self.lock:
            self.last_request = time.monotonic()
            self.profile = profile
            if self.thread is None:
                self.error = None
                self.frame = None
                self.frames = self.served = 0
                self.thread = threading.Thread(target=self._run, name='camera', daemon=True)
                self.thread.start()
            deadline = time.monotonic() + wait
            while (self.frame is None or self.frames <= self.served) and self.error is None:
                left = deadline - time.monotonic()
                if left <= 0:
                    return None, '鏡頭還沒給出畫面'
                self.ready.wait(left)
            if self.frame is None or self.frames <= self.served:
                return None, self.error or '鏡頭還沒給出畫面'
            self.served = self.frames
            return self.frame, None

    def _run(self):
        device = None
        count = 0
        started = time.monotonic()
        try:
            try:
                device = self.open_device()
            except Exception as exc:  # in use by another program, unplugged, or OpenCV missing
                logging.warning('camera could not be opened: %s', exc)
                with self.lock:
                    self.error = f'鏡頭打不開（{exc}）'
                    self.ready.notify_all()
                return
            with self.lock:
                self.opened += 1
            logging.info('camera opened for the phone')
            while True:
                with self.lock:
                    if time.monotonic() - self.last_request > self.idle:
                        break
                with self.lock:
                    profile = self.profile
                data = device.grab_jpeg(profile)
                if not data:
                    logging.warning('camera gave no frame')
                    with self.lock:
                        self.error = '鏡頭讀不到畫面'
                        self.ready.notify_all()
                    break
                count += 1
                with self.lock:
                    self.frame = data
                    self.frames = count
                    self.ready.notify_all()
            logging.info('camera closed after %d frames in %.0f s', count, time.monotonic() - started)
        finally:
            if device is not None:
                try:
                    device.close()
                except Exception:
                    logging.exception('camera close failed')
            with self.lock:
                self.thread = None
                self.ready.notify_all()


class OpenCVCamera:
    """A webcam read through OpenCV (`pip install opencv-python`): frames shrunk and encoded as
    JPEG for the phone, in two sizes: 'low' (data saver, the default: 640 px, quality 50, about
    15 KB a frame on the office webcam) and 'high' (clear: 960 px, quality 70, about 34 KB)."""

    def __init__(self, index=0, long_side=960, quality=70, low_long_side=640, low_quality=50, stamp=True, clock=None):
        import cv2
        self.cv2 = cv2
        backend = getattr(cv2, 'CAP_DSHOW', 0) if sys.platform == 'win32' else 0
        self.capture = cv2.VideoCapture(index, backend) if backend else cv2.VideoCapture(index)
        if not self.capture.isOpened():
            self.capture.release()
            raise RuntimeError('沒有鏡頭，或被其他程式占用')
        self.capture.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        self.capture.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        self.sizes = {'high': (long_side, quality), 'low': (low_long_side, low_quality)}
        self.stamp, self.clock = bool(stamp), clock or datetime.now

    def grab_jpeg(self, profile='low'):
        ok, frame = self.capture.read()
        if not ok or frame is None:
            return None
        long_side, quality = self.sizes.get(profile, self.sizes['low'])
        height, width = frame.shape[:2]
        scale = long_side / max(height, width)
        if scale < 1:
            frame = self.cv2.resize(frame, (int(width * scale), int(height * scale)), interpolation=self.cv2.INTER_AREA)
        if self.stamp:
            stamp_time(self.cv2, frame, self.clock())
        ok, encoded = self.cv2.imencode('.jpg', frame, [self.cv2.IMWRITE_JPEG_QUALITY, quality])
        return encoded.tobytes() if ok else None

    def close(self):
        self.capture.release()


def stamp_time(cv2, frame, when):
    """Writes the date and time (0.5.57, the user 11/12: 「WEBCAM畫面上面可以加上日期時間嗎」) in the
    bottom-left corner of `frame` (in place): white on a dark outline, sized to the picture.
    Bottom-left is away from the light watch's region and anchor (top right), and the text is the
    same from frame to frame, so the exposure check sees no change from it."""
    height, width = frame.shape[:2]
    text = when.strftime('%Y-%m-%d %H:%M:%S')
    scale = max(0.45, width / 1200)
    thickness = 1 if width < 800 else 2
    origin = (8, height - 10)
    cv2.putText(frame, text, origin, cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 0, 0), thickness + 2, cv2.LINE_AA)
    cv2.putText(frame, text, origin, cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), thickness, cv2.LINE_AA)
    return frame


class FakeCamera:
    """The simulator's camera: the fixture picture as the same frame about ten times a second."""

    def __init__(self, path):
        self.data = Path(path).read_bytes()
        self.closed = False

    def grab_jpeg(self, profile='low'):
        time.sleep(0.1)
        return self.data

    def close(self):
        self.closed = True


def region_brightness(jpeg, region):
    """Mean brightness (0-255) of `region` = (x, y, w, h) as fractions of the picture, decoded
    with OpenCV when it is installed, else Pillow."""
    x, y, w, h = region
    try:
        import cv2
        import numpy
        picture = cv2.imdecode(numpy.frombuffer(jpeg, numpy.uint8), cv2.IMREAD_GRAYSCALE)
        if picture is None:
            raise ValueError('not a picture')
        return gray_region_mean(picture, region)
    except ImportError:
        pass
    import io
    from PIL import Image, ImageStat
    picture = Image.open(io.BytesIO(jpeg)).convert('L')
    width, height = picture.size
    box = picture.crop((int(x * width), int(y * height),
                        max(int(x * width) + 1, int((x + w) * width)), max(int(y * height) + 1, int((y + h) * height))))
    return float(ImageStat.Stat(box).mean[0])


def gray_region_mean(picture, region):
    """Mean of a grayscale OpenCV picture inside `region` (fractions)."""
    x, y, w, h = region
    height, width = picture.shape[:2]
    box = picture[int(y * height):max(int(y * height) + 1, int((y + h) * height)),
                  int(x * width):max(int(x * width) + 1, int((x + w) * width))]
    return float(box.mean())


class RegionAim:
    """Finds the watched region again when the camera has been nudged (the user 11/11: 「那個門框
    的圖案你已經記下來了 如果哪天鏡頭碰歪 你要自己找的」). A reference picture (light_reference.jpg
    next to config.json, saved when the region was chosen) and an `anchor` box in it (the door
    frame and wall around the region: structure that does not change with the light) are kept;
    every look, the anchor is searched for in the new picture (OpenCV matchTemplate) and the
    region moves by the same offset. A match below `min_score` keeps the last offset and says so,
    so the phone's camera page shows 「找不到門框」. Needs OpenCV; without it nothing moves."""

    def __init__(self, reference_jpeg, anchor, region, min_score=0.6):
        import cv2
        import numpy
        self.cv2, self.numpy = cv2, numpy
        picture = cv2.imdecode(numpy.frombuffer(reference_jpeg, numpy.uint8), cv2.IMREAD_GRAYSCALE)
        if picture is None:
            raise ValueError('the reference picture cannot be read')
        self.size = (picture.shape[1], picture.shape[0])  # (width, height)
        ax, ay, aw, ah = anchor
        self.origin = (int(ax * self.size[0]), int(ay * self.size[1]))
        self.template = picture[self.origin[1]:int((ay + ah) * self.size[1]), self.origin[0]:int((ax + aw) * self.size[0])]
        if self.template.size < 64:
            raise ValueError('the anchor box is too small')
        self.region, self.min_score = tuple(region), float(min_score)
        self.offset = (0, 0)   # pixels the picture has moved by, in the reference's size
        self.score = None
        self.lost = False

    def measure(self, jpeg):
        """(level, region used) of the region after finding the anchor in `jpeg`."""
        cv2, numpy = self.cv2, self.numpy
        picture = cv2.imdecode(numpy.frombuffer(jpeg, numpy.uint8), cv2.IMREAD_GRAYSCALE)
        if picture is None:
            raise ValueError('not a picture')
        if (picture.shape[1], picture.shape[0]) != self.size:
            picture = cv2.resize(picture, self.size, interpolation=cv2.INTER_AREA)
        result = cv2.matchTemplate(picture, self.template, cv2.TM_CCOEFF_NORMED)
        _, score, _, where = cv2.minMaxLoc(result)
        self.score = float(score)
        if score >= self.min_score:
            offset = (where[0] - self.origin[0], where[1] - self.origin[1])
            if offset != self.offset:
                logging.info('light watch: the picture moved by %+d, %+d px (match %.2f); region re-aimed', offset[0], offset[1], score)
            self.offset, self.lost = offset, False
        elif not self.lost:
            logging.warning('light watch: the anchor was not found (best match %.2f); keeping the last position', score)
            self.lost = True
        x, y, w, h = self.region
        region = (min(max(x + self.offset[0] / self.size[0], 0.0), 1 - w), min(max(y + self.offset[1] / self.size[1], 0.0), 1 - h), w, h)
        return gray_region_mean(picture, region), region


def region_aim_from_config(settings, folder):
    """A RegionAim when `light_watch` names a reference picture and an anchor box, else None."""
    name = settings.get('reference')
    anchor = settings.get('anchor')
    if not name or not anchor:
        return None
    try:
        ax, ay, aw, ah = (float(v) for v in anchor)
    except (TypeError, ValueError):
        raise ValueError('light_watch.anchor must be [x, y, w, h] as fractions of the picture') from None
    if not (0 <= ax < 1 and 0 <= ay < 1 and 0 < aw <= 1 - ax and 0 < ah <= 1 - ay):
        raise ValueError('light_watch.anchor must be [x, y, w, h] as fractions of the picture')
    path = Path(folder) / name
    try:
        reference = path.read_bytes()
    except OSError as exc:
        raise ValueError(f'light_watch.reference cannot be read: {exc}') from None
    try:
        return RegionAim(reference, (ax, ay, aw, ah), tuple(float(v) for v in settings['region']),
                         min_score=float(settings.get('min_score', 0.6)))
    except ImportError:
        logging.warning('light watch: OpenCV is not installed, so the region cannot follow a nudged camera')
        return None
class LightWatch:
    """One region of the webcam picture watched for a light being on (0.5.45; the user 11/11:
    「判斷這區域每天記錄亮白燈和關燈的時間 如果亮燈要通知我」). Every `interval` seconds the camera is
    asked for a picture through CameraFeed (the phone's 看鏡頭 page and this share the one camera;
    the camera is on for a few seconds each time), the region's mean brightness is measured and
    the light counts as on above `on_above`, off below `off_below`, once two samples in a row
    agree (someone walking past, or the exposure settling, does not flip it). Every change is
    appended to light_log.csv next to config.json (date, time, on/off, level): the long record
    stays on the PC (the user: 「長時間紀錄統計的資料存在電腦就好」), and the phone's camera page
    shows today's changes from `/v1/light`. Every change (on and off) is sent to ntfy (and LINE
    when configured; the user 11/11: 「目前先加入亮燈和暗燈的通知就好」); the first look of a
    watch window is notified only when the light is already on.

    0.5.49 (11/12 08:00 the first look of the day read 137 on a washed-out frame, the camera's
    exposure not yet settled after seven hours closed, and said the dark room was lit): after the
    camera opens, frames are taken `settle` seconds apart until the whole picture's brightness
    stops moving (two in a row within SETTLED of each other, at most SETTLE_FRAMES), and the first
    look of a window needs two samples in a row on the same side too, like every change.

    0.5.50 (the user 11/12 「多紀錄多校正」, after closing the glass door took a lit reading from
    158 to 104, inside the thresholds' gap): every sample's level and door-frame match score also
    go to light_samples.csv next to the log (date,time,level,score), so the thresholds can be
    set from what the door looks like open, closed, lit and dark.

    0.5.51 (the user 11/12 08:58 got a second 「亮了」 when the helper was restarted for a config
    change): a window's first state is a restart, not news, when today's log already ends in the
    same state: nothing is logged or sent then. A new day (or a different state) is still
    recorded as 'start' and, when lit, sent."""

    SETTLED = 4.0       # whole-picture mean change (0-255) under which the exposure counts as settled
    SETTLE_FRAMES = 6   # frames waited for at most (settle seconds apart) before measuring anyway

    KEEP = 30  # recent samples kept for /v1/light (to pick the thresholds)

    def __init__(self, feed, region, log_path, notify=None, pc_name='', name='', interval=30.0,
                 on_above=160.0, off_below=120.0, settle=1.0, hours=(0, 24), weekdays_only=False,
                 measure=None, aim=None, clock=time.time, sleep=time.sleep):
        self.feed, self.region, self.log_path = feed, tuple(float(v) for v in region), Path(log_path)
        self.samples_path = self.log_path.with_name('light_samples.csv')  # every look (0.5.50)
        self.notify, self.pc_name, self.name = notify, pc_name, name or '燈'
        self.interval, self.on_above, self.off_below = float(interval), float(on_above), float(off_below)
        self.settle = float(settle)
        self.hours, self.weekdays_only = (int(hours[0]), int(hours[1])), bool(weekdays_only)
        self.aim = aim  # RegionAim: follows the door frame when the camera is nudged (None: fixed region)
        self.measure = measure or (lambda jpeg: self.aim.measure(jpeg)[0] if self.aim is not None else region_brightness(jpeg, self.region))
        self.whole = lambda jpeg: region_brightness(jpeg, (0.0, 0.0, 1.0, 1.0))  # the exposure check (tests swap it)
        self.clock, self.sleep = clock, sleep
        self.lock = threading.Lock()
        self.on = None        # True/False once decided, None before the first readable picture
        self.since = None     # when the light last changed (clock())
        self.level = None     # the last measured brightness
        self.pending = None   # a state seen once that the next sample has to confirm
        self.error = None
        self.samples = []     # the last (when, level)
        self.picture = None   # the JPEG the last level was measured on (sent with a change's notification)

    def active(self, when=None):
        """Whether this moment is inside the watch window (hours, and Monday-Friday when
        weekdays_only); outside it the camera is left alone and nothing is recorded."""
        stamp = datetime.fromtimestamp(self.clock() if when is None else when)
        if self.weekdays_only and stamp.weekday() >= 5:
            return False
        return self.hours[0] <= stamp.hour < self.hours[1]

    def sample(self):
        """One look: the measured level (None when the camera gave nothing), with the change
        applied when a second sample agrees."""
        data, why = self.feed.frame_bytes(wait=8.0)
        if data is not None and self.settle:
            data, why = self.settled(data)
        if data is None:
            with self.lock:
                self.error = why
            return None
        try:
            level = float(self.measure(data))
        except Exception as exc:
            logging.warning('light watch could not read the picture: %s', exc)
            with self.lock:
                self.error = f'畫面讀不出來（{exc}）'
            return None
        now = self.clock()
        change = None
        with self.lock:
            self.picture = data
            self.error = '找不到門框的圖案，用上次的位置量' if self.aim is not None and self.aim.lost else None
            self.level = level
            self.samples = (self.samples + [(now, level)])[-self.KEEP:]
            if self.on is None:  # the window's first state: two looks on the same side of the middle
                state = level >= (self.on_above + self.off_below) / 2
                if self.pending == state:
                    self.pending = None
                    self.on, self.since = state, now
                    change = (state, True)
                else:
                    self.pending = state
            else:
                if self.on and level < self.off_below:
                    state = False
                elif not self.on and level >= self.on_above:
                    state = True
                else:
                    state = None
                if state is None:
                    self.pending = None
                elif self.pending == state:
                    self.pending = None
                    self.on, self.since = state, now
                    change = (state, False)
                else:
                    self.pending = state
        self.keep_sample(now, level)
        if change is not None:
            self.record(now, change[0], level, first=change[1])
        return level

    def keep_sample(self, when, level):
        """Appends one look to light_samples.csv (every sample, not only changes): the level and
        the door-frame match score (blank without RegionAim)."""
        stamp = datetime.fromtimestamp(when)
        score = '' if self.aim is None or self.aim.score is None else f'{self.aim.score:.2f}'
        try:
            new = not self.samples_path.exists()
            with self.samples_path.open('a', encoding='utf-8') as out:
                if new:
                    out.write('date,time,level,score\n')
                out.write(f'{stamp:%Y-%m-%d},{stamp:%H:%M:%S},{level:.1f},{score}\n')
        except OSError as exc:
            logging.warning('light samples could not be written: %s', exc)

    def settled(self, data):
        """Frames `settle` seconds apart until the whole picture's brightness holds still (the
        camera's auto exposure after opening: the first frames can be washed out), at most
        SETTLE_FRAMES of them; (JPEG, None) of the last one, or (None, why) when the camera
        stopped giving frames."""
        try:
            before = float(self.whole(data))
        except Exception:
            before = None  # not a readable picture: measure() will say so
        for frame in range(1, self.SETTLE_FRAMES + 1):
            self.sleep(self.settle)
            data, why = self.feed.frame_bytes(wait=8.0)
            if data is None:
                return None, why
            if before is None:
                return data, None
            try:
                now = float(self.whole(data))
            except Exception:
                return data, None
            if abs(now - before) < self.SETTLED:
                if frame > 1:
                    logging.info('light watch: the exposure settled after %d frames (%.0f -> %.0f)', frame + 1, before, now)
                return data, None
            before = now
        logging.warning('light watch: the exposure was still moving after %d frames (%.0f); measuring anyway',
                        self.SETTLE_FRAMES + 1, before)
        return data, None

    def last_logged(self, date):
        """The state ('on'/'off') of the log's last row when it is from `date` (YYYY-MM-DD),
        else None."""
        try:
            rows = [l for l in self.log_path.read_text(encoding='utf-8').splitlines() if l and not l.startswith('date,')]
        except OSError:
            return None
        if not rows:
            return None
        parts = rows[-1].split(',')
        return parts[2] if len(parts) >= 3 and parts[0] == date else None

    def record(self, when, on, level, first=False):
        stamp = datetime.fromtimestamp(when)
        if first and self.last_logged(f'{stamp:%Y-%m-%d}') == ('on' if on else 'off'):
            logging.info('light %s: %s (level %.0f) at start, as the log already says: a restart', self.name, 'on' if on else 'off', level)
            return
        line = f"{stamp:%Y-%m-%d},{stamp:%H:%M:%S},{'on' if on else 'off'},{level:.1f}"
        if first:
            line += ',start'
        try:
            new = not self.log_path.exists()
            with self.log_path.open('a', encoding='utf-8') as out:
                if new:
                    out.write('date,time,state,level,note\n')
                out.write(line + '\n')
        except OSError as exc:
            logging.warning('light log could not be written: %s', exc)
        logging.info('light %s: %s (level %.0f%s)', self.name, 'on' if on else 'off', level, ', at start' if first else '')
        if self.notify is not None and (on or not first):
            title = f'{self.pc_name}：{self.name}' + ('亮了' if on else '暗了') + ('（小幫手啟動時已亮）' if first else '')
            try:
                self.notify(title, f'{stamp:%H:%M} 亮度 {level:.0f}', tags=['bulb'], picture=self.picture, picture_name='light.jpg',
                            shared=True)
            except OSError as exc:
                logging.warning('light notification failed: %s', exc)

    def snapshot(self):
        with self.lock:
            since = datetime.fromtimestamp(self.since).astimezone().isoformat(timespec='seconds') if self.since else None
            return {'name': self.name, 'on': self.on, 'level': round(self.level, 1) if self.level is not None else None,
                    'since': since, 'error': self.error, 'onAbove': self.on_above, 'offBelow': self.off_below,
                    'intervalSeconds': self.interval, 'region': list(self.region), 'watching': self.active(),
                    'hours': list(self.hours), 'weekdaysOnly': self.weekdays_only,
                    'aim': {'moved': list(self.aim.offset), 'score': round(self.aim.score, 3) if self.aim.score is not None else None,
                            'lost': self.aim.lost} if self.aim is not None else None}

    def history(self, days=1):
        """[{date, changes: [{time, on, level, start}]}] for the last `days` days (today first)
        from the log; a day without changes is listed empty."""
        wanted = [f'{datetime.fromtimestamp(self.clock()) - timedelta(days=i):%Y-%m-%d}' for i in range(max(1, min(int(days), 366)))]
        found = {day: [] for day in wanted}
        try:
            lines = self.log_path.read_text(encoding='utf-8').splitlines()
        except OSError:
            lines = []
        for line in lines[1:]:
            cells = line.split(',')
            if len(cells) < 4 or cells[0] not in found:
                continue
            try:
                level = float(cells[3])
            except ValueError:
                continue
            found[cells[0]].append({'time': cells[1], 'on': cells[2] == 'on', 'level': level,
                                    'start': len(cells) > 4 and cells[4] == 'start'})
        return [{'date': day, 'changes': found[day]} for day in wanted]

    def recent(self):
        with self.lock:
            return [{'at': datetime.fromtimestamp(when).astimezone().isoformat(timespec='seconds'), 'level': round(level, 1)}
                    for when, level in self.samples]

    def run_forever(self):
        logging.info('light watch: %s, region %s, every %.0f s, on above %.0f / off below %.0f',
                     self.name, [round(v, 3) for v in self.region], self.interval, self.on_above, self.off_below)
        while True:
            if not self.active():
                with self.lock:  # the next window starts afresh (its first sample is recorded as 'start')
                    self.on = self.since = self.pending = None
                self.sleep(self.interval)
                continue
            try:
                self.sample()
            except Exception:
                logging.exception('light watch failed')
            self.sleep(self.interval)


def light_watch_from_config(cfg, feed, notify, pc_name, folder):
    """A LightWatch when config.json has `light_watch` and the PC has a camera: {"region":
    [x, y, w, h] as fractions of the picture, "name": "玻璃門", "interval_seconds": 30,
    "on_above": 160, "off_below": 120, "hours": [8, 18], "weekdays_only": true, "reference":
    "light_reference.jpg", "anchor": [x, y, w, h]}; else None. `reference` + `anchor` let the
    region follow a nudged camera (RegionAim)."""
    settings = cfg.get('light_watch')
    if not settings:
        return None
    if feed is None:
        logging.info('light watch: no camera on this PC, nothing watched')
        return None
    region = settings.get('region')
    try:
        x, y, w, h = (float(v) for v in region)
    except (TypeError, ValueError):
        raise ValueError('light_watch.region must be [x, y, w, h] as fractions of the picture') from None
    if not (0 <= x < 1 and 0 <= y < 1 and 0 < w <= 1 - x and 0 < h <= 1 - y):
        raise ValueError('light_watch.region must be [x, y, w, h] as fractions of the picture')
    on_above = float(settings.get('on_above', 160))
    off_below = float(settings.get('off_below', 120))
    if off_below >= on_above:
        raise ValueError('light_watch.off_below must be below on_above')
    hours = settings.get('hours') or [0, 24]
    try:
        first, last = (int(v) for v in hours)
    except (TypeError, ValueError):
        raise ValueError('light_watch.hours must be [start, end] hours of the day') from None
    if not (0 <= first < last <= 24):
        raise ValueError('light_watch.hours must be [start, end] hours of the day')
    return LightWatch(feed, (x, y, w, h), Path(folder) / 'light_log.csv', notify, pc_name,
                      name=str(settings.get('name') or '燈'), interval=float(settings.get('interval_seconds', 30)),
                      on_above=on_above, off_below=off_below, hours=(first, last),
                      weekdays_only=bool(settings.get('weekdays_only', False)), aim=region_aim_from_config(settings, folder))


def cameras_on_this_pc(timeout=30):
    """Names of the cameras Windows lists (asked without opening any, so no camera light); []
    elsewhere or when the question fails."""
    if sys.platform != 'win32':
        return []
    import subprocess
    try:
        done = subprocess.run(
            ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
             'Get-PnpDevice -Class Camera -Status OK -ErrorAction SilentlyContinue | ForEach-Object { $_.FriendlyName }'],
            capture_output=True, timeout=timeout, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except (OSError, subprocess.TimeoutExpired):
        return []
    if done.returncode != 0:
        return []
    return [line.strip() for line in done.stdout.decode('utf-8', 'replace').splitlines() if line.strip()]


def camera_from_config(cfg, names=None):
    """A CameraFeed for the phone when `camera` in config.json is not false, OpenCV is installed
    and Windows lists a camera; else None (the phone then shows no 看鏡頭 row). `camera` may be an
    object: {"index": 0, "long_side": 960, "quality": 70, "low_long_side": 640, "low_quality": 50,
    "idle_seconds": 5} (`long_side`/`quality` are the clear picture, `low_*` the data saver)."""
    settings = cfg.get('camera', True)
    if settings is False:
        return None
    settings = settings if isinstance(settings, dict) else {}
    try:
        import cv2  # noqa: F401
    except ImportError:
        logging.info('camera: OpenCV is not installed (pip install opencv-python); the phone gets no camera page')
        return None
    names = cameras_on_this_pc() if names is None else names
    if not names:
        logging.info('camera: Windows lists no camera; the phone gets no camera page')
        return None
    logging.info('camera: %s (opened only while the phone looks)', ', '.join(names))
    index = int(settings.get('index', 0))
    long_side = int(settings.get('long_side', 960))
    quality = int(settings.get('quality', 70))
    low_long_side = int(settings.get('low_long_side', 640))
    low_quality = int(settings.get('low_quality', 50))
    stamp = bool(settings.get('stamp', True))  # the date and time in the corner of every frame (0.5.57)
    return CameraFeed(lambda: OpenCVCamera(index, long_side, quality, low_long_side, low_quality, stamp=stamp),
                      idle=float(settings.get('idle_seconds', 5)))


def handler_for(hub, gate, networks, runner=None):
    screen_lock = threading.Lock()  # one capture at a time

    class Handler(BaseHTTPRequestHandler):
        server_version = 'DeskRemoteHelper'
        sys_version = ''
        # HTTP/1.1: the phone keeps one connection and reuses it for the next long-poll. Under 1.0
        # every request opened a new TCP connection through ZeroTier, and with the phone's Wi-Fi
        # saturated (AirPlay, 11/8) each lost handshake cost seconds before any words arrived.
        # Every response carries a Content-Length (send_json, send_bytes, send_error).
        protocol_version = 'HTTP/1.1'

        def setup(self):
            super().setup()
            self.connection.settimeout(MAX_WAIT + 10)

        def handle(self):
            # A kept-alive connection the phone drops (the app goes to the background) ends with
            # a reset while the next request line is awaited: not worth a traceback in the log.
            try:
                super().handle()
            except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, TimeoutError):
                pass

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
            self.send_bytes(data, 'image/jpeg')

        def send_bytes(self, data, content_type):
            try:
                self.send_response(200)
                self.send_header('Content-Type', content_type if re.fullmatch(r'image/[a-z0-9.+-]+', content_type) else 'application/octet-stream')
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
            if parts == ['helper', 'restart']:
                if hub.restart is None:
                    return self.send_json(404, error('not-found', '這台電腦的小幫手不能從手機重啟'))
                if runner is not None and runner.queue:
                    return self.send_json(409, error('busy', '手機的動作還在排隊，做完再重啟'))
                threading.Timer(1.0, hub.restart).start()  # after this answer has gone out
                return self.send_json(202, {'ok': True, 'message': '小幫手重新啟動中，約 15 秒後回來'})
            if parts and parts[0] == 'clipboard':
                if hub.clipboard is None:
                    return self.send_json(404, error('not-found', '這台電腦沒有設定共用剪貼簿'))
                body = self.read_body(PHOTO_BODY)
                if body is None:
                    return None
                if len(parts) == 1:
                    return self.send_json(*clipboard_post(hub.clipboard, body))
                if len(parts) == 4 and parts[1] == 'items' and parts[3] == 'apply':
                    if not hub.clipboard.apply_id(parts[2]):
                        return self.send_json(404, error('not-found', '這筆內容已不在共用資料夾'))
                    return self.send_json(200, {'ok': True})
                return self.send_json(404, error('not-found', '沒有這個路徑'))
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
            if parts and parts[0] == 'camera':
                if hub.camera is None:
                    return self.send_json(404, error('not-found', '這台電腦沒有鏡頭（或小幫手沒裝 OpenCV）'))
                if parts == ['camera']:
                    return self.send_json(200, {'ok': True, 'on': hub.camera.on(), 'frames': hub.camera.frames})
                if parts == ['camera', 'frame']:
                    clear = query.get('clear', [''])[0] not in ('', '0', 'false')
                    data, why = hub.camera.frame_bytes(profile='high' if clear else 'low')
                    if data is None:
                        return self.send_json(503, error('camera-failed', why))
                    return self.send_jpeg(data)
                return self.send_json(404, error('not-found', '沒有這個路徑'))
            if parts == ['light']:
                if hub.light is None:
                    return self.send_json(404, error('not-found', '這台電腦沒有設定燈光監看'))
                try:
                    days = int(query.get('days', ['1'])[0])
                except ValueError:
                    days = 1
                return self.send_json(200, dict(hub.light.snapshot(), ok=True, days=hub.light.history(days),
                                                samples=hub.light.recent()))
            if parts and parts[0] == 'clipboard':
                sync = hub.clipboard
                if sync is None:
                    return self.send_json(404, error('not-found', '這台電腦沒有設定共用剪貼簿'))
                if len(parts) == 1:
                    if not sync.store.available():
                        return self.send_json(503, error('clipboard-folder', '共用剪貼簿資料夾不在（雲端硬碟沒掛上）'))
                    return self.send_json(200, {'ok': True, 'pc': hub.pc_name,
                                                'items': sync.store.items(max(1, min(number('limit', 20), 50)))})
                if len(parts) == 3 and parts[1] == 'items':
                    text = sync.store.text(parts[2])
                    if text is None:
                        return self.send_json(404, error('not-found', '這筆內容已不在共用資料夾'))
                    return self.send_json(200, {'ok': True, 'text': text})
                if len(parts) == 3 and parts[1] == 'images':
                    picture = sync.store.image(parts[2])
                    if picture is None:
                        return self.send_json(404, error('not-found', '這張圖已不在共用資料夾'))
                    media, data = picture
                    if query.get('small'):  # the phone's copy: long side 1600 px at most
                        media, encoded = shrink_picture(media, base64.b64encode(data).decode('ascii'))
                        data = base64.b64decode(encoded)
                    return self.send_bytes(data, media)
                return self.send_json(404, error('not-found', '沒有這個路徑'))
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
                if len(parts) == 5 and parts[3] == 'images':
                    picture = hub.image(app, parts[2], parts[4])
                    if picture is None:
                        return self.send_json(404, error('not-found', '這張圖已不在電腦端快取'))
                    return self.send_bytes(picture[1], picture[0])
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


def lan_address():
    """This PC's address on the network the default route uses (the Wi-Fi or Ethernet adapter;
    not ZeroTier, WSL or Hyper-V, which have no default route). A UDP socket "connected" to an
    unroutable test address makes Windows pick the interface without sending anything."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(('192.0.2.1', 9))
            return probe.getsockname()[0]
    except OSError:
        return None


def lan_binding(cfg, lan_address=lan_address):
    """Where the helper also listens on the local network, or None: `lan.bind_ip`, or the address
    of the adapter the default route uses, with `lan.prefix` (24) as the network the phone may come
    from. Off unless `lan.enabled`. Never the ZeroTier address, loopback or 0.0.0.0.

    The phone on the same Wi-Fi reaches this address directly: when the phone and the PC sit
    behind the same NAT, ZeroTier takes minutes to find the direct path and the relayed path in
    between times out (2026-11-11, the office Wi-Fi). App 0.6.10 learns the address from
    `/v1/state` and tries both, keeping whichever answers first."""
    lan = cfg.get('lan') or {}
    if not lan.get('enabled'):
        return None
    ip = lan.get('bind_ip') or lan_address()
    if not ip:
        return None
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return None
    if address.is_unspecified or address.is_loopback or str(address) == cfg.get('bind_ip'):
        return None
    network = ipaddress.ip_network(f'{address}/{int(lan.get("prefix", 24))}', strict=False)
    return str(address), network


def serve_lan(hub, gate, cfg, networks, runner, binding, port=None, retry_seconds=10):
    """Starts the second listener on the local network address in `binding` ((ip, network)) and
    returns its thread; the handler accepts the ZeroTier networks and that network. The adapter
    may not be up yet at logon: a bind that fails because the address is not here yet is retried
    every `retry_seconds` on the thread, any other error is logged once and gives up."""
    ip, network = binding
    port = port or cfg['port']
    handler = handler_for(hub, gate, list(networks) + [network], runner)
    ready = threading.Event()

    def run():
        while True:
            try:
                server = ThreadingHTTPServer((ip, port), handler)
                break
            except OSError as exc:
                if getattr(exc, 'winerror', None) != 10049:
                    logging.warning('lan: cannot listen on %s:%s (%s); ZeroTier only', ip, port, exc)
                    ready.set()
                    return
                time.sleep(retry_seconds)
        server.daemon_threads = True
        hub.lan = (ip, port)
        logging.info('lan: also listening on %s:%s for a phone on the same network', ip, port)
        ready.set()
        server.serve_forever(poll_interval=1)

    thread = threading.Thread(target=run, daemon=True, name='lan-listener')
    thread.ready = ready
    thread.start()
    return thread


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

    def clipboard_sync(self):
        """A shared clipboard folder with the fixture items (fixtures/fake-helper/clipboard), over a
        clipboard in memory, so the simulator can list, copy and send."""
        folder = self.root / 'clipboard'
        shutil.copytree(self.fixtures / 'clipboard', folder)
        return ClipboardSync(ClipboardStore(folder, self.cfg['pc_name']), FakeClipboard(), self.cfg['pc_name'])

    def light_watch(self, feed):
        """The simulator's light watch (0.5.45): a fixed bright reading over the fake camera, with a
        log that already holds yesterday's and today's changes."""
        log = self.root / 'light_log.csv'
        today = datetime.now()
        yesterday = today - timedelta(days=1)
        log.write_text('date,time,state,level,note\n'
                       f'{yesterday:%Y-%m-%d},08:12:30,on,178.4\n{yesterday:%Y-%m-%d},12:03:05,off,74.2\n'
                       f'{yesterday:%Y-%m-%d},13:10:41,on,181.0\n{yesterday:%Y-%m-%d},18:32:12,off,70.9\n'
                       f'{today:%Y-%m-%d},08:05:17,on,179.6\n{today:%Y-%m-%d},12:01:48,off,72.3\n', encoding='utf-8')
        watch = LightWatch(feed, (0.75, 0.4, 0.05, 0.18), log, name='玻璃門', interval=5, settle=0,
                           measure=lambda jpeg: 183.0)
        watch.pending = True  # as if one bright look had happened: the first sample decides (0.5.49 takes two)
        return watch

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
        self.codex_efforts = {}   # Codex: the effort the slider was set to, per page
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
        if app == 'codex':  # the slider's pick shows on the model button until the next reply
            if self.codex_efforts.get(doc, '中') == label:
                return 'already'
            self.codex_efforts[doc] = label
            return 'fake'
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
        if '多工具' in text and app == 'claude':  # a few tool calls before the reply (folded on the phone)
            self.write(app, path, 'tools', text)
        if '計畫' in text and app == 'claude':  # a task list under the reply (a card on the phone)
            self.write(app, path, 'plan', text)
        self.later(app, path, reply, delay, doc)
        return replaced

    def new_send(self, app, button, text, model=None, effort=None, images=None):
        self.calls.append(('new_send', app, button) + tuple(('image', Path(path).stat().st_size) for path in images or []))
        session_id, path = self.setup.create_session(app, text[:24] or '照片')
        self.open_doc[app] = self.hub.sources[app].info(session_id)['doc']
        if model:
            self.set_model(app, self.open_doc[app], model)
        if effort:
            self.set_effort(app, self.open_doc[app], effort)
        if images:
            self.write(app, path, 'user-image', text, len(images))
        else:
            self.write(app, path, 'user', text)
        self.later(app, path, f'（示範）新對話收到：{text[:30] or "照片"}')

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
        ts = datetime.now(UTC).strftime('%Y-%m-%dT%H:%M:%S.000Z')
        if app == 'codex':
            reply = [{'questionItemId': json.dumps([CODEX_QUESTION_TOOL, question['questionId'], n]),
                      'question': q['question'], 'answer': c} for n, (q, c) in enumerate(zip(question['questions'], chosen))]
            text = f'<{CODEX_REPLY_TAG}>\n{json.dumps(reply, ensure_ascii=False)}\n</{CODEX_REPLY_TAG}>\n'
            line = {'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                'type': 'UserMessage', 'content': [{'type': 'text', 'text': text}]}}}
        else:
            pairs = ', '.join(f'"{q["question"]}"="{c}"' for q, c in zip(question['questions'], chosen))
            line = {'type': 'user', 'timestamp': ts,
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
            blocks = [{'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': FAKE_PNG}}] * photos
            if text.strip():
                blocks.append({'type': 'text', 'text': text})
            if app == 'claude':
                lines = [{'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': blocks}}]
            else:
                lines = [{'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'task_started'}},
                         {'timestamp': ts, 'type': 'event_msg', 'payload': {'type': 'item_completed', 'item': {
                             'type': 'UserMessage', 'content': [{'type': 'input_image', 'image_url': 'data:image/png;base64,' + FAKE_PNG}] * photos
                             + blocks[photos:]}}}]  # with the picture, as Codex records it (so the phone shows it)
        elif role == 'plan' and app == 'claude':
            # The task list as the desktop writes it: an update_plan call, then its wrap-up later.
            lines = [{'type': 'assistant', 'timestamp': ts, 'message': {'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': 'fake-plan-' + secrets.token_hex(3), 'name': 'mcp__ccd_turn__update_plan',
                 'input': {'items': [{'content': '讀設定檔', 'status': 'completed'},
                                     {'content': '改程式', 'status': 'in_progress'},
                                     {'content': '跑測試', 'status': 'pending'}], 'scope': 'first_task'}}]}}]
        elif role == 'tools' and app == 'claude':
            # Three tool calls in a row with their results (the phone folds them into one line).
            lines = []
            batch = secrets.token_hex(3)
            for n, (name, data, output) in enumerate([('Bash', {'command': 'ls'}, 'a.txt\nb.txt'),
                                                      ('Read', {'file_path': 'a.txt'}, 'hello'),
                                                      ('Bash', {'command': 'cat b.txt'}, 'world')]):
                lines.append({'type': 'assistant', 'timestamp': ts, 'message': {'role': 'assistant', 'content': [
                    {'type': 'tool_use', 'id': f'fake-tool-{batch}-{n}', 'name': name, 'input': data}]}})
                lines.append({'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': [
                    {'type': 'tool_result', 'tool_use_id': f'fake-tool-{batch}-{n}', 'content': output}]}})
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
    binding = lan_binding(cfg)
    if binding:
        serve_lan(hub, gate, cfg, networks, runner, binding)
    server.serve_forever(poll_interval=1)


def build_driving(hub, driver, notify, pc_name, cfg, interval, verify_seconds, memory=None):
    """Watcher and action runner over `driver`, both on their own threads."""
    watcher = UiWatcher(hub, driver, notify, pc_name, interval=interval, memory=memory)
    folder = (cfg.get('clipboard') or {}).get('folder')
    if folder:
        watcher.board = IdleBoard(folder, pc_name)
    hub.prompts = watcher.prompt_for
    hub.ui = watcher.current
    hub.popups = watcher.popup_list
    hub.versions = watcher.version_list
    hub.strings = load_strings()
    runner = ActionRunner(hub, driver, hub.presence, watcher, notify, pc_name, hub.strings,
                          idle_seconds=int(cfg.get('idle_seconds', 60)), verify_seconds=verify_seconds)
    watcher.busy = lambda: bool(runner.queue)
    hub.capabilities = ['read', 'send', 'permission', 'new', 'open', 'question', 'model', 'effort', 'mode', 'stop',
                        'photo', 'launch', 'photos', 'popups', 'fast', 'update', 'new-photos']
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
# Codex's queued message with its steer/delete buttons, as the worker lists it (home PC 11/6).
FAKE_QUEUE = {'hwnd': 777, 'title': CODEX_QUEUE_TITLE, 'process': 'ChatGPT', 'text': '螢幕也有點閃',
              'buttons': ['引導', '刪除'], 'page': True, 'queue': True}
FAKE_POPUP = {'hwnd': 4242, 'title': 'Windows 安全性', 'process': 'SecurityHealthHost',
              'text': '是否要允許公開和私人網路存取此應用程式?\nWindows 防火牆已封鎖所有公用和私人網路上 示範程式 的部分功能。\n示範程式',
              'buttons': ['允許', '取消']}
# Claude's question, drawn inside its page, when told to restart to update while Claude Code works
# (read live 10/30).
FAKE_QUIT_GUARD = {'hwnd': 4343, 'title': 'Claude 仍在處理中', 'process': 'claude', 'page': True,
                   'text': 'Claude 仍在處理中\nClaude 正在 1 個工作階段中執行作業。立即重新啟動將會中斷該作業。',
                   'buttons': ['取消', '等待 Claude', '仍要更新']}
# A 24 x 24 gradient PNG (981 bytes): the picture in fake mode's photo messages, so the phone has
# something to show.
FAKE_PNG = ('iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAADnElEQVR42hXToRpFERCF0ZNlWZZlWZZlWf6zLMuyLMuyLHuO63qA9Zk9e76PT/BJ'
            'PsWn+Qyf5XN8ni/wRb7EB1/mK3yVr/F1vsE3+Rbf5jt8l+/7EAIhEQqhEQZhEQ7hEQEREQkBIiMKoiIaoiMGYiIWYiMO4iIeJAVSIhVSIw3S'
            'Ih3SIwMyIhMSZEYWZEU2ZEcO5EQu5EYe5EU+SAmURCmURhmURTmURwVURCUUqIwqqIpqqI4aqIlaqI06qIt6kBZoiVZojTZoi3Zojw7oiE5o'
            '0Bld0BXd0B090BO90Bt90Bf9ICMwEqMwGmMwFuMwHhMwEZMwYDKmYCqmYTpmYCZmYTbmYC7mQVZgJVZhNdZgLdZhPTZgIzZhwWZswVZsw3bs'
            'wE7swm7swV7sg5zASZzCaZzBWZzDeVzARVzCgcu4gqu4huu4gZu4hdu4g7u4B3mBl3iF13iDt3iH9/iAj/iEB5/xBV/xDd/xAz/xC7/xB3/x'
            'DwqCIAmKoAmGYAmO4AmBEAmJACETCqESGqETBmESFmETDuESHhQFURIVURMN0RId0RMDMRITEWImFmIlNmInDuIkLuImHuIlPigJkiQpkiYZ'
            'kiU5kicFUiQlEqRMKqRKaqROGqRJWqRNOqRLetD/BF55X+1eYd6q35JevC+YN9L7zGPey1CgQoMOAyYs2HDgvmv8yIIsyYqsyYZsyY7syYEc'
            'yemP5Ewu5Epu5E4e5Ele5E0+5Et+UBEUSVEUTTEUS3EUTwmUSEn/r5RMKZRKaZROGZRJWZRNOZRLeVAVVElVVE01VEt1VE8N1EhN/4FqphZq'
            'pTZqpw7qpC7qph7qpT6oCZqkKZqmGZqlOZqnBVqkpX8sLdMKrdIardMGbdIWbdMO7dIe1AVd0hVd0w3d0h3d0wM90tM/3J7phV7pjd7pgz7p'
            'i77ph37pDxqCIRmKoRmGYRmO4RmBERnpv6KRGYVRGY3RGYMxGYuxGYdxGQ+agimZiqmZhmmZjumZgRmZ6b/omZmFWZmN2ZmDOZmLuZmHeZkP'
            'WoIlWYqlWYZlWY7lWYEVWelfl5VZhVVZjdVZgzVZi7VZh3VZD9qCLdmKrdmGbdmO7dmBHdnpX7qd2YVd2Y3d2YM92Yu92Yd92Q86giM5iqM5'
            'hmM5juM5gRM56V/dkzmFUzmN0zmDMzmLszmHczkPuoIruYqruYZruY7ruYEbuel/ADdzC7dyG7dzB3dyF3dzD/dyfzqBE663RbzJAAAAAElF'
            'TkSuQmCC')
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
            driver.fake_update = {'claude': '重新啟動以更新 v4.30.0', 'codex': '有可用的更新'}
            driver.fake_update_guard = True  # Claude Code is "working": Claude asks first
            driver.fake_versions = {'claude': ('3.6556.2.0', '3.6556.2.0'), 'codex': ('26.1023.6123.0', '26.1023.6123.0')}
        runner = build_driving(hub, driver, None, cfg['pc_name'], cfg, interval=1, verify_seconds=10)
        if args.fake_update:
            # Memory nearly full with a leaking Steam (freed on its own), and a newer helper on disk
            # that the phone restarts into (11/01).
            leak = [{'pid': 7, 'name': 'steam', 'path': 'steam.exe', 'bytes': 2 ** 30, 'handles': 2_470_000},
                    {'pid': 8, 'name': 'game', 'path': 'game.exe', 'bytes': 12 * 2 ** 30, 'handles': 900}]
            hub.ram = MemoryWatch(cfg['pc_name'], charge=lambda: (164 * 2 ** 30, 178 * 2 ** 30),
                                  processes=lambda: leak, steam=lambda processes: 'shut-down')
            disk = ['9.9.9']
            hub.disk_version = lambda: disk[0]
            hub.restart = lambda: disk.__setitem__(0, VERSION)
        hub.elevate = fake.elevate_relay()
        hub.screen = lambda: (fake.fixtures / 'screen.jpg').read_bytes()
        hub.camera = CameraFeed(lambda: FakeCamera(fake.fixtures / 'camera.jpg'), idle=3)
        hub.light = fake.light_watch(hub.camera)
        threading.Thread(target=hub.light.run_forever, daemon=True, name='light-watch').start()
        hub.clipboard = fake.clipboard_sync()
        gate = AuthGate(cfg['token'])
        return serve(hub, gate, cfg, networks, runner)
    path = args.config or default_config_path()
    cfg, networks = load_config(path)
    log = RotatingFileHandler(path.parent / 'helper.log', maxBytes=1048576, backupCount=3, encoding='utf-8')
    log.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s', '%Y-%m-%d %H:%M:%S'))
    logger.addHandler(log)
    pictures, tunnel = pictures_from_config(cfg, path.parent)
    if isinstance(pictures, PictureStore):
        settings = cfg['notify']['pictures']
        pictures.serve(str(settings.get('bind_ip') or '127.0.0.1'), int(settings.get('port') or 18791))
        pictures.sweep()
        threading.Thread(target=pictures.run_forever, daemon=True, name='picture-sweep').start()
        if tunnel is not None:
            threading.Thread(target=tunnel.run_forever, daemon=True, name='quick-tunnel').start()
    elif pictures is not None:  # GitPictures: clone now (the first picture then only pushes), sweep daily
        try:
            pictures.ensure()
            pictures.sweep()
        except OSError as exc:
            logging.warning('pictures: %s', exc)
        threading.Thread(target=pictures.run_forever, daemon=True, name='picture-sweep').start()
    notifier = Notifier(cfg, pictures=pictures)
    notify = notifier.post if (cfg.get('notify') or {}).get('topic') else None
    pc_name = cfg.get('pc_name') or os.environ.get('COMPUTERNAME', 'PC')
    hub = Hub(pc_name, real_sources(cfg), WindowsPresence())
    if cfg.get('codex_live_limits', True):
        live = CodexLiveLimits()
        hub.sources['codex'].live = live
        threading.Thread(target=live.run_forever, daemon=True).start()
    if cfg.get('screen', True):
        hub.screen = capture_screen
    hub.camera = camera_from_config(cfg)
    hub.light = light_watch_from_config(cfg, hub.camera, notify, pc_name, path.parent)
    if hub.light is not None:
        threading.Thread(target=hub.light.run_forever, daemon=True, name='light-watch').start()
    runner = None
    if cfg.get('drive_windows', True):
        driver = WindowsDriver(load_strings())
        runner = build_driving(hub, driver, notify, pc_name, cfg, interval=4, verify_seconds=20,
                               memory=path.parent / 'usage_seen.json')
        hub.ram = MemoryWatch(pc_name, worker=driver.worker)
        hub.restart = lambda: restart_helper(driver.worker)
    hub.clipboard = clipboard_sync_from_config(cfg, pc_name)
    if hub.clipboard is not None:
        threading.Thread(target=hub.clipboard.run_forever, daemon=True).start()
    submit = Path((cfg.get('elevate') or {}).get('submit_file') or elevate.submit_file())
    if submit.exists():  # written by install-elevated.ps1 (run once as administrator)
        port, token = elevate.load_submit(submit)
        hub.elevate = ElevateRelay(lambda message: elevate.call(port, dict(message, token=token)), notify, pc_name)
        threading.Thread(target=hub.elevate.run_forever, daemon=True).start()
    gate = AuthGate(cfg['token'])
    return serve(hub, gate, cfg, networks, runner)


if __name__ == '__main__':
    main()
