#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUNDLE_ID=${IMIC_BUNDLE_ID:-art.malette.imic}
DEVICE_JSON=$(mktemp /tmp/imic-log-device.XXXXXX.json)
trap 'rm -f "$DEVICE_JSON"' EXIT

if ! xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1; then
  echo "无法读取设备列表，请确认 iPhone 已解锁并通过数据线连接。" >&2
  exit 1
fi

DISCOVERED_UDID=$(python3 - "$DEVICE_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    if hardware.get("reality") == "physical" and hardware.get("udid"):
        print(hardware["udid"])
        break
PY
)
UDID=${IMIC_DEVICE_UDID:-$DISCOVERED_UDID}
if [ -z "$UDID" ]; then
  echo "没有找到已连接的物理 iPhone。" >&2
  exit 1
fi

mkdir -p "$ROOT/build/logs"
DEST=${1:-"$ROOT/build/logs/ios-iMic.log"}
xcrun devicectl device copy from \
  --device "$UDID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Library/Logs/iMic/iMic.log \
  --destination "$DEST"
echo "iPhone 日志: $DEST"
