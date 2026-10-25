# iMic

把 iPhone 变成 Mac 的语音输入键。按住底部横条说话，松开后文字直接落进 Mac 当前应用。

- **iPhone 端**：SwiftUI，黑色 + 橙色像素界面，按住说话、上滑取消、触感反馈。
- **Mac 端**：菜单栏应用。保留 Brick Mic 的百炼 ASR、辅助功能输入与权限处理，传输层改为 Apple 原生 Bonjour + Network.framework。
- **链路**：优先局域网 Bonjour + TCP；复杂网络下可启用蓝牙 GATT 字节隧道。Curve25519 交换临时密钥，六位配对码建立信任，之后用设备令牌派生 AES-256-GCM 会话密钥。音频由自己的 Mac 发送至百炼识别；仅在开启润色时，完整文字才发送至选定服务，不经过 iMic 服务器。
- **中心弦**：44 个圆环由频段峰谷主导形状，低频居中、向两侧对称展开，避免人声能量长期偏在左侧。声音通过连续速度的惯性包络起落，不靠整体缩放或降低采集频率制造缓动。两端固定；下拉时弦身光滑弯曲，圆环随切线倾斜、轻微拉伸，上下轨道一起弯曲而非整块平移。松手后，弦首次向上穿过中线时才发送回车，并同步播放短弓弦释放声；重新抓住可取消待发动作。上拨删除、保持上拉加速连删、左右滑动移动光标。
- **实时文字与波形**：iPhone 用 Apple Speech 提供本机实时文字；大字从横条上方出现，沿飞行过程缩小，到波形时为整个生命周期的最小尺寸。落点有约 160ms 的暖白短弧与短促火花；下拉时，所有附着文字和接触位置随张力一起提亮、呼吸。首次向上过中线排队发送回车后，文字整批加速弹射，沿上升距离持续放大并从屏幕顶部离开；波形原位回弹，RX01 保持静态。字形在后台串行生成，使用单通道 Metal 图集和按页批量绘制，复用弦的显示时钟，不逐字创建视图。减少动态效果时保留静态文字和拉力亮度，不飞入、不旋转、不循环闪烁。视效不改识别正文，也不依赖 Mac 是否显示实时预览。
- **文字润色**：可选 DeepSeek 官方、百炼 DeepSeek 或自定义 OpenAI-compatible 服务，来源默认 DeepSeek 官方；提供三级强度与五种场景。iPhone 可修改当前 Mac 的润色开关、强度和场景，收到 Mac 明确确认才表示保存。来源、API Key、模型和地址仍在 Mac 配置；配置无效、超时或服务失败时保留完整原文，不代答、不执行口述请求。

## 下载与安装

从 [GitHub Releases](https://github.com/Drafffffff/iMic/releases/latest) 下载：

- `iMic-1.2.0-macOS-universal.dmg`：macOS 13+，同时支持 Apple Silicon 与 Intel。打开镜像，把 `iMic.app` 拖入「Applications」，再从应用程序中启动。
- `iMic-1.2.0-iOS-unsigned.ipa`：iOS 17+ 的 iPhone 真机包，**未签名，不能直接点击安装**。需通过 AltStore、SideStore、Sideloadly 等工具，用自己的 Apple ID/开发团队重新签名；也可以按下方步骤从源码安装。个人团队通常需要每 7 天续签。
- `SHA256SUMS.txt`：下载两个安装包和此文件到同一目录后，运行 `shasum -a 256 -c SHA256SUMS.txt` 校验完整性。

Mac 公开包使用 ad-hoc 签名，尚未做 Apple 公证。首次打开若被 Gatekeeper 阻止，请确认下载来源与校验和，再到「系统设置 → 隐私与安全性」中允许这一次打开；不需要关闭系统安全保护。辅助功能、本地网络与蓝牙权限仍需自行授权。

iOS Release 不是免签包，也不是 TestFlight/App Store 分发；不包含发布者的个人描述文件、设备清单或签名私钥。百炼和可选 DeepSeek Key 均由使用者自行配置。

## 源码构建环境

- Mac：macOS 13+，Xcode 27（含 iOS 17+ SDK），百炼 API Key。
- iPhone：iOS 17+，与 Mac 在同一 Wi-Fi。
- 无需路由器端口映射；Bonjour 在同一局域网内发现设备。
- 安装 Xcode 命令行工具及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)；使用 Homebrew 时可运行 `brew install xcodegen`。

