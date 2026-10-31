#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
VERSION=$(cat "$ROOT/VERSION")
BUILD=$(cat "$ROOT/MAC_BUILD")
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "MAC_BUILD 必须为正整数。" >&2; exit 1; }
CONFIG=${IMIC_CONFIGURATION:-release}
SWIFT_FLAGS=(-D IMIC_RELEASE)
PUBLIC_KEY_FILE="$ROOT/mac/sparkle-public-key.txt"
if [ "$CONFIG" = debug ]; then
  SWIFT_FLAGS=(-D DEBUG)
  BUILD=${IMIC_TEST_BUILD:-$BUILD}
  [[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "测试构建号必须为正整数。" >&2; exit 1; }
  PUBLIC_KEY_FILE=${IMIC_TEST_PUBLIC_KEY_FILE:-$PUBLIC_KEY_FILE}
elif [ "$CONFIG" != release ]; then
  echo "IMIC_CONFIGURATION 只支持 release / debug。" >&2; exit 1
fi
PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")
AUTOMATIC_CHECKS=true
if ! python3 "$ROOT/tools/appcast.py" key "$PUBLIC_KEY_FILE"; then
  AUTOMATIC_CHECKS=false
  echo "提示：更新公钥尚未配置；开发构建关闭自动更新检查。" >&2
fi
"$ROOT/scripts/fetch-sparkle.sh"
if [ "${DEVELOPER_DIR+x}" != x ]; then
  DEVELOPER_DIR=""
  if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif SELECTED_DEVELOPER_DIR=$(xcode-select -p 2>/dev/null) && [ -d "$SELECTED_DEVELOPER_DIR" ]; then
    DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
  fi
fi
if [ -n "$DEVELOPER_DIR" ]; then export DEVELOPER_DIR; fi
if ! xcrun --find swiftc >/dev/null 2>&1 || ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  echo "未找到 Swift 编译器或 macOS SDK。Mac 端只需要命令行工具，请先运行：xcode-select --install" >&2
  exit 1
fi
SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCH=${IMIC_ARCH:-$(uname -m)}
OUT=${IMIC_BUILD_DIR:-"$ROOT/build/mac.noindex"}
APP="$OUT/iMic.app"
TOOLS="$ROOT/build/tools"

case "$ARCH" in
  arm64|x86_64|universal) ;;
  *) echo "不支持的 Mac 架构: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TOOLS"

# App icon
swiftc -swift-version 5 -O "$ROOT/tools/icon.swift" -o "$TOOLS/icon-gen" -framework AppKit
"$TOOLS/icon-gen" mac "$OUT/iMic.iconset"
iconutil -c icns "$OUT/iMic.iconset" -o "$APP/Contents/Resources/iMic.icns"

build_binary() {
  swiftc -swift-version 5 -O "${SWIFT_FLAGS[@]}" -F "$ROOT/build/vendor/Sparkle" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks -target "${1}-apple-macosx13.0" -sdk "$SDK" \
    -framework AppKit -framework Network -framework CryptoKit -framework ApplicationServices -framework Vision -framework ScreenCaptureKit -framework ServiceManagement \
    "$ROOT/shared/iMicLink.swift" \
    "$ROOT/shared/IMicLog.swift" \
    "$ROOT/shared/DeepSeekPolicy.swift" \
    "$ROOT/shared/TextRevision.swift" \
    "$ROOT/shared/PolishOptions.swift" \
    "$ROOT/shared/GestureControl.swift" \
    "$ROOT/mac/CloudFailure.swift" \
    "$ROOT/mac/DeepSeek.swift" \
    "$ROOT/mac/BLEBridge.swift" \
    "$ROOT/mac/PairingStore.swift" \
    "$ROOT/mac/LinkServer.swift" \
    "$ROOT/mac/ASR.swift" \
    "$ROOT/mac/Credentials.swift" \
    "$ROOT/mac/ShortClipGate.swift" \
    "$ROOT/mac/SingleInstance.swift" \
    "$ROOT/mac/Permissions.swift" \
    "$ROOT/mac/Onboarding.swift" \
    "$ROOT/mac/SettingsValidation.swift" \
    "$ROOT/mac/SettingsField.swift" \
    "$ROOT/mac/SettingsWindow.swift" \
    "$ROOT/mac/Updater.swift" \
    "$ROOT/mac/InputTarget.swift" \
    "$ROOT/mac/PolishPresentation.swift" \
    "$ROOT/mac/TextMarkerGeometry.swift" \
    "$ROOT/mac/TextPolishEffect.swift" \
    "$ROOT/mac/Brand.swift" \
    "$ROOT/mac/StatusBar.swift" \
    "$ROOT/mac/MacExperience.swift" \
    "$ROOT/mac/Interface.swift" \
    "$ROOT/mac/main.swift" \
    -o "$2"
}

