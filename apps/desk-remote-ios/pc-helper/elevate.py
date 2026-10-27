"""elevate: run one PowerShell command or script as administrator, after the phone approves it.

    elevate -c "<PowerShell command>" [--cwd DIR] [--timeout SECONDS]
    elevate -f <script.ps1>           [--cwd DIR] [--timeout SECONDS]

The request goes to the elevated companion (desk_remote_elevated.ps1, 127.0.0.1 only), which
pushes it to the phone through the desk remote helper. It runs only after the phone approves
it with Face ID, then its output and exit code come back here unchanged. Exit codes of its own:
126 denied or not approved within 10 minutes, 124 stopped at its time limit, 125 refused
(too many requests waiting, empty or too large), 127 the companion is not running.

This file also holds the protocol's Python twin (ElevatorLogic), used by the helper's tests
and the simulator's fake helper; the real companion is the PowerShell script.
"""
import argparse
import hashlib
import hmac
import json
import os
import secrets
import socket
import socketserver
import sys
import threading
import time
from pathlib import Path

TTL = 600
MAX_PENDING = 3
PER_MINUTE = 5
MAX_CONTENT = 100000


def submit_file():
    return Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'DeskRemote' / 'elevate-submit.json'


def load_submit(path=None):
    """(port, token) from the file the admin install wrote for this user."""
    data = json.loads(Path(path or submit_file()).read_text(encoding='utf-8-sig'))
    return int(data['port']), str(data['submit_token'])


def call(port, message, timeout=10):
    """One JSON line to the companion on 127.0.0.1 and its one-line answer."""
    with socket.create_connection(('127.0.0.1', port), timeout=timeout) as sock:
        sock.sendall((json.dumps(message, ensure_ascii=True) + '\n').encode('ascii'))
        buffer = b''
        while not buffer.endswith(b'\n'):
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
    return json.loads(buffer.decode('utf-8'))


def signed_message(request_id, content, cwd, expires):
    sha = hashlib.sha256(content.encode('utf-8')).hexdigest()
    return f'{request_id}\n{sha}\n{cwd}\n{int(expires)}'.encode('utf-8')


def signature(key, request_id, content, cwd, expires):
    """What the phone computes to approve: HMAC-SHA256 over id, content hash, cwd and expiry."""
    return hmac.new(key, signed_message(request_id, content, cwd, expires), hashlib.sha256).hexdigest()


class ElevatorLogic:
    """The companion's rules in Python, for tests and the fake helper. `run(content, cwd, timeout)`
    returns (exit code, stdout, stderr) and stands in for an elevated PowerShell."""

    def __init__(self, key, token, run=None, clock=time.time, ttl=TTL):
        self.key, self.token, self.clock, self.ttl = key, token, clock, ttl
        self.run = run or (lambda content, cwd, timeout: (0, f'(fake) ran: {content[:60]}\n', ''))
        self.requests, self.recent, self.asked = {}, [], []
        self.lock = threading.Lock()

    def handle(self, message):
        if not hmac.compare_digest(str(message.get('token', '')).encode(), self.token.encode()):
            return {'ok': False, 'error': 'unauthorized'}
        with self.lock:
            self.expire()
            op = message.get('op')
            if op == 'request':
                return self.ask(message)
            if op == 'list':
                pending = [self.public(r) for r in sorted(self.requests.values(), key=lambda r: r['created'])
                           if r['state'] == 'pending']
                recent = [{'id': r['id'], 'kind': r['kind'], 'name': r['name'], 'state': r['state'],
                           'exitCode': r['exitCode'], 'finished': r['finished'], 'content': r['content'][:500],
                           'output': (r['stdout'] + r['stderr'])[:2000]} for r in self.recent]
                return {'ok': True, 'pending': pending, 'recent': recent}
            if op == 'status':
                r = self.requests.get(message.get('id')) or next((x for x in self.recent if x['id'] == message.get('id')), None)
                if r is None:
                    return {'ok': False, 'error': 'not-found'}
                return {'ok': True, 'state': r['state'], 'exitCode': r.get('exitCode'), 'stdout': r.get('stdout', ''),
                        'stderr': r.get('stderr', ''), 'expires': r['expires']}
            if op == 'decide':
                return self.decide(message)
        return {'ok': False, 'error': 'bad-request'}

    def ask(self, message):
        content = str(message.get('content') or '')
        if not content.strip():
            return {'ok': False, 'error': 'empty'}
        if len(content) > MAX_CONTENT:
            return {'ok': False, 'error': 'too-large'}
        now = int(self.clock())
        self.asked = [t for t in self.asked if now - t < 60]
        waiting = sum(1 for r in self.requests.values() if r['state'] == 'pending')
        if waiting >= MAX_PENDING or len(self.asked) >= PER_MINUTE:
            return {'ok': False, 'error': 'busy'}
        self.asked.append(now)
        timeout = int(message.get('timeout') or 600)
        r = {'id': secrets.token_hex(8), 'kind': 'script' if message.get('kind') == 'script' else 'command',
             'name': str(message.get('name') or ''), 'content': content, 'cwd': str(message.get('cwd') or ''),
             'created': now, 'expires': now + self.ttl, 'timeout': min(max(timeout, 1), 3600), 'state': 'pending',
             'exitCode': None, 'stdout': '', 'stderr': '', 'finished': None}
        self.requests[r['id']] = r
        return {'ok': True, 'id': r['id'], 'expires': r['expires']}

    def decide(self, message):
        r = self.requests.get(message.get('id'))
        if r is None or r['state'] != 'pending':
            return {'ok': False, 'error': 'not-found'}
        if self.clock() > r['expires']:
            return {'ok': False, 'error': 'expired'}
        if message.get('decision') == 'deny':
            self.finish(r, 'denied', 126, '', 'denied on the phone')
            return {'ok': True, 'state': 'denied'}
        if message.get('decision') != 'allow':
            return {'ok': False, 'error': 'bad-request'}
        expected = signature(self.key, r['id'], r['content'], r['cwd'], r['expires'])
        if not hmac.compare_digest(str(message.get('hmac') or '').lower().encode(), expected.encode()):
            return {'ok': False, 'error': 'bad-signature'}
        r['state'] = 'running'
        code, out, err = self.run(r['content'], r['cwd'], r['timeout'])
        self.finish(r, 'done', code, out, err)
        return {'ok': True, 'state': 'running'}

    def expire(self):
        now = self.clock()
        for r in list(self.requests.values()):
            if r['state'] == 'pending' and now > r['expires']:
                self.finish(r, 'expired', 126, '', 'the phone did not approve in time')

    def finish(self, r, state, code, out, err):
        r.update(state=state, exitCode=code, stdout=out, stderr=err, finished=int(self.clock()))
        self.requests.pop(r['id'], None)
        self.recent = ([r] + self.recent)[:10]

    @staticmethod
    def public(r):
        return {k: r[k] for k in ('id', 'kind', 'name', 'content', 'cwd', 'created', 'expires')}


