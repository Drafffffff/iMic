# 验证与合并说明

最新视觉已按 [HUD 视觉修订](visual-pass.md) 替换；下文为首次交付的历史记录。

后续与 PR #23 / #24 的合并验证见 [合并验证记录](merge-validation.md)；下文保留首次引导交付的验收记录。

基线：`269ad67`（`codex/ui-phosphor-wireframe`）。工作分支：`codex/ios-onboarding-redesign`。

## 实现

- App 始终呈现同一个 HomeView；欢迎、练习和首次输入是其锚点上的 60% 黑色挖空提示层。真实录音横条、StringMotionStore、ReceiverFlowStore、HUD、波形、文字附着/飞行、声音和触感共用正式路径。
- 练习按住超过 0.5 秒自动切到“松手”；短按不推进。松手逐字补齐结果后进入下拉；下拉在真实回弹过中线时推进。可选删字、光标、清空、取消仍通过 HomeView 的原手势处理。
- 删除独立 PracticeView、灰色横条、假 Mac 文本框、重复的弦物理和循环手指插画，以及假本地网络权限框。手势圆点只移动一次；减少动态效果时用静态图示。
- “稍后再连接”保存暂停自动连接的选择；返回/重启均保持未连接主页，主动打开电脑入口、设置连接页或按录音条才恢复发现，不会再次自动弹出配对。退出按钮固定在安全区域底部。
- DeviceSelectionView 增加引导显示方式，仍共用设备行、选择和 PairingSheet 的六位码输入；搜索开始才启动本地网络发现。下载卡共用 OnboardingLinks、Handoff、ShareLink 与复制。
- 麦克风只在正式模式第一次按住时进入原有权限路径；语音识别保留原有时机，没有修改录音授权/引擎实现。
- 保存主流程、练习动作和重播来源；进程被杀后恢复。正在按住的步骤恢复为重新按住。已完成/已有配对的默认跳过策略保留，设置可重播且不再走欢迎/连接。
- 高亮组件保留原生辅助功能操作，提示可朗读，VoiceOver 另有“跳过此步”。提示使用动态字体；SE 最大字号下仪器缩小上移，同一真实主页几何同时用于绘制、触摸、物理与引导挖空。

## 练习隔离

1. HomeView 在任何 `link.start()` 前调用 `configureOnboarding()`；欢迎/练习调用 `suspendForPractice()`，同步关闭 TCP / BLE 和 NWBrowser、取消重连，并保持 `startDeferred`。重播也先停止现有链路。
2. SessionModel 的 `beginListening` / `endListening` 在方法入口转入本地 PracticeSession 后立即返回，完全不经过 AudioCapture、麦克风/语音权限、音频分帧或 beginStreaming。`sendInput` 直接落到本地文本游标。
3. PracticeSession 仅持有文本、游标、有限的合成播放 Task 和真实 SpectrumStore 的引用参数，没有 AudioCapture、SpeechPreview 或网络客户端。它不是另一个页面，也不实现手势/弹簧。
4. 额外保留 LinkClient 的 practice 发送锁；前后台激活和过期远端回调在练习期间不进入真实会话。
5. 结束/退出取消本地 Task、清空文字/游标/波形/notice、移除回调、清空接收器与触摸状态，再恢复正常发现。

XCUITest 从无预览参数的新手流程验证了：

```text
PRACTICE AUDIT: link=0 send=0 mic=undetermined speech=undetermined practice=true phase=result text=25
PRACTICE AUDIT: link=0 send=0 mic=undetermined speech=undetermined practice=true phase=idle text=0
PRACTICE CLEANUP: ... send=0 mic=undetermined speech=undetermined practice=false phase=idle text=0 deferred=true idle=true
```

重播检查只统计本次 `active=true` 后的区间；进入连接页之后的正常 Bonjour 发现不计作练习发送。完整测试日志摘录见 [test-results.txt](test-results.txt)。Release 测试应用只使用系统语言参数，不含 `--debug-*` / `--ui-preview` / `--demo-script`。

## SessionModel.swift 的最小改动（合并录音任务时按此核对）

1. 增加 `practiceActive`、本地 `practice` 数据源和 `setPracticeActive` 桥接；快照仅写既有 phase / elapsed / transcript / liveTranscript / pasted / target。
2. begin / end / sendInput 的方法入口增加练习早返回；本地 clear 复用 clearGeneration。三个手势开关仅在练习时视为可用，远端设置值不变。
3. activate / foreground / background 与结果、clear 回调增加练习隔离检查。
4. 离开时调用现有 reset / deactivateAudio 清理，并归零 elapsed / copied。

没有修改 `AudioCapture.swift`、协议、Mac 源码或 Mac 资源。录音引擎、授权、采样、短按音频门槛、缓存、流式提交和正式识别结果处理保持原实现。

`HoldControl` 仅新增默认空回调，向练习报告原生 UITouch 时长，防止主线程繁忙时把真实长按误判成短按。HomeView 的 GestureState 取消兜底延后到松手处理之后，避免优化构建先清空方向状态而吞掉发射；没有改动弦物理。

字符串 catalog 新增 `ios-only` 注释；生成器跳过这些纯 iOS 文案，避免同步翻译时改动 Mac 资源。

## 验证范围

要求的协议、构建、本地化、选择、重连和 UI 检查结果见 `test-results.txt`。真实手势与隔离在专用模拟器验证；模拟器录屏不记录触觉，音效通过原事件路径及日志核对，未声称做过真机手感或云识别验收。首次真实输入的完成条件为 Mac 结果 `pasted == true`，失败继续显示主页原有状态。

专用设备（iOS 27.0）：

- iPhone 17 Pro：`FB98BBCE-9779-45DB-9576-E4E70B6354B8`
- iPhone SE 3：`E13612D9-AE13-4B2C-BF1E-1473872AC414`

只对上述两台安装、启动、录屏和测试；没有构建到真机。验收结束后已关闭并删除这两台设备，并复查设备清单确认两个 UDID 均不存在。

## 录屏文件

`build/onboarding-redesign/release-journey.mp4`：iPhone SE 专用模拟器的正式 Release 引导，21.3 秒；只裁去 XCTest 启动/退出的系统等待，没有加速动作。完整覆盖欢迎、按住、松手文字动画、真实下拉弹射、更多手势卡、连接与稍后再连接后的干净主页。

SHA-256：`8e4502f433197926a6a70997d05780d52268ca6b51c973dad8bbac372d164415`。
