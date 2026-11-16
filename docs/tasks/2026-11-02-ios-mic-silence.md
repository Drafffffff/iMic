# 任务书：排查 iPhone 显示正在录音但录不到声音

日期：2026-11-02
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件、`AGENTS.md`、`docs/design/idle-screen-power.md`（待机节能与热启动窗口）、`ios/iMic/AudioCapture.swift`、`ios/iMic/SessionModel.swift` 中与录音相关的部分、`ios/iMic/SpeechPreview.swift`、`ios/iMic/SoundDesign.swift`。

---

## 0. 交付方式

1. 从 `codex/ui-phosphor-wireframe` 最新提交新建分支 `codex/ios-mic-silence`，在专用 worktree 中工作。
2. 提交说明用简体中文。推送后用 `gh pr create` 向 `codex/ui-phosphor-wireframe` 提 PR，附第 6 节报告。不要自行合并。
3. 另一个任务 `codex/ios-onboarding-redesign`（新手引导重做）同时进行，会在 `SessionModel.swift` 中加练习模式。本任务尽量把改动集中在 `AudioCapture.swift` 和新文件中；改 `SessionModel.swift` 时只动录音生命周期相关的部分，并在 PR 中列出改动点。
4. **不要构建或安装到真机，不要使用 Personal Team 签名发布 Bundle ID**（见 `scripts/ios-bundle-id.sh`）。需要真机验证的部分，写清楚步骤，由用户执行。
5. 不改协议（`shared/iMicLink.swift`）；如确需改，按 `AGENTS.md` 同步四处并在 PR 中说明。

## 1. 现象（用户报告）

在 iPhone 上使用 iMic：

- 按住横条后，App 显示正在录音，系统的**橙色麦克风指示灯也亮着**；
- 但**实际上没有录到声音**（识别结果为空或提示没听清，波形不随声音变化）；
- 同一台手机上的**系统「语音备忘录」录音正常**，所以麦克风硬件与系统权限没有问题；
- 问题是「老是」出现，不是每次，说明和某种状态或时机有关。

## 2. 已知代码事实（Claude 已核对）

- `AudioCapture.swift`：每次开始录音新建 `AVAudioEngine`，`setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])`，偏好采样率 16 kHz、IO 缓冲 10ms，`setActive(true)`，用 `AVAudioSinkNode` 接输入节点；停止时 `setActive(false, options: .notifyOthersOnDeactivation)`。
- **没有监听** `AVAudioSession.interruptionNotification`、`AVAudioSession.routeChangeNotification`、`AVAudioSession.mediaServicesWereResetNotification`（`SoundDesign` 监听了最后一个，但只用于音效），也**没有监听** `AVAudioEngineConfigurationChange`。
- `SessionModel` 有约 5 秒的**热启动窗口**（warm lease）：松手后引擎继续运行，保留 150ms 预录，下次按住直接用；还有一个"audio check FAIL stale lease"的检查。
- `SoundDesign` 不使用 `AVAudioSession` / `AVAudioEngine`（注释说明有意避开采集链路）。
- `SpeechPreview` 复用采集到的缓冲，不单独开麦。

## 3. 主要假设（请逐一验证，不要只按假设修改）

1. **会话被中断后没有恢复**：其他 App 使用麦克风（例如其他语音输入 App、语音备忘录、通话、Siri、听写）会中断 iMic 的音频会话。iMic 的引擎状态仍是"运行中"、UI 显示正在录音、橙色指示灯可能仍亮，但输入节点只收到静音或不再回调。热启动窗口让引擎跨越这些事件存活，放大了问题。
2. **路由或配置变化后引擎失效**：接入/断开耳机、AirPods，或系统调整采样率后，`AVAudioEngine` 发出配置变化通知并停止，代码没有重建。
3. **输入采样率或格式不匹配**：偏好 16 kHz 与硬件实际速率不同，或会话激活前读取了 `inputNode.outputFormat`，导致 sink 收到的格式与预期不符（例如全零或通道数错误）。请核对激活顺序与格式读取时机。
4. **会话被提前停用**：停止时 `setActive(false)` 与下一次开始之间有竞争（`lifecycle` 队列与主线程的请求编号逻辑），可能出现新一轮录音的引擎跑在已停用的会话上。
5. **`.measurement` 模式**关闭了自动增益：会让声音偏小，但不应完全无声；请确认是否和"录不上"有关，不要轻易更换模式（会影响识别效果和回声）。

