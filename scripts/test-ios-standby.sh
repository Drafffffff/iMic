#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEVICE=${IMIC_SIM_NAME:-booted}
APP=${IMIC_SIM_APP:-$ROOT/build/ios.noindex/Build/Products/Debug-iphonesimulator/iMic.app}
xcrun simctl install "$DEVICE" "$APP"
python3 - "$DEVICE" <<'PY'
import pathlib, subprocess, sys, time
device = sys.argv[1]
container = pathlib.Path(subprocess.check_output([
    'xcrun', 'simctl', 'get_app_container', device, 'com.drafffffff.imic', 'data'
], text=True).strip())
log = container / 'Library/Logs/iMic/iMic.log'
offset = log.stat().st_size if log.exists() else 0
subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', device,
                'com.drafffffff.imic', '--ui-preview=idle', '--debug-standby-check'], check=True)
deadline = time.monotonic() + 80
while time.monotonic() < deadline:
    data = log.read_bytes() if log.exists() else b''
    recent = data[offset if len(data) >= offset else 0:].decode(errors='replace')
    if 'visual check FAIL' in recent:
        raise SystemExit(recent)
    if 'visual check PASS' in recent:
        print('Standby: 40-second hold, smooth fade/resume, zero idle callbacks, Reduce Motion, gestures, text, flight and visibility passed')
        break
    time.sleep(0.5)
else:
    raise SystemExit('Standby diagnostics did not complete within 80 seconds')
PY
