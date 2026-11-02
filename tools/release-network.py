#!/usr/bin/env python3
"""Bound release network operations; retain the exact submitted DMG for recovery.

No credentials are read here: Apple tools use the existing Keychain profile.
Retries never remove timestamp requirements or permit an unaccepted submission.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid


DELAYS = (0, 15, 30, 60, 120, 180, 240, 300)
NETWORK = re.compile(
    r'HTTPClientError|Trust failed|certificate.*(?:match|invalid|trust)|'
    r'NSURLError|\b-120[0-6]\b|timed?\s*out|timeout|network|connection|'
    r'could not connect|temporar|timestamp was expected but was not found|'
    r'timestamp service is not available|CloudKit.*(?:failed|error)|'
    r'Record not found|Could not find base64 encoded ticket', re.I)
AUTH = re.compile(r'\b(?:401|403)\b|unauthorized|forbidden|invalid credentials|'
                  r'No Keychain .* item found|authentication failed', re.I)


def network_error(output):
    return bool(NETWORK.search(output)) and not AUTH.search(output)


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run(command, timeout=120, log=None):
    # Kill the entire child process group on timeout, not just xcrun's wrapper.
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        data, _ = process.communicate(timeout=timeout)
        code = process.returncode
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        data, _ = process.communicate()
        data += f'\nNetwork command timeout after {timeout} seconds\n'.encode()
        code = 124
    output = data.decode(errors='replace')
    if log:
        log.write_text(output)
    print(output, end='', flush=True)
    return code, output


class Notarization:
    def __init__(self, dmg, profile, submission=None, output_directory=None):
        self.dmg = dmg.resolve(strict=True)
        self.profile = profile
        self.output_directory = output_directory or Path(__file__).resolve().parents[1] / "build/release"
        self.submission = submission
        self.state_path = self.dmg.with_suffix('.notarization.json')
        # One shared wall-clock budget for submit, status polling and stapling.
        self.deadline = time.monotonic() + 1800
        self.logs = Path(tempfile.mkdtemp(prefix='notarization-', dir=self.dmg.parent))
        if submission:
            uuid.UUID(submission)
            state = json.loads(self.state_path.read_text())
            if state['sha256'] != digest(self.dmg):
                raise ValueError('DMG changed since the notarization checkpoint')
            if state.get('id') and state['id'] != submission:
                raise ValueError('Submission ID differs from the retained DMG checkpoint')
        self.save()

    def save(self):
        state = {'id': self.submission, 'dmg': str(self.dmg), 'sha256': digest(self.dmg)}
        temporary = self.state_path.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(self.state_path)

    def pause(self, seconds):
        if time.monotonic() + seconds >= self.deadline:
            raise RuntimeError('Notarization/staple reached the 30-minute limit')
        if seconds:
            print(f'Waiting {seconds}s before the next attempt', flush=True)
            time.sleep(seconds)

    def command(self, name, *args):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Notarization/staple reached the 30-minute limit')
        return run(['xcrun', *args], timeout=min(120, remaining), log=self.logs / name)

    def submit(self):
        # Submit only once. Even a failed upload may have allocated a submission ID.
        # Use normal, non-progress output so that ID survives a transport failure.
        code, output = self.command('submit.log', 'notarytool', 'submit', str(self.dmg),
                                    '--keychain-profile', self.profile, '--no-wait', '--no-progress')
        match = re.search(r'^\s*id:\s*([0-9a-fA-F-]{36})\s*$', output, re.M)
        if match:
            self.submission = str(uuid.UUID(match[1]))
            self.save()
        if code and (not self.submission or not network_error(output)):
            raise RuntimeError(f'notarytool submit failed (exit {code}); not resubmitting')
        if not self.submission:
            raise RuntimeError('notarytool did not return a submission ID')

    def wait(self):
        for attempt, delay in enumerate(DELAYS, 1):
            self.pause(delay)
            print(f'==> Notarization info {attempt}/8: {self.submission}', flush=True)
            code, output = self.command(f'info-{attempt}.log', 'notarytool', 'info',
                                        self.submission, '--keychain-profile', self.profile,
                                        '--output-format', 'json')
            if code:
                if network_error(output):
                    continue
                raise RuntimeError(f'notarytool info failed (exit {code})')
            info = json.loads(output)
            if info.get('id', '').lower() != self.submission.lower():
                raise RuntimeError('Apple returned a different submission ID')
            status = info['status']
            if status == 'Accepted':
                return
            if status in ('Invalid', 'Rejected'):
                self.command('rejection.log', 'notarytool', 'log', self.submission,
                             '--keychain-profile', self.profile)
                raise RuntimeError(f'Apple rejected notarization: {status}')
            if status != 'In Progress':
                raise RuntimeError(f'Unexpected Apple notarization status: {status}')
        raise RuntimeError('Notarization still unavailable/pending after 8 status attempts')

    def staple(self):
        for attempt, delay in enumerate(DELAYS, 1):
            self.pause(delay)
            print(f'==> Staple {attempt}/8', flush=True)
            code, output = self.command(f'staple-{attempt}.log', 'stapler', 'staple', str(self.dmg))
            # Stapling may have attached bytes even when a later network check fails.
            # Persist those exact bytes so a second invocation can safely resume.
            self.save()
            if not code:
                code, _ = self.command('staple-validate.log', 'stapler', 'validate', str(self.dmg))
                if code:
                    raise RuntimeError('Stapled ticket validation failed')
                return
            if not network_error(output):
                raise RuntimeError(f'stapler failed (exit {code})')
        raise RuntimeError('Stapling failed after 8 network attempts')

    def recovery(self):
        print(f'Retained DMG: {self.dmg}\nSubmission ID: {self.submission or "not received"}',
              file=sys.stderr)
        if self.submission:
            script = Path(__file__).resolve().parents[1] / 'scripts/package-release.sh'
            print('Resume: ' + shlex.join(['env', 'IMIC_NOTARY_PROFILE=' + self.profile,
                  str(script), '--resume-notarization', self.submission, str(self.dmg), str(self.output_directory)]),
                  file=sys.stderr)
        else:
            print('No submission ID: retain this signed DMG; resolve the submit error before submitting it again.',
                  file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    notarize = commands.add_parser('notarize')
    notarize.add_argument('--dmg', type=Path, required=True)
    notarize.add_argument('--profile', required=True)
    notarize.add_argument('--resume')
    notarize.add_argument('--output-directory', type=Path)
    retry = commands.add_parser('retry')
    retry.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'retry':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('retry requires a command')
        # Codesign timestamp failures are bounded independently (4 calls, <= 9 min).
        for attempt, delay in enumerate((0, 5, 15, 30), 1):
            if delay:
                print(f'Retrying timestamp in {delay}s ({attempt}/4)', flush=True)
                time.sleep(delay)
            code, output = run(command)
            if not code:
                return
            if not network_error(output):
                raise RuntimeError(f'Command failed (exit {code}); not a network/timestamp error')
        raise RuntimeError('Timestamp signing failed after 4 attempts')
    job = Notarization(args.dmg, args.profile, args.resume, args.output_directory)
    try:
        if not args.resume:
            job.submit()
        job.wait()
        job.staple()
    except BaseException:
        job.recovery()
        raise


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, KeyError) as error:
        print(f'Release network operation failed: {error}', file=sys.stderr)
        sys.exit(1)
