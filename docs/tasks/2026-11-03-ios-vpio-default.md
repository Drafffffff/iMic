# 任务书：iPhone 录音默认使用苹果语音处理（VPIO）

日期：2026-11-03
执行者：Codex（接续麦克风修复 #23 / #27 的会话）
审核：Claude
动手前请阅读本文件、`AGENTS.md`、`ios/iMic/AudioCapture.swift`、`ios/iMic/AudioCaptureController.swift`、`ios/iMic/MicrophoneTestView.swift`、`ios/iMic/SessionModel.swift`（录音生命周期部分），以及留档分支 `claude/mic-quick-test`（提交 `6ae69b0`）中的现场诊断代码。

---

## 0. 交付方式

1. 从 `codex/ui-phosphor-wireframe` 最新提交新建分支 `codex/ios-vpio-default`，专用 worktree。
2. 提交说明用简体中文。推送后用 `gh pr create` 向 `codex/ui-phosphor-wireframe` 提 PR，附第 6 节内容。不要自行合并。
3. 不改协议、Mac 端、版本号；不构建或安装到真机（Claude 会用 `.dev` Bundle ID 装到用户手机验证）；只用自己创建的专用模拟器，用完删除。
4. `claude/mic-quick-test` 只作参考，**不要合并它**；需要的功能在本分支按本文要求重新实现。
5. 在 `docs/releases/NEXT.md` 记录。

## 1. 背景：真机排查结论（2026-11-03）

用户 iPhone 16 Pro，iOS 27.0.1：

- 语音备忘录、相机、钉钉会议、Chrome 麦克风测试网站正常；Siri、微信语音消息、iMic 录不到声音。
- iMic 在 `measurement`、`default`、`voiceChat` 三种模式下，底部、前置、后置三个内置麦克风，输入电平都只有 RMS ≈ 0.0002、峰值 ≈ 0.0008（约 −74 dBFS，接近底噪），路由有效、不是全零。
- 在 `AVAudioEngine` 的输入节点上 `setVoiceProcessingEnabled(true)`（VPIO）后电平恢复、可以正常识别；关掉 VPIO 立即又变成几乎无声。不是「踢醒」系统，而是 VPIO 这条通路能绕过故障。
- 结论：该系统版本上不带处理的原始输入通路异常，苹果语音处理通路正常。对语音输入类应用，默认使用 VPIO 也是更常见、更稳妥的选择（回声消除、降噪、自动增益）。

## 2. 目标

1. **默认打开 VPIO**：正式录音与 MIC TEST 默认都走苹果语音处理。
2. **可以关闭**：设置中提供开关，关闭后回到现在的原始通路（`measurement` 模式）。
3. **自动兜底**：用户关闭 VPIO 时，如果检测到原始通路「几乎无声」，自动用 VPIO 重试一次，并提示用户。
4. **诊断可见**：MIC TEST 显示当前是否使用 VPIO，并保留 #23 / #27 的全部诊断。

## 3. 实现要求

### 3.1 音频会话与引擎

- VPIO 打开时：`setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])`（蓝牙选项按现有路由策略判断是否需要，若会改变现有行为就不加，并在 PR 中说明），在读取 `inputNode.outputFormat` **之前** 调用 `inputNode.setVoiceProcessingEnabled(true)`；为满足 VPIO 要求，必要时访问 `engine.mainMixerNode` / 连接输出节点，但不得播放任何声音。
- 启用后重新读取实际格式（VPIO 可能改变采样率与声道），沿用现有转换器转为 16 kHz 单声道 PCM16。
- **其他音频的闪避降到最小**：iOS 17+ 使用 `inputNode.voiceProcessingOtherAudioDuckingConfiguration`（`enableAdvancedDucking = false`、`duckingLevel = .min`），减少录音时对其他 App 音量的影响。
- **自动增益保持开启**（`isVoiceProcessingAGCEnabled = true`，默认值）。不要绕过 VPIO 的回声消除。
- VPIO 关闭时：完全保持现有的 `measurement` 路径不变。
- 每次开始录音记录日志：`vpio=on/off`、`mode`、实际格式、闪避配置是否生效。
- 中断、路由变化、媒体服务重置、静音检测与单次恢复（#23 / #27）在 VPIO 打开时同样生效；重建引擎时按当前 VPIO 设置重新启用。

