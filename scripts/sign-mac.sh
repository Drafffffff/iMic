#!/bin/bash
# Sign nested code explicitly from the inside out. Never use codesign --deep to sign.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
APP=${1:?App path required}
IDENTITY=${2:?Signing identity required}
OPTIONS=(--verbose=0)
if [ "${3:-}" = release ]; then OPTIONS=(--options runtime --timestamp); fi
sign_code() {
  # Release signatures always retain hardened runtime + a secure timestamp.
  # Retry only transport/timestamp failures; never fall back to an unsigned mode.
  if [ "$RELEASE" = true ]; then
    python3 "$ROOT/tools/release-network.py" retry -- codesign "$@"
  else
    codesign "$@"
  fi
}
RELEASE=false
if [ "${3:-}" = release ]; then RELEASE=true; fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FRAMEWORK" ]; then
  sign_code --force "${OPTIONS[@]}" --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Autoupdate"
  sign_code --force "${OPTIONS[@]}" --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Updater.app"
  # iMic is not sandboxed: both optional XPC services are removed when embedding.
  sign_code --force "${OPTIONS[@]}" --sign "$IDENTITY" "$FRAMEWORK"
fi
sign_code --force "${OPTIONS[@]}" --sign "$IDENTITY" --identifier com.drafffffff.imic \
  --entitlements "$ROOT/mac/iMic.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
