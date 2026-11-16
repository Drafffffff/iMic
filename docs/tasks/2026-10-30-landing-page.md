# 任务书：iMic 落地页（GitHub Pages）

日期：2026-10-30
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 在分支 `codex/landing-page` 上工作，这个分支从 `codex/ui-phosphor-wireframe` 的最新提交创建。如果启动时你已经处在为此准备好的 worktree 和分支里，直接使用。**不要在 `codex/ui-phosphor-wireframe` 上直接提交。**
2. 提交说明用简体中文，可以分多次提交。
3. 推送：`git push -u origin codex/landing-page`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**，不要选 `main`（`main` 停在 1.4.0）。
5. PR 描述必须附第 12 节规定的**全量测试报告和页面截图**。没有报告的 PR 不予审核。
6. 由 Claude 审核。**不要自行合并**，不要开启自动合并。
7. **不修改 GitHub 仓库设置**：不启用 Pages，不改环境规则，不改仓库主页字段，不创建 Release。需要用户操作的设置写进 PR 的"上线清单"。
8. 不改 `VERSION` 和版本号，不覆盖 `/Applications/iMic.app`（不要运行 `install-mac.sh`）。
9. 在 `docs/releases/NEXT.md` 记录：落地页，以及 Mac 菜单新增的帮助入口。

### 并行任务

- `codex/ios-first-run-onboarding`（iOS 首次引导）同时进行。它会在 App 里链接到 `https://drafffffff.github.io/iMic/?from=ios#download`，本页**必须支持这个地址**（见 6.2）。
- `codex/sweep-follow-resizing-field`（Mac 扫光）也在进行，它会改 `mac/TextPolishEffect.swift` 等文件。本任务只改 `mac/MacExperience.swift` 和设置页的一处链接，**不要碰扫光相关文件**。
- **模拟器与前台**：另一个 Codex 任务可能同时在使用模拟器。录制素材时请创建你自己的专用模拟器，例如 `xcrun simctl create "iMic Site Capture" "iPhone 17 Pro"`（机型名以 `xcrun simctl list devicetypes` 为准），结束后删除。**不要使用、关闭或擦除其他已启动的模拟器。** 需要接管前台的 Mac 录屏（`scripts/test-polish-apps.sh`）会和别人抢焦点，请放在最后单独做，或者改用现有的截图产物，见 7.2。

---

## 1. 目标与定位

- 一个单页落地页，托管在 GitHub Pages：**https://drafffffff.github.io/iMic/**
- 定位：iMic 的亮点是**交互体验**，不只是"语音转文字"，而是"手机变成一件趁手的输入乐器"：按住说话、松手发射、弦手势、实时预览、润色扫光、8-bit 音效。页面要让人**看到**这些交互，不是只读文字描述。
- 主要访客：
  1. 第一次听说 iMic 的人：要在 10 秒内明白它是什么、为什么好用。
  2. 从 iPhone 引导跳过来的人（`?from=ios`）：要立刻找到 Mac 版下载。
- 简体中文，`lang="zh-Hans"`。英文版本次不做，但结构上留好扩展的余地，例如文案集中、不要散落在 JS 里。

## 2. 目录与技术选型

```
site/
  index.html
  404.html
  robots.txt
  assets/
    css/site.css
    js/site.js            # 原生 JS，无框架、无打包
    img/                  # 海报图、截图（webp + png 兜底）
    video/                # mp4（H.264）短片
    pixel/                # 由 App 像素字体生成的 SVG 标签
    icons/                # favicon、apple-touch-icon、og 图
.github/workflows/pages.yml
tools/site-pixel.swift    # 从 ios/iMic/PixelFont.swift 生成像素字 SVG
tools/check-site.py       # 本地校验：资源存在、体积预算、链接、HTML 基本结构
scripts/site-preview.sh   # 本地预览：python3 -m http.server -d site
```

