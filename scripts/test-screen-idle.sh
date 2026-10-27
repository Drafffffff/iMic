#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-screen-idle.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library "$ROOT/ios/iMic/IdleScreenDimming.swift" \
  "$ROOT/tests/ScreenIdle/main.swift" -o "$WORK/screen-idle-tests"
"$WORK/screen-idle-tests"
