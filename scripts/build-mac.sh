#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
VERSION=$(cat "$ROOT/VERSION")
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
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
  swiftc -swift-version 5 -O -target "${1}-apple-macosx13.0" -sdk "$SDK" \
    -framework AppKit -framework Network -framework CryptoKit -framework ApplicationServices \
    "$ROOT/shared/iMicLink.swift" \
    "$ROOT/shared/IMicLog.swift" \
    "$ROOT/shared/DeepSeekPolicy.swift" \
    "$ROOT/shared/TextRevision.swift" \
    "$ROOT/shared/PolishOptions.swift" \
    "$ROOT/mac/DeepSeek.swift" \
    "$ROOT/mac/BLEBridge.swift" \
    "$ROOT/mac/PairingStore.swift" \
    "$ROOT/mac/LinkServer.swift" \
    "$ROOT/mac/ASR.swift" \
    "$ROOT/mac/Credentials.swift" \
    "$ROOT/mac/ShortClipGate.swift" \
    "$ROOT/mac/SingleInstance.swift" \
    "$ROOT/mac/Permissions.swift" \
    "$ROOT/mac/InputTarget.swift" \
    "$ROOT/mac/Brand.swift" \
    "$ROOT/mac/StatusBar.swift" \
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
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>iMic 通过本地网络或点对点链路与你的 iPhone 建立加密语音连接。</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>iMic 在局域网不可用时通过蓝牙点对点连接 iPhone。</string>
<key>NSBonjourServices</key><array><string>_imic._tcp</string></array>
<key>NSHumanReadableCopyright</key><string>iMic · 语音输入，少一步。</string>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources/Legal"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Legal/"
ditto "$ROOT/licenses" "$APP/Contents/Resources/Legal/licenses"


# 使用开发者证书可以保持辅助功能授权在重新编译后继续有效。
IDENTITY=${IMIC_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}
if [ -z "$IDENTITY" ]; then
  echo "warning: no Apple Development identity found; signing ad hoc (permissions may need re-approval after rebuild)" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier com.drafffffff.imic --entitlements "$ROOT/mac/iMic.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP (signed by: $IDENTITY)"
