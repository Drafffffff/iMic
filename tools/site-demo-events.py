#!/usr/bin/env python3
"""Attach recording times to demo events by reading the app's corner event counter.

    site-demo-events.py <normalised-60fps-movie> <events.jsonl>

Simulator recordings are variable-frame-rate and their timestamps drift from wall time
under load, so wall clocks cannot place events in the video. The demo app draws its
event counter as 12 binary cells (3pt each, 3x pixels) in the top-left corner; event n
happens at the first frame whose counter reaches n. Rewrites the file with "v" (seconds
in the recording) on every event the counter covers.
"""
import json
import subprocess
import sys

movie, events_path = sys.argv[1:3]
# Optional: <x> <y> <pixels-per-point> of the counter's top-left (defaults: iPhone corner).
X0, Y0, SCALE = (int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 else (0, 0, 3)
W, H = 20 * SCALE, 8 * SCALE
FPS = 60   # the normalised constant-frame-rate copy: frame i is at i / 60 s
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", movie, "-vf", f"crop={W}:{H}:{X0}:{Y0},format=gray",
                      "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
frames = len(raw) // (W * H)
pts = [i / FPS for i in range(frames)]

events = [json.loads(line) for line in open(events_path, encoding="utf-8")]
max_n = max((e.get("n") or 0) for e in events)
first_seen = {}
for i in range(frames):
    image = raw[i * W * H:(i + 1) * W * H]
    value = 0
    for bit in range(12):
        x = int((1 + (bit % 6) * 3 + 1.5) * SCALE)
        y = int((1 + (bit // 6) * 3 + 1.5) * SCALE)
        if image[y * W + x] > 128:
            value |= 1 << bit
    # A sync flash or other bright frame reads as an impossible count: ignore it.
    if value and value <= max_n and value not in first_seen:
        first_seen[value] = pts[i]

known = sorted(first_seen)
placed = 0
for event in events:
    n = event.get("n")
    if n is None:
        continue
    # The first frame showing n or any later count (a frame can skip quick events).
    later = [first_seen[k] for k in known if k >= n]
    if later:
        event["v"] = min(later)
        placed += 1
with open(events_path, "w", encoding="utf-8") as handle:
    for event in events:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")
print(f"placed {placed}/{len(events)} events from {len(known)} counter values in {frames} frames", file=sys.stderr)
