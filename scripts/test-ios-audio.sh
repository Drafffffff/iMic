#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
WORK=$(mktemp -d /tmp/imic-audio-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 "$ROOT/ios/iMic/AudioCaptureController.swift" "$ROOT/ios/iMic/VoiceProcessingPolicy.swift" \
  "$ROOT/tests/AudioCapture/main.swift" -o "$WORK/audio-tests"
"$WORK/audio-tests"
