#!/usr/bin/env python3
"""Compose landing-page demo videos from the iPhone and Mac demo recordings.

    site-demo-compose.py <raw-dir> <work-dir> <site-dir> [scene ...]

For each scene this aligns the two recordings by their wall-clock stamps, places the
real iPhone screen and the Mac demo window on one canvas, adds camera moves and impact
punches keyed to the recorded events, cuts dead time with dissolves, closes the loop with
a crossfade, and encodes a 60fps H.264 file (plus a poster). The SOUND scene also gets
the app's own synthesized cues as an audio track and a block visualisation drawn from
those same samples. Nothing here invents product UI: only camera, dissolves, touch
indicators (drawn by the app) and small pixel labels are added.
"""
import json
import math
import os
import re
import subprocess
import sys
import wave

import numpy as np
from PIL import Image, ImageDraw

RAW, WORK, SITE = sys.argv[1:4]
ONLY = set(sys.argv[4:])
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FPS = 60
XFADE = 0.30          # dissolve between cut segments
LOOP = 0.40           # end-to-start crossfade that closes the loop
INK = (11, 11, 12)
IVORY = (242, 237, 224)
ORANGE = (255, 92, 26)
os.makedirs(WORK, exist_ok=True)


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(" ".join(cmd)[:2000] + "\n" + result.stderr[-4000:])
        raise SystemExit(f"ffmpeg failed: {cmd[-1]}")
    return result


def probe_duration(path):
    out = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]).stdout
    return float(out.strip())


# ---------------------------------------------------------------- pixel labels

def pixel_glyphs():
    source = open(os.path.join(ROOT, "ios/iMic/PixelFont.swift"), encoding="utf-8").read()
    glyphs = {}
    for char, rows in re.findall(r'"(.)":\s*\[((?:"[01]+",?\s*)+)\]', source):
        glyphs[char] = re.findall(r'"([01]+)"', rows)
    return glyphs


GLYPHS = pixel_glyphs()


