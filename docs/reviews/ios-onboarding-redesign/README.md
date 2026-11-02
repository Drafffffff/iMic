# iPhone 主页引导验收

本目录是任务书第 8 节的截图与报告。截图由本任务创建的专用模拟器、真实 HomeView / DeviceSelectionView / PairingSheet 组件生成；预览只提供可重复的状态数据。录屏与手势 UI 测试走正式引导状态机；视觉回归使用可重复的预览状态。

- [最新 HUD 视觉修订、逐项对照与测试](visual-pass.md)
- [改前 / 改后对照拼图](before-after.png)
- [初次交付的测试、隔离与合并说明](verification.md)
- [新旧屏数与逐屏字数](copy-counts.md)
- 录屏：仓库本地 `build/onboarding-redesign/release-journey.mp4`，在 Release 模拟器包中从欢迎、三步练习、更多手势 HUD 面板、连接页到“稍后再连接”返回主页。文件不纳入 Git。

## 截图矩阵

| 状态 | 17 Pro 中文 | 17 Pro English | SE 中文 | SE English |
| --- | --- | --- | --- | --- |
| 欢迎 | [PNG](pro-zh-Hans-01-welcome.png) | [PNG](pro-en-01-welcome.png) | [PNG](se-zh-Hans-01-welcome.png) | [PNG](se-en-01-welcome.png) |
| 练习 1 · 按住 | [PNG](pro-zh-Hans-02-hold.png) | [PNG](pro-en-02-hold.png) | [PNG](se-zh-Hans-02-hold.png) | [PNG](se-en-02-hold.png) |
| 练习 2 · 松手 | [PNG](pro-zh-Hans-03-release.png) | [PNG](pro-en-03-release.png) | [PNG](se-zh-Hans-03-release.png) | [PNG](se-en-03-release.png) |
| 练习 3 · 下拉 | [PNG](pro-zh-Hans-04-send.png) | [PNG](pro-en-04-send.png) | [PNG](se-zh-Hans-04-send.png) | [PNG](se-en-04-send.png) |
| 更多手势 | [PNG](pro-zh-Hans-05-more.png) | [PNG](pro-en-05-more.png) | [PNG](se-zh-Hans-05-more.png) | [PNG](se-en-05-more.png) |
| 搜索 Mac | [PNG](pro-zh-Hans-06-search.png) | [PNG](pro-en-06-search.png) | [PNG](se-zh-Hans-06-search.png) | [PNG](se-en-06-search.png) |
| 发现 Mac | [PNG](pro-zh-Hans-07-found.png) | [PNG](pro-en-07-found.png) | [PNG](se-zh-Hans-07-found.png) | [PNG](se-en-07-found.png) |
| 真实配对码组件 | [PNG](pro-zh-Hans-08-pair.png) | [PNG](pro-en-08-pair.png) | [PNG](se-zh-Hans-08-pair.png) | [PNG](se-en-08-pair.png) |
| 下载链接底部卡 | [PNG](pro-zh-Hans-09-download.png) | [PNG](pro-en-09-download.png) | [PNG](se-zh-Hans-09-download.png) | [PNG](se-en-09-download.png) |
| 首次真实输入提示 | [PNG](pro-zh-Hans-10-ready.png) | [PNG](pro-en-10-ready.png) | [PNG](se-zh-Hans-10-ready.png) | [PNG](se-en-10-ready.png) |
| 完成提示 | [PNG](pro-zh-Hans-11-complete.png) | [PNG](pro-en-11-complete.png) | [PNG](se-zh-Hans-11-complete.png) | [PNG](se-en-11-complete.png) |

另附 [SE 最大辅助功能字号](se-en-accessibility-xxxl.png)。说明复用主页 InstrumentHint 的系统 10pt 基准并随动态字体放大；辅助功能字号下真实弦缩小并让开状态区，录音条与弦仍保持原生操作。

“发现 Mac / 配对 / 首次输入 / 完成”截图使用 DEBUG 可视化数据，未向真实 Mac 输入；系统配对输入框和下载共享面板仍是正式组件。练习功能和录屏使用的 Release 流程不依赖这些预览参数。