## 快速开始

### 1. 构建并安装 Mac 端

```bash
./scripts/build-mac.sh
./scripts/install-mac.sh
```

开发产物默认位于 `build/mac.noindex/`，模拟器与真机派生目录分别为 `build/ios.noindex/`、`build/ios-device.noindex/`，避免被 Spotlight 当作额外应用收录。正式入口只使用 `/Applications/iMic.app`；安装脚本把旧版本备份为 `~/Library/Application Support/iMic/backups/时间戳/iMic.app.zip`，不再留下可启动的备份副本。

首次启动后：

1. 打开 iMic 主窗口，填入百炼 API Key 并保存。
2. 在「系统设置 → 隐私与安全性 → 辅助功能」中允许 iMic，才能把文字填入其他应用。
3. 允许 iMic 使用本地网络（macOS 可能弹出提示）。

### 2. 构建 iPhone 端

文字着色器在构建期编译。若 Xcode 提示缺少 Metal Toolchain，先执行一次：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain`。

```bash
./scripts/build-ios.sh --run
```

会生成 `ios/iMic.xcodeproj`、应用图标，并在第一个可用的 iPhone 模拟器上安装启动。

真机安装：

```bash
./scripts/install-ios-device.sh
```

脚本会自动识别已连接的 iPhone、用当前 Xcode 登录的 Personal Team 构建并安装。首次安装后需要在 iPhone 上信任开发证书：

**设置 → 通用 → VPN 与设备管理 → 开发者 App → Apple Development: … → 信任**

个人团队签名 7 天后过期，到期重新运行脚本即可；登录付费开发者账号后可改为一年期。

若无法自动发现开发团队，可从 Xcode 的「Signing & Capabilities」确认 Team，并显式指定：`IMIC_DEV_TEAM=你的团队ID ./scripts/install-ios-device.sh`。仓库不绑定发布者的个人团队。

### 3. 配对

Mac 窗口显示六位配对码。iPhone 点击顶部电脑名称进入「连接电脑」二级页面，查看当前目标、附近电脑与已记住的 Mac；首次选择后输入六位码。右上角天线图标打开配对、AI 润色偏好与波形复看。各台令牌分别保存在 iPhone 钥匙串与 Mac 的 `~/Library/Application Support/iMic/paired.json`；切换不会删除旧配对，且只重连明确选定的电脑。录音或识别中切换须先确认取消，旧会话不会交给新 Mac，已识别文字仍可复制。

### 4. 使用

在 Mac 上点进任意输入框，按住 iPhone 底部橙色横条说话：

- 松开：结束录音并完成识别；开启实时预览后，支持范围核验或键盘兼容模式的目标可在录音期间逐字输入，完整识别和润色再差量更新本轮内容。
- 上滑后松开：取消本次输入。
- 少于 0.5 秒的误触会被忽略。
- 单次最长 10 分钟，到达上限会提示并自动提交；音频补发日志与队列跟随同一上限，波形复看仍只保留每次前 60 秒。
- 中心弦：下拉松手只启动回弹，首次向上穿过中线时才发送回车并播放发射声；上拨超过阈值后松手删除一字，保持上拉约 0.4 秒开始连删，之后约 2.2 秒内从每字 180ms 加速至 60ms；松手、明显下移或回到阈值以内停止。左右滑动移动光标。
- Mac 设置页可开关蓝牙兜底、三个弦手势、实时预览与文字润色，并配置润色来源、Key、模型与完整地址。iPhone 的「右上角天线 → AI 润色偏好」可设置润色开关、强度、场景。开启实时预览后，支持范围验证的目标应用可边说边输入临时文字，最终识别和润色只修订本轮内容。

## 设计

- **背景**：保留极淡网格与中轴，不绘制屏幕边缘角标，避免与 iPhone 圆角冲突。
- **协议**：Bonjour 服务 `_imic._tcp`，TCP 长度前缀帧。控制消息与 20ms PCM 音频共用一条连接，天然有序。
- **加密**：ECDH（Curve25519）+ HKDF-SHA256，首次配对用六位码加盐，之后用 32 字节设备令牌；每帧 AES-256-GCM 独立随机 nonce，篡改即断链。
- **音频**：原生 `AVAudioSinkNode` 输入经有界队列、串行重采样转为 16 kHz 单声道 PCM16；频谱使用 32ms 重叠窗，随新 PCM 更新，不再等待 tap 约 100ms 的批次。传输仍为每帧 320 采样 / 20ms。Mac 端缓冲 0.5 秒后开始流式上传百炼，松开即提交。
- **输入**：Mac 记住录音开始时的前台应用，只在识别完成且前台未变化时用 Unicode 键盘事件输入，不覆盖剪贴板。
- **隐私**：不保存录音或识别正文；本地只缓存最近 3 次频谱可视化用于复看，超过 24 小时的缓存会在读取或保存时清理，可随时清除。配对令牌仅存本机。

## 目录

```
shared/          iMic Link 协议（分帧、消息、ECDH、AES-GCM、配对码）
mac/             AppKit 菜单栏应用、Bonjour 服务、ASR、权限、文字输入
ios/             SwiftUI iPhone 应用、XcodeGen 工程配置
tools/           图标生成、端到端联调客户端
tests/           协议、ASR 流式边界与润色来源行为测试
scripts/         构建、安装、联调脚本
docs/            协议与架构说明
```

## 开发验证

```bash
# 协议单元测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# ASR 临时/确认句子、乱序补齐、修订、取消与会话隔离（不联网）
./scripts/test-asr.sh

