# 任务书：修复 Retina 屏上首屏标题只显示第一行

日期：2026-11-02
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请阅读本文件和 `AGENTS.md`。

---

## 0. 交付方式

1. 从 `codex/ui-phosphor-wireframe` 最新提交新建分支 `codex/site-crt-hidpi`，在专用 worktree 中工作。
2. 只改 `site/assets/js/site.js`（必要时 `site/assets/css/site.css`）和测试工具；在 `docs/releases/NEXT.md` 记一行。
3. 推送后用 `gh pr create` 向 `codex/ui-phosphor-wireframe` 提 PR，附第 4 节的前后截图和测试结果。不要自行合并。

## 1. 现象

用户在 Retina iMac 的 Chrome 中打开官网，首屏标题「一只手机，接管所有输入。」只显示第一行「一只手机，」，字号明显偏大，第二行消失，副标题紧贴在第一行下面。

## 2. 复现与根因（已查明）

只在**设备像素比为 2**、且浏览器走 HTML-in-Canvas 路径（官网已有源试用令牌，Chrome 访客默认就走这条路径）时出现。复现：

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --user-data-dir=/tmp/imic-hidpi --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1440,900 --virtual-time-budget=4000 \
  --screenshot=/tmp/hidpi.png "https://drafffffff.github.io/iMic/"
```

`--force-device-scale-factor=1` 时显示正常。

根因在 `site/assets/js/site.js` 末尾的 CRT 标题模块：`paint()` 先 `ctx.setTransform(dpr, 0, 0, dpr, 0, 0)`，再调用 `drawElementImage(copy, pad, pad)`。实测在 Chrome 156 中，`drawElementImage` 绘制出的元素图像已经是设备像素尺寸，再乘一次 `dpr` 就被放大两倍；画布高度只按 CSS 尺寸 × dpr 分配，所以第二行被裁掉。

注意：这是根据截图得出的判断，请先用 Chrome 的实际行为确认（例如在 DPR 1 与 2 下分别读取绘制结果的尺寸），不要只照本文修改。

## 3. 要做的事

1. 修正 `paint()`（以及 `tear()` 等所有依赖坐标的地方），让画布在任何设备像素比下都按 1:1 绘制标题副本：画布背板尺寸、`drawElementImage` 的坐标与缩放、辉光、扫描线、亮带、glitch 撕裂都要一致。扫描线行距在 DPR 2 下应与 DPR 1 视觉上相同。
2. 兼容 Chrome 155 之前的旧接口（返回 DOMMatrix 的版本）：如果旧接口在 DPR 处理上不同，用特性检测分别处理，并在注释中说明。拿不到旧版 Chrome 时，在 PR 中写明未验证。
3. 加一个**保险**：每次绘制后，如果检测到副本绘制尺寸与真实标题尺寸明显不一致（例如超过 10%），就放弃画布效果，移除画布并恢复真实标题的可见文字（去掉 `crt-lit`），退回 CSS 辉光。这样以后接口再变，用户最差也只是看不到画布特效，不会看不到标题。
4. 页面缩放（浏览器 Cmd +/-）和窗口在不同 DPR 的屏幕之间拖动时，画布要重新计算尺寸（监听 `devicePixelRatio` 变化，例如 `matchMedia('(resolution: …dppx)')`）。

## 4. 验证（附在 PR 里）

用本机 Chrome（156）加 `--enable-blink-features=CanvasDrawElement`，对本 worktree 自己启动的 HTTP 服务截图（中英文首屏各一张），修复前后对比：

- DPR 1 和 DPR 2，窗口 1440×900 与 2560×1440。
- 开启画布路径与关闭画布路径（不加开关）各一组。
- 一张 glitch 撕裂进行中的截图（可以通过派发 `imic:glitch` 事件触发，参考 `tools/test-site-browser.mjs` 中已有的做法）。
- 标题仍可选中：用 CDP 鼠标拖选首屏标题，`getSelection().toString()` 为完整标题且不重复。

另外：

```bash
python3 tools/check-site.py
IMIC_SITE_URL=<本 worktree 的服务> node tools/test-site-browser.mjs
```

浏览器测试使用你自己在 worktree 中启动的 HTTP 服务，不要用 8000 端口。如果可以，在 `tools/test-site-browser.mjs` 中加一项检查：设备像素比为 2 时，画布（若启用）的绘制区域高度不小于真实标题高度；未启用画布时跳过。
