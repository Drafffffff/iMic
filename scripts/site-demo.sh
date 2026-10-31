#!/bin/bash
# Regenerate the landing-page demo videos from the real app.
#
#   ./scripts/site-demo.sh                 # all scenes
#   ./scripts/site-demo.sh polish string   # selected scenes
#
# 1. Builds the DEBUG iPhone app and UI tests for a USB iPhone (or a dedicated simulator),
#    and the scripted speech the demo feeds through the app's microphone analyzer.
# 2. For each scene: a UI test performs real gestures on the app in preview mode with a
#    scripted utterance (no Mac connection, no microphone, nothing sent) while the
#    phone or simulator screen is recorded; the app logs timestamped events.
# 3. The Mac demo window replays those events in its own text field (with the real
#    polish sweep) while only that window's region is recorded. It appears in the middle
#    of the main display for the length of each scene.
# 4. tools/site-demo-compose.py aligns, composes and encodes site/assets/video/*.mp4.
# Requires Xcode, ffmpeg, Python with Pillow and numpy, and the Accessibility grant of
# the installed /Applications/iMic.app (the Mac demo window is signed the same way).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT="$ROOT/build/site-demo"
RAW="$OUT/raw"
SCENES=("$@")
[ ${#SCENES[@]} -gt 0 ] || SCENES=(hero hold string live polish sound)
mkdir -p "$RAW"

# Real iPhone over USB (smooth 60fps capture) when IMIC_DEMO_DEVICE is set or exactly
# one iPhone is attached; otherwise the simulator (renders and records far fewer frames).
DEVICE=${IMIC_DEMO_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | sed -nE 's/.* ([0-9A-F]{8}-[0-9A-F]{16}) \(UDID\).*physical.*/\1/p' | head -1)}
(cd "$ROOT/ios" && xcodegen generate >/dev/null)
mkdir -p "$ROOT/build/tools" "$OUT/bin"
swiftc -swift-version 5 -O "$ROOT/tools/icon.swift" -o "$ROOT/build/tools/icon-gen" -framework AppKit
"$ROOT/build/tools/icon-gen" ios "$ROOT/ios/iMic/Assets.xcassets/AppIcon.appiconset"
"$ROOT/scripts/site-demo-build-mac.sh"
# Speech for every utterance, fed through the app's microphone analyzer during the demo.
xcrun swiftc -O "$ROOT/tools/site-demo-speech.swift" -o "$OUT/bin/speech" -framework AVFoundation
"$OUT/bin/speech" "$ROOT/ios/iMic/Demo/DemoScript.swift" "$OUT/speech"

if [ -n "$DEVICE" ]; then
  TEAM=${IMIC_DEV_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | grep -o 'teamID = [A-Z0-9]*' | head -1 | awk '{print $3}')}
  "$ROOT/scripts/site-demo-build-iphone-capture.sh" >/dev/null
  xcodebuild build-for-testing -project "$ROOT/ios/iMic.xcodeproj" -scheme iMic -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$OUT/dd-device" -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" > "$OUT/build-for-testing.log" 2>&1
  RAW="$OUT/device"
  for scene in "${SCENES[@]}"; do
    "$ROOT/scripts/site-demo-iphone-capture.sh" "$scene" "$RAW" "$DEVICE"
    "$ROOT/scripts/site-demo-mac-capture.sh" "$scene" "$RAW"
  done
  echo "Done on $DEVICE. Reinstall the normal app with ./scripts/install-ios-device.sh and remove the"
  echo "UI test runner: xcrun devicectl device uninstall app --device $DEVICE art.malette.imic.uitests.xctrunner"
else
  DEVICE_TYPE=$(xcrun simctl list devicetypes | sed -nE 's/^(iPhone 1[7-9] Pro) \(.*/\1/p' | head -1)
  UDID=$(xcrun simctl create "iMic Demo Capture" "${DEVICE_TYPE:-iPhone 17 Pro}")
  cleanup() { xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; xcrun simctl delete "$UDID" >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  xcodebuild build-for-testing -project "$ROOT/ios/iMic.xcodeproj" -scheme iMic \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$OUT/dd" > "$OUT/build-for-testing.log" 2>&1
  for scene in "${SCENES[@]}"; do
    "$ROOT/scripts/site-demo-ios-capture.sh" "$scene" "$RAW" "$UDID"
    "$ROOT/scripts/site-demo-mac-capture.sh" "$scene" "$RAW"
  done
fi

# The app renders its sound cues on first launch; the SOUND scene mixes those files
# (taken from a simulator run of the same build).
if [ -n "${UDID:-}" ]; then
  CONTAINER=$(xcrun simctl get_app_container "$UDID" art.malette.imic data)
  mkdir -p "$OUT/sounds"
  cp "$CONTAINER"/Library/Caches/iMicSounds-v*/*.wav "$OUT/sounds/"
fi
[ -n "$(ls "$OUT/sounds"/*.wav 2>/dev/null)" ] || { echo "no sound cues in $OUT/sounds: run once on the simulator" >&2; exit 1; }

python3 "$ROOT/tools/site-demo-compose.py" "$RAW" "$OUT/work" "$ROOT/site" "${SCENES[@]}"
