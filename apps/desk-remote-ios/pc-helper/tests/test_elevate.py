"""Tests for phone-approved administrator commands (elevate.py, the relay, and on Windows the real
PowerShell companion, run without elevation against a scratch config)."""
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import desk_remote_helper as h  # noqa: E402
import elevate  # noqa: E402

KEY = b'k' * 32
TOKEN = 'submit-token-for-tests'
# Shared with the Swift tests: the phone must compute exactly this signature.
VECTOR = {'id': '0123456789abcdef', 'content': 'Restart-Service -Name Spooler\r\n# 測試', 'cwd': 'C:\\work',
          'expires': 1793100000}
VECTOR_HMAC = '0ca586d0d0ea0c76843937f83eb9541cf0726b8040a81b448472a864e62a4a6d'


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0

    def __call__(self):
        return self.now


def logic(clock=None, runs=None):
    def run(content, cwd, timeout):
        if runs is not None:
            runs.append((content, cwd))
        return 0, f'ran {content}\n', ''
    return elevate.ElevatorLogic(KEY, TOKEN, run=run, clock=clock or Clock())


def ask(lg, content='Get-Date', cwd='C:\\x', **extra):
    return lg.handle(dict({'op': 'request', 'token': TOKEN, 'kind': 'command', 'content': content, 'cwd': cwd}, **extra))


class LogicTests(unittest.TestCase):
    def test_signature_vector_is_stable(self):
        got = elevate.signature(KEY, VECTOR['id'], VECTOR['content'], VECTOR['cwd'], VECTOR['expires'])
        self.assertEqual(got, VECTOR_HMAC)

    def test_only_the_phone_signature_approves(self):
        runs = []
        lg = logic(runs=runs)
        r = ask(lg)
        self.assertTrue(r['ok'])
        pending = lg.handle({'op': 'list', 'token': TOKEN})['pending']
        self.assertEqual([p['id'] for p in pending], [r['id']])
        bad = lg.handle({'op': 'decide', 'token': TOKEN, 'id': r['id'], 'decision': 'allow', 'hmac': '0' * 64})
        self.assertEqual(bad['error'], 'bad-signature')
        self.assertEqual(runs, [])
        good = elevate.signature(KEY, r['id'], 'Get-Date', 'C:\\x', r['expires'])
        self.assertTrue(lg.handle({'op': 'decide', 'token': TOKEN, 'id': r['id'], 'decision': 'allow', 'hmac': good})['ok'])
        self.assertEqual(runs, [('Get-Date', 'C:\\x')])
        status = lg.handle({'op': 'status', 'token': TOKEN, 'id': r['id']})
        self.assertEqual((status['state'], status['exitCode']), ('done', 0))
        again = lg.handle({'op': 'decide', 'token': TOKEN, 'id': r['id'], 'decision': 'allow', 'hmac': good})
        self.assertEqual(again['error'], 'not-found', 'an approval is single use')

    def test_signature_binds_content_cwd_expiry_and_id(self):
        base = elevate.signature(KEY, 'a' * 16, 'Get-Date', 'C:\\x', 100)
        for other in (elevate.signature(KEY, 'b' * 16, 'Get-Date', 'C:\\x', 100),
                      elevate.signature(KEY, 'a' * 16, 'Get-Date ', 'C:\\x', 100),
                      elevate.signature(KEY, 'a' * 16, 'Get-Date', 'C:\\y', 100),
                      elevate.signature(KEY, 'a' * 16, 'Get-Date', 'C:\\x', 101),
                      elevate.signature(b'x' * 32, 'a' * 16, 'Get-Date', 'C:\\x', 100)):
            self.assertNotEqual(base, other)

    def test_deny_needs_no_signature_and_is_final(self):
        lg = logic()
        r = ask(lg)
        self.assertEqual(lg.handle({'op': 'decide', 'token': TOKEN, 'id': r['id'], 'decision': 'deny'})['state'], 'denied')
        self.assertEqual(lg.handle({'op': 'status', 'token': TOKEN, 'id': r['id']})['state'], 'denied')

    def test_late_approval_is_refused(self):
        clock = Clock()
        lg = logic(clock)
        r = ask(lg)
        good = elevate.signature(KEY, r['id'], 'Get-Date', 'C:\\x', r['expires'])
        clock.now += elevate.TTL + 1
        answer = lg.handle({'op': 'decide', 'token': TOKEN, 'id': r['id'], 'decision': 'allow', 'hmac': good})
        self.assertFalse(answer['ok'])
        self.assertEqual(lg.handle({'op': 'status', 'token': TOKEN, 'id': r['id']})['state'], 'expired')

    def test_limits_and_token(self):
        clock = Clock()
        lg = logic(clock)
        self.assertEqual(lg.handle({'op': 'list', 'token': 'wrong'})['error'], 'unauthorized')
        self.assertEqual(ask(lg, content='  ')['error'], 'empty')
        self.assertEqual(ask(lg, content='x' * (elevate.MAX_CONTENT + 1))['error'], 'too-large')
        self.assertTrue(all(ask(lg)['ok'] for _ in range(elevate.MAX_PENDING)))
        self.assertEqual(ask(lg)['error'], 'busy', 'at most three waiting')
        lg2 = logic(clock)
        for _ in range(elevate.PER_MINUTE):
            r = ask(lg2)
            lg2.handle({'op': 'decide', 'token': TOKEN, 'id': r['id'], 'decision': 'deny'})
        self.assertEqual(ask(lg2)['error'], 'busy', 'at most five a minute')
        clock.now += 61
        self.assertTrue(ask(lg2)['ok'])