def serve_logic(logic, port=0):
    """Serves ElevatorLogic on 127.0.0.1 with the same line protocol; returns the server."""
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            try:
                answer = logic.handle(json.loads(self.rfile.readline().decode('utf-8')))
            except ValueError:
                answer = {'ok': False, 'error': 'bad-request'}
            self.wfile.write((json.dumps(answer, ensure_ascii=True) + '\n').encode('ascii'))

    server = socketserver.ThreadingTCPServer(('127.0.0.1', port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


EXIT = {'denied': 126, 'expired': 126, 'timeout': 124}
REFUSED = {'busy': '已經有太多請求在等手機核准，請稍後再試', 'empty': '指令是空的', 'too-large': '指令太長',
           'unauthorized': '提交 token 不對（請重新執行管理員安裝腳本）'}


def run(argv=None, submit_path=None, poll=2.0, out=sys.stdout, err=sys.stderr):
    parser = argparse.ArgumentParser(prog='elevate', description='Run as administrator after phone approval')
    what = parser.add_mutually_exclusive_group(required=True)
    what.add_argument('-c', '--command', help='a PowerShell command')
    what.add_argument('-f', '--file', type=Path, help='a PowerShell script to run (its content is sent)')
    parser.add_argument('--cwd', default=os.getcwd())
    parser.add_argument('--timeout', type=int, default=600, help='seconds the approved command may run (max 3600)')
    args = parser.parse_args(argv)
    if args.file:
        content = args.file.read_text(encoding='utf-8-sig')
        kind, name = 'script', args.file.name
    else:
        content, kind, name = args.command, 'command', ''
    try:
        port, token = load_submit(submit_path)
    except (OSError, ValueError, KeyError):
        print('elevate: 找不到提權設定；請先用系統管理員身分執行 install-elevated.ps1', file=err)
        return 127
    try:
        answer = call(port, {'op': 'request', 'token': token, 'kind': kind, 'name': name, 'content': content,
                             'cwd': str(args.cwd), 'timeout': args.timeout})
    except OSError:
        print('elevate: 提權夥伴沒有在執行（排程工作 DeskRemoteElevated）', file=err)
        return 127
    if not answer.get('ok'):
        print('elevate: ' + REFUSED.get(answer.get('error'), f"被拒絕：{answer.get('error')}"), file=err)
        return 125
    print('elevate: 已送到手機，等待核准（最多 10 分鐘）…', file=err, flush=True)
    while True:
        time.sleep(poll)
        try:
            status = call(port, {'op': 'status', 'token': token, 'id': answer['id']})
        except OSError:
            print('elevate: 和提權夥伴的連線中斷', file=err)
            return 127
        state = status.get('state')
        if state in ('pending', 'running'):
            continue
        if status.get('stdout'):
            out.write(status['stdout'])
        if status.get('stderr'):
            err.write(status['stderr'])
        if state == 'done':
            return int(status.get('exitCode') or 0)
        print({'denied': 'elevate: 手機拒絕了這個請求', 'expired': 'elevate: 10 分鐘內沒有在手機核准',
               'timeout': 'elevate: 執行超過時間上限，已停止'}.get(state, f'elevate: {state}'), file=err)
        return EXIT.get(state, 126)


if __name__ == '__main__':
    sys.exit(run())