# 目标输入范围、终端换行、Unicode 坐标与原稿保护（不发送按键）
./scripts/test-input.sh

# 润色来源、凭据隔离、地址安全和错误回退
./scripts/test-polish.sh

# Mac 端无界面 + 真实 ASR 的端到端测试（使用 Mac 默认音频）
./scripts/test-link.sh

# App 界面预览
open build/mac.noindex/iMic.app --args --ui-preview=ready
xcrun simctl launch booted com.drafffffff.imic --ui-preview=result
```

## 重新打包发布文件

```bash
./scripts/package-release.sh
# 可选：指定输出目录
./scripts/package-release.sh /绝对路径/输出目录
```

默认输出到 `build/release/`：Mac 通用版 DMG、未签名 iOS IPA 与 SHA-256 清单。脚本从 `VERSION` 读取版本，在隔离目录构建，不替换本机已安装的应用，不使用个人设备签名产物。两端源码版本号须与 `VERSION` 保持一致。

仅打包 iOS：`./scripts/package-ios.sh`。仅构建通用 Mac：`IMIC_ARCH=universal ./scripts/build-mac.sh`；开发用默认构建仍保留本机架构与本地签名行为。

## 蓝牙兜底

当公司网络或访客网络阻断 Bonjour / 同网段 TCP 时，可在 Mac 设置 →「BLUETOOTH FALLBACK」启用蓝牙 GATT 兜底：

- Mac 作为 BLE 外设，iPhone 作为 BLE 中心；音频与握手字节通过 GATT 隧道转发到 Mac 的 LinkServer，协议与加密不变。
- 首次使用需要允许 Mac 和 iPhone 使用蓝牙；macOS 若没有弹出授权，请在「系统设置 → 隐私与安全性 → 蓝牙」中允许 iMic。
- PCM16 加帧头与 AES-GCM 至少约需 34,050 字节/秒持续上行（不含 ATT 开销）；蓝牙性能受环境影响，不保证总能实时。发送按动态 MTU 持续排空，遇系统背压等待 ready，控制帧等待最后 ATT 确认；两端都有 64 MiB 队列上限，超限明确失败，不丢掉开头继续识别尾段。
- iPhone 在 TCP 约 3 秒内仍未建立时扫描已选择 Mac 的蓝牙身份特征；TCP 一旦建立立即取消该兜底定时器，等待用户输入配对码不再触发误降级。不会连接任意扫描结果。Mac 和 iPhone 需同时更新；首次先在同一 Wi-Fi 选择目标并配对。
- 2026-10-25 的 iPhone 16 Pro → Mac 纯 BLE 实测：ATT 上限 512 字节，有效上行约 18–22 KB/s，低于实时所需速率；5 秒、250 帧、80,000 样本最终完整到达并确认结束。该结果说明必须保留缓存和上传状态，不能把 BLE 当成低延迟主链路；它不是所有设备/环境的速度保证。
- 蓝牙队列只合并尚未开始发送的旧 `preview`，不替换已分片发送的加密帧，不跨越开始、结束或取消等控制屏障；音频逐帧保留，不通过丢帧缩短等待。
- 「连接电脑」页面明确显示当前是局域网还是蓝牙。蓝牙下长录音可能在松手后继续补传；空闲时可点「改用局域网」，只重连当前选定的 Mac，不在录音或上传期间换链路。手机区分蓝牙补传与局域网剩余音频，真实排空 `audio.end` 后才进入识别等待。

## 实时预览与润色

- 实时预览在新安装中默认开启，已有开关选择保留。一旦收到 iPhone 的 Apple Speech 增量预览，本次录音持续使用手机预览；停顿产生的百炼确认句不抢占手机来源，没有手机预览时才使用百炼流式结果。完整百炼正文在录音结束后统一校正，再可选润色。
- **范围校验模式**：保留 Chrome、苹果终端等范围接口可靠目标的原有路径；核对前台应用、输入框、光标和本轮文字后，只修订变化尾部，不全选、不设置整框 `AXValue`。键盘投递后异步确认，等待期间合并最新预览。最终结果有独立的确认时间，不继承润色前的旧期限。
- **键盘兼容模式**：用户已授权用于 Otty、缺少范围接口的自定义编辑器，以及范围持续 1.5 秒无法同步的目标。Otty 的画面范围不代表 TUI 编辑光标，直接选择兼容模式；ChatGPT、Zed/VS Code 等缺少所需接口时自动选择。按本轮已投递文字计算退格与追加，不等待 AX 光标；界面显示「已投递」，日志记录 `mode=keyboard_compatibility`，不冒充已核验目标正文。
- 两种模式都监视手动按键、点击及应用切换；用户接管后冻结本轮，最终回写也不能绕过。iMic 自己的按键带独立来源标记，不读取或记录按键正文。兼容模式不能独立核验目标程序自行改稿或丢弃按键，仍有重复文字或误删原稿的风险；录音期间避免在目标编辑器中混合编辑。取消、失败与新会话取消旧任务，撤回本轮未确认尾部；兼容模式依据投递记录而非 AX 内容执行。
- 没有可用接管监视且范围不可核验时，只在结束后通过 Unicode 键盘事件投递最终结果。初次输入收起已知选区；选区不可读时使用无修饰右方向键，避免直接替换选中原稿，但光标原本位于正文中间时可能向右移动一字符。
- iPhone 的 Apple Speech 在用户允许后独立运行；拒绝授权或不可用不阻塞百炼。每 45 秒滚动分段，保留之前正文；松手最多收尾 6 秒，但不阻塞 `audio.end`。Mac 收到完整百炼正文后忽略迟到临时预览。
- 润色默认关闭，来源默认「DeepSeek 官方」。在设置的 `TEXT POLISH` 中选择来源并保存；切换来源只修改草稿，保存后才生效，每个来源分别记住模型与地址。
  - **DeepSeek 官方**：独立的 `DEEPSEEK_API_KEY`，默认 `deepseek-flash`，请求使用 `thinking.type=disabled`，参见[官方 Chat Completions 文档](https://api-docs.deepseek.com/api/create-chat-completion/)。
  - **百炼 DeepSeek**：复用顶部识别所用的百炼 Key（`DASHSCOPE_API_KEY` / `BAILIAN_API_KEY`），默认 `deepseek-v4.1-flash`，请求使用顶层 `enable_thinking=false`。默认地址为北京 DashScope 兼容端点；其他地域或工作空间需在「模型与地址」填入对应的完整 Chat Completions URL，Key 与地域须匹配，参见[百炼 DeepSeek 文档](https://help.aliyun.com/zh/model-studio/deepseek-api)。
  - **自定义兼容服务**：独立的 `IMIC_CUSTOM_POLISH_API_KEY`，自行填写模型与以 `/chat/completions` 结尾的完整 URL。远程地址必须使用 HTTPS；只有本机 `127.0.0.1` / `[::1]` 可使用 HTTP。不跟随重定向，避免把 Key 转发到其他地址。
  - Mac 的三类 Key 保存于 `~/.zshrc`，不互相代用；不执行该文件中的命令。无效配置或请求失败回退完整识别原文，日志不记录 Key、请求地址或正文。
- iPhone 通过加密 `settings` 接收当前 Mac 的功能位与完整润色偏好；修改时发送 `polish.settings`，等待 `polish.saved` 明确确认。保存中禁用编辑，不把发送成功当成保存成功；离线或旧 Mac 不支持时不能修改。切换 Mac 或重连后重新读取权威状态，不自动重发旧目标的修改；手机不持久化第二套偏好，Mac 本地修改也会同步回显。Key 与服务地址不进入这些消息。
- 上传与最终识别分别计时；iPhone 的 `audio.end` 排空后才启动结果等待，Mac 从百炼 `finish-task` 送达后计算最终识别期限。失败或断线保留本机已识别文字，可从底部「查看结果」复制，不自动投递给新电脑。
- Mac 的润色选项为两行单选按钮：轻度 / 中度 / 重度及五种场景；手机使用对应选择项，等待 Mac 确认后更新选中值。轻度尽量保留原句，只修标点与同音错字；中度去口头语、重复并整理语序；重度可重组结构，但仍须保留原意、事实、问题和请求。场景只调整排版与语气，不允许新增内容或代答。

## 波形复看

- iPhone 点击右上角连接图标 →「波形复看」，可播放、暂停、重播、循环、导出 JSON 或清除缓存，不改变主界面布局。
- 缓存仅含 44 个频段、可视化响度、原始 RMS dBFS 与相对时间，最多 50Hz、每次 60 秒、最近 3 次；取消的录音不入库。不会缓存闲置热麦、原始音频或识别正文。
- `MICROPHONE` 表示真实麦克风，`SYNTHETIC` 明确表示合成测试。数字静音为 `−∞ dBFS`，JSON 中编码为 `"-Infinity"`，应用会成对回解。RMS 是数字响度，不是校准声压。
- 复看使用同一 `TorusView` 与原始采样间隔，不启动麦克风、不联网、不向 Mac 输入文字。缓存位于应用容器的 `Library/Caches/iMicWaveforms/`，不备份。
- 开发构建支持 `--waveform-replay=latest`，或 `--waveform-replay=/应用容器内/导出文件.json`，可直接复看而不启动录音链路；发布构建不依赖该参数。
- DEBUG 界面预览新增 `--ui-preview=devices`，直接打开正式设备切换页面；不需要真实链路。


## 调试日志

- Mac：`~/Library/Logs/iMic/iMic.log`（超过 2 MB 自动轮换到 `iMic.1.log`）。
- iPhone：运行 `./scripts/pull-ios-log.sh`，日志会拉到 `build/logs/ios-iMic.log`。
- BLE 日志记录 MTU、`queued`、`bytesPerSecond` 与合并的预览数；TCP 日志记录建立时间、接口和配对阶段；润色日志记录来源、模型、安全的状态码与耗时，用于区分链路积压、识别和润色，不记录正文或凭据。
- 日志包含链路状态、会话号、音频序号、缺口/补发请求、ASR 阶段和字数；不记录令牌、音频内容或识别正文。

## 音频可靠性

- iPhone 在按下时立即发送 `audio.start`，Mac 立即显示「正在听」；音频仍经过 0.5 秒短按门限。
- iPhone 保留当前会话最多 600 秒的音频日志。Mac 发现首帧缺失或中间缺口时发送 `audio.need`，iPhone 从日志补发；补发完成前 Mac 不会把缺口之后的尾段先送去识别。
- Mac 不再因为一次缺口直接取消整次输入；`audio.end` 与本地帧数不一致时会先请求补发，再继续识别。
- 百炼上传队列按 600 秒录音有界保留，并区分上传排空与最终识别期限，避免固定总超时截断长句。
- 日志会记录 `preview`、`input`、`settings` 和 BLE 状态；实时预览和手势如果被设置关闭，会以 `ignored` / `off` 记录，不会误投递。

## 已知边界

- 需要 Mac 与 iPhone 在同一局域网；跨网段、AP 隔离或公司访客网络可能阻断 Bonjour。
- 识别依赖阿里云百炼 `qwen-audio-3.1-asr-flash-message`，需要网络与有效 Key。
- 自动输入需要 macOS 辅助功能权限；未授权时文字仍会保留在窗口与 iPhone 上，可复制。
- 当前一次只连接一台 iPhone；新手机会替换旧连接。
- Mac 端未做 Apple 公证，首次打开可能需要在「隐私与安全性」中手动允许。

## 许可

Mac 端复用 Brick Mic 的实现，沿用 GPL-3.0。协议与 iOS 端为本次新增代码，随项目整体以 GPL-3.0 分发。