- **纯静态**：HTML + CSS + 原生 JS。不用 React、Vite、Jekyll，也不需要 npm 构建。
- **为什么放在 `site/` 而不是 `docs/`**：`docs/` 里都是开发文档（协议、任务书、隐私说明等）。如果把 Pages 的来源设成 `docs/`，这些文档会被当成网页公开发布，结构也会乱。
- 加一个 `site/.nojekyll` 空文件。
- **不使用任何第三方 CDN、字体服务、统计或广告**：不用 Google Fonts，不用 jsDelivr、unpkg，不用 Google Analytics 或百度统计，也不用 Cookie。原因：国内访问不稳定；隐私承诺要和 App 一致（见 `docs/PRIVACY.md`）。
- 字体：正文用系统字体栈 `-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif`；等宽用 `ui-monospace, "SF Mono", Menlo, Consolas, monospace`。像素字**不引入字体文件**，用 `tools/site-pixel.swift` 读取 `ios/iMic/PixelFont.swift` 里的 `PixelFont.glyphs` 点阵，生成 SVG（例如 `HOLD`、`RETURN`、`POLISH`、`LINK` 等标签和 `iMic` 字标）。这样与 App 的像素字完全一致，也没有字体授权问题。
- 图标：用 `tools/icon.swift` 生成 favicon（32、180、512 px）和 og 图里的图标。需要新的输出模式时，在 `icon.swift` 里加 `site` 模式，**不要改动 Mac 和 iOS 的现有输出**。

## 3. 视觉规范（与 App 一致）

- 墨黑背景（取 App `Theme` / `Brand.swift` 的 ink 颜色值），正文用象牙白，次要文字用灰色（`muted`）。
- **橙色只用于强调、交互和状态**（按钮、链接悬停、当前项、少量高光），不铺大面积背景（AGENTS.md）。
- 技术标签用英文像素字，说明文字用简体中文。
- 可以有轻微的 CRT 或荧光质感（细扫描线、微弱辉光），但要克制。开启"减弱动态效果"时全部静止。
- 布局：最大内容宽度约 1120px，移动端单列。断点至少检查 390px（iPhone）、768px（iPad）、1440px（桌面）。
- 颜色对比度：正文对背景至少 4.5:1。

## 4. 页面结构与文案

文案要真实、克制，不写无法保证的话（例如"零延迟""100% 准确""完全免费"）。以下文案是草稿，可以润色，但事实部分不得改变。每节标题用像素字标签加一行中文标题。

### 4.1 首屏 `iMic`

- 主标题："按住说话，松手即输入。"
- 副标题："iPhone 当 Mac 的麦克风。说完松手，文字直接打进你正在用的任何应用。"
- 视觉：一段循环短片（≤8 秒），内容是主页荧光波形 → 松手发射 → Mac 输入框里出现文字。素材见第 7 节。
- 按钮：「下载 Mac 版」（主按钮，橙色，跳到 `#download` 并带上最新版本号，见 6.1）；「获取 iPhone 版」（次按钮，跳到 `#download`）。
- 下方一行小字：`macOS 13+ · iOS 17+ · 需要你自己的阿里云百炼 API Key`

### 4.2 交互亮点 `FEEL`（核心部分，篇幅最大）

每项为"短片 + 像素标签 + 一句标题 + 一两句说明"，桌面端左右交替排列：

1. `HOLD` **按住说话，松手发射**：按住底部横条说话，荧光波形实时跳动；松手，文字带着 8-bit 音效"发射"到 Mac。
2. `STRING` **弦手势**：不用碰 Mac 键盘。下拉弦松手 = 回车；上拉 = 连续删除；左右滑动 = 移动光标；拉到顶部 = 清空。
3. `LIVE` **边说边出字**：说话时文字就开始出现在 Mac 的输入框里，说完再精确修订。
4. `POLISH` **润色扫光**：AI 润色完成时，一道光沿着新文字扫过输入框，你能看到改了哪里。
5. `SOUND` **8-bit 音效**：每个动作都有短促、克制的芯片音，也可以在设置里关闭。

> 手势的名称和行为以 App 现有代码和 `README.md` 为准；与本节描述不一致时，以代码为准，并修正文案。

### 4.3 AI 润色 `POLISH`

- 说明："一个百炼 Key，识别和润色都能用。口语自动整理成书面文字，也可以一键换个说法。"
- 五种模式：Agent 指令、终端命令、文言文、废话文学、翻译腔。每种给一个"原话 → 结果"的对照卡片。示例请用 `scripts/test-polish.sh` 或现有提示词测试里的样例，或者手写一个合理的示例并标明"示例"。**不要调用真实 API 生成，不要使用任何真实用户内容。**
- 输出语言：中文、英文等 4 种（以 `shared/PolishOptions.swift` 为准）。
- 注明："终端命令模式只输出单行命令，不会自动执行。"

