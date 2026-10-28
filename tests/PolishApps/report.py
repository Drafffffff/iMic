#!/usr/bin/env python3
"""Build an HTML report from one or more test-polish-apps runs.

    python3 tests/PolishApps/report.py OUT_DIR RUN_DIR [RUN_DIR ...]

Later run directories override earlier ones case by case, so a full matrix can
be followed by targeted reruns. Screenshots are copied next to index.html.
"""
import base64, html, json, math, os, shutil, subprocess, sys

out, runs = sys.argv[1], sys.argv[2:]
os.makedirs(os.path.join(out, "shots"), exist_ok=True)

APPS = [
    ("textedit", "TextEdit"), ("safari-textarea", "Safari · textarea"), ("safari-rich", "Safari · 富文本"),
    ("terminal", "Terminal.app"), ("chrome-input", "Chrome · 单行 input"), ("chrome-textarea", "Chrome · textarea"),
    ("chrome-rich", "Chrome · 富文本"), ("chrome-chat-dark", "Chrome · 底部深色对话框"),
    ("cursor", "Cursor"), ("zed", "Zed"), ("iterm", "iTerm"), ("otty", "Otty"),
]
CASES = {
    "empty": "空白输入框", "after": "已有文字之后", "before": "已有文字之前", "middle": "行中间",
    "spaces": "前后带空格", "short": "两字短文本", "nl-before": "前面有换行", "nl-after": "后面有换行",
    "between": "两个段落之间", "grow": "一行扩成四行", "scrolled": "长文滚动后", "long-line": "超长单行", "shorten": "润色后变短",
}
TIER = {"ax_range": "AX 行范围", "ax_marker": "文本标记", "field_estimate": "单行估算",
        "ocr": "框内 OCR", "window_ocr": "整窗 OCR"}
RELEASE = {"readable_layout": "AX 确认", "confirmed_range_layout": "AX 确认",
           "ocr_display_match": "OCR 确认", "display_deadline_estimated": "估算"}
NOTES = {
    "terminal": "终端对中文只按半宽报告 AX 几何（偏差 0px 是假象，端点实际在行中间）；现已对终端里的全角文字改用 OCR。终端不提供可靠光标位置，偏差按截图核对。",
    "iterm": "终端里的全角文字使用 OCR；光标偏差数值来自终端 AX，仅供参考，按截图核对。",
    "otty": "同 Terminal.app：AX 中文几何只有一半宽，已改用 OCR；偏差数值仅供参考，按截图核对。",
    "cursor": "整窗 OCR。代码编辑器默认不折行，长行的尾部和光标在窗口外时不显示扫光；两字短文本在整窗模式下按设计不匹配。",
    "zed": "整窗 OCR。代码编辑器默认不折行，长行的尾部和光标在窗口外时不显示扫光；两字短文本在整窗模式下按设计不匹配。",
}

results = {}
for run in runs:
    for name in sorted(os.listdir(run)):
        if not name.endswith(".json") or "--" not in name: continue
        with open(os.path.join(run, name)) as handle:
            data = json.load(handle)
        data["_run"] = run
        results[data["name"]] = data

def end(effect, key):
    for line in effect:
        if key in line:
            token = next((t for t in line.split() if t.startswith("end=")), None)
            source = line.split("source=")[1].split()[0] if "source=" in line else ""
            return source, (tuple(int(v) for v in token[4:].split(",")) if token else None)
    return "", None

def classify(data):
    effect = data.get("effect", [])
    tier = "-"
    for line in effect:
        if "locate source=" in line: tier = line.split("locate source=")[1].split()[0]
        elif "fallback=window_ocr" in line: tier = "window_ocr"
    if tier == "-" and any("ocr lines=" in l and "ocr lines=0" not in l for l in effect): tier = "ocr"
    skipped = next((l.split("reason=")[1] for l in effect if "skipped reason=" in l), "")
    _, sweep = end(effect, "sweep lines=")
    release, landed = end(effect, "release source=")
    caret_typed, caret_final = data.get("caretTyped") or None, data.get("caretFinal") or None
    if data["name"].split("--")[0] in ("terminal", "iterm", "otty"):
        caret_typed = caret_final = None   # terminal AX carets are half-width for CJK; judge by screenshot
    sweep_delta = round(math.dist(sweep, caret_typed)) if sweep and caret_typed else None
    release_delta = round(math.dist(landed, caret_final)) if landed and caret_final else None
    if data.get("status") != "ok" or data.get("error"):
        verdict = "error"
    elif skipped and not release:
        verdict = "skip"
    elif release == "display_deadline_estimated":
        verdict = "estimate" if (release_delta or 0) > 3 else "ok"
    elif release:
        verdict = "ok" if release_delta is None or release_delta <= 3 else "offset"
    else:
        verdict = "skip"
    return dict(tier=TIER.get(tier, tier), skipped=skipped, sweep=sweep_delta, release=RELEASE.get(release, release or "—"),
                release_delta=release_delta, verdict=verdict, measured=caret_final is not None)

