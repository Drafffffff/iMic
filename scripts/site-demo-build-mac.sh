#!/bin/bash
# Build the landing-page Mac demo window with the same bundle ID and Developer ID as the
# installed iMic, so it reuses the existing Accessibility grant for its own text field.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
APP="$ROOT/build/site-demo/mac/iMic.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework ApplicationServices -framework Vision -framework ScreenCaptureKit -framework CoreImage \
  "$ROOT/shared/Localization.swift" "$ROOT/shared/LinkStatusText.swift" "${ROOT}/shared/IMicLog.swift" "$ROOT/shared/TextRevision.swift" \
  "$ROOT/mac/InputTarget.swift" "$ROOT/mac/PolishPresentation.swift" "$ROOT/mac/TextMarkerGeometry.swift" \
  "$ROOT/mac/TextPolishEffect.swift" "$ROOT/tools/site-demo-mac/main.swift" -o "$APP/Contents/MacOS/iMic"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.drafffffff.imic</string>
<key>CFBundleName</key><string>iMic</string>
<key>CFBundleExecutable</key><string>iMic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$(cat "$ROOT/VERSION")</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
IDENTITY=${IMIC_DEMO_SIGNING_IDENTITY:-$(codesign -dvv /Applications/iMic.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)}
codesign --force --timestamp=none --sign "${IDENTITY:--}" --identifier com.drafffffff.imic \
  --entitlements "$ROOT/mac/iMic.entitlements" "$APP"
echo "Built $APP (${IDENTITY:-ad-hoc})"