### 4.4 能用在哪里 `ANYWHERE`

- "任何能打字的 Mac 应用：备忘录、Chrome、微信、飞书、终端、VS Code、Cursor……"（只列出现有测试覆盖过的，参考 `tests/PolishApps/report.py` 中的 `APPS`，不要编造兼容列表。）
- "录音时切换了应用？iMic 不会把字打进别的窗口，文字会保留下来让你复制。"
- "在终端里，换行会被替换成空格，多行结果不会被逐行执行。"

### 4.5 安全与隐私 `PRIVATE`

- 局域网直连，逐帧 AES-GCM 加密；同一 Wi-Fi 不可用时，可以用蓝牙兜底。
- API Key 只保存在你的 Mac 上（`~/Library/Application Support/iMic/`，权限 0600）。
- 音频由你的 Mac 直接发送给阿里云百炼识别；开启润色时，识别出的文字会发送给你选定的润色服务。iMic 没有自己的服务器。
- 不追踪，没有统计。链接到 GitHub 上的 `docs/PRIVACY.md`。
- 以上每一句都要与 `docs/PRIVACY.md`、`docs/PROTOCOL.md` 核对；不一致时以文档为准。

### 4.6 三步开始 `START`

1. **Mac**：下载 iMic，拖进「应用程序」并打开。按设置向导填入百炼 API Key，打开辅助功能权限。
2. **iPhone**：安装 iMic（TestFlight），打开后按引导操作。
3. **配对**：在 iPhone 上输入 Mac 窗口里显示的 6 位配对码。完成。

附链接："如何获取百炼 API Key？" → `https://bailian.console.aliyun.com/?tab=model#/api-key`。

### 4.7 下载 `DOWNLOAD`（`id="download"`）

- **Mac 卡片**：
  - 「下载 iMic for Mac」，链接到最新版 DMG（见 6.1）。按钮下方显示 `版本 1.4.4 · 1.6 MB · macOS 13+ · Apple Silicon 与 Intel`（版本和大小从 API 动态获取）。
  - 小字："已通过 Apple 公证，下载后可直接打开。"以及"校验：SHA256SUMS.txt"（链接到同一 Release 的附件）。
  - 次要链接："所有版本" → `https://github.com/Drafffffff/iMic/releases`。
- **iPhone 卡片**：
  - 链接集中放在 `site/assets/js/site.js` 顶部的配置里：`const IOS_TESTFLIGHT_URL = ""`。
  - 为空时：按钮显示"TestFlight 测试即将开放"，不可点；下面一行小字"关注 GitHub 获取更新"，链接到仓库。
  - 有值时：按钮「通过 TestFlight 安装」，链接到该地址。
  - **不要**把未签名 IPA 作为主按钮。可以在"所有版本"的说明里提一句"高级用户可以自行签名安装 IPA"。

### 4.8 常见问题 `FAQ`

用 `<details>` 折叠，至少包含：
- 百炼 API Key 怎么获取？要花多少钱？（说明按量计费、以阿里云官网为准，不要写具体价格）
- iPhone 和 Mac 必须在同一个 Wi-Fi 吗？（推荐同一 Wi-Fi；不行时可以用蓝牙兜底，速度较慢；访客或公司网络可能禁止设备互访）
- 支持哪些应用？（见 4.4）
- 我的语音和文字会被上传吗？（见 4.5）
- 为什么需要辅助功能权限？（用来把文字输入到当前应用；iMic 不会修改系统权限设置）
- 下载很慢怎么办？（GitHub 在部分网络下较慢，可以稍后重试，或在"所有版本"页面手动下载）
- 遇到问题怎么反馈？（邮箱 `i0.0ia@qq.com`，或 GitHub Issues）

### 4.9 页脚

- GitHub 仓库链接、隐私说明链接、反馈邮箱、`© 2026 iMic`。
- 写明许可证，以仓库 `LICENSE` 为准。

## 5. SEO 与分享