def pixel_label(text, cell, color=IVORY, marker=True):
    """A pixel-font label like the site's: an orange square, then the word."""
    width = sum(len(GLYPHS.get(c, ["00000"])[0]) + 1 for c in text) * cell
    pad = cell * 4 if marker else 0
    image = Image.new("RGBA", (width + pad, 7 * cell), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if marker:
        draw.rectangle([0, 2 * cell, 2 * cell - 1, 4 * cell - 1], fill=ORANGE + (255,))
    x = pad
    for char in text:
        rows = GLYPHS.get(char)
        if rows is None:
            x += 3 * cell
            continue
        for y, row in enumerate(rows):
            for i, bit in enumerate(row):
                if bit == "1":
                    draw.rectangle([x + i * cell, y * cell, x + (i + 1) * cell - 1, (y + 1) * cell - 1], fill=color + (255,))
        x += (len(rows[0]) + 1) * cell
    return image


# ---------------------------------------------------------------- frames & masks

def rounded_mask(size, radius):
    image = Image.new("L", size, 0)
    ImageDraw.Draw(image).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return image


def bezel(size, radius, ring, color=(40, 40, 43)):
    w, h = size
    image = Image.new("RGBA", (w + 2 * ring, h + 2 * ring), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle([0, 0, w + 2 * ring - 1, h + 2 * ring - 1], radius=radius + ring, fill=color + (255,))
    draw.rounded_rectangle([ring, ring, ring + w - 1, ring + h - 1], radius=radius, fill=(0, 0, 0, 0))
    # A faint inner highlight so the bezel reads on the ink background.
    draw.rounded_rectangle([1, 1, w + 2 * ring - 2, h + 2 * ring - 2], radius=radius + ring - 1,
                           outline=(78, 78, 82, 255), width=2)
    return image


# ---------------------------------------------------------------- scene data

def load_scene(scene):
    def number(name):
        return float(open(os.path.join(RAW, f"{scene}.{name}")).read().strip())
    events = []
    for line in open(os.path.join(RAW, f"{scene}.events.jsonl"), encoding="utf-8"):
        e = json.loads(line)
        if "v" in e:          # position in the recording, from the corner event counter
            e["t"] = e["v"]
            events.append(e)
    timeline = json.load(open(os.path.join(RAW, f"{scene}.timeline.json"), encoding="utf-8"))
    # Mac offset from every replayed item found by the window's corner counter: item k was
    # scheduled at t_k (+shift in iPhone time) and seen at v_k in the Mac recording.
    offsets = []
    for line in open(os.path.join(RAW, f"{scene}.mac.items.jsonl"), encoding="utf-8"):
        item = json.loads(line)
        if "v" in item:
            offsets.append(item["t"] + timeline["shift"] - item["v"])
    offsets.sort()
    mac_delay = offsets[len(offsets) // 2]
    spread = (offsets[-1] - offsets[0]) if offsets else 0
    print(f"{scene}: Mac offset {mac_delay:.3f}s from {len(offsets)} items (spread {spread * 1000:.0f} ms)")
    return events, mac_delay


def times(events, kind, **match):
    return [e["t"] for e in events if e["event"] == kind and all(e.get(k) == v for k, v in match.items())]


def first(events, kind, **match):
    found = times(events, kind, **match)
    if not found:
        raise SystemExit(f"missing event {kind} {match}")
    return found[0]


# ---------------------------------------------------------------- layouts

LAYOUTS = {
    # canvas is rendered at 2x the output, then the camera crops and scales it down
    "hero": dict(out=(1400, 1120), phone_h=1720, phone_x=60, mac_w=1880, gap=30),
    "hero-mobile": dict(out=(720, 900), phone_h=1040, phone_x=480, mac_w=1300, gap=0),
    "feature": dict(out=(1280, 960), phone_h=1440, phone_x=140, mac_w=1620, gap=70),
}
# The Mac window's upper part is empty chat history: show the latest bubbles and the
# composer, which is where everything happens, so the text stays legible.
MAC_SOURCE = (1656, 1216)
MAC_CROP_TOP = 0.26


def geometry(kind):
    L = LAYOUTS[kind]
    W, H = L["out"][0] * 2, L["out"][1] * 2
    ph = L["phone_h"]
    pw = round(1206 * ph / 2622 / 2) * 2
    py = (H - ph) // 2
    mw = L["mac_w"]
    visible = MAC_SOURCE[1] * (1 - MAC_CROP_TOP)
    mh = round(visible * mw / MAC_SOURCE[0] / 2) * 2
    mx = L["phone_x"] + pw + L["gap"]
    my = (H - mh) // 2
    if kind == "hero-mobile":
        # Stack the same recordings on a portrait canvas. Mac close-ups can
        # fill the phone width without cutting the recording or inventing UI.
        mx, my, py = (W-mw)//2, H-mh-18, 12
        L = dict(L, phone_x=(W-pw)//2)
    return dict(W=W, H=H, out=L["out"], pw=pw, ph=ph, px=L["phone_x"], py=py, mw=mw, mh=mh, mx=mx, my=my)


# ---------------------------------------------------------------- camera

def smooth_expr(T, keys):
    """Piecewise smoothstep through (time, value) keys as an ffmpeg expression in T."""
    keys = sorted(keys)
    expr = f"{keys[-1][1]:.5f}"
    for (t0, v0), (t1, v1) in reversed(list(zip(keys, keys[1:]))):
        if t1 - t0 < 1e-3 or abs(v1 - v0) < 1e-6:
            segment = f"{v0:.5f}"
        else:
            u = f"min(1,max(0,({T}-{t0:.4f})/{t1 - t0:.4f}))"
            segment = f"({v0:.5f}+({v1 - v0:.5f})*{u}*{u}*(3-2*{u}))"
        expr = f"if(lt({T},{t1:.4f}),{segment},{expr})"
    return f"if(lt({T},{keys[0][0]:.4f}),{keys[0][1]:.5f},{expr})"


def punch_expr(T, beats, amount=0.035):
    """Quick push-in that springs back: rise in ~60ms, decay over ~220ms."""
    parts = []
    for t in beats:
        d = f"({T}-{t:.4f})"
        parts.append(f"if(gte({d},0)*lt({d},0.9),{amount:.4f}*(1-exp(-{d}/0.022))*exp(-{d}/0.17),0)")
    return "+".join(parts) if parts else "0"


# ---------------------------------------------------------------- scene plans

def plan(scene, events):
    """Segments (absolute iPhone-recording seconds), camera keys and beats."""
    g = None
    if scene == "hero":
        h, r = first(events, "hold"), first(events, "release")
        p, ty, rt = first(events, "polish.start"), first(events, "typed"), first(events, "input", action="return")
        segs = [(h - 0.7, rt + 1.35)]
        cam = [("full", h - 0.7), ("full", h + 0.1), ("phone", h + 0.9), ("phone", r + 0.15),
               ("mac", p + 0.45), ("mac", ty + 0.75), ("full", rt - 0.45), ("full", rt + 2)]
        beats = [r, ty + 0.32, rt]
        poster = rt + 0.12
    elif scene == "hold":
        h, r, ty = first(events, "hold"), first(events, "release"), first(events, "typed")
        segs = [(h - 0.6, ty + 2.1)]
        cam = [("full", h - 0.6), ("phone", h + 0.7), ("phone", r + 0.1), ("mac", ty + 0.1), ("mac", ty + 1.0),
               ("full", ty + 1.75)]
        beats = [r, ty]
        poster = r - 0.6
    elif scene == "string":
        holds, rels, tys = times(events, "hold"), times(events, "release"), times(events, "typed")
        lefts, rights = times(events, "input", action="left"), times(events, "input", action="right")
        dels, clr = times(events, "input", action="delete"), first(events, "input", action="clear")
        rt = first(events, "input", action="return")
        segs = [(holds[0] - 0.25, tys[0] + 0.45), (lefts[0] - 0.25, clr + 0.65),
                (holds[1] - 0.2, tys[1] + 0.4), (rt - 0.7, rt + 0.95)]
        cam = [("full", holds[0] - 0.4), ("wide", lefts[0] - 0.2), ("wide", rt + 2)]
        beats = [lefts[0], dels[0], clr, rt]
        labels = [("CURSOR", lefts[0] - 0.25, (rights or lefts)[-1] + 0.55),
                  ("DELETE", dels[0] - 0.35, dels[-1] + 0.5),
                  ("CLEAR", clr - 0.45, clr + 0.8),
                  ("RETURN", rt - 0.55, rt + 0.95)]
        return dict(segs=segs, cam=cam, beats=beats, labels=labels, poster=clr - 0.15)
    elif scene == "live":
        h, r, ty = first(events, "hold"), first(events, "release"), first(events, "typed")
        segs = [(h - 0.5, ty + 1.9)]
        cam = [("full", h - 0.5), ("live", h + 0.6), ("live", ty + 0.9), ("full", ty + 1.55)]
        beats = [ty]
        poster = r - 0.2
    elif scene == "polish":
        h, r = first(events, "hold"), first(events, "release")
        p, ty = first(events, "polish.start"), first(events, "typed")
        segs = [(h - 0.5, ty + 2.0)]
        cam = [("full", h - 0.5), ("full", r - 0.4), ("macclose", p + 0.35), ("macclose", ty + 0.85), ("full", ty + 1.6)]
        beats = [r, ty + 0.3]
        poster = ty + 0.33
    elif scene == "sound":
        holds, tys = times(events, "hold"), times(events, "typed")
        clr, rt = first(events, "input", action="clear"), first(events, "input", action="return")
        segs = [(holds[0] - 0.4, clr + 0.85), (holds[1] - 0.3, rt + 1.25)]
        cam = [("full", holds[0] - 0.4), ("full", rt + 2)]
        beats = [clr, rt]
        poster = rt + 0.1
    else:
        raise SystemExit(f"unknown scene {scene}")
    return dict(segs=segs, cam=cam, beats=beats, labels=[], poster=poster)


def camera_keys(cam, g):
    W, H = g["W"], g["H"]
    phone = (g["px"] + g["pw"] / 2, g["py"] + g["ph"] * 0.56)
    mac = (g["mx"] + g["mw"] / 2, g["my"] + g["mh"] / 2)
    composer = (g["mx"] + g["mw"] / 2, g["my"] + g["mh"] * 0.78)
    views = {
        "full": (1.0, W / 2, H / 2),
        "wide": (1.03, W / 2, H / 2),
        # Close-ups put the action where the eye is: the rising words and the bar on the
        # phone, then the composer on the Mac when the text lands.
        "phone": (1.38, phone[0] + g["pw"] * 0.16, g["py"] + g["ph"] * 0.62),
        "live": (1.12, W / 2 + W * 0.04, H / 2 + H * 0.04),
        "mac": (1.30, composer[0] - g["mw"] * 0.06, composer[1] - H * 0.08),
        "macclose": (1.55, composer[0] - g["mw"] * 0.04, composer[1] - H * 0.03),
    }
    keys = [(t, views[name]) for name, t in cam]
    return ([(t, v[0]) for t, v in keys], [(t, v[1]) for t, v in keys], [(t, v[2]) for t, v in keys])


# ---------------------------------------------------------------- sound

def sound_dir():
    """The app's own rendered cues, copied from the simulator by scripts/site-demo.sh."""
    return os.path.join(RAW, "..", "sounds")


def read_wav(path):
    with wave.open(path) as handle:
        rate, channels, width = handle.getframerate(), handle.getnchannels(), handle.getsampwidth()
        data = np.frombuffer(handle.readframes(handle.getnframes()), dtype="<i2" if width == 2 else "<i4")
    data = data.reshape(-1, channels).mean(axis=1) / (32768.0 if width == 2 else 2 ** 31)
    return rate, data


CUE_LABEL = {"release": "SEND", "result": "TEXT", "polishReady": "POLISH", "delete": "DEL", "clear": "CLEAR",
             "bowArmed": "ARMED", "snapReturn": "RETURN"}


def sound_overlay(events, segments_out, duration, size, path_pattern):
    """Block visualisation frames drawn from the real cue samples, in output time."""
    cues = []
    for e in events:
        if e["event"] != "sound":
            continue
        key = e["cue"]
        rate, data = read_wav(os.path.join(sound_dir(), f"{key}.wav"))
        out_t = map_time(e["t"], segments_out)
        if out_t is None:
            continue
        cues.append((out_t, key, rate, data))
    width, height = size
    bars, levels, cell, gap = 22, 8, 17, 5
    for frame in range(int(round(duration * FPS))):
        t = frame / FPS
        image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        active = [(start, key, rate, data) for start, key, rate, data in cues if start <= t < start + len(data) / rate + 0.25]
        if active:
            start, key, rate, data = active[-1]
            i = int((t - start) * rate)
            window = data[max(0, i - 1100):i + 1100] if i < len(data) else np.zeros(2200)
            chunks = np.array_split(np.abs(window) if len(window) else np.zeros(bars), bars)
            peak = max(1e-4, float(np.abs(data).max()))
            fade = min(1.0, max(0.0, (start + len(data) / rate + 0.25 - t) / 0.25))
            for b, chunk in enumerate(chunks):
                level = int(min(levels, round(float(chunk.max() if len(chunk) else 0) / peak * levels)))
                x0, y1 = b * (cell + gap), height - 4
                draw.rectangle([x0, y1 - cell, x0 + cell, y1], fill=(70, 70, 74, int(255 * fade)))
                for k in range(level):
                    x0 = b * (cell + gap)
                    y1 = height - 4 - k * (cell + 4)
                    color = ORANGE if k >= levels - 2 else IVORY
                    draw.rectangle([x0, y1 - cell, x0 + cell, y1], fill=color + (int(235 * fade),))
            base = key.split("-")[0]
            label = pixel_label(CUE_LABEL.get(base, base.upper()), 7)
            alpha = label.getchannel("A").point(lambda a: int(a * fade))
            label.putalpha(alpha)
            image.alpha_composite(label, (bars * (cell + gap) + 30, height - 4 - 7 * 7 - 20))
        image.save(path_pattern % frame)
    return cues


def map_time(t, segments_out):
    """Absolute recording time -> final output time (None when cut out)."""
    for start, end, out_start in segments_out:
        if start <= t <= end:
            return out_start + (t - start) - LOOP
    return None


# ---------------------------------------------------------------- render

def render_segment(scene, kind, g, events, mac_delay, seg, keys, beats, labels, out_path):
    start, end = seg
    length = end - start
    ios = os.path.join(RAW, f"{scene}.norm.mp4")      # constant 60fps copies, see capture scripts
    mac = os.path.join(RAW, f"{scene}.mac.norm.mp4")
    assets = os.path.join(WORK, f"assets-{kind}")
    os.makedirs(assets, exist_ok=True)
    phone_r, mac_r, ring = int(g["pw"] * 0.135), 30, 12
    rounded_mask((g["pw"], g["ph"]), phone_r).save(f"{assets}/phone-mask.png")
    bezel((g["pw"], g["ph"]), phone_r, ring).save(f"{assets}/phone-bezel.png")
    rounded_mask((g["mw"], g["mh"]), mac_r).save(f"{assets}/mac-mask.png")
    bezel((g["mw"], g["mh"]), mac_r, 3, color=(34, 34, 37)).save(f"{assets}/mac-bezel.png")

    zk, xk, yk = keys
    T = f"({start:.4f}+on/{FPS})"
    Z = f"({smooth_expr(T, zk)}+{punch_expr(T, beats)})"
    CX, CY = smooth_expr(T, xk), smooth_expr(T, yk)
    W, H = g["W"], g["H"]
    ow, oh = g["out"]
    inputs = ["-ss", f"{start:.3f}", "-t", f"{length:.3f}", "-i", ios,
              "-ss", f"{max(0, start - mac_delay):.3f}", "-t", f"{length:.3f}", "-i", mac,
              "-loop", "1", "-i", f"{assets}/phone-mask.png", "-loop", "1", "-i", f"{assets}/phone-bezel.png",
              "-loop", "1", "-i", f"{assets}/mac-mask.png", "-loop", "1", "-i", f"{assets}/mac-bezel.png"]
    filters = [
        f"color=c=0x0b0b0c:s={W}x{H}:r={FPS}:d={length:.3f}[bg]",
        f"[0:v]fps={FPS},scale={g['pw']}:{g['ph']}:flags=lanczos,format=rgba[pv]",
        f"[2:v]format=gray,scale={g['pw']}:{g['ph']}[pm]",
        "[pv][pm]alphamerge[phone]",
        f"[1:v]fps={FPS},crop=iw:ih*{1 - MAC_CROP_TOP:.3f}:0:ih*{MAC_CROP_TOP:.3f},scale={g['mw']}:{g['mh']}:flags=lanczos,format=rgba[mv]",
        f"[4:v]format=gray,scale={g['mw']}:{g['mh']}[mm]",
        "[mv][mm]alphamerge[macp]",
        f"[bg][3:v]overlay={g['px'] - ring}:{g['py'] - ring}:shortest=1[b1]",
        f"[b1][phone]overlay={g['px']}:{g['py']}:shortest=1[b2]",
        f"[b2][5:v]overlay={g['mx'] - 3}:{g['my'] - 3}:shortest=1[b3]",
        f"[b3][macp]overlay={g['mx']}:{g['my']}:shortest=1[comp]",
        f"[comp]zoompan=z='{Z}':x='max(0,min(iw-iw/zoom,{CX}-iw/zoom/2))':"
        f"y='max(0,min(ih-ih/zoom,{CY}-ih/zoom/2))':d=1:s={ow}x{oh}:fps={FPS}[cam]",
    ]
    last = "cam"
    for index, (text, a, b) in enumerate(labels):
        if b < start or a > end:
            continue
        label_path = f"{assets}/label-{text}.png"
        pixel_label(text, 6).save(label_path)
        inputs += ["-loop", "1", "-t", f"{length:.3f}", "-i", label_path]
        n = 6 + sum(1 for (_, la, lb) in labels[:index] if not (lb < start or la > end))
        a0, b0 = max(0.0, a - start), min(length, b - start)
        filters.append(f"[{n}:v]format=rgba,fade=in:st={a0:.3f}:d=0.14:alpha=1,fade=out:st={max(a0, b0 - 0.2):.3f}:d=0.2:alpha=1[l{index}]")
        filters.append(f"[{last}][l{index}]overlay=56:{oh - 96}:shortest=1[o{index}]")
        last = f"o{index}"
    filters.append(f"[{last}]format=yuv420p[v]")
    run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(filters), "-map", "[v]",
         "-t", f"{length:.3f}", "-r", str(FPS), "-c:v", "libx264", "-preset", "medium", "-crf", "12",
         "-pix_fmt", "yuv420p", out_path])


def join_and_loop(parts, out_path):
    """Dissolve between cut segments, then crossfade the end into the start."""
    durations = [probe_duration(p) for p in parts]
    body = parts[0]
    if len(parts) > 1:
        inputs, filters, offset, label = [], [], 0.0, "0:v"
        for p in parts:
            inputs += ["-i", p]
        for i in range(1, len(parts)):
            offset += durations[i - 1] - XFADE if i == 1 else durations[i - 1] - XFADE
            total_before = sum(durations[:i]) - XFADE * i
            filters.append(f"[{label}][{i}:v]xfade=transition=fade:duration={XFADE}:offset={total_before:.3f}[j{i}]")
            label = f"j{i}"
        body = out_path + ".body.mov"
        run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(filters), "-map", f"[{label}]",
             "-r", str(FPS), "-c:v", "libx264", "-preset", "medium", "-crf", "12", "-pix_fmt", "yuv420p", body])
    length = probe_duration(body)
    filters = (f"[0:v]split[a][b];[a]trim=start={LOOP},setpts=PTS-STARTPTS[main];"
               f"[b]trim=end={LOOP},setpts=PTS-STARTPTS[head];"
               f"[main][head]xfade=transition=fade:duration={LOOP}:offset={length - 2 * LOOP:.3f}[v]")
    run(["ffmpeg", "-v", "error", "-y", "-i", body, "-filter_complex", filters, "-map", "[v]", "-r", str(FPS),
         "-c:v", "libx264", "-preset", "medium", "-crf", "12", "-pix_fmt", "yuv420p", out_path])
    segments_out, cursor = [], 0.0
    return durations, length - LOOP


