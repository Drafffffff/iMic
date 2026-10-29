#!/usr/bin/env python3
"""Drive the polish sweep self-test across real apps and input positions.

Every case opens its own throwaway document or test page, types a draft at a
chosen caret position, lets the sweep run, replaces it with a "polished" final
text and records screenshots plus the effect log. It never presses Return.
"""
import base64, json, math, os, subprocess, sys, time, urllib.parse, plistlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.environ.get("IMIC_SELFTEST_APP", os.path.join(ROOT, "build/polish-apps.noindex/iMic.app"))
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/imic-polish-apps"
ONLY = sys.argv[2].split(",") if len(sys.argv) > 2 and sys.argv[2] else None
CASE_ONLY = os.environ.get("IMIC_CASES", "").split(",") if os.environ.get("IMIC_CASES") else None
# IMIC_PAIRS="target--case,..." reruns exactly those combinations.
PAIRS = set(os.environ["IMIC_PAIRS"].split(",")) if os.environ.get("IMIC_PAIRS") else None
WORK = os.path.join(OUT, "docs")
os.makedirs(WORK, exist_ok=True)

MED = "今天下午三点开会讨论输入框动画的细节"
MED_F = "今天下午三点开会，讨论输入框动画的细节。"
MIX = "请帮我验证一次 OCR 的位置是否正确"
MIX_F = "请帮我再验证一次 OCR 的位置是否正确。"
LONG = ("我想把今天讨论的交互细节整理成一页说明，重点保留按住说话和松开即输入的节奏，"
        "还要检查长段文字自动换行以后每一行的下划线是否都贴着文字，最后的端点是否盖住光标")
LONG_F = ("今天讨论的交互细节整理成一页说明，重点保留按住说话、松开即输入的节奏。\n\n"
          "另外检查长段文字自动换行后，每一行的下划线是否贴着文字，最后的端点是否盖住光标。")
GROW = "扩展成四行"
GROW_F = "第一行：文字从少量扩展成完整内容。\n第二行：输入框在结果写入后变高。\n第三行：新的下划线逐行画出。\n第四行：端点落在最后一行末尾。"
SCROLL_PRE = "".join(f"这是第 {i} 行已有的文字，用来把输入区域撑到需要滚动。\n" for i in range(1, 31))

# name: (pre, post, typed, final, multiline_only)
RESIZE_DRAFT = "第一行是要整理的草稿，保留按住说话的节奏。\n第二行讨论输入框从三行缩成两行时的位置。\n第三行检查骨架线是否紧贴文字而没有跳动。"
CASES = {
    "shrink": ("", "", RESIZE_DRAFT, "保留按住说话的节奏。\n检查两行文字与骨架线的位置。", True),
    "shrink-to-one": ("", "", RESIZE_DRAFT, "检查缩成一行后骨架线和文字仍然对齐。", True),
    "empty":      ("", "", MED, MED_F, False),
    "after":      ("已有的前文内容。", "", MIX, MIX_F, False),
    "before":     ("", "后面已有的文字。", MED, MED_F, False),
    "middle":     ("前面一段", "后面一段文字。", MED, MED_F, False),
    "spaces":     ("前文  ", "  后文", " 带空格的文字 ", " 带空格的文字。 ", False),
    "short":      ("", "", "好的", "好的。", False),
    "nl-before":  ("第一段已有内容。\n", "", MIX, MIX_F, True),
    "nl-after":   ("", "\n第二段已有内容。", MED, MED_F, True),
    "between":    ("第一段。\n\n", "\n\n第三段。", LONG, LONG_F, True),
    "grow":       ("", "", GROW, GROW_F, True),
    "scrolled":   (SCROLL_PRE, "", LONG, LONG_F, True),
    "long-line":  ("这是一段很长的单行输入框里已有的文字，", "", LONG, LONG_F.replace("\n\n", ""), False),
    # Polishing removes filler: the result is much shorter than the draft.
    "shorten":    ("", "", "嗯那个就是我想说一下今天下午三点要开会然后讨论一下那个输入框动画的细节吧", "今天下午三点开会，讨论输入框动画细节。", False),
}

def b64(text):
    return base64.b64encode(text.encode()).decode()

def caret_keys(pre):
    # From document start: one Right per character (line breaks included).
    return ["cmd+up"] + ([f"right*{len(pre)}"] if pre else [])