- `<title>iMic · 按住说话，松手即输入</title>`
- `meta description`：一句话介绍。
- Open Graph 和 Twitter Card：`og:title`、`og:description`、`og:image`（1200×630，用首屏截图加像素字标合成，放在 `assets/icons/og.png`）、`og:url`。
- `<link rel="canonical" href="https://drafffffff.github.io/iMic/">`
- favicon、`apple-touch-icon`。
- `404.html`：同样的风格，一句"页面不存在"，加回首页链接。
- `robots.txt`：允许抓取。

## 6. 行为逻辑（`site.js`）

### 6.1 最新版下载链接

- 页面加载后请求 `https://api.github.com/repos/Drafffffff/iMic/releases/latest`，超时 4 秒（用 `AbortController`）。
- 在 `assets` 中找名字匹配 `/macOS-universal\.dmg$/` 的文件，用它的 `browser_download_url`、`size`，以及 `tag_name` 填入下载按钮和版本说明；同时找到 `SHA256SUMS.txt` 的链接。
- **兜底**（API 失败、超时、限流返回 403 或 429、找不到对应文件）：按钮链接到 `https://github.com/Drafffffff/iMic/releases/latest`，版本说明显示"最新版本"。**HTML 里的默认 `href` 就是这个兜底地址**，这样没有 JS 时也能用。
- 不把结果写入 Cookie 或 `localStorage`（不需要缓存，每次访问只请求一次）。
- 为了测试，支持 `?release-api=fail`，强制走兜底分支。只影响页面展示。

### 6.2 来自 iPhone 引导（`?from=ios`）

- 检测到 `from=ios` 参数，或 URL 中有 `#download`，页面加载后平滑滚动到 `#download`（减弱动态效果时直接跳过去），并给 Mac 卡片加 1.5 秒的橙色描边高亮。
- 顶部显示一条提示条："正在为 iPhone 上的 iMic 准备 Mac 版下载。"
- 不做任何统计，参数只用于展示。

### 6.3 在手机上打开时

很多人会直接在 iPhone 上点开这个链接（例如从 App 里点了"共享"，自己又在手机上打开）。

- 检测设备：`/iPhone|iPod|Android/i.test(navigator.userAgent)`；iPadOS 用桌面 UA 时，再判断 `navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1`（iPad 视同移动设备）。
- 在移动设备上，Mac 卡片的主按钮改为**「把链接发送到 Mac」**：
  - 支持 `navigator.share` 时，调用它分享页面地址（iOS 会出现隔空投送）。
  - 否则复制链接（`navigator.clipboard.writeText`），提示"已复制，可在 Mac 上粘贴打开（需开启通用剪贴板）"。
  - 下面一行小字："Mac 版需要在 Mac 上下载。"并保留一个次要的直接下载链接，给确实想在手机上先下载的人。
- iPhone 卡片在移动设备上保持原样。

### 6.4 视频与动效

- 所有视频：`<video muted loop playsinline preload="none" poster="…">`。用 `IntersectionObserver` 在进入视口时才设置 `src` 并播放，离开视口时暂停。
- `prefers-reduced-motion: reduce` 时：不自动播放，只显示海报图，并提供一个"播放"按钮；关闭扫描线和辉光动画。
- 视频没有声音，所以不需要字幕；但每个视频要有 `aria-label` 描述画面内容。

## 7. 素材制作

### 7.1 原则

- **只用自己录制的素材**：iOS 模拟器的预览状态、Mac 的预览模式，以及仓库测试页（`tests/PolishApps/fields.html`）。不使用网上图片或来源不明的素材。
- **画面里不得出现任何个人信息**：真实聊天内容、姓名、邮箱、API Key、配对码以外的个人数据、真实设备名（例如 "zhou"）。设备名一律用 preview 数据里的 "MacBook Pro"、"iPhone 17 Pro"。
- 文字内容使用 preview 里已有的示例文字，或中性的示例句子。

### 7.2 制作方法

