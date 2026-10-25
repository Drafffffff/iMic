#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
SWIFT_SUPPORT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
WORK=$(mktemp -d /tmp/imic-polish-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -swift-version 5 -F "$FRAMEWORKS" -I "$SWIFT_SUPPORT" \
  -L "$SWIFT_SUPPORT" -lXCTestSwiftSupport -framework XCTest \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$SWIFT_SUPPORT" \
  "$ROOT/shared/PolishOptions.swift" "$ROOT/shared/DeepSeekPolicy.swift" \
  "$ROOT/shared/IMicLog.swift" "$ROOT/mac/Credentials.swift" \
  "$ROOT/mac/DeepSeek.swift" "$ROOT/tests/PolishProviders/main.swift" \
  -o "$WORK/polish-tests"
"$WORK/polish-tests"
