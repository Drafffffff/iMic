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