def encode(master, audio, out_path, budget):
    for crf in (21, 23, 25, 27, 29, 31):
        cmd = ["ffmpeg", "-v", "error", "-y", "-i", master]
        if audio:
            cmd += ["-i", audio, "-map", "0:v", "-map", "1:a", "-c:a", "aac", "-b:a", "96k", "-shortest"]
        else:
            cmd += ["-an"]
        cmd += ["-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-crf", str(crf), "-r", str(FPS),
                "-pix_fmt", "yuv420p", "-movflags", "+faststart", out_path]
        run(cmd)
        size = os.path.getsize(out_path)
        if size <= budget:
            return crf, size
    raise SystemExit(f"{out_path} over budget at crf 31: {size}")


def build(scene, name=None, kind=None):
    name = name or scene
    kind = kind or ("hero" if scene == "hero" else "feature")
    g = geometry(kind)
    events, mac_delay = load_scene(scene)
    p = plan(scene, events)
    keys = camera_keys(p["cam"], g)
    parts = []
    for i, seg in enumerate(p["segs"]):
        part = os.path.join(WORK, f"{name}-seg{i}.mov")
        render_segment(scene, kind, g, events, mac_delay, seg, keys, p["beats"], p["labels"], part)
        parts.append(part)
    master = os.path.join(WORK, f"{name}-master.mov")
    durations, length = join_and_loop(parts, master)
    # Output start of each segment in body time (before the loop trim).
    segments_out, cursor = [], 0.0
    for (start, end), d in zip(p["segs"], durations):
        segments_out.append((start, end, cursor))
        cursor += d - XFADE

    audio = None
    if scene == "sound":
        frames = os.path.join(WORK, "sound-viz")
        os.makedirs(frames, exist_ok=True)
        viz_w, viz_h = 860, 180
        cues = sound_overlay(events, segments_out, length, (viz_w, viz_h), os.path.join(frames, "%05d.png"))
        with_viz = os.path.join(WORK, "sound-viz.mov")
        # Centred under the Mac window, in the empty band below it.
        vx = int((g["mx"] + g["mw"] / 2) / 2 - 380)
        vy = int((g["my"] + g["mh"]) / 2 + 36)
        run(["ffmpeg", "-v", "error", "-y", "-i", master, "-framerate", str(FPS), "-i", os.path.join(frames, "%05d.png"),
             "-filter_complex", f"[0:v][1:v]overlay={vx}:{vy}:shortest=1[v]",
             "-map", "[v]", "-r", str(FPS), "-c:v", "libx264", "-preset", "medium", "-crf", "12", "-pix_fmt", "yuv420p", with_viz])
        master = with_viz
        audio = os.path.join(WORK, "sound-mix.wav")
        inputs, parts_a = [], []
        for i, (start, key, rate, data) in enumerate(cues):
            inputs += ["-i", os.path.join(sound_dir(), f"{key}.wav")]
            parts_a.append(f"[{i}:a]adelay={int(start * 1000)}:all=1[a{i}]")
        mix = "".join(f"[a{i}]" for i in range(len(cues)))
        run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex",
             ";".join(parts_a) + f";{mix}amix=inputs={len(cues)}:normalize=0,apad,atrim=0:{length:.3f},"
             f"loudnorm=I=-16:TP=-1.5:LRA=11[a]", "-map", "[a]", "-ar", "44100", audio])

    # Keep both hero variants under the former first-screen transfer cost.
    budget = 1_000_000 if scene == "hero" else 2_500_000
    final = os.path.join(SITE, "assets/video", f"{name}.mp4")
    crf, size = encode(master, audio, final, budget)
    poster_t = map_time(p["poster"], segments_out) or length / 2
    png = os.path.join(SITE, "assets/img", f"{name}.png")
    run(["ffmpeg", "-v", "error", "-y", "-ss", f"{max(0, poster_t):.3f}", "-i", final, "-frames:v", "1", png])
    Image.open(png).convert("RGB").save(os.path.join(SITE, "assets/img", f"{name}.webp"), quality=80, method=6)
    print(f"{name}: {length:.2f}s · crf {crf} · {size:,} bytes · poster {poster_t:.2f}s")
    json.dump({"segments": segments_out, "length": length, "beats": [map_time(b, segments_out) for b in p["beats"]],
               "labels": p["labels"]}, open(os.path.join(WORK, f"{name}-plan.json"), "w"), indent=1)


for scene in ["hero", "string", "polish", "sound"]:
    if not ONLY or scene in ONLY:
        build(scene)
if not ONLY or "hero" in ONLY or "hero-mobile" in ONLY:
    build("hero", name="hero-mobile", kind="hero-mobile")