- **iOS**：在你的专用模拟器上用 `--ui-preview=idle`、`result`、`flight`（`--debug-flight-count=…`）、`settings` 等现有状态（见 `README.md` 和 `AGENTS.md`），用 `xcrun simctl io <UDID> recordVideo --codec=h264 out.mov` 录制。用 `xcrun simctl status_bar <UDID> override --time 9:41 --batteryState charged --batteryLevel 100` 统一状态栏。
- **Mac 扫光**：优先复用 `build/polish-apps/` 下已有的截图产物，或者在本机打开 `tests/PolishApps/fields.html` 测试页，配合 Mac 端的预览模式录屏（`screencapture -v -R x,y,w,h out.mov`，只录指定区域）。真实应用的批量测试（`scripts/test-polish-apps.sh`）会接管前台约 10 分钟，**除非必要不要运行**；如果运行，放在最后并在报告里写明。
- **转码**：用 `ffmpeg`（已安装在 `/opt/homebrew/bin/ffmpeg`）：H.264、`yuv420p`、`-movflags +faststart`、最大 720p（竖屏视频最大 720×1560）、30fps、无音轨（`-an`）、每段 ≤8 秒。海报图用第一帧或有代表性的一帧，导出 webp，并提供 png 兜底。
- 原始录屏放在 `build/site-capture/`（不提交）；只把转码后的成品放进 `site/assets/`。
- 把制作过程写成脚本 `scripts/site-capture.sh`（录制加转码），便于以后更新素材。脚本只操作自己创建的模拟器。

### 7.3 体积预算（由 `tools/check-site.py` 检查，超出时报错）

| 项 | 上限 |
|---|---|
| HTML + CSS + JS（首屏加载，未压缩） | 150 KB |
| 首屏海报图 | 200 KB |
| 首屏总加载（不含懒加载视频） | 1 MB |
| 单个视频 | 1.5 MB |
| `site/` 总体积 | 15 MB |

## 8. 部署（GitHub Actions）

- `.github/workflows/pages.yml`：
  - 触发：`push` 到 `codex/ui-phosphor-wireframe` 且改动了 `site/**` 或本 workflow 文件；另加 `workflow_dispatch`。
  - 权限：`contents: read`、`pages: write`、`id-token: write`。
  - `concurrency: { group: pages, cancel-in-progress: true }`。
  - 两个 job：`build`（`actions/checkout` → 运行 `python3 tools/check-site.py site` 校验 → `actions/configure-pages` → `actions/upload-pages-artifact`，`path: site`）和 `deploy`（`actions/deploy-pages`，`environment: github-pages`）。
  - **只用 GitHub 官方 action，并锁定到完整的 commit SHA**，用注释标出版本号，例如 `uses: actions/checkout@<40位SHA> # v4.x.x`。SHA 用 `gh api repos/actions/checkout/git/ref/tags/v4…` 查询得到，不要凭记忆写。
- 校验 workflow 语法：`ruby -ryaml -e 'YAML.load_file(".github/workflows/pages.yml")'`（macOS 自带 Ruby）。
- PR 合并前 workflow 不会运行；部署需要用户先完成下面的设置。

### 上线清单（写进 PR 描述，由用户操作）

1. 仓库 Settings → Pages → Build and deployment → Source 选 **GitHub Actions**。
2. Settings → Environments → `github-pages` → Deployment branches：把 `codex/ui-phosphor-wireframe` 加入允许列表。默认只允许默认分支 `main`，而 `main` 停在 1.4.0。
3. 合并 PR 后，到 Actions 页面确认 "Deploy site" 运行成功，然后访问 https://drafffffff.github.io/iMic/ 。
4. 可选：仓库首页 About 的 Website 填入上述地址（`gh repo edit --homepage …`，由用户决定）。
5. 拿到 TestFlight 公开链接后，修改 `site/assets/js/site.js` 里的 `IOS_TESTFLIGHT_URL`。

## 9. Mac 端帮助入口（小改动）

- `mac/MacExperience.swift` 的菜单栏菜单中，在"设置…"下方加一项 **「iMic 官网与帮助…」**，用 `NSWorkspace.shared.open` 打开 `https://drafffffff.github.io/iMic/`。
- 设置窗口「高级」页底部加一个链接按钮 **「iMic 官网 ↗」**，打开同一地址。
- 地址放在一个常量里，例如 `mac/` 下已有的 `SetupLinks`（`Onboarding.swift`）中加 `website`，菜单和设置共用。
- 预览模式（`preview != nil`）下不打开浏览器（与现有 `openBailianConsole` 一致）。
- 改的是已有文件，不需要改 `scripts/build-mac.sh`。`scripts/test-mac-settings.sh` 会检查菜单结构：如果有菜单项数量之类的断言，同步更新测试。

## 10. README 与文档

