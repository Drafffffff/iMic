# 并发与线程安全 审计

## 范围与方法

先读取了 `AGENTS.md`，随后对全仓 Swift 检索队列、Actor、锁、异步回调、定时器及析构路径，重点追踪：

- Mac：`LinkServer`、`BLEBridge`、`PairingStore`、`ASR`、`DeepSeek`、`main.swift`、`InputTarget`、`TextPolishEffect`、设置验证与更新器。
- iOS：`LinkClient`、`BLELinkClient`、`SessionModel`、录音控制器、`SpeechPreview`、Metal 渲染、声音、触感及显示时钟。
- 共享代码、工具中的异步入口，以及相关回归 harness 和协议、架构、声音、渲染文档。

尝试运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --scratch-path /tmp/imic-audit-concurrency
```

沙箱拒绝创建 Xcode 临时缓存，命令以 `permissionDenied` 失败，测试未启动。以下均为静态审计结果；没有修改仓库、访问网络、调用真实 API 或操作应用及系统设置。

## 发现

### [P1] 配对存储未串行化持久化，撤销记录可能被旧写入恢复

- 位置：`mac/PairingStore.swift:145`、`mac/PairingStore.swift:164`、`mac/PairingStore.swift:186`；调用入口为 `mac/LinkServer.swift:319`、`mac/main.swift:1491`。
- 证据：`trust`、`forget`、`forgetAll` 均在修改 `stored` 后解锁，再调用 `save()`；`save()` 不加锁，直接执行 `JSONEncoder().encode(stored)` 和原子文件写入。
- 触发条件：网络队列正在完成配对，用户同时在主线程解除配对。可达时序为：配对操作编码旧快照 → 解除配对写入新快照 → 配对操作最后完成旧快照的原子替换。
- 后果：磁盘状态落后于内存，重启后重新加载已经撤销的令牌；也可能丢失刚完成的配对记录。`.atomic` 只保证单次文件替换，不保证多个保存操作的顺序；编码读取本身也未受修改状态时的锁保护。
- 建议修复：让状态修改、编码和文件提交经过同一串行存储域；简单实现可使用锁内的 `saveLocked()`。仅在锁内复制快照、锁外并发写盘仍不能解决覆盖顺序问题。
- 置信度：高。

### [P2] 换机入口在主线程清理网络队列拥有的可变状态

- 位置：`ios/iMic/LinkClient.swift:514`、`ios/iMic/LinkClient.swift:548`、`ios/iMic/LinkClient.swift:1705`；竞争访问见 `ios/iMic/LinkClient.swift:1056`、`ios/iMic/LinkClient.swift:1077`。
- 证据：两个用户选择入口在进入 `queue.async` 前直接调用 `invalidateEpoch()`。该函数只用 `epochLock` 保护 `transportEpoch`，随后无锁修改 `pendingPolishPreferences`、`supportsPolishPreferences`、`remoteGestureRevision`、`remoteGestureReady` 和 `pendingClearRevision`；这些属性同时由网络队列回调读写。
- 触发条件：切换 Mac 时，原连接正在处理设置确认、手势租约或清空确认。
- 后果：确定存在跨队列、未同步的读写。**[推测]** 清理与旧回调交错时，可能出现 UI 展示的手势租约与发送端状态不一致，使 `sendInput()` 返回成功后，命令仍被 `enqueue` 的租约检查拒绝。该用户可见时序尚未动态复现。
- 建议修复：拆分函数：主线程仅同步推进受锁保护的 epoch；协议状态清理由网络队列上的 `resetProtocolStateLocked()` 完成。向主线程发布时只传递队列内生成的不可变快照。
- 置信度：高（数据竞争）；中（用户可见后果）。

### [P2] ASR 错误回调形成永久引用环，每次识别均泄漏对象

- 位置：`mac/main.swift:710`、`mac/main.swift:713`、`mac/ASR.swift:321`。
- 证据：`recognizer.onError` 的捕获列表只有 `[weak self]`，闭包内部读取 `recognizer.failureCode`，因此强持有 `recognizer`。引用关系为：`recognizer → onError → recognizer`。`cancel()` 没有清除该回调。
- 触发条件：录音达到门限并创建 `BailianASR`。无需发生错误；正常完成后将 `asr = nil` 也不能断开引用环。
- 后果：每次识别结束后 ASR 对象均无法释放，其 `results`、`confirmedText` 等状态持续留在内存，内存占用随识别次数累计增长。现有 ASR harness 使用的回调没有复制这一生产捕获方式。
- 建议修复：在错误回调中同时弱捕获 `recognizer`；或者让错误回调直接携带错误码，避免回读自身对象。
- 置信度：高。

### [P2] UI 纹理原地补丁没有与在途 GPU 读取同步

- 位置：`ios/iMic/PhosphorCompositor.swift:75`、`ios/iMic/PhosphorCompositor.swift:173`、`ios/iMic/PhosphorCompositor.swift:184`；调用见 `ios/iMic/ReceiverFlow.swift:503`。
- 证据：`replaceArtwork()` 对同一张 `.shared` 纹理直接调用 `artwork.replace(...)`；此前提交的 command buffer 仍可能在 Bloom 或最终合成中采样它。渲染器允许三个 command buffer 在途，补丁调用也没有等待相关 command buffer 完成。
- 触发条件：显示动画持续提交期间，连接状态、录音条或提示文字变化，触发局部纹理更新；GPU 尚未读完上一帧。
- 后果：CPU 写入与 GPU 读取缺少同步。**[推测]** 在 GPU 积压时，同一帧可能采样到补丁更新前后的混合内容，产生状态文字或录音条闪烁、撕裂。现有 shader 测试逐次 `waitUntilCompleted()`，不能覆盖此时序。
- 建议修复：沿用字形图集的做法，生成独立 staging buffer，在同一 Metal command queue 中将补丁 blit 编码到采样之前；或换用新纹理并保留旧纹理至在途读取结束。
- 置信度：高（同步缺口）；中（具体视觉表现）。

### [P2] 媒体服务重置后，旧声音初始化任务仍可覆盖新结果

- 位置：`ios/iMic/SoundDesign.swift:37`、`ios/iMic/SoundDesign.swift:49`、`ios/iMic/SoundDesign.swift:55`。
- 证据：媒体服务重置将状态设为 `.cold` 并启动新一轮 `warmUp()`，但此前运行于全局队列的 `registerAll()` 没有取消或代际标识；其主线程完成回调无条件覆盖 `ids` 和 `state`。
- 触发条件：声音注册 A 尚未完成时发生媒体服务重置，注册 B 随后启动；B 完成后，A 才回写结果。
- 后果：A 中重置前取得的失效 `SystemSoundID` 可以覆盖 B 的有效结果，并将状态设为 `.ready`。后续播放只检查 `.ready` 和字典是否有 ID，不会因此重新注册，相关提示音可能持续失效至下一次重置或重启。
- 建议修复：增加注册代际，重置时推进代际，每次初始化捕获代际并在回写前核对；过期结果应丢弃，并清理仍有效的多余声音资源。
- 置信度：高。

## 已检查且未发现问题的方面

- **录音生命周期串行化**：启动、停止、路由恢复共用生命周期队列；请求代际和控制器 epoch 拦截旧回调。析构前检查队列标识，避免同步派发到自身队列。
- **Speech 分段隔离**：识别状态集中在主 Actor；音频入口计数受锁保护，取消和新录音推进 generation，旧分段回调不能继续修改新会话。
- **Mac UI 回调线程**：生产 ASR、润色和设置验证的网络完成回调均切回主队列，未发现这些路径直接在后台修改 AppKit 控件。
- **BLE 状态队列**：两端 CoreBluetooth delegate 与传输缓冲使用各自串行队列；连接身份检查及 generation 拦截迟到回调。
- **扫光异步隔离**：后台任务使用目标快照和带锁取消令牌，主线程回写核对代际；屏幕几何通过带锁快照提供给后台任务。
- **显示时钟与定时器**：`CADisplayLink` 使用弱代理并在析构时失效；已检查的心跳、上传及结果定时器具备取消或会话过滤。未发现可达的同步派发自锁路径。
- 文档已明确说明的键盘兼容模式风险、AX 调用等待及无线环境限制，未重复列为缺陷。