### 3.2 音效与回声

- 确认 `SoundDesign` 的播放方式在 VPIO 打开时仍然正常发声，且不会被录进识别结果（回声消除应当处理）；如果音效播放被 VPIO 影响（音量变小、被压掉、延迟），在 PR 中说明并给出处理。
- 录音期间触感反馈保持不变（`setAllowHapticsAndSystemSoundsDuringRecording(true)`）。

### 3.3 设置项

- 设置页增加开关「语音处理（推荐）」/「Voice processing (recommended)」，默认开启。说明文字一行：「降噪、回声消除与自动增益。部分系统版本上关闭后可能录不到声音。」/英文对应。
- 设置值保存在 `UserDefaults`。迁移：新安装和已安装用户都默认开启；如果开发版里存在旧键 `micDebug.voiceProcessing`，忽略它（它只存在于诊断版）。
- 遵守 `AGENTS.md` 界面规范：技术标签英文像素字（可用 `VPIO`），说明中英文。

### 3.4 自动兜底（用户关闭 VPIO 时）

- 在 #23 / #27 已有的静音检测上，增加「几乎无声」判定：**按住录音期间**，连续约 1.5 秒 RMS < 0.001 且峰值 < 0.003，视为几乎无声（与全零同等处理）。只在按住期间、整段都低于阈值时触发，避免误伤正常停顿。
- VPIO 关闭且触发几乎无声：本次按住内自动改用 VPIO 重建一次（与现有单次恢复共享预算，不能循环）；成功后提示一次「已自动开启语音处理以恢复录音」，并询问是否保持开启（或直接把设置改为开启并说明，二选一，在 PR 中说明选择理由）。
- VPIO 打开时仍几乎无声：按现有逻辑提示「没有收到声音」，并给出打开 MIC TEST 的入口。
- `recoveryResult` 区分 `signalDetected`（电平正常）与 `lowLevel`（有信号但几乎无声）。#27 现在会把几乎无声误判为 `signalDetected`，必须修正。

### 3.5 MIC TEST

- 显示「VPIO：开/关」与当前 `mode`。
- 提供临时切换 VPIO 开/关的按钮，用于对照测试；**测试中的临时切换不改变设置项**，离开 MIC TEST 后恢复为设置值。
- 电平状态标注：正常 / 几乎无声 / 全零（按 3.4 阈值）。
- 复制诊断信息包含 VPIO 状态、mode、实际格式、闪避配置、判定结果。
- 内置麦克风数据源切换与模式切换（诊断版中的 MODE / MIC 行）**不进入正式版**；如认为有保留价值，可放在 DEBUG 构建中。

## 4. 不要做的事

- 不保存、不发送任何音频；MIC TEST 不启动识别。
- 不在正式版保留 `claude/mic-quick-test` 中的临时诊断 UI。
- 不改协议、Mac 端、版本号；不构建到真机。

## 5. 测试

- 注入式单元测试：VPIO 开/关时的会话配置与启用顺序；重建时保持 VPIO 设置；几乎无声判定的阈值、持续时间与停顿不误判；VPIO 关闭时几乎无声 → 自动改用 VPIO 一次，并与现有恢复共享预算；`recoveryResult` 区分 `lowLevel`；设置默认值与迁移；MIC TEST 临时切换不改设置。
- 运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/test-ios-audio.sh
./scripts/build-ios.sh
./scripts/test-ios-standby.sh
./scripts/test-polish-link.sh
python3 tools/check-l10n.py
```

## 6. PR 中必须附上

1. 实现说明：会话配置、VPIO 启用顺序、格式变化处理、闪避配置、音效与回声的核对结果。
2. 测试报告（第 5 节全部命令与新增测试结果）。
3. 设置页与 MIC TEST 截图（中英文，模拟器）。
4. 给用户的真机验证清单：
   - 默认（VPIO 开）：正常按住说话三次，识别正常；MIC TEST 显示 VPIO 开、电平正常。
   - 录音时播放音乐：音乐音量被压低的程度可以接受；识别结果中没有音乐或音效。
   - 关闭 VPIO：在故障手机上应自动改用 VPIO 并提示；在正常手机上应正常录音。
   - 嘈杂环境与轻声说话对比 VPIO 开/关的识别效果。
