#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-polish-link.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -D DEBUG -swift-version 5 -O \
  "$ROOT/shared/Localization.swift" "$ROOT/shared/LinkStatusText.swift" "${ROOT}/shared/MacSelection.swift" "$ROOT/shared/iMicLink.swift" "$ROOT/shared/PolishOptions.swift" "$ROOT/shared/IMicLog.swift" \
  "$ROOT/mac/PairingStore.swift" "$ROOT/mac/LinkServer.swift" \
  "$ROOT/ios/iMic/LinkClient.swift" "$ROOT/ios/iMic/BLELinkClient.swift" \
  "$ROOT/tests/PolishLink/main.swift" \
  -framework Network -framework CryptoKit -framework CoreBluetooth -framework Combine -framework Security \
  -o "$WORK/polish-link-tests"
"$WORK/polish-link-tests" --debug-host=127.0.0.1 --debug-port="${IMIC_POLISH_TEST_PORT:-47934}" \
  --debug-pair-code=246810 --debug-no-ble-fallback
