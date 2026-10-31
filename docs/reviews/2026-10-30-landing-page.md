# iMic 落地页验收报告

日期：2026-10-30。分支：`codex/landing-page`；审核目标：`codex/ui-phosphor-wireframe`。

## 改动

- `site/`：纯静态中文单页、404、SEO/分享图、图标、App 预览视频与 WebP/PNG 海报；无 npm、CDN、字体文件、统计、Cookie 或持久缓存。
- `site/assets/js/site.js`：4 秒超时的 GitHub 最新版下载、失败回退、TestFlight 配置、引导深链、手机分享/复制、视口懒加载与减弱动态效果。
- `.github/workflows/pages.yml`：仅官方 action，完整 SHA 固定；build 校验并上传 site，deploy 使用 github-pages 环境。未启用 Pages 或修改任何仓库设置。
- `mac/MacExperience.swift`、`mac/SettingsWindow.swift`：菜单与高级设置新增官网帮助入口；`mac/Onboarding.swift` 的 `SetupLinks.website` 统一地址，预览模式直接返回。
- `tests/MacSettings/main.swift`：校验新增菜单位置、设置链接、共享常量与预览调用。
- `tools/site-pixel.swift`：直接解析 App 的 `PixelFont.glyphs`；`tools/icon.swift` 仅增加 site 输出分支；`tools/site-og.swift` 用首屏截图、字标和原图标合成 1200×630 分享图。
- `tools/check-site.py`：无依赖的资源、锚点、HTML、外部资源、体积、视频时长/编码/faststart 校验。
- `scripts/site-preview.sh`、`scripts/site-capture.sh` / `tools/site-capture.py`、`tools/test-site-browser.mjs`：本地预览、专用模拟器录制/转码、真实无头 Chrome 行为验收。
- README、TestFlight 上手文档、NEXT 更新入口和发布待办；本报告与截图作为可审阅产物，不提交 build 或原始录屏。

## 页面结构对照

- 4.1 首屏：主标题、Mac/iPhone 下载锚点、动态版本、系统要求、自己的百炼 Key 提示，8 秒预览合成短片。
- 4.2 FEEL：HOLD、STRING、LIVE、POLISH、SOUND 五项左右交替；手机单列；清空核验、实时兼容输入风险、扫光权限与系统版本均说明。
- 4.3 POLISH：五种模式各一组手写「示例」，不调用真实 API；中/英/日/韩；终端只输入单行命令、不自动执行。
- 4.4 ANYWHERE：仅列测试矩阵的 TextEdit、Safari、Chrome、Terminal、Cursor、Zed、iTerm、Otty。说明应用切换保留结果与终端换行转空格。
- 4.5 PRIVATE：局域网/BLE、逐帧 AES-GCM、Mac credentials.json 0600、百炼/润色服务数据流、Apple Speech 可能联网、完整隐私链接。
- 4.6 START：Mac Key→权限、iPhone TestFlight、六位码配对；百炼控制台链接。
- 4.7 DOWNLOAD：动态 DMG/体积/版本/SHA256；公证说明；所有版本；TestFlight 空配置显示禁用按钮，高级用户 IPA 提示。
- 4.8 FAQ：7 个原生 details，键盘 Enter 可展开。
- 4.9 页脚：仓库、隐私、反馈邮箱、© 2026 iMic、GPL-3.0。
- 6.1：正常 API、强制失败、403/429、缺附件、坏 JSON、异常 URL、断网、4 秒超时、无 JS 均测试；每次加载只请求一次。
- 6.2：from=ios 或 #download 显示提示条并滚动，Mac 高亮 1.5 秒；减弱动态效果直接定位。
- 6.3：iPhone/Android/iPod 和 iPad 桌面 UA 检测；分享、取消分享、复制、权限拒绝后的手动链接均覆盖。
- 6.4：进入视口设置 src 并播放，离开暂停；减弱动态效果仅海报，用户可主动播放；所有视频静音、无音轨、有画面描述。

## 与草稿的差异及原因