class CliTests(unittest.TestCase):
    def setUp(self):
        self.lg = logic()
        self.server = elevate.serve_logic(self.lg)
        self.addCleanup(self.server.shutdown)
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder)
        self.submit = folder / 'elevate-submit.json'
        self.submit.write_text(json.dumps({'port': self.server.server_address[1], 'submit_token': TOKEN}), encoding='utf-8')
        self.folder = folder

    def run_cli(self, argv, decide):
        out, err = io.StringIO(), io.StringIO()
        result = {}
        thread = threading.Thread(target=lambda: result.update(code=elevate.run(argv, self.submit, 0.05, out, err)))
        thread.start()
        deadline = time.monotonic() + 5
        pending = []
        while time.monotonic() < deadline and not pending:
            pending = self.lg.handle({'op': 'list', 'token': TOKEN})['pending']
            time.sleep(0.02)
        self.assertTrue(pending, 'the CLI did not ask')
        decide(pending[0])
        thread.join(5)
        return result['code'], out.getvalue(), err.getvalue(), pending[0]

    def test_approved_command_prints_its_output_and_exit_code(self):
        def approve(p):
            self.lg.handle({'op': 'decide', 'token': TOKEN, 'id': p['id'], 'decision': 'allow',
                            'hmac': elevate.signature(KEY, p['id'], p['content'], p['cwd'], p['expires'])})
        code, out, err, p = self.run_cli(['-c', 'Get-Service Spooler', '--cwd', 'C:\\work'], approve)
        self.assertEqual((code, out), (0, 'ran Get-Service Spooler\n'))
        self.assertIn('等待核准', err)
        self.assertEqual((p['cwd'], p['kind']), ('C:\\work', 'command'))

    def test_denied_command_exits_126(self):
        code, out, err, _ = self.run_cli(['-c', 'Get-Date'], lambda p: self.lg.handle(
            {'op': 'decide', 'token': TOKEN, 'id': p['id'], 'decision': 'deny'}))
        self.assertEqual(code, 126)
        self.assertIn('拒絕', err)

    def test_script_file_sends_its_content(self):
        script = self.folder / 'fix.ps1'
        script.write_text('Write-Output 修好了\n', encoding='utf-8')
        code, out, err, p = self.run_cli(['-f', str(script)], lambda p: self.lg.handle(
            {'op': 'decide', 'token': TOKEN, 'id': p['id'], 'decision': 'deny'}))
        self.assertEqual((p['kind'], p['name'], p['content']), ('script', 'fix.ps1', 'Write-Output 修好了\n'))

    def test_missing_companion_or_setup_exits_127(self):
        self.server.shutdown()
        self.server.server_close()
        err = io.StringIO()
        self.assertEqual(elevate.run(['-c', 'x'], self.submit, 0.05, io.StringIO(), err), 127)
        self.assertEqual(elevate.run(['-c', 'x'], self.folder / 'missing.json', 0.05, io.StringIO(), io.StringIO()), 127)


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.lg = logic()
        self.sent = []
        self.relay = h.ElevateRelay(lambda m: self.lg.handle(dict(m, token=TOKEN)), lambda *a: self.sent.append(a), '辦公室')

    def test_relay_forwards_but_cannot_approve(self):
        ask(self.lg, content='秘密指令 Stop-Service X')
        snap = self.relay.snapshot()
        self.assertEqual(len(snap['pending']), 1)
        self.assertEqual(self.sent, [], 'requests already waiting at startup are not announced')
        p = snap['pending'][0]
        self.assertEqual(self.relay.decide(p['id'], 'allow', None)[0], 400)
        self.assertEqual(self.relay.decide(p['id'], 'allow', 'f' * 64)[0], 403)
        good = elevate.signature(KEY, p['id'], p['content'], p['cwd'], p['expires'])
        self.assertEqual(self.relay.decide(p['id'], 'allow', good)[0], 200)
        self.assertEqual(self.relay.snapshot()['recent'][0]['state'], 'done')

    def test_only_new_requests_go_to_ntfy_without_the_command(self):
        self.relay.poll()
        r = ask(self.lg, content='秘密指令 Stop-Service X')
        self.relay.poll()
        self.relay.poll()
        self.assertEqual([s[0] for s in self.sent], ['🔐 需要管理員權限'])
        self.relay.decide(r['id'], 'deny', None)
        self.relay.poll()
        # The result needs nobody (decided on the phone): not sent (user's choice 10/27).
        self.assertEqual([s[0] for s in self.sent], ['🔐 需要管理員權限'])
        self.assertFalse(any('秘密' in s[1] for s in self.sent), 'the command leaked into ntfy')

    def test_unreachable_companion_is_reported(self):
        def down(message):
            raise ConnectionRefusedError()
        relay = h.ElevateRelay(down)
        self.assertFalse(relay.snapshot()['available'])
        self.assertEqual(relay.decide('a' * 16, 'deny', None)[0], 503)