FOCUS_WEB = set()

def page(app, kind, theme="light"):
    if app == "Safari": FOCUS_WEB.add(app)
    def prepare(case):
        pre, post = CASES[case][0], CASES[case][1]
        query = urllib.parse.urlencode({"kind": kind, "pre": pre, "post": post, "theme": theme})
        with open(os.path.join(ROOT, "tests/PolishApps/fields.html")) as handle:
            html = handle.read().replace("<script>", f"<script>window.IMIC_CASE = {json.dumps(query)};\n", 1)
        path = os.path.join(WORK, f"{app.replace(' ', '')}-{kind}-{case}-{int(time.time()*1000)}.html")
        with open(path, "w") as handle:
            handle.write(html)
        subprocess.run(["open", "-a", app, path], check=True)
        time.sleep(2.2)
        # Safari leaves focus in the address bar for opened files; focus the page field via AX.
        return (["focus-web"] if app in FOCUS_WEB else []), ["cmd+w"]
    return prepare

def document(app, suffix, save=False):
    def prepare(case):
        pre, post = CASES[case][0], CASES[case][1]
        path = os.path.join(WORK, f"{app.replace(' ', '')}-{case}-{int(time.time()*1000)}.{suffix}")
        with open(path + ".txt" if suffix == "rtf" else path, "w") as handle:
            handle.write(pre + post)
        if suffix == "rtf":
            subprocess.run(["textutil", "-convert", "rtf", "-output", path, path + ".txt"], check=True)
        subprocess.run(["open", "-a", app, path], check=True)
        time.sleep(2.5)
        return caret_keys(pre), (["cmd+s"] if save else []) + ["cmd+w"]
    return prepare

def shell(app):
    """A fresh terminal window running `cat`: typed text is echoed, never executed."""
    script = os.path.join(WORK, "imic-cat.command")
    with open(script, "w") as handle:
        handle.write("#!/bin/zsh\nclear\nprintf 'iMic 终端测试 · 输入不会被执行\\n'\nexec /bin/cat\n")
    os.chmod(script, 0o755)
    def prepare(case):
        pre = CASES[case][0]
        subprocess.run(["open", "-a", app, script], check=True)
        time.sleep(3.0)
        # Cooked-mode input cannot move the caret; existing text is typed first.
        return ([f"pretype:{b64(pre)}"] if pre else []), ["ctrl+c", "cmd+w"]
    return prepare

def new_window(app):
    """A new terminal window (Cmd+N) at a fresh shell prompt. Existing sessions are
    never typed into; Return is never pressed; the line is cleared before closing."""
    def prepare(case):
        pre = CASES[case][0]
        subprocess.run(["open", "-a", app], check=True)
        time.sleep(1.5)
        return ["cmd+n", "wait:1800"] + ([f"pretype:{b64(pre)}"] if pre else []), ["ctrl+u", "cmd+w"]
    return prepare

SHELL_CASES = {"empty", "after", "spaces", "short", "long-line", "shorten"}

TARGETS = {
    "chrome-grow-bottom": (page("Google Chrome", "grow-bottom"), True),
    "chrome-grow-top": (page("Google Chrome", "grow-top"), True),
    "chrome-grow-animated": (page("Google Chrome", "grow-animated"), True),
    "chrome-grow-max": (page("Google Chrome", "grow-max"), True),
    "chrome-input":    (page("Google Chrome", "input"), False),
    "chrome-textarea": (page("Google Chrome", "textarea"), True),
    "chrome-rich":     (page("Google Chrome", "rich"), True),
    "chrome-chat-dark": (page("Google Chrome", "chat", "dark"), True),
    "safari-textarea": (page("Safari", "textarea"), True),
    "safari-rich":     (page("Safari", "rich", "dark"), True),
    "textedit":        (document("TextEdit", "rtf"), True),
    "zed":             (document("Zed", "txt", save=True), True),
    "cursor":          (document("Cursor", "txt", save=True), True),
    "terminal":        (new_window("Terminal"), False),
    "iterm":           (new_window("iTerm"), False),
    "otty":            (new_window("Otty"), False),
}

