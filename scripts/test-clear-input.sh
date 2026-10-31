#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-clear-integration.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 "$ROOT/tests/InputClearFixture/main.swift" \
  -framework AppKit -o "$WORK/clear-fixture"
xcrun swiftc -swift-version 5 "$ROOT/shared/Localization.swift" "$ROOT/shared/LinkStatusText.swift" "${ROOT}/shared/IMicLog.swift" "$ROOT/shared/TextRevision.swift" \
  "$ROOT/mac/InputTarget.swift" "$ROOT/tests/InputClearIntegration/main.swift" \
  -framework AppKit -framework ApplicationServices -o "$WORK/clear-check"
for mode in direct ignored-value readonly; do
  "$WORK/clear-check" "$WORK/clear-fixture" "$mode"
done
