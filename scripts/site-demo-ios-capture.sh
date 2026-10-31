#!/bin/bash
# Record one demo scene on the dedicated simulator while the UI test drives real gestures.
#   scripts/site-demo-ios-capture.sh <scene> <raw-dir> <simulator-udid>
# Requires a prior `xcodebuild build-for-testing` into build/site-demo/dd.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SCENE=${1:?scene}
RAW=${2:?raw directory}
UDID=${3:?simulator udid}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MOVIE="$RAW/$SCENE.mov"
mkdir -p "$RAW"
rm -f -- "${MOVIE:?}"

xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode notSupported
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$MOVIE" > "$RAW/$SCENE.rec.log" 2>&1 &
RECORDER=$!
# Wait until the recorder reports it has started, then stamp the wall clock.
for _ in $(seq 1 100); do grep -q "Recording started" "$RAW/$SCENE.rec.log" 2>/dev/null && break; sleep 0.05; done

TEST_RUNNER_IMIC_DEMO_SCENE="$SCENE" xcodebuild test-without-building -project "$ROOT/ios/iMic.xcodeproj" \
  -scheme iMic -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/build/site-demo/dd" \
  -only-testing:iMicUITests/DemoCaptureUITests/testScene > "$RAW/$SCENE.test.log" 2>&1 || {
    kill -INT "$RECORDER"; echo "$SCENE: UI test failed (see $RAW/$SCENE.test.log)" >&2; exit 1; }
kill -INT "$RECORDER"
wait "$RECORDER" || true

CONTAINER=$(xcrun simctl get_app_container "$UDID" art.malette.imic data)
cp "$CONTAINER/Documents/demo-events.jsonl" "$RAW/$SCENE.events.jsonl"
# Place every event in the recording by the app's corner event counter (simulator
# recordings drift from wall time, so wall clocks cannot be used).
# Normalise to constant 60fps without reordering, and use only that file downstream.
# Presentation timestamps in these recordings are unreliable while decode timestamps
# follow capture order (no frame reordering), so time every frame by its decode time.
ffmpeg -v error -y -i "$MOVIE" -c copy -bsf:v "setts=pts=DTS" "${MOVIE%.mov}.dts.mov"
ffmpeg -v error -y -i "${MOVIE%.mov}.dts.mov" -vf fps=60 -c:v libx264 -preset veryfast -crf 8 -bf 0 -g 30 \
  -pix_fmt yuv420p "$RAW/$SCENE.norm.mp4"
python3 "$ROOT/tools/site-demo-events.py" "$RAW/$SCENE.norm.mp4" "$RAW/$SCENE.events.jsonl"
python3 "$ROOT/tools/site-demo-timeline.py" "$SCENE" "$RAW/$SCENE.events.jsonl" "$RAW/$SCENE.timeline.json"
