#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
SWIFT_SUPPORT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
WORK=$(mktemp -d /tmp/imic-sweep-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 -O -F "$FRAMEWORKS" -I "$SWIFT_SUPPORT" \
  -L "$SWIFT_SUPPORT" -lXCTestSwiftSupport -framework XCTest \
  -framework AppKit -framework ApplicationServices -framework Vision -framework ScreenCaptureKit \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$SWIFT_SUPPORT" \
  "$ROOT/shared/IMicLog.swift" "$ROOT/shared/TextRevision.swift" \
  "$ROOT/mac/InputTarget.swift" "$ROOT/mac/PolishPresentation.swift" "$ROOT/mac/TextMarkerGeometry.swift" "$ROOT/mac/TextPolishEffect.swift" \
  "$ROOT/tests/PolishEffect/main.swift" -o "$WORK/polish-effect-tests"
"$WORK/polish-effect-tests" "$@"
