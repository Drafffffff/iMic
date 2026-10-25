#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DESTINATION=${IMIC_SIM_DESTINATION:-generic/platform=iOS Simulator}
RUN=false
if [ "${1:-}" = "--run" ]; then RUN=true; fi

cd "$ROOT/ios"
xcodegen generate

mkdir -p "$ROOT/build/tools"
swiftc -swift-version 5 -O "$ROOT/tools/icon.swift" -o "$ROOT/build/tools/icon-gen" -framework AppKit
"$ROOT/build/tools/icon-gen" ios "$ROOT/ios/iMic/Assets.xcassets/AppIcon.appiconset"

xcodebuild \
  -project "$ROOT/ios/iMic.xcodeproj" \
  -scheme iMic \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT/build/ios.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$ROOT/build/ios.noindex/Build/Products/Debug-iphonesimulator/iMic.app"
echo "Built: $APP"

if [ "$RUN" = true ]; then
  DEVICE=${IMIC_SIM_NAME:-$(xcrun simctl list devices available | sed -nE 's/^ +iPhone[^(]*\(([0-9A-F-]{36})\).*/\1/p' | head -1)}
  if [ -z "$DEVICE" ]; then
    echo "没有可用的 iPhone 模拟器，请先安装 iOS Simulator runtime。" >&2
    exit 1
  fi
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  xcrun simctl bootstatus "$DEVICE" -b
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl launch "$DEVICE" com.drafffffff.imic
  echo "Launched on simulator: $DEVICE"
fi