class HttpElevateTests(unittest.TestCase):
    """The phone's side: GET /v1/elevate and POST /v1/elevate/<id> on the fake helper."""

    def setUp(self):
        import ipaddress
        import urllib.request
        from http.server import ThreadingHTTPServer
        self.urllib = urllib
        fake = h.FakeSetup(HERE.parent.parent / 'fixtures' / 'fake-helper')
        self.addCleanup(shutil.rmtree, fake.root, True)
        self.key = bytes.fromhex(fake.cfg['elevate_key'])
        hub = h.Hub('示範電腦', fake.sources(), h.FixedPresence(fake.cfg['presence']))
        hub.elevate = fake.elevate_relay()
        self.token = fake.cfg['token']
        server = ThreadingHTTPServer(('127.0.0.1', 0), h.handler_for(hub, h.AuthGate(self.token), [ipaddress.ip_network('127.0.0.0/8')]))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.base = f'http://127.0.0.1:{server.server_address[1]}'

    def http(self, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = self.urllib.request.Request(self.base + path, data=data, method='POST' if data else 'GET',
                                              headers={'Authorization': f'Bearer {self.token}'})
        try:
            with self.urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except self.urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_phone_lists_and_approves_with_its_own_signature(self):
        state = self.http('/v1/state')[1]
        self.assertIn('elevate', state['capabilities'])
        code, listing = self.http('/v1/elevate')
        self.assertEqual((code, listing['available'], len(listing['pending'])), (200, True, 2))
        p = listing['pending'][0]
        self.assertEqual(p['content'], 'Restart-Service -Name Spooler')
        self.assertEqual(self.http(f"/v1/elevate/{p['id']}", {'decision': 'allow', 'hmac': '0' * 64})[0], 403)
        sig = elevate.signature(self.key, p['id'], p['content'], p['cwd'], p['expires'])
        self.assertEqual(self.http(f"/v1/elevate/{p['id']}", {'decision': 'allow', 'hmac': sig}), (200, {'ok': True, 'state': 'running'}))
        recent = self.http('/v1/elevate')[1]['recent']
        self.assertEqual((recent[0]['state'], recent[0]['exitCode']), ('done', 0))
        self.assertEqual(self.http('/v1/elevate/not-an-id', {'decision': 'deny'})[0], 404)


@unittest.skipUnless(os.name == 'nt' and shutil.which('powershell.exe'), 'the real companion runs on Windows')
class RealCompanionTests(unittest.TestCase):
    """desk_remote_elevated.ps1 itself, not elevated, against a scratch config."""

    @classmethod
    def setUpClass(cls):
        cls.folder = Path(tempfile.mkdtemp())
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            cls.port = probe.getsockname()[1]
        config = cls.folder / 'elevated.json'
        config.write_text(json.dumps({'port': cls.port, 'elevate_key': KEY.hex(), 'submit_token': TOKEN}), encoding='utf-8')
        cls.process = subprocess.Popen(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                        '-File', str(HERE.parent / 'desk_remote_elevated.ps1'), '-Config', str(config)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                socket.create_connection(('127.0.0.1', cls.port), timeout=1).close()
                break
            except OSError:
                time.sleep(0.2)

    @classmethod
    def tearDownClass(cls):
        cls.process.kill()
        cls.process.wait(10)
        shutil.rmtree(cls.folder, True)

    def call(self, **message):
        return elevate.call(self.port, dict(message, token=message.pop('token', TOKEN)))

    def wait_done(self, request_id):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            status = self.call(op='status', id=request_id)
            if status.get('state') not in ('pending', 'running'):
                return status
            time.sleep(0.3)
        self.fail('the approved command did not finish')

    def test_wrong_token_and_wrong_signature_are_refused(self):
        self.assertEqual(self.call(op='list', token='wrong')['error'], 'unauthorized')
        r = self.call(op='request', kind='command', content='Write-Output nope', cwd=str(self.folder))
        self.assertEqual(self.call(op='decide', id=r['id'], decision='allow', hmac='0' * 64)['error'], 'bad-signature')
        self.assertEqual(self.call(op='decide', id=r['id'], decision='deny')['state'], 'denied')

    def test_signed_command_runs_and_returns_utf8_output(self):
        content = 'Write-Output "hello 你好"; exit 3'
        r = self.call(op='request', kind='command', content=content, cwd=str(self.folder))
        self.assertTrue(r['ok'], r)
        pending = [p for p in self.call(op='list')['pending'] if p['id'] == r['id']][0]
        self.assertEqual(pending['content'], content, 'the phone must see exactly the content that will run')
        sig = elevate.signature(KEY, r['id'], pending['content'], pending['cwd'], pending['expires'])
        self.assertTrue(self.call(op='decide', id=r['id'], decision='allow', hmac=sig)['ok'])
        status = self.wait_done(r['id'])
        self.assertEqual((status['state'], status['exitCode']), ('done', 3), status)
        self.assertIn('hello 你好', status['stdout'])
        self.assertEqual(self.call(op='decide', id=r['id'], decision='allow', hmac=sig)['error'], 'not-found')


if __name__ == '__main__':
    unittest.main()
