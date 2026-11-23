#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/voxchord-history-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 -O "$ROOT/shared/IMicLog.swift" "$ROOT/mac/TextHistoryStore.swift" \
  "$ROOT/tests/TextHistory/main.swift" -o "$WORK/text-history"
"$WORK/text-history"
