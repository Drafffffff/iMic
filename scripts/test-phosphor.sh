#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-phosphor-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 "$ROOT/ios/iMic/PhosphorGeometry.swift" \
  "$ROOT/tests/Phosphor/main.swift" -framework Metal -o "$WORK/phosphor-tests"
"$WORK/phosphor-tests" "$ROOT/ios/iMic/PhosphorScene.metal"