1. 按代码修正弦手势时机和清空成功条件；未把清空描述成对所有应用无条件成功。见 [DEVELOPMENT.md「实现概览」](../DEVELOPMENT.md#实现概览)中的「中心弦」、PROTOCOL「手势就绪与清空」。
2. 实时输入注明范围核验/键盘兼容的边界及重复或误删风险；用户接管后冻结。见根目录 AGENTS.md 与 [DEVELOPMENT.md「实时预览与润色」](../DEVELOPMENT.md#实时预览与润色)。
3. 隐私中补充 Apple Speech 可能使用在线服务，应用内 Key 的准确文件名与环境变量方式，符合 PRIVACY.md。
4. Mac 扫光复用现有中性测试截图，静态展示收尾；未接管前台录制，未运行 `test-polish-apps.sh`。这是任务书 7.2 / 13 允许的替代。
5. 首屏由真实 App 预览与仓库测试页合成，明确标为预览；LIVE 为测试页逐字演示，不声称它是线上识别链路录屏。STRING 短片展示附着文字及发射，完整编辑手势以 App 为准；SOUND 为声音设置界面静音展示。
6. 元素状态采用轻量细线；没有额外扫描线/辉光动画，因此减弱动态效果时无需等待装饰动画结束。

事实出处：`README.md`、`docs/PRIVACY.md`、`docs/PROTOCOL.md`、`shared/PolishOptions.swift`、`tests/PolishApps/report.py` 的 APPS、`LICENSE`。未修改协议、iOS、扫光文件、版本号、TCC 或 `/Applications/iMic.app`。

## 素材

专用模拟器：`iMic Site Capture landing-page`，iPhone 17 Pro，iOS 27.0；UDID `8E1C946A-D01F-471A-AB9C-318CEE535DE9`，由本任务创建并已删除。没有使用、关闭或擦除其他模拟器。

录制采用 `xcrun simctl io <专用 UDID> recordVideo --codec=h264`，状态栏统一 9:41/满电；原始 mov 保留在本地 `build/site-capture/`。转码脚本限定自身创建并记录的 UDID，finally 删除模拟器。以下全部 H.264、yuv420p、30fps、无音轨、faststart，ffprobe 与校验器均通过。

| 文件 | 来源（命令/制作） | 时长 | 体积 |
|---|---|---|---|
| `site/assets/video/flight.mp4` | `--ui-preview=flight --debug-flight-count=36 --debug-flight-delay=1` | 6s | 76,680 B |
| `site/assets/video/hero.mp4` | listening 前 2 秒 + flight 前 4 秒 + live 最后 2 秒，预览合成 | 8s | 75,426 B |
| `site/assets/video/listening.mp4` | `--ui-preview=listening` 波形预览 | 6s | 70,068 B |
| `site/assets/video/live.mp4` | 无头 Chrome 打开 `tests/PolishApps/fields.html?kind=chat&theme=dark`，仅向测试页写入中性示例，record start/stop；静帧补足 6 秒 | 6s | 12,902 B |
| `site/assets/video/sound.mp4` | `--ui-preview=sounds`，静态帧延长至 6 秒 | 6s | 32,096 B |
| `site/assets/img/hero.webp / .png` | 视频代表帧，ffmpeg 提取 PNG，Pillow 本地转 WebP | 静态 | 10,812 B / 99,459 B |
| `site/assets/img/listening.webp / .png` | 视频代表帧，ffmpeg 提取 PNG，Pillow 本地转 WebP | 静态 | 15,446 B / 131,779 B |
| `site/assets/img/flight.webp / .png` | 视频代表帧，ffmpeg 提取 PNG，Pillow 本地转 WebP | 静态 | 15,240 B / 166,330 B |
| `site/assets/img/live.webp / .png` | 视频代表帧，ffmpeg 提取 PNG，Pillow 本地转 WebP | 静态 | 3,916 B / 20,063 B |
| `site/assets/img/sound.webp / .png` | 视频代表帧，ffmpeg 提取 PNG，Pillow 本地转 WebP | 静态 | 19,406 B / 101,403 B |
| `site/assets/img/polish.webp / .png` | 复用现有 `build/polish-apps/report/shots/chrome-chat-dark--empty-final.png`；仅中性测试句与输入框 | 静态 | 5,280 B / 38,318 B |

图标由 `swift tools/icon.swift site site/assets/icons` 生成；字标/标签由 `swift tools/site-pixel.swift` 生成；分享图由 `swift tools/site-og.swift` 合成（需先生成桌面首屏截图）。均使用项目内源素材，不使用网上图片或真实用户内容。

复现：安装 ffmpeg、Pillow 和 agent-browser 后，运行 `IMIC_SITE_SWEEP_SOURCE=<已审阅的本地测试截图> ./scripts/site-capture.sh`；已有录屏可用 `--transcode` 重做。当前 ffmpeg 不含 WebP 编码器，因此脚本通过 Pillow 保存 WebP。预览：`./scripts/site-preview.sh`，地址 `http://127.0.0.1:8787`。

## 体积预算与外链

`python3 tools/check-site.py site`：

```text
HTML + CSS + JS: 40,158 bytes / 150,000 bytes
Hero poster WebP: 10,812 bytes / 200,000 bytes
First-screen envelope (no video): 349,215 bytes / 1,000,000 bytes
site total: 1,133,591 bytes / 15,000,000 bytes
Video flight.mp4: 6.00s · 76,680 bytes / 1,500,000 bytes · H.264 · faststart · silent
Video hero.mp4: 8.00s · 75,426 bytes / 1,500,000 bytes · H.264 · faststart · silent
Video listening.mp4: 6.00s · 70,068 bytes / 1,500,000 bytes · H.264 · faststart · silent
Video live.mp4: 6.00s · 12,902 bytes / 1,500,000 bytes · H.264 · faststart · silent
Video sound.mp4: 6.00s · 32,096 bytes / 1,500,000 bytes · H.264 · faststart · silent

External links (navigation/API only):
  https://api.github.com/repos/Drafffffff/iMic/releases/latest
  https://bailian.console.aliyun.com/?tab=model#/api-key
  https://drafffffff.github.io/iMic/
  https://drafffffff.github.io/iMic/?from=ios#download
  https://github.com/Drafffffff/iMic
  https://github.com/Drafffffff/iMic/blob/codex/ui-phosphor-wireframe/LICENSE
  https://github.com/Drafffffff/iMic/blob/codex/ui-phosphor-wireframe/docs/PRIVACY.md
  https://github.com/Drafffffff/iMic/issues
  https://github.com/Drafffffff/iMic/releases
  https://github.com/Drafffffff/iMic/releases/latest
  mailto:i0.0ia@qq.com

PASS: 2 HTML pages, 42 files, local references, anchors, accessibility attributes and budgets.
```

首屏包络保守计入了全部代码、所有像素标签、所有图标（包括正常浏览不请求的 OG）和两种首屏海报；不含懒加载视频。不会把 docs 发布到 Pages。

## 截图

截图由专用 agent-browser 会话启动 `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` 无头模式生成；CDP 固定视口和设备 UA，未接管可见 Chrome。验收同时覆盖根路径 `8787/` 和 Pages 子路径 `8788/iMic/`。原始截图在 `build/ux-shots/site/`，下方为随提交保留的审阅副本。

- [1440×900 首屏](landing-page/desktop-hero.png)（本地 `build/ux-shots/site/desktop-hero.png`）
- [1440×900 交互亮点](landing-page/desktop-feel.png)（本地 `build/ux-shots/site/desktop-feel.png`）
- [1440×900 下载区，真实 API 1.4.4](landing-page/desktop-download.png)（本地 `build/ux-shots/site/desktop-download.png`）
- [390×844 首屏，iPhone UA](landing-page/mobile-hero.png)（本地 `build/ux-shots/site/mobile-hero.png`）
- [390×844 下载区，显示「把链接发送到 Mac」](landing-page/mobile-download.png)（本地 `build/ux-shots/site/mobile-download.png`）
- [768×1024 iPad 桌面 UA + 触点识别](landing-page/tablet-download.png)（本地 `build/ux-shots/site/tablet-download.png`）
- [from=ios#download，Mac 描边高亮（固定 1.4.4 API 响应以捕捉 1.5 秒状态）](landing-page/from-ios-highlight.png)（本地 `build/ux-shots/site/from-ios-highlight.png`）
- [release-api=fail，回退到 releases/latest](landing-page/release-fallback.png)（本地 `build/ux-shots/site/release-fallback.png`）
- [禁用 JavaScript 后仍可下载](landing-page/no-javascript.png)（本地 `build/ux-shots/site/no-javascript.png`）
- [减弱动态效果，海报和手动播放](landing-page/reduced-motion.png)（本地 `build/ux-shots/site/reduced-motion.png`）
- [/iMic/404.html 的同风格错误页](landing-page/404.png)（本地 `build/ux-shots/site/404.png`）

## 全量测试报告

所有命令在本 worktree 运行，`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。14/14 通过，无环境阻塞、无既有失败。Mac 设置测试会按原脚本打开测试窗口；未运行批量真实应用扫光脚本。iOS 构建为 generic Simulator 编译（不加 --run），素材安装及启动仅使用上述专用 UDID。

| 命令 | 结果 | 耗时 | 关键输出 |
|---|---|---|---|
| `python3 tools/check-site.py site` | 通过 | 0.04s | 2 个 HTML、42 个文件；本地资源/锚点/无外部资源/体积均通过 |
| `ruby -ryaml -e 'YAML.load_file(".github/workflows/pages.yml"); puts "ok"'` | 通过 | 0.09s | ok |
| `swift test` | 通过 | 184.74s | 64 tests，0 failures |
| `./scripts/test-mac-settings.sh` | 通过 | 32.06s | 原有设置/菜单测试及新增帮助入口、共享地址、预览隔离断言通过 |
| `./scripts/test-polish-effect.sh` | 通过 | 39.06s | 56 tests，0 failures |
| `./scripts/test-polish.sh` | 通过 | 8.10s | 17 tests，0 failures；mock 服务，不生成线上素材 |
| `./scripts/test-input.sh` | 通过 | 4.42s | 21 tests，0 failures |
| `./scripts/test-clear-input.sh` | 通过 | 15.55s | direct / ignored-value / readonly 均通过 |
| `./scripts/test-ios-mac-selection.sh` | 通过 | 61.85s | 所有自动 Mac 选择集成检查通过 |
| `./scripts/test-ios-reconnect.sh` | 通过 | 48.74s | 所有前台重连检查通过 |
| `./scripts/test-polish-link.sh` | 通过 | 37.58s | 真实本地加密链路：模式/语气/语言同步，旧端能力限制通过 |
| `./scripts/test-screen-idle.sh` | 通过 | 6.24s | 待机遮罩、触摸唤醒、忙碌保护及生命周期取消通过 |
| `./scripts/build-mac.sh` | 通过 | 66.99s | 双架构构建成功，仅输出 build/mac.noindex/iMic.app |
| `IMIC_SIM_NAME=8E1C946A-D01F-471A-AB9C-318CEE535DE9 ./scripts/build-ios.sh` | 通过 | 12.28s | BUILD SUCCEEDED；IMIC_SIM_NAME=8E1C946A-D01F-471A-AB9C-318CEE535DE9，未加 --run |

本地完整日志保留在 `build/site-tests/`，没有提交构建产物。协议 XCTest 64、扫光 56、润色 17、输入范围 21 合计 158 项通过，其他脚本含设置与链路/清空/待机集成断言。

### 浏览器验收

`node tools/test-site-browser.mjs <专用 Chrome 的 CDP URL>`：21/21 通过（不依赖 Playwright，不调用百炼）。可用 `IMIC_SITE_URL=http://127.0.0.1:8788/iMic/` 测试 Pages 子路径。

| 检查 | 结果 | 耗时 |
|---|---|---|
| Real latest API → v1.4.4 DMG, size and checksum | 通过 | 1.13s |
| One API request; dynamic release replaces every DMG link | 通过 | 0.22s |
| API fallback: 403 | 通过 | 0.18s |
| API fallback: 429 | 通过 | 0.18s |
| API fallback: missing DMG | 通过 | 0.20s |
| API fallback: invalid JSON | 通过 | 0.18s |
| API fallback: unsafe asset URL | 通过 | 0.18s |
| API fallback: offline | 通过 | 0.19s |
| API fallback: 4-second timeout | 通过 | 4.18s |
| Explicit fail query | 通过 | 0.49s |
| No JavaScript: download remains usable; TestFlight disabled | 通过 | 0.43s |
| 390px iPhone: share button, direct link, no horizontal overflow | 通过 | 1.81s |
| Native share receives production URL | 通过 | 0.26s |
| Share cancel preserves UI without error | 通过 | 0.26s |
| Clipboard fallback and manual recovery | 通过 | 0.29s |
| 768px iPad desktop-UA detection and layout | 通过 | 0.39s |
| from=ios scroll, banner, 1.5s Mac highlight | 通过 | 1.81s |
| Hash-only deep link | 通过 | 0.18s |
| Reduced motion: posters only until explicit play | 通过 | 0.25s |
| Lazy videos start in viewport and pause after leaving | 通过 | 0.30s |
| FAQ keyboard interaction and storage-free page | 通过 | 0.32s |

真实 API 在本地服务器中确认：按钮指向 `https://github.com/Drafffffff/iMic/releases/download/v1.4.4/iMic-1.4.4-macOS-universal.dmg`，显示 `版本 1.4.4 · 1.6 MB`；SHA256 指向同一 v1.4.4 的附件。`?release-api=fail`、断网或超时均指向 `https://github.com/Drafffffff/iMic/releases/latest`，显示「最新版本」。9.8.7 仅用于验证动态替换的 mock 数据，不写入页面。

附加检查：`git diff --check` 通过；ffprobe 对全部五个视频验证编码/尺寸/30fps/时长/无音轨；axe WCAG 2 A/AA 自动检查 0 violations。axe 的两类人工核验项为非文字箭头的对比度与无声视频字幕：手工确认正文/次要文案/按钮对比度均 ≥4.5:1，视频没有音轨且相邻文字与 aria-label 描述画面，因此按任务书不另加字幕。自动检查结果不等同于完整无障碍认证。

## 官方 Action 来源

以下 SHA 均实际用 `gh api repos/actions/<action>/git/ref/tags/<version>` 查询，object.type 为 commit，并已写入 workflow 注释。

| action | 版本 | SHA |
|---|---|---|
| actions/checkout | v4.3.1 | 34e114876b0b11c390a56381ad16ebd13914f8d5 |
| actions/configure-pages | v5.0.0 | 983d7736d9b0ae728b81ab479565c72886d7745b |
| actions/upload-pages-artifact | v3.0.1 | 56afc609e74202658d3ffba0e8f6dda462b719fa |
| actions/deploy-pages | v4.0.5 | d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e |

## 上线清单（需要用户操作）

1. Claude 审核 PR；由维护者合并到 `codex/ui-phosphor-wireframe`，不合并到停在 1.4.0 的 main。本任务不合并、不启用自动合并。
2. Settings → Pages → Build and deployment → Source 选择 **GitHub Actions**。
3. Settings → Environments → `github-pages` → Deployment branches，允许 `codex/ui-phosphor-wireframe`。
4. 合并后确认 Actions 的 **Deploy site** 成功；访问 https://drafffffff.github.io/iMic/ 和 https://drafffffff.github.io/iMic/?from=ios#download 。未配置环境前，不能把本地验证当成线上部署成功。
5. 拿到 TestFlight 公开链接后，填写 `site/assets/js/site.js` 顶部的 `IOS_TESTFLIGHT_URL`，检查启用后的安装按钮。
6. 可选：由用户决定是否在仓库 About 的 Website 填入官网地址。

本任务仅提交与推送分支并创建 PR；没有启用 Pages、修改环境/主页字段、创建 Release、安装 Mac App 或改动版本号。

由 Codex 实现，待 Claude 审核。
