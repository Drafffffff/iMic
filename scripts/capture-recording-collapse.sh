#!/bin/bash
# Static previews or real TTS + native-gesture recordings, on an explicitly named
# simulator. For send/cancel, first build-for-testing and start a headless Mac with
# --no-input --port=47856 --pair-code=864209 (same secure protocol as normal use).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
source "$ROOT/scripts/ios-bundle-id.sh"
DEVICE=${IMIC_SIM_NAME:?Set IMIC_SIM_NAME to the dedicated simulator UDID}
MODE=${1:-static}
OUT=${IMIC_COLLAPSE_OUT:-$ROOT/build/recording-collapse}
mkdir -p "$OUT"
python3 - "$ROOT" "$DEVICE" "$IMIC_SIM_BUNDLE_ID" "$MODE" "$OUT" <<'PY'
import os, pathlib, signal, subprocess, sys, time
root, device, bundle, mode, out = sys.argv[1:]
out = pathlib.Path(out)
def sim(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True, timeout=60).strip()
if mode in ('static', 'timeline'):
    cases = [('0', '0', 'crt'), ('025', '.25', 'crt'), ('060', '.6', 'crt'),
             ('100', '1', 'crt'), ('clean', '1', 'clean'), ('glow', '1', 'glow')]
    if mode == 'timeline':
        cases = [('time-0', '0', 'crt'), ('time-2', '2', 'crt'), ('time-5', '5', 'crt'), ('time-10', '10', 'crt'),
                 ('time-30', '30', 'crt'), ('time-60', '60', 'crt'), ('time-clean', '30', 'clean')]
    flag = '--debug-collapse-time=' if mode == 'timeline' else '--debug-collapse='
    for label, amount, material in cases:
        container = pathlib.Path(sim('get_app_container', device, bundle, 'data'))
        log = container / 'Library/Logs/iMic/iMic.log'
        offset = log.stat().st_size if log.exists() else 0
        sim('launch', '--terminate-running-process', device, bundle,
            '--ui-preview=idle', flag+amount, '--debug-display='+material)
        deadline = time.monotonic()+45
        while time.monotonic() < deadline:
            data = log.read_bytes() if log.exists() else b''
            if b'HDR targets' in data[offset if len(data)>=offset else 0:]:
                break
            time.sleep(.1)
        else:
            raise SystemExit('Unified renderer did not produce a frame')
        time.sleep(.5)
        sim('io', device, 'screenshot', str(out / ('collapse-'+label+'.png')))
    sys.exit(0)
if mode not in ('send', 'cancel'):
    raise SystemExit('Use static, timeline, send or cancel')
container = pathlib.Path(sim('get_app_container', device, bundle, 'data'))
app_log = container / 'Library/Logs/iMic/iMic.log'
offset = app_log.stat().st_size if app_log.exists() else 0
env = dict(os.environ, TEST_RUNNER_IMIC_COLLAPSE_CAPTURE=mode)
command = ['xcodebuild', 'test-without-building', '-project', root+'/ios/iMic.xcodeproj',
           '-scheme', 'iMic', '-destination', 'platform=iOS Simulator,id='+device,
           '-derivedDataPath', root+'/build/ios.noindex', '-parallel-testing-enabled', 'NO',
           'CODE_SIGNING_ALLOWED=NO', 'IMIC_BUNDLE_ID='+bundle,
           '-only-testing:iMicUITests/RecordingCollapseUITests/testRecordingRelease']
recorder = None
with (out / (mode+'.test.log')).open('w') as test_log, (out / (mode+'.rec.log')).open('w') as rec_log:
    test = subprocess.Popen(command, env=env, stdout=test_log, stderr=subprocess.STDOUT)
    deadline = time.monotonic()+100
    try:
        while test.poll() is None and time.monotonic() < deadline:
            # XCTest may reinstall the app into a new data-container UUID.
            if not app_log.exists():
                container = pathlib.Path(sim('get_app_container', device, bundle, 'data'))
                next_log = container / 'Library/Logs/iMic/iMic.log'
                if next_log != app_log:
                    app_log = next_log
            data = app_log.read_bytes() if app_log.exists() else b''
            recent = data[offset if len(data)>=offset else 0:].decode(errors='replace')
            if recorder is None and 'collapse begin' in recent:
                recorder = subprocess.Popen(['xcrun', 'simctl', 'io', device, 'recordVideo',
                    '--codec=h264', '--force', str(out / (mode+'.mov'))], stdout=rec_log, stderr=subprocess.STDOUT)
            time.sleep(.1)
        if test.poll() is None:
            test.terminate()
            raise SystemExit('Recording UI test timed out')
        if test.returncode or recorder is None:
            raise SystemExit('Capture failed; see '+str(out / (mode+'.test.log')))
    finally:
        if recorder is not None:
            recorder.send_signal(signal.SIGINT)
            recorder.wait(timeout=20)
    data = app_log.read_bytes()
    recent = data[offset if len(data)>=offset else 0:].decode(errors='replace')
    if 'collapse '+mode not in recent or 'collapse settled' not in recent:
        raise SystemExit('Missing release/settle evidence in app log')
    (out / (mode+'.app.log')).write_text(recent)
    print(mode+': real TTS, native release, collapse return and settling passed')
PY
