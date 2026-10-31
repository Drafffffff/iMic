#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-mac-selection.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cat "$ROOT/ios/iMic/LinkClient.swift" "$ROOT/tests/LinkSelection/ClientHarness.swift" > "$WORK/LinkClient.swift"
xcrun swiftc -D DEBUG -swift-version 5 -O \
  "$ROOT/shared/Localization.swift" "$ROOT/shared/LinkStatusText.swift" "${ROOT}/shared/MacSelection.swift" "$ROOT/shared/iMicLink.swift" \
  "$ROOT/shared/PolishOptions.swift" "$ROOT/shared/IMicLog.swift" \
  "$ROOT/mac/PairingStore.swift" "$ROOT/mac/LinkServer.swift" \
  "$WORK/LinkClient.swift" "$ROOT/ios/iMic/BLELinkClient.swift" \
  "$ROOT/tests/LinkSelection/main.swift" \
  -framework Network -framework CryptoKit -framework CoreBluetooth -framework Combine -framework Security \
  -o "$WORK/selection-tests"
"$WORK/selection-tests" --debug-no-ble-fallback