- `README.md` 开头加一行官网链接。
- `docs/TESTFLIGHT-QUICKSTART.md` 中下载 Mac 版的链接，改为指向落地页的下载区（保留 Releases 链接作为备用）。

## 11. 硬性约束

- 不修改协议、iOS 代码、扫光相关的 Mac 代码。
- 不引入任何第三方 CDN、字体、统计、追踪或 Cookie。
- 不使用来源不明的素材；画面里不出现个人信息。
- 页面上的事实性描述（系统要求、隐私、加密、兼容应用）必须与仓库文档一致，有出处可查。
- 不修改 GitHub 仓库设置（见 0.7）。
- workflow 只用锁定 SHA 的官方 action。
- 不提交 `.claude/`、`build/` 下的产物和原始录屏。

## 12. 测试与验收

### 12.1 页面检查

1. `tools/check-site.py site`：所有本地引用的资源都存在；体积预算（7.3）；每个 `<img>` 和 `<video>` 都有 `alt` 或 `aria-label`；只有一个 `<h1>`；没有引用第三方域名的 `<script>`、`<link>`、`<img>`（GitHub API 请求除外，它在 JS 里）；外链列表输出到报告中。
2. 本地预览：`scripts/site-preview.sh`（`python3 -m http.server 8787 -d site --bind 127.0.0.1`）。
3. 用 Chrome 无头模式截图（`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --screenshot=… --window-size=…`），至少截以下几张，放在 `build/ux-shots/site/`：
   - 桌面 1440×900：首屏、交互亮点、下载区。
   - 移动 390×844：首屏、下载区（应显示"把链接发送到 Mac"）。可以用 `--user-agent` 模拟 iPhone。
   - `?from=ios#download`：下载区高亮。
   - `?release-api=fail`：兜底链接。
   - 减弱动态效果：可以用 CSS 媒体查询的模拟方式，或者在截图前注入样式。
   如果无头截图拿不到完整的长页面，就分段截图。
4. 在本地服务器上手动确认（写进报告）：API 正常时，下载按钮指向 `iMic-1.4.4-macOS-universal.dmg`，版本号正确；断网或 `?release-api=fail` 时，指向 releases/latest。

### 12.2 全量测试（PR 必须附报告）

本任务改了 Mac 菜单，所以依然要跑全量。每条记录：通过或失败、耗时、关键输出（失败时附最后 20 行）。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 tools/check-site.py site
ruby -ryaml -e 'YAML.load_file(".github/workflows/pages.yml"); puts "ok"'
swift test
./scripts/test-mac-settings.sh
./scripts/test-polish-effect.sh
./scripts/test-polish.sh
./scripts/test-input.sh
./scripts/test-clear-input.sh
./scripts/test-ios-mac-selection.sh
./scripts/test-ios-reconnect.sh
./scripts/test-polish-link.sh
./scripts/test-screen-idle.sh
./scripts/build-mac.sh
IMIC_SIM_NAME=<你的专用模拟器 UDID> ./scripts/build-ios.sh
```

环境原因无法执行的命令，如实写明原因，不要写成"通过"。在干净分支上也失败的测试，标注为"既有失败"，不要顺手修。

### PR 描述模板

```markdown
## 改动
- …（每个文件或目录一句话）

## 页面结构对照
- 4.1 首屏 … 4.9 页脚：…
- 6.1 最新版链接 / 6.2 from=ios / 6.3 手机打开 / 6.4 视频：…
- 偏离之处及原因：…

## 素材
| 文件 | 来源（命令） | 时长 | 体积 |
|---|---|---|---|

## 体积预算
（check-site.py 输出）

## 截图
- build/ux-shots/site/…（逐张说明）

## 全量测试报告
| 命令 | 结果 | 耗时 | 备注 |
|---|---|---|---|

## 上线清单（需要用户操作）
1. Pages Source 选 GitHub Actions
2. github-pages 环境允许 codex/ui-phosphor-wireframe
3. …

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## 13. 遇到以下情况时停下来，在 PR 中说明

- 无法在不接管前台的情况下录到 Mac 扫光素材。先用静态截图代替，并说明。
- 页面描述与仓库文档有矛盾，无法确定以哪个为准。
- 官方 action 的 SHA 无法查询。
- 体积预算无法满足。说明原因和建议。
