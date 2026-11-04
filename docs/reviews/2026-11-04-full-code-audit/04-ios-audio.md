# iPhone 音频采集与会话 审计

## 范围与方法

已阅读 `AGENTS.md`、指定的音频采集、ObjC 桥接、Speech、会话、自检、音效与触感文件，并追踪 `HomeView.swift`、`HoldControl.swift`、自检入口和 `VoiceProcessingPolicy.swift`。使用 `rg`、`nl`、`cat`、`git log` 核对调用链、现有测试及文档中的已知边界。

尝试执行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/imic-audit-iphone-audio
```

沙箱拒绝创建 `/tmp` 编译缓存，测试未启动。以下结论来自静态代码与可达执行路径，未经真机复现。未修改仓库、访问网络或调用真实 API。

## 发现

### [P1] 首次授权期间松手不会撤销录音请求

- 位置：[HomeView.swift:730](../../../ios/iMic/HomeView.swift:730)、[SessionModel.swift:413](../../../ios/iMic/SessionModel.swift:413)。
- 证据：等待麦克风授权时，`wantsRecording` 已为 `true`，但尚未进入 `.listening`。主页的松手回调仅在 `.listening` 时调用 `endListening()`，因此不会执行其中的 `wantsRecording = false`。`HoldControl.swift:77` 的触摸取消也走这一回调。
- 触发条件：麦克风权限尚未决定；按住后出现权限弹窗，用户松手或触摸被取消；授权 continuation 在应用为 `.active` 时恢复。
- 后果：已结束的按住仍能通过授权后的守卫，启动采集与会话。超过采样门限后继续发送音频，直到下一次操作、后台取消或录音上限。
- 建议修复：主页在任何松手或取消时都调用 `endListening()`；该函数已经在阶段检查前撤销录音意图。授权等待同时绑定本次按住的代际，防止旧回调借用新请求。
- 置信度：高。

### [P1] 冷启动尚未完成就发出“可以说话”触感

- 位置：[SessionModel.swift:402](../../../ios/iMic/SessionModel.swift:402)、[SessionModel.swift:573](../../../ios/iMic/SessionModel.swift:573)、[AudioCapture.swift:73](../../../ios/iMic/AudioCapture.swift:73)。
- 证据：`startAudioEngine()` 只是异步排入启动工作便返回 `true`；调用方立即执行 `startCapture()` 并播放 `.recordingStarted`。实际成功回调仅执行 `Haptics.shared.prepare(force: true)`，没有在采集准备完成后补发开始提示。
- 触发条件：首次录音或五秒热窗口结束后的冷启动；会话激活、VPIO 配置或引擎启动存在延迟。
- 后果：用户按开始触感开口时，引擎可能还未采集，句首音频无法恢复；启动最终失败时也已经给出成功提示。`docs/ARCHITECTURE.md:34` 明确承诺“采集准备好后给开始录音触感”，实现与之不符。
- 建议修复：保留立即响应的 `.press`；将 `.recordingStarted` 移到启动成功回调，并校验录音代际、仍在按住及前台状态。热引擎复用路径单独发出就绪提示。
- 置信度：高。

### [P1] 松手提交没有排空已采集但尚未交付的音频

- 位置：[SessionModel.swift:645](../../../ios/iMic/SessionModel.swift:645)、[SessionModel.swift:359](../../../ios/iMic/SessionModel.swift:359)、[IMicAudioInputBridge.m:258](../../../ios/iMic/IMicAudioInputBridge.m:258)。
- 证据：`endListening()` 只 flush 主线程的 `pending`，随即切到 `.transcribing` 并提交结束计数。此时没有等待 bridge 槽位、转换器和主线程投递队列排空；随后到达的 PCM 会被 `handleLiveAudio()` 放入 `preRoll`，不再计入当前录音。
- 触发条件：松手时，已有硬件采样仍停留在 worker 队列、转换器或待执行的主线程回调中。worker 调度延迟会扩大被遗漏的尾段。
- 后果：本轮末尾音频被静默排除，结束计数仍自洽，远端无法通过重传检测恢复。尾段还可能进入下一轮预录。`SpeechPreview.finish()` 也只等待已经进入其 gate 的 buffer，未覆盖仍在 bridge 中的输入。
- 建议修复：增加录音结束边界：记录松手对应的采集序号，排空该边界之前的音频及交付回调，再 flush、固定计数并发送 `audio.end`；边界之后的数据才进入热窗口预录。
- 置信度：高。

### [P2] 识别结果返回会把正在运行的 MIC TEST 当作热麦关闭

- 位置：[SessionModel.swift:278](../../../ios/iMic/SessionModel.swift:278)、[SessionModel.swift:286](../../../ios/iMic/SessionModel.swift:286)、[MicrophoneTestView.swift:32](../../../ios/iMic/MicrophoneTestView.swift:32)。
- 证据：自检接管同一个 `AudioCapture`，但没有记录采集所有权；进入自检也不结束 `.transcribing`。结果返回令 `phase` 改变，触发 `updateAudioStandby()`：先关闭监测，再因 `audio.isRunning` 安排五秒后的 `audio.stop()`。
- 触发条件：提交录音后，在结果返回前通过设置打开 MIC TEST；自检启动后收到本轮结果或失败。
- 后果：自检的恢复监测被关闭，五秒后采集被停止。该停止路径不会更新自检模型的诊断，界面可能继续显示 `RUNNING` 和冻结的旧电平。
- 建议修复：为共享采集对象增加明确的 owner/lease 标识；自检持有期间，普通会话的阶段变化不得操作其 monitoring 或安排热窗口回收。显式停止也应同步发布停止诊断。
- 置信度：高。

## 已检查且未发现问题的方面

- **生命周期与旧代隔离**：启动、恢复、停止及会话停用集中在串行队列；请求代际、controller epoch 和引擎对象身份分别过滤旧回调。
- **中断与媒体服务重置**：现有路径会释放旧引擎，中断结束不自动恢复旧录音；正常后台入口取消录音并回收采集资源。
- **路由与恢复预算**：按 UID/type 集合判断输入设备，避免把采样率、声道数或输出设备变化直接当作输入切换；自动、手动与 VPIO 恢复共享一次预算。
- **VPIO 与格式配置**：启用 VPIO 后重新读取实际格式，再连接 sink 和转换器；未把偏好 16 kHz 当作硬件实际格式。
- **桥接内存与缓冲区**：IO 使用预分配有界槽位，消费完成才释放槽位；PCM16 数据拥有独立内存，Speech 在借用回调内复制原生 buffer。未发现可证实的越界或释放后使用路径。
- **已说明的边界**：Apple Speech 可能使用在线服务、五秒热窗口及 150ms 预录均有文档说明，未作为缺陷报告。音效未改写采集会话配置，触感失败存在系统反馈回退。