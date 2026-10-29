#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-quick-switch.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 "$ROOT/shared/MacSelection.swift" \
  "$ROOT/ios/iMic/MacSwitchCoordinator.swift" "$ROOT/tests/QuickMacSwitch/main.swift" \
  -framework SwiftUI -framework Combine -o "$WORK/quick-switch-tests"
"$WORK/quick-switch-tests"
