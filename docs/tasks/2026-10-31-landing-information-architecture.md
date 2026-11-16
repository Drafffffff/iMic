# 任务书：首页信息框架优化

日期：2026-10-31
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件、仓库根目录的 `AGENTS.md`，以及上一轮的 `docs/tasks/2026-10-30-landing-page.md` 和 `docs/tasks/2026-10-31-landing-demo-videos.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 的最新提交新建分支 `codex/landing-ia`，在这个分支上工作。**不要直接提交到 `codex/ui-phosphor-wireframe`。**
2. 提交说明用简体中文，可以分多次提交。
3. 推送分支：`git push -u origin codex/landing-ia`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**（不要选 `main`）。
5. PR 描述必须附第 8 节要求的**全量测试报告**，以及第 7 节要求的**前后对比截图**。没有报告的 PR 不予审核。
6. 由 Claude 审核。**不要自行合并**，也不要开启自动合并。
7. 不改 GitHub 仓库设置，不改 `VERSION`，不碰 Mac 和 iOS 的 App 代码。本任务只改 `site/`、`tools/`（与站点相关的部分）和文档。
8. 在 `docs/releases/NEXT.md` 的官网条目里，用一两句话记录本次改版。

---

## 1. 背景与目标

首页现在约 8,300px 高（视口 1024px 宽时），一共 8 个区块。其中 FEEL 区块就有 2,700px，五个亮点上下堆叠，每个都带一段说明和一段长免责声明，信息显得繁杂。首屏的文案和视频是上下排列，而且内容最宽只有 1120px，在大屏上显得局促。

本次目标：

1. **首屏**：文案和视频左右并排（桌面端）。
2. **删减**：删除"按住说话，松手发射"（HOLD）和"边说，边看到文字"（LIVE）两个亮点。
3. **整体排版**：页面更宽、更舒展，区块更少、更短，每个区块只讲一件事。
4. **品牌**：顶部 Logo 和 App 内的 Logo 保持一致。

产品定位不变：iMic 的卖点是交互手感，而不只是语音转文字。

## 2. 首屏（HERO）

### 2.1 桌面端（≥ 1000px）：左右布局

- 左边是文案（眉标、标题、简介、下载按钮、系统要求），右边是视频。文案与视频的列宽比例建议约 5:7，以视频为主。整个首屏块垂直居中，首屏高度控制在一屏内（以 1440×900 视口为准，标题、按钮和视频完整可见，不需要滚动）。
- 删除 `hero-foot` 这一行（"手机，变成一件趁手的输入乐器 / 感受一下 ↓"），这句话可以作为副标语放进文案区，或者干脆删掉。不要在首屏下方再加一条横线分隔栏。
- **可读性验收**：视口 1440px 宽时，视频里 Mac 聊天气泡的文字渲染出来**不小于 13 CSS px**。现在的 `hero.mp4` 是 1600×1000（16:10），iPhone 在左、Mac 在右，Mac 文字在原片里约 28px。放到右栏后如果文字太小，按下面 2.3 的方法重新合成首屏视频，不要只靠缩小字号来"凑合"。
- 视频右上角的播放/暂停按钮保留，位置不变。

### 2.2 手机端（< 760px）

用户的要求是"根据实际情况再看"。请按以下方式处理，并在 PR 里附截图说明你的选择：

- 默认：上下排列，文案在上，视频在下，视频占满内容宽度。
- 检查 390px 宽视口下视频里 Mac 文字是否还能看清。看不清的话，可以给手机端单独提供一个更"竖"的画面版本（例如 4:5 或 1:1，镜头更靠近 iPhone 和 Mac 输入框），用 `<source media>` 或者 CSS 切换海报和视频。这是可选项：如果增加的体积超过 1.5 MB，就不做，在 PR 里说明。
- 760–1000px 之间的平板宽度：采用你认为最合适的方式（建议仍然左右并排，比例调为 1:1），截图说明。

### 2.3 重新合成首屏视频（需要时）

- 原始素材在 `~/.codex/worktrees/landing-demo-videos/iMic/build/site-demo/device/`（真机 60fps 录制，包含 iPhone 录屏、Mac 录屏、事件时间线和计数码数据）。**只做重新合成，不要重新录制**：重录需要连接用户的 iPhone。
- 合成工具是 `tools/site-demo-compose.py`。首屏布局常量在文件开头（`hero` 1600×1000）。可以新增一个更接近 4:3 或 1:1 的首屏布局（例如 1400×1120），缩小 iPhone 和 Mac 之间的空白，并让 Mac 窗口占更大比例。镜头关键帧（`full`/`phone`/`mac` 等视角）随新画布一起调整。
- 运行方式参考 `scripts/site-demo.sh` 最后一行：`python3 tools/site-demo-compose.py <raw-dir> <work-dir> site hero`。原始素材目录在别的 worktree 里，**只读不写**；工作目录用你自己 worktree 里的 `build/`。
- 合成后用 `tools/check-site.py` 检查（60fps、时长、体积预算），并用 `scripts/site-demo-review.sh` 生成审阅截图，更新 `docs/reviews/landing-demo-videos/hero-*.jpg`。
- 如果原始素材目录不存在或无法读取，就停下来，在 PR 里说明，**不要**改用模拟器重录。

## 3. 删减与重组

### 3.1 删除

- **HOLD 亮点（01 / 05 "按住说话，松手发射。"）**：整块删除。首屏视频已经演示了按住说话。
- **LIVE 亮点（03 / 05 "边说，边看到文字。"）**：整块删除。
- 删除不再使用的资源：`site/assets/video/hold.mp4`、`live.mp4`，`site/assets/img/hold.*`、`live.*`，`site/assets/pixel/hold.svg`、`live.svg`（先确认没有别处引用）。同时更新 `tools/check-site.py` 和 `tools/test-site-browser.mjs` 中对应的检查项。
- **实时预览的风险说明不能消失。** `AGENTS.md` 要求兼容模式可能重复或误删的风险必须写进文档。删掉 LIVE 区块后，在 FAQ 里新增一条，例如："实时预览会不会改错字？"，用一两句话说明：实时预览默认关闭；部分应用使用键盘兼容模式，无法核验目标程序自己改稿或丢键，可能重复或误删；用户手动操作后本轮停止修订。措辞以现有 LIVE 区块的 `.fine` 文字为准，可以精简，但不能改变意思。

### 3.2 新的信息框架

从上到下：

| # | 区块 | 内容 | 说明 |
|---|---|---|---|
| 1 | HERO | 一句话说清是什么 + 下载 | 左右布局，见第 2 节 |
| 2 | FEEL | 3 个亮点：STRING、POLISH（扫光）、SOUND | 编号改为 `01 / 03` 到 `03 / 03` |
| 3 | MODES | 润色模式示例 | 现在的 `#polish` 区块，见 3.4 |
| 4 | ANYWHERE | 支持的应用 + 两条说明 | 压缩，见 3.5 |
| 5 | PRIVATE | 隐私三条 | 基本不变，只调排版 |
| 6 | START → DOWNLOAD | 三步上手 + 下载卡片 | 合并成一个区块，见 3.6 |
| 7 | FAQ | 常见问题 | 新增实时预览一条，见 3.1 |

