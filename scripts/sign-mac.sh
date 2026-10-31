#!/bin/bash
# Sign nested code explicitly from the inside out. Never use codesign --deep to sign.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
APP=${1:?App path required}
IDENTITY=${2:?Signing identity required}
OPTIONS=(--verbose=0)
if [ "${3:-}" = release ]; then OPTIONS=(--options runtime --timestamp); fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FRAMEWORK" ]; then
  codesign --force "${OPTIONS[@]}" --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Autoupdate"
  codesign --force "${OPTIONS[@]}" --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Updater.app"
  # iMic is not sandboxed: both optional XPC services are removed when embedding.
  codesign --force "${OPTIONS[@]}" --sign "$IDENTITY" "$FRAMEWORK"
fi
codesign --force "${OPTIONS[@]}" --sign "$IDENTITY" --identifier com.drafffffff.imic \
  --entitlements "$ROOT/mac/iMic.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
