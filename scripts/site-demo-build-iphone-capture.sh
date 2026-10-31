#!/bin/bash
# Build the iPhone screen recorder as a small app bundle, so macOS can ask the user for
# camera access in its own name (iPhone screen capture counts as a camera source).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
APP="$ROOT/build/site-demo/bin/iMic Demo Capture.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O "$ROOT/tools/site-demo-iphone-capture.swift" -o "$APP/Contents/MacOS/iphone-capture" \
  -framework AVFoundation -framework CoreMediaIO
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>art.malette.imic.democapture</string>
<key>CFBundleName</key><string>iMic Demo Capture</string>
<key>CFBundleExecutable</key><string>iphone-capture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>录制通过数据线连接的 iPhone 屏幕，用于制作 iMic 官网演示视频。</string>
<key>NSMicrophoneUsageDescription</key><string>iPhone 屏幕采集源包含音频通道；不会录制 Mac 麦克风。</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier art.malette.imic.democapture "$APP"
echo "$APP"
