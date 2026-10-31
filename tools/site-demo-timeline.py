#!/usr/bin/env python3
"""Turn an iPhone demo event log into the Mac demo window's timeline.

    site-demo-timeline.py <scene> <events.jsonl> <out.json>

Event times come from the recording itself ("v", placed by site-demo-events.py), so
the Mac recording aligns to the iPhone recording by a single offset.
"""
import json
import sys

SCENES = {
    "hero":   ("设计组", ["明天的评审需要准备什么？"]),
    "hold":   ("设计组", ["设计稿什么时候能给我？"]),
    "string": ("产品讨论", ["下午的会几点开始？"]),
    "live":   ("首页改版", ["动效方案怎么安排？"]),
    "polish": ("输入框动画", ["今天的会主要讨论什么？"]),
    "sound":  ("测试", ["收到请回复"]),
}

scene, events_path, out_path = sys.argv[1], sys.argv[2], sys.argv[-1]
items = []
for line in open(events_path, encoding="utf-8"):
    event = json.loads(line)
    if "v" not in event:
        continue          # before the counter was on screen (launch)
    t = round(event["v"], 3)
    kind = event["event"]
    if kind == "hold":
        items.append({"t": t, "kind": "hold"})
    elif kind == "live":
        items.append({"t": t, "kind": "live", "text": event["text"]})
    elif kind == "polish.start":
        items.append({"t": t, "kind": "polish.start"})
    elif kind == "typed":
        items.append({"t": t, "kind": "typed", "text": event["final"]})
    elif kind == "input":
        items.append({"t": t, "kind": event["action"]})
if not items:
    sys.exit("no demo events found")
# Start the Mac replay shortly before the first event; the shift aligns it back later.
shift = round(max(0.0, items[0]["t"] - 1.5), 3)
for item in items:
    item["t"] = round(item["t"] - shift, 3)
title, history = SCENES[scene]
timeline = {"title": title, "history": history, "items": items, "shift": shift,
            "duration": items[-1]["t"] + 3.0}
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(timeline, handle, ensure_ascii=False, indent=1)
print(f"{scene}: {len(items)} items, shift {shift:.2f}s, last at {items[-1]['t']:.2f}s")
