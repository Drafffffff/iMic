# Windows 与 Android 端可行性评估

日期：2026-11-01
状态：评估结论，尚未立项。

## 结论

可以做，大部分体验能接近现在的 iPhone + Mac。iMic 由三部分组成：手机端、电脑接收端、两者之间的协议。其中协议和云端识别天然可以跨平台，需要重写的是各平台的原生部分。

建议顺序：

1. **先做 Windows 接收端（iPhone → Windows）。** 只需新写一端，手机体验不变；核心功能（打字、手势、切换应用保护）难度低，润色扫光放到第二阶段。
2. **Android 手机端放在后面。** 工作量接近重写一个 iOS 端，而且触感在不同机型上差异很大，需要先设计中低端机的降级方案。
3. **无论先做哪端，第一步都是给协议补标准测试向量**（见下文），这是多语言实现能互通的前提。

这也契合「一只手机，接管所有输入」：协议走局域网，与生态无关，一部 iPhone 可以同时连家里的 Mac 和公司的 Windows。

## 天然可移植的部分

- **协议**：设备发现用 mDNS / DNS-SD（Windows 10 以上自带，Android 有 `NsdManager`）；传输为 TCP 长度前缀帧；加密为 X25519 交换、HKDF-SHA256 派生、AES-256-GCM 逐帧随机 nonce。C#、Kotlin、Rust 都有成熟的标准实现。
- **语音识别与润色**：百炼的 WebSocket 和 HTTP 接口与平台无关，电脑端照样调用。
- **需要补的工作**：目前 `shared/iMicLink.swift` 是唯一协议来源。换语言重写前，要把一套固定的输入输出样例（密钥派生、帧编码、加密、配对码）写进 `docs/PROTOCOL.md` 和测试，保证各端逐字节一致。`AGENTS.md` 中「改协议必须同步四处」的规则届时要扩展到新端。

## Windows 接收端

| 功能 | Mac 现状 | Windows 方案 | 难度 |
|---|---|---|---|
| 向任意输入框打字 | Unicode 键盘事件 | `SendInput` + `KEYEVENTF_UNICODE`，几乎等价 | 低 |
| 权限 | 需开启辅助功能 | 不需要授权，门槛比 Mac 低 | 低 |
| 记录前台应用，切换后不输入 | 辅助功能 API | `GetForegroundWindow` + 进程信息 | 低 |
| 弦手势（回车、删字、移光标） | 键盘事件 | `SendInput` | 低 |
| 实时预览范围核验、清空 | 辅助功能读取输入框 | UI Automation（TextPattern、ValuePattern） | 中，各应用支持程度不一 |
| 润色扫光 | 辅助功能定位 + OCR + 屏幕录制兜底 | UI Automation 取文字区域 + 系统 OCR（Windows.Media.Ocr）+ 透明置顶窗口 | 高，工作量最大 |
| 蓝牙兜底 | GATT 外设 | Windows 支持 GATT 服务端，依赖网卡和驱动 | 中 |
| 自动更新与签名 | Sparkle + Developer ID | WinSparkle 或 Velopack + 代码签名证书 | 中 |

Windows 特有的问题：

- **管理员窗口**：系统不允许普通程序向以管理员身份运行的窗口发送按键（例如管理员终端），需要检测并提示用户。
- **SmartScreen**：未签名的安装包会被拦截警告，需要代码签名证书或 Azure 托管签名服务。

技术选型建议：C#/.NET 8 + WPF 或 WinUI 3，调用 UI Automation 与 `SendInput` 最直接、资料最多。Rust 可行，但调用 UI Automation 较麻烦。

## Android 手机端

手机端承载 iMic 的手感：弦的物理效果、44 个圆环、文字弹射、触感与 8-bit 音效。

| 体验 | iPhone 现状 | Android 方案 | 差距 |
|---|---|---|---|
| 弦与弹射动画 | Metal，显示时钟同步 | Compose Canvas + AGSL 着色器，或 OpenGL / Vulkan | 能做到，需要重写 |
| 触感 | Core Haptics，所有机型一致 | `VibrationEffect` 组合原语（Android 12 以上） | **最大差距**：旗舰机好，中低端机马达差，部分机型不支持精细振动 |
| 音效延迟 | 系统音频，延迟低 | Oboe / AAudio | 主流机型可接受 |
| 实时预览文字 | Apple 本机语音识别 | 本机识别器质量与中文支持因厂商而异，国内很多机型没有谷歌服务 | 较大 |
| 录音 | 有界队列重采样 | AudioRecord，各厂商行为有差异 | 可控 |
| 分发 | TestFlight / App Store | Google Play + 国内各应用商店，或直接提供 APK | 渠道多 |

技术选型建议：Kotlin 原生 + 自定义渲染。Flutter、React Native 等跨平台框架难以达到现在的手势与动画水准。弦的物理逻辑可从 Swift 移植。

### 实时预览改由电脑端提供（候选方向）

不依赖手机本机识别，改用电脑端百炼返回的中间结果回传手机显示：

- 好处：各平台效果一致；解决国内安卓机没有谷歌服务的问题；iPhone 端也能统一识别效果。
- 代价：多一点延迟；需要改协议，让电脑把中间文字传回手机（按 `AGENTS.md` 同步协议四处）。

## 四种组合

| 组合 | 需要新做 | 体验能否接近现在 |
|---|---|---|
| iPhone → Mac | 现状 | — |
| iPhone → Windows | Windows 接收端 | 基本一致；扫光与实时预览核验在部分应用里较弱 |
| Android → Mac | Android 手机端 | 大体一致，触感取决于机型 |
| Android → Windows | 两端都要做 | 以上两条叠加 |

## 待决定的问题

1. 目标用户（使用 Agent 的开发者）中 Windows 用户占比多少？如果仍以 Mac 为主，Android 手机端可能更有价值。
2. 实时预览是否改为由电脑端回传中间结果？
3. Android 中低端机触感不足时的降级方案（只保留音效、简化振动，还是提示用户）。
