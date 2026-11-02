# HUD 视觉修订（PR #25）

按 `docs/tasks/2026-11-03-onboarding-visual-pass.md` 修订；本记录取代首次交付中有关黑色遮罩、悬浮提示、白色开始按钮和底部卡片的说明。流程仍为同一个真实 HomeView 的欢迎 → 本地练习 → 连接 Mac → 首次输入。

[改前 / 改后对照拼图](before-after.png)（17 Pro 中文，同一列上下对照）；[完整截图矩阵](README.md)。44 张普通截图全部替换，另附 SE 最大辅助功能字号。

| 原问题 | 本次处理与截图 |
| --- | --- |
| 欢迎白色按钮、重复居中字标、标语压弦、暗红横条、悬浮老用户入口 | 只保留左上真实 Wordmark；READY 的原状态说明显示标语；真实橙色横条显示 HOLD TO START，按住直接开始本地录音练习；老用户入口移到页头 GUIDE HUD。[欢迎](pro-zh-Hans-01-welcome.png) |
| 练习提示悬空、进度和跳过挤在页头下面 | HOLD / RELEASE / PULL 与原 READY 共用 InstrumentStatus；一句说明就在原状态说明行。右侧原设备入口替换为 GUIDE 01/03 · 跳过，触摸区域至少 44pt。[HOLD](pro-zh-Hans-02-hold.png)、[RELEASE](pro-zh-Hans-03-release.png)、[PULL](pro-zh-Hans-04-send.png) |
| 黑色遮罩压暗横条、通用手指图形 | 删除遮罩及其拦截层；四个细 HUD 角括号使用真实锚点，60%–100% 亮度、1.6 秒周期，观察既有活动时钟；手势用小象牙白方点和短拖尾，移动一次消失。减少动态效果时静止。横条各步骤保留 Theme.orange。 |
| 更多手势卡片压住横条 | 无圆角、Theme.ink 背景、Theme.line 细框，MORE / GESTURES，四行像素图形 + 说明 + TRY ›、底部 LATER。真实弦在本步骤缩小并下移，面板位于其上方；大字号行可滚动。[更多](se-zh-Hans-05-more.png) |
| 连接页系统导航、大 LINK、菊花 | 复用主页 InstrumentIdentity、HUDDivider、InstrumentStatus 与 TechBackground，LINK / MAC + SCAN → FOUND → PAIR。设备行和选择逻辑共用设置页路径，电脑与选中对勾用 PixelSymbol。三个方块依次点亮代替菊花，稍后连接在页头。[搜索](pro-zh-Hans-06-search.png)、[找到](pro-zh-Hans-07-found.png)、[配对](pro-zh-Hans-08-pair.png) |
| 下载卡错误 IMIC 字体 | 改用真实 Wordmark 资源，共享和复制用细线行，保留 Handoff、ShareLink 和剪贴板行为。[下载](pro-zh-Hans-09-download.png) |
| 首次输入、完成提示悬浮 | READY 的状态说明教学，权限小字在同一区域；成功显示 DONE +「完成。以后就这样用。」，两秒后恢复；真实错误仍显示原错误与 MIC TEST。[首次输入](pro-zh-Hans-10-ready.png)、[完成](pro-zh-Hans-11-complete.png) |

## 复用与范围

- InstrumentStatus、InstrumentIdentity 同时供原生界面与 PhosphorArtwork 使用，防止 Metal 显示与真实点击/辅助功能内容分叉。说明沿用 InstrumentHint 的 10pt 基准并支持动态字体；未新增颜色或字体常量。
- VoiceOver 可读状态字、说明及真实控件；页头跳过提供手势替代。辅助功能字号下文字完整换行，真实弦缩小并让开状态区。大字状态变更完整重绘，避免局部纹理残影。
- 保留 HoldControl、PracticeSession、StringMotionStore、ReceiverFlowStore、真实动画/音效/触感路径；本轮没有修改 SessionModel 的练习桥接或 AudioCapture 实现。
- 新增 OnboardingVisualUITests：所有 11 个主页引导状态均无 `onboarding.start` 按钮、横条可点击且位于屏内、实际截图横条像素为橙色；更多面板与横条/弦框不相交，四个 TRY 与 LATER 都可点击且在面板内。两种屏幕运行同一组断言。
- 旧流程、练习隔离与 SessionModel 最小改动的背景见 [verification.md](verification.md)，采集恢复合并背景见 [merge-validation.md](merge-validation.md)。本轮同步和最终测试结果见下方。

