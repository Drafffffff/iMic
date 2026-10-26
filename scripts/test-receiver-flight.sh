#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-flight-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 "$ROOT/ios/iMic/ReceiverFlightLayout.swift" \
  "$ROOT/ios/iMic/WaveTextGeometry.swift" "$ROOT/tests/ReceiverFlight/MetalChecks.swift" \
  "$ROOT/tests/ReceiverFlight/main.swift" -framework Metal -o "$WORK/flight-tests"
"$WORK/flight-tests" "$ROOT/ios/iMic/WaveText.metal"
