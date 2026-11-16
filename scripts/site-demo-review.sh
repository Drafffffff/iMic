#!/bin/bash
# Review artifacts for the landing-page demo videos: a contact sheet per scene (one frame
# every 0.25 s) and full-size frames at each impact beat, in docs/reviews/landing-demo-videos.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OUT="$ROOT/docs/reviews/landing-demo-videos"
WORK="$ROOT/build/site-demo/work"
mkdir -p "$OUT"
for scene in hero hold string live polish sound; do
  video="$ROOT/site/assets/video/$scene.mp4"
  [ -f "$video" ] || continue
  duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
  count=$(python3 -c "import math,sys; print(math.ceil(float(sys.argv[1]) * 4))" "$duration")
  columns=8
  rows=$(( (count + columns - 1) / columns ))
  ffmpeg -v error -y -i "$video" -vf "fps=4,scale=320:-1,tile=${columns}x${rows}:padding=4:color=0x0b0b0c" \
    -frames:v 1 -q:v 5 "$OUT/$scene-contact.jpg"
  python3 - "$WORK/$scene-plan.json" "$video" "$OUT" "$scene" <<'PY'
import json, subprocess, sys
plan, video, out, scene = sys.argv[1:5]
beats = [b for b in json.load(open(plan))["beats"] if b is not None and b >= 0][:3]
for i, t in enumerate(beats, 1):
    # Just after the beat, when the push-in peaks.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t + 0.07:.3f}", "-i", video, "-frames:v", "1",
                    "-q:v", "3", f"{out}/{scene}-beat{i}.jpg"], check=True)
PY
  echo "$scene: $(ls "$OUT"/"$scene"-* | wc -l | tr -d ' ') files"
done