if [ "$ARCH" = universal ]; then
  BIN_DIR=$(mktemp -d "$OUT/.universal.XXXXXX")
  trap 'rm -rf "$BIN_DIR"' EXIT
  build_binary arm64 "$BIN_DIR/iMic-arm64"
  build_binary x86_64 "$BIN_DIR/iMic-x86_64"
  lipo -create "$BIN_DIR/iMic-arm64" "$BIN_DIR/iMic-x86_64" -output "$APP/Contents/MacOS/iMic"
  lipo "$APP/Contents/MacOS/iMic" -verify_arch arm64
  lipo "$APP/Contents/MacOS/iMic" -verify_arch x86_64
else
  build_binary "$ARCH" "$APP/Contents/MacOS/iMic"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.drafffffff.imic</string>
<key>CFBundleName</key><string>iMic</string>
<key>CFBundleDisplayName</key><string>iMic</string>
<key>CFBundleIconFile</key><string>iMic</string>
<key>CFBundleExecutable</key><string>iMic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>SUFeedURL</key><string>https://drafffffff.github.io/iMic/appcast.xml</string>
<key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><$AUTOMATIC_CHECKS/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>iMic 通过本地网络或点对点链路与你的 iPhone 建立加密语音连接。</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>iMic 在局域网不可用时通过蓝牙点对点连接 iPhone。</string>
<key>NSScreenCaptureUsageDescription</key><string>iMic 仅在本机识别目标输入框的文字位置，用于润色完成时的扫光效果，不保存或上传截图。</string>
<key>NSBonjourServices</key><array><string>_imic._tcp</string></array>
<key>NSHumanReadableCopyright</key><string>iMic · 语音输入，少一步。</string>
</dict></plist>
PLIST
if [ "$CONFIG" = debug ] && [ "${IMIC_UPDATE_TEST:-0}" = 1 ]; then
  /usr/libexec/PlistBuddy -c 'Add :IMicUpdaterTest bool true' "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$ROOT/build/vendor/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
rm "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
mkdir -p "$APP/Contents/Resources/Legal"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Legal/"
ditto "$ROOT/licenses" "$APP/Contents/Resources/Legal/licenses"


# 使用开发者证书可以保持辅助功能授权在重新编译后继续有效。
IDENTITY=${IMIC_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}
if [ -z "$IDENTITY" ]; then
  echo "提示：未找到 Apple Development 证书，使用 ad-hoc 签名。" >&2
  echo "每次重新构建后，辅助功能授权会失效：请在「系统设置 → 隐私与安全性 → 辅助功能」中删除旧的 iMic，再重新添加。" >&2
  echo "可设置 IMIC_SIGNING_IDENTITY 指定签名证书。" >&2
  IDENTITY="-"
fi
"$ROOT/scripts/sign-mac.sh" "$APP" "$IDENTITY"
codesign --verify --deep --strict "$APP"
SIGNING_LABEL="$IDENTITY"
if [ "$IDENTITY" = "-" ]; then SIGNING_LABEL=ad-hoc; fi
echo "已构建：${APP}（签名：${SIGNING_LABEL}）"