def shot(data, phase):
    run, name = data["_run"], data["name"]
    source = os.path.join(run, f"{name}-{phase}.png")
    if not os.path.exists(source): return ""
    target = f"shots/{name}-{phase}.png"
    shutil.copyfile(source, os.path.join(out, target))
    # Inline a small JPEG thumbnail so the page also works as a single file.
    thumb = os.path.join(out, "shots", f"{name}-{phase}.thumb.jpg")
    subprocess.run(["sips", "-Z", "420", "-s", "format", "jpeg", "-s", "formatOptions", "70", source, "--out", thumb],
                   check=False, capture_output=True)
    if os.path.exists(thumb):
        with open(thumb, "rb") as handle:
            inline = "data:image/jpeg;base64," + base64.b64encode(handle.read()).decode()
    else:
        inline = target
    return f'<a href="{target}" target="_blank"><img src="{inline}" alt="{phase}"></a>'

LABEL = {"ok": ("通过", "ok"), "estimate": ("估算", "warn"), "offset": ("偏差", "warn"),
         "skip": ("未显示", "bad"), "error": ("错误", "bad")}
sections, summary = [], []
for key, title in APPS:
    rows = [(case, results[f"{key}--{case}"]) for case in CASES if f"{key}--{case}" in results]
    if not rows: continue
    counts = {"ok": 0, "estimate": 0, "offset": 0, "skip": 0, "error": 0}
    body = []
    for case, data in rows:
        info = classify(data)
        counts[info["verdict"]] += 1
        label, css = LABEL[info["verdict"]]
        delta = lambda v: "—" if v is None else f"{v}px"
        reason = f'<div class="muted">{html.escape(info["skipped"])}</div>' if info["skipped"] else ""
        run = os.path.basename(os.path.normpath(data["_run"]))
        body.append(f"""<tr><td>{CASES[case]}<div class="muted">{case} · {html.escape(run)}</div></td>
<td>{html.escape(info['tier'])}{reason}</td><td>{delta(info['sweep'])}</td>
<td>{html.escape(info['release'])}</td><td>{delta(info['release_delta'])}</td>
<td><span class="badge {css}">{label}</span></td>
<td class="shots">{shot(data, 'hold')}{shot(data, 'final')}</td></tr>""")
    note = f'<p class="note">{html.escape(NOTES[key])}</p>' if key in NOTES else ""
    sections.append(f"""<section id="{key}"><h2>{html.escape(title)}</h2>{note}
<table><thead><tr><th>情形</th><th>定位方式</th><th>扫光端点偏差</th><th>收尾依据</th><th>收尾端点偏差</th><th>结论</th><th>保持阶段 / 收尾截图</th></tr></thead>
<tbody>{''.join(body)}</tbody></table></section>""")
    summary.append(f"""<tr><td><a href="#{key}">{html.escape(title)}</a></td><td>{counts['ok']}</td><td>{counts['estimate'] + counts['offset']}</td>
<td>{counts['skip'] + counts['error']}</td><td>{html.escape(NOTES.get(key, ''))}</td></tr>""")

page = f"""<!doctype html><html lang="zh-Hans"><meta charset="utf-8"><title>iMic 输入框扫光验证报告</title>
<style>
body {{ font: 14px -apple-system, "PingFang SC", sans-serif; margin: 32px; color: #1d1d1f; background: #fafafa; }}
h1 {{ font-size: 22px; margin-bottom: 4px; }} h2 {{ font-size: 17px; margin-top: 36px; }}
table {{ border-collapse: collapse; width: 100%; background: #fff; }}
th, td {{ border-bottom: 1px solid #e5e5e5; padding: 8px 10px; text-align: left; vertical-align: top; }}
th {{ font-weight: 600; background: #f2f2f2; position: sticky; top: 0; }}
.muted {{ color: #888; font-size: 12px; margin-top: 2px; }} .note {{ color: #9a5b00; }}
.badge {{ padding: 2px 8px; border-radius: 10px; font-size: 12px; white-space: nowrap; }}
.ok {{ background: #e3f5e8; color: #1b7a3a; }} .warn {{ background: #fff2d6; color: #9a5b00; }} .bad {{ background: #fde4e1; color: #b3261e; }}
.shots img {{ height: 90px; margin-right: 6px; border: 1px solid #ddd; background: #fff; }}
</style>
<h1>iMic 输入框扫光验证报告</h1>
<p class="muted">数据来源（后者覆盖前者的同名用例）：{html.escape(' → '.join(os.path.basename(os.path.normpath(r)) for r in runs))}</p>
<p>偏差是扫光或收尾端点与系统插入光标之间的距离；编辑器不提供光标位置时（Chrome、Zed、部分 Cursor）显示「—」，需要看截图。
「估算」表示最终布局没拿到确认几何、按字宽估算的端点偏离光标超过 3px；「偏差」表示已确认位置但端点仍偏离光标超过 3px；「未显示」表示定位失败、直接输入文字，不影响输入本身。</p>
<h2>汇总</h2>
<table><thead><tr><th>应用</th><th>通过</th><th>估算 / 偏差</th><th>未显示</th><th>备注</th></tr></thead><tbody>{''.join(summary)}</tbody></table>
{''.join(sections)}
</html>"""
with open(os.path.join(out, "index.html"), "w") as handle:
    handle.write(page)
print(os.path.join(out, "index.html"))
