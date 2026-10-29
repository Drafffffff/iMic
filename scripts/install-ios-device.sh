#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUNDLE_ID=${IMIC_BUNDLE_ID:-art.malette.imic}
DEVICE_JSON=$(mktemp /tmp/imic-device.XXXXXX.json)
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
  echo "没有找到已连接的物理 iPhone。请解锁手机并重新插线。" >&2
  exit 1
fi
DEVICE_NAME=$(python3 - "$DEVICE_JSON" "$UDID" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for device in data.get("result", {}).get("devices", []):
    if device.get("hardwareProperties", {}).get("udid") == sys.argv[2]:
        print(device.get("deviceProperties", {}).get("name", "iPhone"))
        break
PY
)

TEAM=${IMIC_DEV_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
  | grep -o 'teamID = [A-Z0-9]*' | head -1 | awk '{print $3}')}
if [ -z "$TEAM" ]; then
  echo "没有可用的 Personal Team。请先在 Xcode → Settings → Accounts 登录 Apple ID。" >&2
  exit 1
fi

echo "设备: $DEVICE_NAME ($UDID)"
echo "团队: $TEAM"

cd "$ROOT/ios"
xcodegen generate >/dev/null

echo "==> 构建 Release"
xcodebuild \
  -project "$ROOT/ios/iMic.xcodeproj" \
  -scheme iMic \
  -configuration Release \
  -destination "id=$UDID" \
  -derivedDataPath "$ROOT/build/ios-device.noindex" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build | tail -4

APP="$ROOT/build/ios-device.noindex/Build/Products/Release-iphoneos/iMic.app"
if [ ! -d "$APP" ]; then
  echo "构建产物不存在: $APP" >&2
  exit 1
fi
if [ -f "$APP/embedded.mobileprovision" ]; then
  security cms -D -i "$APP/embedded.mobileprovision" > /tmp/imic-installed-profile.plist 2>/dev/null || true
  EXPIRY=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' /tmp/imic-installed-profile.plist 2>/dev/null || true)
  [ -n "$EXPIRY" ] && echo "描述文件到期: $EXPIRY"
  rm -f /tmp/imic-installed-profile.plist
fi

echo "==> 安装到 $DEVICE_NAME"
xcrun devicectl device install app --device "$UDID" "$APP" | tail -6

echo "==> 启动"
if xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"; then
  echo "已启动 iMic"
else
  cat <<'MSG'
应用已安装，但自动启动失败。请根据上方 devicectl 的具体错误处理：
- 若提示 Locked：解锁 iPhone 后打开 iMic。
- 若提示开发者证书未信任：到「设置 → 通用 → VPN 与设备管理」
  选择用于签名的 Apple Development 开发者证书并信任。

首次启动请允许「本地网络」与「麦克风」。
个人团队签名 7 天后过期，到期重新运行本脚本即可。
MSG
  exit 1
fi