def bundle_for_target(target):
    app = ("Google Chrome" if target.startswith("chrome-") else "Safari" if target.startswith("safari-")
           else {"textedit": "TextEdit", "zed": "Zed", "cursor": "Cursor", "terminal": "Terminal", "iterm": "iTerm", "otty": "Otty"}[target])
    for root in ("/Applications", "/System/Applications", "/System/Applications/Utilities"):
        path = os.path.join(root, app + ".app", "Contents/Info.plist")
        if os.path.exists(path):
            with open(path, "rb") as f: return plistlib.load(f)["CFBundleIdentifier"]
    raise RuntimeError("Test target is not installed: " + app)

def run_case(target, case):
    growing = target.startswith("chrome-grow-")
    if growing and case not in ("shrink", "grow", "shrink-to-one"): return None
    if not growing and case in ("shrink", "shrink-to-one"): return None
    prepare, multiline = TARGETS[target]
    pre, post, typed, final, multiline_only = CASES[case]
    if multiline_only and not multiline:
        return None
    if case == "long-line" and multiline:
        return None
    if target in ("terminal", "iterm", "otty") and case not in SHELL_CASES:
        return None
    keys, cleanup = prepare(case)
    name = f"{target}--{case}"
    env = ["--env", f"IMIC_RESULT_DELAY={os.environ['IMIC_RESULT_DELAY']}"] if os.environ.get("IMIC_RESULT_DELAY") else []
    args = [f"--expected-bundle={bundle_for_target(target)}", f"--out={OUT}", f"--name={name}", "--keys=" + ",".join(keys),
            f"--type-b64={b64(typed)}", f"--final-b64={b64(final)}", "--cleanup=" + ",".join(cleanup)]
    if os.environ.get("IMIC_PROBE_ENHANCED"): args.append("--probe-enhanced")
    if os.environ.get("IMIC_SELFTEST_LAUNCH") == "direct":
        # Uses the invoking tool's existing grants; never edits TCC or installs an app.
        subprocess.run([os.path.join(APP, "Contents/MacOS/iMic")] + args, check=False)
    else:
        subprocess.run(["open", "-n", "-g", "-W"] + env + [APP, "--args"] + args, check=False)
    time.sleep(0.6)
    try:
        with open(os.path.join(OUT, name + ".json")) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {"name": name, "status": "missing"}

def parse(effect, key):
    for line in effect:
        if key in line:
            for token in line.split():
                if token.startswith("end="):
                    x, y = token[4:].split(",")
                    return line, (int(x), int(y))
            return line, None
    return None, None

def summarize(result):
    effect = result.get("effect", [])
    tier = next((l.split("locate ")[1].split()[0] for l in effect if "locate " in l), None)
    if any("ocr lines=" in l and "ocr lines=0" not in l for l in effect): tier = (tier + "+" if tier else "") + "ocr"
    skipped = next((l.split("reason=")[1] for l in effect if "skipped reason=" in l), "")
    sweep_line, sweep_end = parse(effect, "sweep lines=")
    release_line, release_end = parse(effect, "release source=")
    source = release_line.split("source=")[1].split()[0] if release_line else ""
    def distance(point, caret):
        return round(math.dist(point, caret)) if point and caret else None
    caret_typed = tuple(result.get("caretTyped") or []) or None
    caret_final = tuple(result.get("caretFinal") or []) or None
    return {
        "case": result["name"], "role": result.get("role"), "tier": tier or "-", "skipped": skipped,
        "sweep_vs_caret": distance(sweep_end, caret_typed), "release": source,
        "release_vs_caret": distance(release_end, caret_final), "status": result.get("status"),
    }

if __name__ == "__main__":
    rows = []
    for target in TARGETS:
        if ONLY and target not in ONLY: continue
        for case in CASES:
            if CASE_ONLY and case not in CASE_ONLY: continue
            if PAIRS and f"{target}--{case}" not in PAIRS: continue
            result = run_case(target, case)
            if result is None: continue
            row = summarize(result) if result.get("status") != "missing" else {"case": result["name"], "status": "missing"}
            rows.append(row)
            print(json.dumps(row, ensure_ascii=False), flush=True)
    with open(os.path.join(OUT, "summary.json"), "w") as handle:
        json.dump(rows, handle, ensure_ascii=False, indent=1)
    # An interrupted fixture is not a passing visual regression run.
    if any(row.get("status") != "ok" for row in rows): sys.exit(1)
