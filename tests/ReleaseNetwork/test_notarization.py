import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_network', ROOT / 'tools/release-network.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
ID = '11111111-2222-3333-4444-555555555555'


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dmg = Path(self.temp.name) / 'iMic-1.4.6-macOS-universal.dmg'
        self.dmg.write_bytes(b'signed original archive')
        self.job = release.Notarization(self.dmg, 'existing-profile')
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def status(self, value):
        return 0, json.dumps({'id': ID, 'status': value})

    def submitted(self):
        self.job.submission = ID
        self.job.save()

    def test_submit_transport_error_keeps_allocated_id_without_resubmitting(self):
        with patch.object(self.job, 'command', return_value=(1, f'id: {ID}\nHTTPClientError.connectTimeout')) as cmd:
            self.job.submit()
        self.assertEqual(cmd.call_count, 1)
        self.assertEqual(json.loads(self.job.state_path.read_text())['id'], ID)
        self.assertEqual(self.dmg.read_bytes(), b'signed original archive')

    def test_submit_error_without_id_does_not_resubmit(self):
        with patch.object(self.job, 'command', return_value=(1, 'connection reset')) as cmd:
            with self.assertRaisesRegex(RuntimeError, 'not resubmitting'):
                self.job.submit()
        self.assertEqual(cmd.call_count, 1)
        self.assertTrue(self.dmg.exists())

    def test_wait_recovers_then_accepts_same_id(self):
        self.submitted()
        with patch.object(self.job, 'command', side_effect=[(1, 'Trust failed: certificate name does not match input'),
                    self.status('In Progress'), self.status('Accepted')]) as cmd, patch.object(release.time, 'sleep') as sleep:
            self.job.wait()
        self.assertEqual(cmd.call_count, 3)
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [15, 30])

    def test_rejection_immediately_fetches_log(self):
        self.submitted()
        for status in ('Invalid', 'Rejected'):
            with self.subTest(status=status), patch.object(self.job, 'command', side_effect=[self.status(status), (0, 'reason')]) as cmd:
                with self.assertRaisesRegex(RuntimeError, 'rejected'):
                    self.job.wait()
                self.assertEqual(cmd.call_count, 2)
                self.assertIn('log', cmd.call_args.args)

    def test_authentication_error_is_not_retried(self):
        self.submitted()
        with patch.object(self.job, 'command', return_value=(1, '401 authentication failed; network')) as cmd:
            with self.assertRaisesRegex(RuntimeError, 'info failed'):
                self.job.wait()
        self.assertEqual(cmd.call_count, 1)

    def test_wait_exhausts_eight_attempts_and_preserves_checkpoint(self):
        self.submitted()
        with patch.object(self.job, 'command', return_value=(1, 'HTTPClientError.connectTimeout')) as cmd, patch.object(release.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, '8 status attempts'):
                self.job.wait()
        self.assertEqual(cmd.call_count, 8)
        self.assertEqual(json.loads(self.job.state_path.read_text())['sha256'], release.digest(self.dmg))

    def test_shared_deadline_prevents_another_poll(self):
        self.submitted()
        self.job.deadline = release.time.monotonic() - 1
        with patch.object(self.job, 'command') as cmd:
            with self.assertRaisesRegex(RuntimeError, '30-minute'):
                self.job.wait()
        cmd.assert_not_called()

    def test_resume_uses_checkpoint_and_rejects_other_bytes_or_id(self):
        self.submitted()
        resumed = release.Notarization(self.dmg, 'existing-profile', ID)
        self.assertEqual(resumed.submission, ID)
        with self.assertRaisesRegex(ValueError, 'Submission ID'):
            release.Notarization(self.dmg, 'existing-profile', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
        self.dmg.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'DMG changed'):
            release.Notarization(self.dmg, 'existing-profile', ID)

    def test_staple_retry_saves_changed_bytes_then_validates(self):
        self.submitted()
        def command(name, *args):
            if name == 'staple-1.log':
                self.dmg.write_bytes(b'partially stapled')
                return 1, 'network connection lost'
            return 0, 'ok'
        with patch.object(self.job, 'command', side_effect=command) as cmd, patch.object(release.time, 'sleep'):
            self.job.staple()
        self.assertEqual(cmd.call_count, 3)
        self.assertIn('validate', cmd.call_args.args)
        self.assertEqual(json.loads(self.job.state_path.read_text())['sha256'], release.digest(self.dmg))

    def test_permanent_staple_failure_stops_immediately(self):
        self.submitted()
        with patch.object(self.job, 'command', return_value=(65, 'unsupported file format')) as cmd:
            with self.assertRaisesRegex(RuntimeError, 'stapler failed'):
                self.job.staple()
        self.assertEqual(cmd.call_count, 1)

    def test_timestamp_classification_preserves_security_failures(self):
        self.assertTrue(release.network_error('A timestamp was expected but was not found.'))
        self.assertFalse(release.network_error('The specified item could not be found in the keychain.'))
        self.assertFalse(release.network_error('code object is not signed at all'))

    def test_bounded_command_terminates_without_success(self):
        code, output = release.run(['python3', '-c', 'import time; time.sleep(10)'], timeout=0.05)
        self.assertEqual(code, 124)
        self.assertIn('timeout', output)

    def test_cancel_kills_and_reaps_child_that_ignores_term(self):
        # A ready handshake makes cancellation deterministic: SIGTERM is already
        # ignored before communicate is interrupted. The watchdog only prevents
        # an old implementation from hanging the suite; it cannot satisfy the
        # assertion that run() itself escalated to SIGKILL.
        real_popen, real_killpg = subprocess.Popen, os.killpg
        children = []
        watchdogs = []

        def launch(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            children.append(child)
            self.assertTrue(select.select([child.stdout], [], [], 5)[0])
            self.assertEqual(child.stdout.readline(), b'ready\n')
            communicate = child.communicate
            first = True

            def interrupted_communicate(*args, **kwargs):
                nonlocal first
                if first:
                    first = False
                    raise KeyboardInterrupt('cancel fixture')
                return communicate(*args, **kwargs)

            child.communicate = interrupted_communicate

            def watchdog():
                try:
                    real_killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

            timer = threading.Timer(5, watchdog)
            timer.daemon = True
            timer.start()
            watchdogs.append(timer)
            return child

        try:
            with patch.object(release.subprocess, 'Popen', side_effect=launch), \
                    patch.object(release.os, 'killpg', wraps=real_killpg) as killpg, \
                    patch.object(release, 'CANCEL_GRACE_SECONDS', 0.05):
                with self.assertRaisesRegex(KeyboardInterrupt, 'cancel fixture'):
                    release.run([sys.executable, '-c',
                        'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                        'print("ready", flush=True); time.sleep(60)'])
                child = children[0]
                self.assertEqual([call.args for call in killpg.call_args_list],
                                 [(child.pid, signal.SIGTERM), (child.pid, signal.SIGKILL)])
                self.assertEqual(child.returncode, -signal.SIGKILL)
                with self.assertRaises(ChildProcessError):
                    os.waitpid(child.pid, os.WNOHANG)
                self.assertTrue(child.stdout.closed)
        finally:
            for timer in watchdogs:
                timer.cancel()
                timer.join()
            for child in children:
                if child.poll() is None:
                    real_killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
                child.stdout.close()


if __name__ == '__main__':
    unittest.main()
