# iMic

把 iPhone 变成 Mac 的语音输入键。按住底部横条说话，松开后文字直接落进 Mac 当前应用。

- **iPhone 端**：SwiftUI，黑色 + 橙色像素界面，按住说话、上滑取消、触感反馈。
- **Mac 端**：菜单栏应用。保留 Brick Mic 的百炼 ASR、辅助功能输入与权限处理，传输层改为 Apple 原生 Bonjour + Network.framework。
- **链路**：优先局域网 Bonjour + TCP；复杂网络下可启用蓝牙 GATT 字节隧道。Curve25519 交换临时密钥，六位配对码建立信任，之后用设备令牌派生 AES-256-GCM 会话密钥。语音不经过 iMic 服务器，只在你自己的 Mac、阿里云百炼和 DeepSeek 之间传输。
- **中心弦**：44 个圆环由频段峰谷主导形状，低频居中、向两侧对称展开，避免人声能量长期偏在左侧。声音通过连续速度的惯性包络起落，不靠整体缩放或降低采集频率制造缓动。两端固定；下拉时弦身光滑弯曲，圆环随切线倾斜、轻微拉伸，上下轨道一起弯曲而非整块平移。松手后，弦首次向上穿过中线时才发送回车，并同步播放短弓弦释放声；重新抓住可取消待发动作。上拨删除、保持上拉加速连删、左右滑动移动光标。
- **实时文字与波形**：iPhone 用 Apple Speech 提供本机实时文字；新增字形从录音横条分散融入真实圆环，在实际落点亮起短促暖白高光，约 160ms 内衰减，留下有上限的局部光能，随弦一起下拉蓄力。首次向上过中线成功投递回车后，已融合文字继承弦速，以高初速度整批飞出屏幕顶部；波形留在原位回弹，RX01 只作静态标记。Metal 字形图集与批量实例绘制复用弦的显示时钟，不为每个字创建视图；到达中的文字归下一轮，旧正文不重放。减少动态效果时保留静态亮度反馈，不显示落点闪光。视效不修改识别正文；Mac 的实时输入开关仅控制是否投递临时文字，不关闭本机识别。
- **DeepSeek 润色**：可选使用 DeepSeek 官方 `deepseek-flash`，提供轻度 / 中度 / 重度和通用 / 日常聊天 / 工作邮件 / 会议笔记 / Agent 指令场景；失败自动回退原始结果，不代答、不执行口述请求。

## 下载与安装

从 [GitHub Releases](https://github.com/Drafffffff/iMic/releases/latest) 下载：

- `iMic-1.1.0-macOS-universal.dmg`：macOS 13+，同时支持 Apple Silicon 与 Intel。打开镜像，把 `iMic.app` 拖入「Applications」，再从应用程序中启动。
- `iMic-1.1.0-iOS-unsigned.ipa`：iOS 17+ 的 iPhone 真机包，**未签名，不能直接点击安装**。需通过 AltStore、SideStore、Sideloadly 等工具，用自己的 Apple ID/开发团队重新签名；也可以按下方步骤从源码安装。个人团队通常需要每 7 天续签。
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

Mac 窗口显示六位配对码。iPhone 点击顶部电脑名称进入「连接电脑」二级页面，查看当前目标、附近电脑与已记住的 Mac；首次选择后输入六位码。右上角天线图标仍打开配对与波形复看。各台令牌分别保存在 iPhone 钥匙串与 Mac 的 `~/Library/Application Support/iMic/paired.json`；切换不会删除旧配对，且只重连明确选定的电脑。录音或识别中切换须先确认取消，旧会话不会交给新 Mac，已识别文字仍可复制。

### 4. 使用

在 Mac 上点进任意输入框，按住 iPhone 底部橙色横条说话：

- 松开：结束录音并识别，文字自动填入录音开始时 Mac 的前台应用。
- 上滑后松开：取消本次输入。
- 少于 0.5 秒的误触会被忽略。
- 单次最长 10 分钟，到达上限会提示并自动提交；音频补发日志与队列跟随同一上限，波形复看仍只保留每次前 60 秒。
- 中心弦：下拉松手只启动回弹，首次向上穿过中线时才发送回车并播放发射声；上拨超过阈值后松手删除一字，保持上拉约 0.4 秒开始连删，之后约 2.2 秒内从每字 180ms 加速至 60ms；松手、明显下移或回到阈值以内停止。左右滑动移动光标。
- Mac 设置页可以开关蓝牙兜底、三个弦手势、实时预览和 DeepSeek 润色，并可保存 DeepSeek Key。

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
tests/           协议单元测试
scripts/         构建、安装、联调脚本
docs/            协议与架构说明
```

## 开发验证

```bash
# 协议单元测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Mac 端无界面 + 真实 ASR 的端到端测试（使用 Mac 默认音频）
./scripts/test-link.sh

# App 界面预览
open build/mac/iMic.app --args --ui-preview=ready
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
- iPhone 在 TCP 约 3 秒内不可用时自动扫描已选择 Mac 的蓝牙身份特征；不连接任意扫描结果。Mac 和 iPhone 需同时更新；首次先在同一 Wi-Fi 选择目标并配对。
- 2026-10-25 的 iPhone 16 Pro → Mac 纯 BLE 实测：ATT 上限 512 字节，有效上行约 18–22 KB/s，低于实时所需速率；5 秒、250 帧、80,000 样本最终完整到达并确认结束。该结果说明必须保留缓存和上传状态，不能把 BLE 当成低延迟主链路；它不是所有设备/环境的速度保证。

## 实时预览与润色

- Mac 实时输入默认关闭；本机 Apple Speech 在用户允许后独立运行，拒绝授权或不可用时不阻塞百炼最终识别。每 45 秒切换新识别分段，保留之前正文，旧分段继续排空；松手关闭音频入口并最多收尾 6 秒，不阻塞 `audio.end`。百炼完整正文就绪后先补齐输入框，再继续可选润色；迟到临时结果不覆盖完整正文。前台不匹配时不删除、不输入，结果仍可复制。
- DeepSeek 润色默认关闭。填入 DeepSeek 官方 API Key、打开开关后，最终识别结果会先经过 `deepseek-flash` 整理；失败不会阻塞输入，直接使用原始结果。
- 所有开关都在 Mac 设置页；iPhone 通过加密的 `settings` 消息同步功能位。
- 上传与最终识别分别计时；iPhone 的 `audio.end` 排空后才启动结果等待，Mac 从百炼 `finish-task` 送达后计算最终识别期限。失败或断线保留本机已识别文字，可从底部「查看结果」复制，不自动投递给新电脑。
- 润色选项直接显示为两行横排单选按钮：第一行轻度 / 中度 / 重度，第二行五种使用场景；每项都有图标和文字，选中项橙色高亮。选择后立即保存、同步说明，重新打开保持选择。轻度尽量保留原句，只修标点与同音错字；中度去口头语、重复并整理语序；重度可重组结构，但仍须保留原意、事实、问题和请求。场景只调整排版与语气，不允许新增内容或代答。

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
- BLE 日志记录 MTU、`queued`、`bytesPerSecond`，用于区分采集不足、链路积压与云端等待；不记录音频内容。
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