## 4. 要做的事

### 4.1 先加诊断，再改

- 在 `IMicAudioInputBridge` / `AudioCapture` 中加**输入电平诊断**：每 0.5–1 秒记录一次 RMS 与峰值（只写 `IMicLog`，不记录任何音频内容），以及当前路由（输入端口类型）、会话采样率、引擎是否在运行、回调次数。
- **静音检测**：录音期间，如果引擎显示在运行但连续约 1 秒回调为 0，或者样本全部为零（数字静音，而不是环境底噪），记录 `iphone.audio silent-capture` 事件。
- 在 App 的「设置」中加一个**麦克风自检**入口（技术标签 `MIC TEST`，说明用中英文）：显示实时电平条、输入设备名称、采样率、引擎状态；用户可以在出问题时打开，看是否有电平，并能一键复制诊断信息。不保存录音。

### 4.2 修复

- 监听 `interruptionNotification`：中断开始时，结束当前录音（按取消处理，保留已识别文字的现有逻辑），释放热启动窗口；中断结束后**不自动恢复录音**，下一次按住时重新建立引擎和会话。
- 监听 `routeChangeNotification` 与 `AVAudioEngineConfigurationChange`：引擎被系统停止或输入路由变化时，丢弃当前引擎；正在录音则安全结束本轮，下次按住重建。
- 监听 `mediaServicesWereResetNotification`：完整重建。
- 静音检测触发时：自动用新引擎和重新激活的会话重试一次（只重试一次，记录日志）；仍然静音则提示用户「没有收到声音」，并给出「打开麦克风自检」的入口。
- 回到前台（`didBecomeActive`）时，如果热启动窗口中的引擎可能已失效（例如期间发生过中断或路由变化），丢弃它。
- 核对 `start`/`stop` 的竞争：保证每一轮录音的会话激活与引擎启动属于同一代请求，旧一代的 `setActive(false)` 不会停用新一代的会话。
- 中断、路由变化、重试、静音提示都要写日志，方便以后排查。

### 4.3 测试

- 能在模拟器或单元测试中覆盖的：用可注入的通知中心和假的引擎/会话包装，测试中断、路由变化、配置变化、媒体服务重置、静音检测与单次重试、热启动窗口在这些事件后被释放、旧一代停用不影响新一代。
- 模拟器的音频输入不可靠，不要把模拟器的静音当作真机结论。

## 5. 需要用户在真机上验证的步骤（写进 PR，由用户执行）

请写一份简短的真机验证清单，例如：

1. 安装开发版（`./scripts/install-ios-device.sh`，会使用 `art.malette.imic.dev`）。
2. 正常按住说话三次，确认有声音。
3. 打开语音备忘录录 3 秒，回到 iMic 立即按住说话。
4. 在热启动窗口内（松手后 5 秒内）切到别的语音输入 App 录音，再回来按住。
5. 录音过程中接入/断开 AirPods 或有线耳机。
6. 录音过程中来电（或用 FaceTime 音频模拟），挂断后再按住。
7. 每一步之后打开「麦克风自检」看电平；出问题时用 `./scripts/pull-ios-log.sh` 拉取日志。

并说明每一步修复前预期会怎样、修复后应该怎样。

## 6. PR 中必须附上

1. 根因分析：哪些假设被确认或排除、依据是什么（代码路径、Apple 文档、测试）。如果无法在没有真机的情况下确认根因，明确写出。
2. 改动说明，以及 `SessionModel.swift` 中的改动点清单。
3. 麦克风自检界面截图（中英文，模拟器即可）。
4. 测试报告：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-ios.sh
./scripts/test-ios-standby.sh
./scripts/test-ios-reconnect.sh
./scripts/test-polish-link.sh
python3 tools/check-l10n.py
```

   以及新增的单元测试结果。
5. 第 5 节的真机验证清单。