导航改为：`交互` (#feel) · `润色` (#modes) · `隐私` (#private) · `下载 ↗` (#download)。

### 3.3 FEEL 亮点

- 3 个亮点保留"文字 + 视频"左右交替。视频变大：以内容宽度的约 60% 为准。
- **每个亮点的正文控制在两行左右（约 60 个汉字以内）。** 小字免责声明（`.fine`）移到 FAQ 或删除。具体要求：
  - STRING：保留"下拉发射回车、上拨删字、左右移光标、拉到顶清空"这四个动作，可以用一行图例或短列表，取代现在的长句。"清空在无法核验的编辑器或终端中会被拒绝"移到 FAQ"支持哪些应用"那一条里（那条已经提到清空可能被拒绝，合并即可）。
  - POLISH：一句话描述扫光，"可关闭、需要 macOS 14+、部分定位方式需要屏幕录制权限"压缩成一行小字，可以保留在这里。
  - SOUND：基本不变，保留"开启声音"按钮。
- 删除每个视频下方重复的说明文字"App 真实界面录制 · 无声短片"，在 FEEL 区块标题下统一写一次即可，例如："以下均为 App 与 Mac 真实界面录制。"

### 3.4 MODES（原 `#polish` 区块）

- 现在页面上有两个 POLISH（亮点里的扫光，和下面的润色模式示例），名字重复。把示例区块改名为 **MODES**：用 `tools/site-pixel.swift` 生成 `modes.svg` 像素字，锚点改为 `#modes`。
- 5 个示例在桌面端一行排开（或者 3+2 排列），卡片更紧凑：标题、原文、箭头、结果，去掉"示例 01"这样的编号。
- 区块末尾那段"终端命令模式只输出单行命令……"保留为一行小字。

### 3.5 ANYWHERE

- 应用列表和两条说明（"切换了应用？文字先留住"/"终端里，多行变一行"）放在同一行：左边是标题和应用列表，右边是两条说明。整个区块控制在约 400px 高。

### 3.6 START + DOWNLOAD 合并

- 用户读到"三步上手"时就应该能直接下载。把 START 的三步放在下载区块的标题下方（横排三列），下面紧接两张下载卡片。锚点 `#download` 指向这个合并后的区块，`#start` 保留为同一区块内的锚点，或者重定向到 `#download`（保证旧链接不失效）。
- 下载卡片上的小字精简：保留"已通过 Apple 公证"、校验和链接、"所有版本"。IPA 自签名这一条移到 FAQ。
- **以下 id 和行为必须保持不变**（`site/assets/js/site.js` 依赖它们，iOS App 也会链接到 `?from=ios#download`）：`origin-banner`、`mac-download-link`、`data-dmg-link`、`share-link`、`release-meta`、`mobile-download-note`、`share-status`、`share-manual`、`checksum-link`、`testflight-pending`、`testflight-link`、`data-hero-version`。改完后运行浏览器测试确认。

## 4. 整体排版

- **内容宽度**：`.shell` 现在是 `min(1120px, 100% - 64px)`。改成 `min(1360px, 100% - 2 × 边距)`，边距随视口变化（例如 `clamp(20px, 5vw, 64px)`）。1500px 以上的宽屏要能看出页面变宽了，不能在两侧留出大片空白。文字段落本身仍然限制行宽（每行约 36 个汉字以内），宽度给视频和网格用。
- **字号**：标题使用 `clamp()` 随视口缩放。建议：H1 在 1440px 宽时约 64–72px，H2 约 40–44px，正文 16–17px。首屏标题在手机端不小于 36px。
- **节奏**：区块上下内边距统一，建议 `clamp(64px, 9vw, 120px)`。删除区块之间多余的分隔线，只在大区块之间保留一条细线。
- **页面总高度目标**：1440×900 视口下，页面总高度相比现在**减少至少 35%**。在 PR 里给出前后两个数值，测量方法：`document.body.scrollHeight`，分别在 1440 和 390 宽度下测。
- 遵守 `AGENTS.md` 的品牌规则：技术标签用英文像素字，说明文字用简体中文；橙色只用于状态、交互和强调，不铺大面积背景。
- 保持现有的无障碍处理：跳到正文链接、`prefers-reduced-motion`、视频的 `aria-label`、播放/暂停按钮、键盘焦点样式。

## 5. Logo 与 App 同步

- **现状**：网站顶部用的是 `site/assets/pixel/imic.svg`，一个细的全大写像素字 "IMIC"，旁边加一个独立的橙色方点。而 iPhone App 顶部用的是 `ios/iMic/Assets.xcassets/Wordmark.imageset/wordmark@3x.png`：粗的像素字 "iMic"（大小写混合），i 上的点是橙色。两者不一致。
- **要求**：网站顶部和页脚的字标改成与 App 相同的 "iMic" 字标。
  - 以 `wordmark@3x.png` 为准，按像素网格还原成 SVG（`shape-rendering="crispEdges"`，每个像素一个矩形或合并后的路径）。主体色 `#f2f0e6`，i 的点 `#ff4a00`，与 PNG 逐像素一致。把生成逻辑加进 `tools/site-pixel.swift`（或者新建一个小工具，从 PNG 读取像素网格并输出 SVG），保证以后可以重新生成，不要手写坐标。
  - 输出到 `site/assets/pixel/imic.svg`（替换旧文件），删除旁边多余的 `.brand-dot`（橙色点已经在字标里了）。
  - 顶部字标高度约 22–26px，与 App 中的比例一致（App 中是 76×22pt）。
- **图标**：`site/assets/icons/`（favicon、apple-touch-icon、icon-512）应该已经来自 `tools/icon.swift site`。请确认它们与当前 App 图标一致，如果不一致就重新生成。`og.png`（`tools/site-og.swift`）里如果用到了旧字标，也一起换成新字标并重新生成。
- 404 页（`site/404.html`）同样换成新字标。

## 6. 不要做的事

- 不重新录制任何演示视频，不改 `ios/`、`mac/`、`shared/` 下的代码。
- 不引入前端框架、构建工具或第三方字体/脚本。页面仍然是纯静态的 HTML + CSS + 少量 JS。
- 不改下载逻辑和 TestFlight 状态逻辑，不改 `?from=ios` 的行为。
- 不删除隐私区块里的任何事实性说明（Key 存放位置、数据发往哪里），只调整排版。
- 不增加追踪、统计或 Cookie。

## 7. 截图要求（附在 PR 里）

每个截图都给出**改版前**（线上 https://drafffffff.github.io/iMic/）和**改版后**（本地）的对比：

1. 1440×900：首屏。
2. 1440 宽：整页长截图。
3. 1920×1080：首屏（确认宽屏不空）。
4. 820×1180（平板）：首屏。
5. 390×844：首屏和整页长截图。
6. 顶部 Logo 放大截图，与 App 内字标（`--ui-preview=idle` 模拟器截图）并排对比。
7. `?from=ios` 在 390 宽下打开的样子（应该直接看到下载区块和提示条）。

截图放进 `docs/reviews/landing-ia/`，PR 里引用。

## 8. 测试报告（附在 PR 里）

逐项写出命令、结果（PASS/FAIL）和关键输出：

```bash
python3 tools/check-site.py                 # 静态检查：引用、锚点、无障碍、体积预算
node tools/test-site-browser.mjs            # 浏览器测试：视频懒加载、下载逻辑、from=ios、减少动态效果
python3 -m http.server -d site 8000         # 本地预览，手动核对第 7 节截图
```

另外报告：

- 页面总高度：改版前后，在 1440 和 390 宽度下的 `document.body.scrollHeight`。
- 首屏视频里 Mac 文字在 1440 宽时的渲染字号（换算方法写清楚），以及是否重新合成了首屏视频。如果重新合成了，附上 `check-site` 对 `hero.mp4` 的帧率、时长和体积输出。
- 页面传输总量（首屏加载时）的前后对比，不能变大。
- 删除了哪些文件，并确认 `grep -r "hold\.mp4\|live\.mp4\|hold\.svg\|live\.svg" site tools` 没有残留引用。
- 手机端是否提供了单独的竖版首屏视频，以及原因。

## 9. 验收清单

- [ ] 桌面端首屏左右布局，1440×900 下标题、按钮、视频不需要滚动就完整可见。
- [ ] 1440 宽时首屏视频中 Mac 文字 ≥ 13 CSS px。
- [ ] HOLD、LIVE 两个亮点及其资源已删除；FEEL 只剩 3 个亮点，编号正确。
- [ ] 实时预览的风险说明已移到 FAQ，意思没有改变。
- [ ] MODES 改名完成，导航和锚点正确，`#start` 旧链接仍然可用。
- [ ] START 与 DOWNLOAD 合并，下载相关 id 和 `?from=ios` 行为不变，浏览器测试通过。
- [ ] 内容宽度加大，1920 宽下不显得空。页面总高度减少 ≥ 35%（1440 宽）。
- [ ] 顶部、页脚和 404 页的字标与 App 一致（橙色 i 点），由工具生成；favicon 和 OG 图一致。
- [ ] `check-site.py` 和 `test-site-browser.mjs` 全部 PASS。
- [ ] `docs/releases/NEXT.md` 已记录。
