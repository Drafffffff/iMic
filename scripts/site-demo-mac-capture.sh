#!/bin/bash
# Replay one scene's timeline in the Mac demo window and record only that screen region.
#   scripts/site-demo-mac-capture.sh <scene> <raw-dir>
# The window appears in the middle of the main display for the length of the scene.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SCENE=${1:?scene}
RAW=${2:?raw directory}
APP="$ROOT/build/site-demo/mac/iMic.app"
TIMELINE="$RAW/$SCENE.timeline.json"
READY="$RAW/$SCENE.ready"
MOVIE="$RAW/$SCENE.mac.mov"
# Record inside the window only (rounded corners and shadow excluded): nothing else on
# screen can appear in the video.
MARGIN=-16

rm -f -- "${READY:?}" "${MOVIE:?}"
"$APP/Contents/MacOS/iMic" "$TIMELINE" "$READY" > "$RAW/$SCENE.mac.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 80); do [ -s "$READY" ] && break; sleep 0.1; done
[ -s "$READY" ] || { echo "demo window did not start" >&2; kill "$APP_PID" 2>/dev/null; exit 1; }
read -r X Y W H <<< "$(cut -d' ' -f1 "$READY" | tr ',' ' ')"
DURATION=$(python3 -c "import json,sys; print(round(json.load(open(sys.argv[1]))['duration'] + 1.0, 1))" "$TIMELINE")

screencapture -v -x -V "$DURATION" -R "$((X - MARGIN)),$((Y - MARGIN)),$((W + 2 * MARGIN)),$((H + 2 * MARGIN))" "$MOVIE" \
  > "$RAW/$SCENE.sc.log" 2>&1 &
CAPTURE_PID=$!
sleep 0.8
date +%s.%N > "$RAW/$SCENE.macbegin"
kill -USR1 "$APP_PID"
wait "$CAPTURE_PID" || true
wait "$APP_PID" 2>/dev/null || true
# screencapture's presentation timestamps follow real time (unlike the simulator's, see
# site-demo-ios-capture.sh); normalise to constant 60fps on them.
ffmpeg -v error -y -i "$MOVIE" -vf fps=60 -c:v libx264 -preset veryfast -crf 8 -bf 0 -g 30 \
  -pix_fmt yuv420p "$RAW/$SCENE.mac.norm.mp4"
# Place each replayed item in the recording by the window's corner counter (top-left of
# the recorded area: 2pt in from the 16pt inset, 2 pixels per point on Retina).
python3 - "$TIMELINE" "$RAW/$SCENE.mac.items.jsonl" <<'PY'
import json, sys
items = sorted(json.load(open(sys.argv[1]))["items"], key=lambda i: i["t"])
with open(sys.argv[2], "w") as out:
    for n, item in enumerate(items, 1):
        out.write(json.dumps({"n": n, "t": item["t"], "kind": item["kind"]}) + "\n")
PY
python3 "$ROOT/tools/site-demo-events.py" "$RAW/$SCENE.mac.norm.mp4" "$RAW/$SCENE.mac.items.jsonl" 4 4 2
echo "$SCENE: $(cat "$READY") -> $MOVIE"
