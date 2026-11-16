#!/usr/bin/env python3
"""Compose App Store screenshots (1320x2868) from real simulator frames.

usage: compose.py <source-frames-dir> <output-dir>
Source frames are named <lang>-<scene>.png (lang: zh-Hans | en).
Requires Google Chrome (headless) for rendering.
"""
import base64, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
PIXEL = ROOT / "site/assets/pixel"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1320, 2868

SHOTS = [
    ("listen", "anywhere",
     {"zh-Hans": ("一只手机，<br>接管所有输入。", "按住说话，松手落字。终端、编辑器、聊天框都能用。"),
      "en": ("One phone.<br>Every text field.", "Hold to speak, release to type — in terminals, editors and chats.")}),
    ("pull", "string",
     {"zh-Hans": ("下拉琴弦，<br>弹射发送。", "上拨删字，左右移动光标。和 Agent 来回对话，手不用回到键盘。"),
      "en": ("Pull the string<br>to send.", "Flick up to delete, swipe to move the cursor. Talk to your agents hands-free.")}),
    ("polish", "polish",
     {"zh-Hans": ("随口说，<br>落笔即成文。", "AI 润色去掉口头禅、理顺语序，口语直接变书面。"),
      "en": ("Speak casually.<br>Type cleanly.", "AI polish trims filler words and fixes word order as you go.")}),
    ("settings", "modes",
     {"zh-Hans": ("一句话，<br>多种写法。", "Agent 指令、终端命令、文言文……按场景一键切换。"),
      "en": ("One voice,<br>many styles.", "Agent prompts, terminal commands and more — switch with one tap.")}),
    ("devices-manage", "link",
     {"zh-Hans": ("多台 Mac，<br>随时切换。", "iPhone 记住你的每一台 Mac，点一下就换过去。"),
      "en": ("All your Macs,<br>one tap away.", "Your iPhone remembers every Mac. Switch whenever you like.")}),
    ("pairing", "private",
     {"zh-Hans": ("直连你的 Mac，<br>没有中转。", "6 位配对码配对，局域网内加密传输，不经过第三方服务器。"),
      "en": ("Straight to<br>your Mac.", "Pair with a 6-digit code. Encrypted over your local network — no relay server.")}),
]

def pixel_svg(name, color):
    svg = (PIXEL / f"{name}.svg").read_text()
    return svg.replace("#f2f0e6", color)

def page(lang, idx, scene, label, head, sub, frame):
    img = base64.b64encode(frame.read_bytes()).decode()
    font = '"PingFang SC", -apple-system, sans-serif' if lang == "zh-Hans" else '-apple-system, "SF Pro Display", sans-serif'
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;width:{W}px;height:{H}px;overflow:hidden;background:#090909}}
body{{position:relative;font-family:{font};color:#f2f0e6;-webkit-font-smoothing:antialiased}}
.grid{{position:absolute;inset:0;background-image:linear-gradient(rgba(242,240,230,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(242,240,230,.035) 1px,transparent 1px);background-size:66px 66px}}
.glow{{position:absolute;left:50%;top:1820px;width:1500px;height:1500px;transform:translate(-50%,-50%);background:radial-gradient(circle,rgba(255,74,0,.26) 0%,rgba(255,74,0,.08) 38%,transparent 66%)}}
.scan{{position:absolute;inset:0;background:repeating-linear-gradient(0deg,rgba(0,0,0,.18) 0 2px,transparent 2px 6px);pointer-events:none}}
.top{{position:absolute;left:110px;right:110px;top:170px}}
.meta{{display:flex;align-items:center;justify-content:space-between;font:500 30px/1 ui-monospace,"SF Mono",Menlo,monospace;color:#a29e96;letter-spacing:.08em}}
.label svg{{height:42px;width:auto;display:block}}
.idx b{{color:#ff4a00;font-weight:500}}
.rule{{height:2px;margin:40px 0 64px;background:linear-gradient(90deg,#ff4a00 0 120px,rgba(242,240,230,.14) 120px)}}
h1{{margin:0;font-size:{116 if lang=='zh-Hans' else 118}px;line-height:1.14;font-weight:700;letter-spacing:{'.01em' if lang=='zh-Hans' else '-.02em'}}}
p{{margin:36px 0 0;font-size:44px;line-height:1.5;color:#a29e96;max-width:1080px}}
.device{{position:absolute;left:50%;top:{H-1955-110}px;width:900px;height:1955px;transform:translateX(-50%);border-radius:128px;padding:18px;background:#141414;box-shadow:0 0 0 3px #2a2826,0 40px 120px rgba(0,0,0,.7),0 0 160px rgba(255,74,0,.18)}}
.device img{{width:100%;height:100%;border-radius:112px;display:block}}
</style></head><body>
<div class="grid"></div><div class="glow"></div>
<div class="top">
  <div class="meta"><span class="label">{pixel_svg(label, '#ff4a00')}</span><span class="idx"><b>{idx:02d}</b> / {len(SHOTS):02d}</span></div>
  <div class="rule"></div>
  <h1>{head}</h1>
  <p>{sub}</p>
</div>
<div class="device"><img src="data:image/png;base64,{img}"></div>
<div class="scan"></div>
</body></html>"""

def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as tmp:
        for lang in ("zh-Hans", "en"):
            (out / lang).mkdir(parents=True, exist_ok=True)
            for i, (scene, label, text) in enumerate(SHOTS, 1):
                head, sub = text[lang]
                html = pathlib.Path(tmp) / f"{lang}-{i}.html"
                html.write_text(page(lang, i, scene, label, head, sub, src / f"{lang}-{scene}.png"))
                dest = out / lang / f"{i:02d}-{scene}.png"
                subprocess.run([CHROME, "--headless=new", "--hide-scrollbars", f"--window-size={W},{H}",
                                "--force-device-scale-factor=1", f"--screenshot={dest}", html.as_uri()],
                               check=True, capture_output=True)
                print(dest)

if __name__ == "__main__":
    main()