本轮回归补充：HUD 操作与 LATER 显式设置矩形点击区域（至少 44pt），避免空白处点穿；延迟连接后的设置重播也实际按住录音并核验隔离，练习按下不会恢复正式发现。修改只在 HomeView 的正式连接入口增加 `!practiceActive` 判断，SessionModel 未增加本轮改动。

## 最终同步、验证与清理

实现完成后唯一一次合并基础分支 `f7ec9961d31db709b0d73bbf9052666ef3bbbc33`（含 #23 / #24 / #27），自动整合 catalog 与 SessionModel，无文本冲突。AudioCapture.swift、AudioCaptureController.swift、MicrophoneTestView.swift 和协议均与该基础版本逐字一致；上游静音监测、路由恢复与 MIC TEST 保留。视觉轮未扩大 SessionModel 的练习改动。

随后执行一轮全量脚本。首轮 UI 发现 LATER 空白区域点穿，补矩形点击区域后定向复测引导；Pro 浮点高度为 43.99999999999994pt，断言仅容忍 0.001pt 舍入；SE 底部刻度间距调整后定向复测视觉和 Release。未再次同步基础分支或重复整套脚本。所有项目的最终结果如下（首次失败和后续通过均保留在日志摘录中）。

| 检查 | 最终结果 |
| --- | --- |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | 74 tests / 0 failures |
| `./scripts/build-ios.sh` | Debug Simulator 构建通过 |
| `python3 tools/check-l10n.py` | 双语、占位符、生成资源与中文检查通过 |
| `./scripts/test-ios-mac-selection.sh` | 全部通过 |
| `IMIC_RESUME_TEST_PORT=47939 ./scripts/test-ios-reconnect.sh` | 全部通过 |
| `./scripts/test-ios-audio.sh` | 94 capture assertions 全部通过 |
| `OnboardingUITests` / SE | 3/3 通过，含恢复、全部手势、跳过、稍后连接、实际长按重播与隔离 |
| `OnboardingVisualUITests` / SE + 17 Pro | 两种屏幕均通过，各覆盖 11 个主页状态；真实橙色像素、可点击性、44pt HUD、面板/弦/横条不相交 |
| `MicrophoneEntryMergeUITests` / SE | 1/1，通过原自检页、设置入口及首次输入错误恢复入口 |
| Release `build-for-testing` + `ShippingPracticeUITests` / SE | 构建与正式流程通过；全新安装，仅系统语言参数 |
| 截图 | 45 张非空原生尺寸 PNG + 改前/改后拼图；大字号人工检查 |

[日志摘录](visual-test-results.txt)。完整命令、输出、xcresult 与清理 JSON 位于本地 `build/onboarding-visual-report/`。

本轮 Release 录屏：`build/onboarding-redesign/release-journey.mp4`，39.19 秒 / 30,998,716 bytes，完整录制、未加速。SHA-256：`53a37364018b59ce01089b876ac529e3cfe27f1d2ccc1551f37c2de1ec6f3d60`。

只使用本轮创建的 iOS 27.0 专用设备：

- iMic Visual Pass Pro Codex / iPhone 17 Pro：`2773097F-7641-4708-B67E-005610F11AA4`
- iMic Visual Pass SE Codex / iPhone SE 3：`41520B60-659F-4D12-A769-705D91D29A3D`
- 仅补拍首帧较慢的中文松手截图：iMic Visual Pass Pro Screenshot Codex / iPhone 17 Pro：`CF6FD049-658E-435A-9570-E25B98CA9E93`

三台均已关闭并删除，并核验设备清单无上述 UDID；测试禁用并行克隆。未使用其他模拟器、未构建到真机、未合并 PR。模拟器不能证明真实触觉；音效和触感共用正式事件路径，未声称真机或云识别验收。
