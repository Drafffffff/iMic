#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-link-revocation.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 -O \
  "$ROOT/shared/Localization.swift" "$ROOT/shared/PolishOptions.swift" \
  "$ROOT/shared/IMicLog.swift" "$ROOT/shared/iMicLink.swift" \
  "$ROOT/mac/PairingStore.swift" "${IMIC_REVOCATION_SERVER_SOURCE:-$ROOT/mac/LinkServer.swift}" \
  "$ROOT/tests/LinkRevocation/main.swift" \
  -framework Network -framework CryptoKit -o "$WORK/revocation-tests"
"$WORK/revocation-tests"
