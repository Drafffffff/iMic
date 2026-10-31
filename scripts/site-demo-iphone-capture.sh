#!/bin/bash
# Record one demo scene on a USB-connected iPhone while the UI test drives real gestures.
#   scripts/site-demo-iphone-capture.sh <scene> <raw-dir> <device-udid>
# Needs: build-for-testing into build/site-demo/dd-device, the phone unlocked with a
# Focus mode on, and camera access granted to the capture tool (macOS asks once).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SCENE=${1:?scene}
RAW=${2:?raw directory}
UDID=${3:?device udid}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MOVIE="$RAW/$SCENE.mov"
CAPTURE_APP="$ROOT/build/site-demo/bin/iMic Demo Capture.app"
mkdir -p "$RAW"
rm -f -- "${MOVIE:?}"

# The scene's speech (16 kHz PCM from tools/site-demo-speech.swift) goes into the app's
# Documents/demo-speech, where the demo feeds it through the microphone analyzer.
for pcm in "$ROOT/build/site-demo/speech/$SCENE"-*.pcm; do
  [ -f "$pcm" ] || continue
  xcrun devicectl device copy to --device "$UDID" --domain-type appDataContainer \
    --domain-identifier art.malette.imic --source "$pcm" \
    --destination "Documents/demo-speech/$(basename "$pcm")" > "$RAW/$SCENE.speechcopy.log" 2>&1 \
    || echo "warning: could not copy $(basename "$pcm") (an earlier copy is used if present)" >&2
done

# Launched as its own app so macOS attributes camera access to it (asked once).
: > "$RAW/$SCENE.rec.log"
open -n --stdout "$RAW/$SCENE.rec.log" --stderr "$RAW/$SCENE.rec.log" "$CAPTURE_APP" --args "$MOVIE"
stop_recorder() {
  pkill -INT -f "Contents/MacOS/iphone-capture $MOVIE" || true
  for _ in $(seq 1 40); do pgrep -f "Contents/MacOS/iphone-capture $MOVIE" >/dev/null || return 0; sleep 0.25; done
}
for _ in $(seq 1 1200); do grep -qE "Capture ready|not granted|no iPhone|error" "$RAW/$SCENE.rec.log" 2>/dev/null && break; sleep 0.05; done
grep -q "Capture ready" "$RAW/$SCENE.rec.log" || { stop_recorder; cat "$RAW/$SCENE.rec.log" >&2; exit 1; }

run_test() {
  TEST_RUNNER_IMIC_DEMO_SCENE="$SCENE" xcodebuild test-without-building -project "$ROOT/ios/iMic.xcodeproj" \
    -scheme iMic -destination "id=$UDID" -derivedDataPath "$ROOT/build/site-demo/dd-device" \
    -only-testing:iMicUITests/DemoCaptureUITests/testScene > "$RAW/$SCENE.test.log" 2>&1
}
# The device test runner occasionally exits before bootstrapping; one retry is enough.
run_test || { sleep 3; run_test; } || {
  stop_recorder; echo "$SCENE: UI test failed (see $RAW/$SCENE.test.log)" >&2; exit 1; }
sleep 0.5
stop_recorder

xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
  --domain-identifier art.malette.imic --source Documents/demo-events.jsonl \
  --destination "$RAW/$SCENE.events.jsonl" > "$RAW/$SCENE.copy.log" 2>&1

# Time frames by decode order, normalise to constant 60fps, and place events by the
# corner counter (3pt cells; pixels per point from the recorded width of a 402pt screen).
ffmpeg -v error -y -i "$MOVIE" -map 0:v -c copy -bsf:v "setts=pts=DTS" "${MOVIE%.mov}.dts.mov"
WIDTH=$(ffprobe -v error -select_streams v -show_entries stream=width -of csv=p=0 "${MOVIE%.mov}.dts.mov")
ffmpeg -v error -y -i "${MOVIE%.mov}.dts.mov" -vf fps=60 -c:v libx264 -preset veryfast -crf 8 -bf 0 -g 30 \
  -pix_fmt yuv420p "$RAW/$SCENE.norm.mp4"
SCALE=$(python3 -c "import sys; print(int(sys.argv[1]) / 402)" "$WIDTH")
python3 "$ROOT/tools/site-demo-events.py" "$RAW/$SCENE.norm.mp4" "$RAW/$SCENE.events.jsonl" 0 0 "$SCALE"
python3 "$ROOT/tools/site-demo-timeline.py" "$SCENE" "$RAW/$SCENE.events.jsonl" "$RAW/$SCENE.timeline.json"
