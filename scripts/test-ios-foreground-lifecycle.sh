#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-foreground-lifecycle.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SOURCE=${IMIC_LINK_CLIENT_SOURCE:-"$ROOT/ios/iMic/LinkClient.swift"}
cat "$SOURCE" "$ROOT/tests/LinkResumeLifecycle/ClientHarness.swift" > "$WORK/LinkClient.swift"
xcrun swiftc -D DEBUG -swift-version 5 -O \
  "$ROOT/shared/Localization.swift" "$ROOT/shared/LinkStatusText.swift" "$ROOT/shared/MacSelection.swift" \
  "$ROOT/shared/iMicLink.swift" "$ROOT/shared/PolishOptions.swift" "$ROOT/shared/IMicLog.swift" \
  "$ROOT/mac/PairingStore.swift" "$ROOT/mac/LinkServer.swift" "$WORK/LinkClient.swift" \
  "$ROOT/ios/iMic/BLELinkClient.swift" "$ROOT/tests/LinkResumeLifecycle/main.swift" \
  -framework Network -framework CryptoKit -framework CoreBluetooth -framework Combine -framework Security \
  -o "$WORK/lifecycle-tests"
"$WORK/lifecycle-tests" --test-port="${IMIC_LIFECYCLE_TEST_PORT:-48124}" --debug-no-ble-fallback
