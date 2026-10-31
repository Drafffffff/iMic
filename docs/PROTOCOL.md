# iMic Link 1.0

iMic 的传输层只做三件事：发现、认证、按序送音频。没有云中转，没有自定义 UDP 重传，也没有把音频 base64 塞进 JSON。

## 发现

Mac 通过 Bonjour 广播：

```
service type: _imic._tcp
instance:     iMic · <Mac 名称>
TXT:          id=<Mac UUID>, v=1
```

iPhone 用带 TXT 元数据的 `NWBrowser.Descriptor.bonjourWithTXTRecord` 浏览服务，以 `id` 匹配配对令牌与明确选择的目标。没有选择时，只有一台 Mac 才自动连接；选择后只重连该 Mac，不被其他发现结果抢占。切换保留各台 Mac 的令牌，关闭旧链路并作废旧发送与回调代际。

同一 UUID 的多接口/重复服务记录合并为一项，优先保留当前连接端点；不同 UUID 即使名称相同也分别显示。缺少合法 UUID 的临时发现结果不冒充新设备。

## 传输

一条 TCP 连接（`NWParameters.tcp`，启用 peer-to-peer）。所有帧：

```
u32 length   // 大端，仅负载长度
u8  kind
   1 = 明文 JSON      （仅握手）
   2 = 加密 JSON      （AES-GCM combined）
   3 = 加密音频帧
payload[length]
```

握手完成后拒绝明文 JSON。单帧上限 128 KiB。

## 握手与密钥

1. iPhone 连接后发送明文 `hello`，携带 `device_id`、`device_name`、临时 Curve25519 公钥、`has_token`。
2. Mac 生成自己的临时密钥，回复明文 `hello`，带 `mac_id`、名称、公钥、`status`：
   - `auth`：Mac 有该设备的令牌，等 iPhone 证明身份。
   - `pair_required`：首次或令牌失效，等六位配对码。
3. **已配对**：
   - `session_key = HKDF-SHA256(ECDH(phone_priv, mac_pub), salt = token, info = "iMic-session-v1")`
   - iPhone 发送加密 `auth`；Mac 解密成功即进入 ready。
4. **首次配对**：
   - `pair_key = HKDF-SHA256(ECDH(...), salt = SHA256("iMic-pair-v1:" + code), info = "iMic-pair-v1")`
   - iPhone 用 `pair_key` 加密 `pair`，内容为设备名与一个新的 32 字节随机 `token`。
   - Mac 解密成功才保存令牌，并用 `pair_key` 回复 `paired`；随后切换为 `session_key`，发送 `ready`。
   - Mac 在收到每次 `pair` 时按**当前**配对码派生 `pair_key`；等待输入期间配对码过期或被手动更换，也能直接用新码配对。
   - 单条连接内错误配对码最多尝试 3 次，随后以 `auth` 断开。
   - 错误次数另按 Mac 全局累计，重连不会清零：累计 5 次后立即轮换配对码并进入冷却，冷却 30 秒起逐次翻倍、上限 15 分钟。冷却期间 Mac 不解密 `pair`，直接回复 `pair_locked`，也不计入错误次数。配对成功或用户在 Mac 上手动换码后复位。
   - 配对成功后配对码立即轮换。
   - iPhone 收到 `pair_code` / `pair_locked` 后丢弃已提交的码，重连时不得自动重发。

安全边界：

- ECDH 临时密钥每次连接重新生成，前向保密。
- 六位码只用于首次信任；之后的连接依赖 32 字节令牌，离线猜解不可行。
- 每帧 AES-GCM 使用独立随机 nonce，篡改的帧会解密失败并断开。
- 会话密钥每次连接重新派生，旧连接的帧在新连接上无法通过校验。但**同一连接内**的加密帧没有序号、两个方向共用同一把密钥，能截获流量的攻击者可以重放、丢弃、重排或把帧反射回发送方；音频帧靠自身 `seq` 去重，控制消息没有此保护。修复需要协议升级（帧序号 + 按方向派生密钥）。
- 配对阶段的 ECDH 本身未经认证：被动监听者无法枚举配对码，但配对时在线的主动中间人截获一帧 `pair` 后可以离线试出六位码。全局限速只限制直接在线猜码，不能防御这种攻击；彻底解决需要改用 PAKE（如 CPace / SPAKE2）。
- 新连接先完成握手；只有认证或配对成功后才替换当前 iPhone，未认证连接不能挤掉已就绪链路。同时握手的候选连接最多 4 条，超出时淘汰最早的候选。
- 令牌保存在 iPhone 钥匙串（`AfterFirstUnlockThisDeviceOnly`）与 Mac 的 0600 文件中，不进日志。

## 消息

所有字段为 snake_case。

| `t` | 方向 | 字段 | 说明 |
| --- | --- | --- | --- |
| `hello` | 双向 | `v, device_id, device_name, public_key, has_token, mac_id, name, status` | 握手 |
| `auth` | iPhone → Mac | — | 令牌认证 |
| `pair` | iPhone → Mac | `device_id, device_name, token` | 首次配对 |
| `paired` | Mac → iPhone | `mac_id, name` | 配对确认 |
| `ready` | Mac → iPhone | — | 链路可用 |
| `error` | 双向 | `code, message` | `pair_code` 可重试；`pair_locked` 表示配对冷却中，`message` 含剩余秒数，连接保持；其余通常断开 |
| `audio.start` | iPhone → Mac | `session` | 开始一段输入 |
| audio 帧 | iPhone → Mac | 二进制 | 见下 |
| `audio.end` | iPhone → Mac | `session, samples, frames` | 结束并提交识别 |
| `audio.cancel` | iPhone → Mac | `session` | 取消 |
| `audio.need` | Mac → iPhone | `session, seq` | 请求从 `seq` 开始补发本会话音频 |
| `input` | iPhone → Mac | `action` | 中心弦手势：`return` / `delete` / `left` / `right`；新端可带 `seq` 就绪代际，`clear` 必须带代际 |
| `input.state` | Mac → iPhone | `seq, status` | bit5 能力：`ready` / `busy`，权威手势就绪租约 |
| `input.result` | Mac → iPhone | `seq, action, status, message` | 清空确认：`action=clear`，`applied` / `rejected` |
| `preview` | iPhone → Mac | `text` | Apple Speech 的临时转写；Mac 实时预览开启且可用范围核验或已授权的键盘兼容模式时逐字投递目标应用，否则仅在 Mac 窗口显示。此为 Mac 本地输入策略，不改变消息字段与加密格式 |
| `settings` | Mac → iPhone | `features, polish` | 完整功能状态；bit0 预览、bit1 回车、bit2 删除、bit3 光标、bit4 润色偏好设置、bit5 手势就绪与清空、bit6 润色输出模式 |
| `polish.settings` | iPhone → Mac | `polish, features?` | 请求当前 Mac 保存完整润色偏好；仅认证完成后的加密链路可用。`features` 声明手机理解的偏好字段（bit6） |
| `polish.saved` | Mac → iPhone | `features, polish` | 本次保存请求的明确确认，携带实际保存值；不以普通状态广播代替确认 |
| `state` | Mac → iPhone | `session, phase` | `listening` / `transcribing` |
| `result` | Mac → iPhone | `session, text, latency, pasted, target` | 最终文字；`pasted` 表示所选输入通路已完成，键盘兼容模式仅确认事件投递，不表示目标正文经独立核验 |
| `failure` | Mac → iPhone | `session, code, message` | 识别失败 |
| `ping` / `pong` | 双向 | `ts` | 10 秒心跳，40 秒无数据断开 |

### 润色偏好与能力协商

协议版本仍为 `1`，不改变握手、密钥派生或帧格式。Mac 在 `ready` 后通过加密 `settings` 发送当前功能位与已保存的完整偏好。下面的 `208` 为 bit4、bit6、bit7 的并集，其他功能位按实际状态叠加：

```json
{"t":"settings","features":208,"polish":{"enabled":true,"options":{"strength":"medium","scenario":"agent","mode":"waffle","tone":"moe","output":"japanese"}}}
```

- `IMicLink.polishPreferencesFeature = 1 << 4`：支持手机设置润色偏好。声明 bit4 的 `settings` 必须携带非空、完整、合法的 `polish`。`polish.settings` / `polish.saved` 同样必须携带完整偏好，保存确认必须声明 bit4。
- `polish.enabled` 为必填布尔值；`options` 必填。旧字段 `strength`（`light` / `medium` / `heavy`）与 `scenario`（`general` / `chat` / `email` / `notes` / `agent`）保留用于旧版解码器，仍严格校验，缺失、null、类型错误或非法枚举均拒绝。这两个字段不再参与转换提示词，也不出现在新设置页。
- `IMicLink.polishModesFeature = 1 << 7`：支持新的模式、语气与输出语言。新手机要求 Mac 声明 bit4 和 bit7 才允许编辑，并在保存请求声明 bit6 与 bit7。
  - `mode`：`agent`（Agent 指令）、`terminal`（终端命令）、`classical`（文言文）、`waffle`（废话文学）、`dubbed`（翻译腔）。
  - `tone`：`normal`（正经说话）、`sarcastic`（阴阳怪气）、`moe`（萌系暴击）、`rant`（暴躁吐槽）。
  - `output`：`chinese` / `english` / `japanese` / `korean`，只表示语言，默认 `chinese`；新界面没有“保持原语言”。
  - bit7 消息必须完整提供三个新字段；缺失、null、非法枚举、类型错误全部拒绝。即使没有声明 bit7，只要出现 `mode` 或 `tone`，也必须完整提供合法的三字段组合，不能提交半份设置。
- `IMicLink.polishOutputFeature = 1 << 6` 保留为旧版输出模式能力位。没有新字段的旧偏好仍可解码：旧 `output=command` 迁移到 `mode=terminal`，旧 `original`、缺失、null 或未知字符串迁移到中文，非字符串类型仍拒绝；旧场景迁移为 Agent 指令、语气为正经说话。Mac 读取已有本地偏好使用相同迁移规则，保留有效的四种语言。
- 新 Mac 收到没有 bit7 的旧手机请求时只更新 `enabled`，保留 Mac 当前完整模式、语气和语言，回传实际保存状态，避免旧手机把新选项覆盖为默认值。新手机连接旧 Mac 时提示更新，不能提交新模式。
- `terminal` 使用独立提示词，只输出一行 zsh 命令；语气与语言选项保留但不参与命令转换。不会自动按回车执行。多行、控制字符等结果被拒绝；无法生成命令、超时或失败时输入 `# 原话` 单行注释。其他模式失败时回退完整原文，可能保留原语言。
- 普通文字均按最小改动整理，不大幅扩写或重组；模式决定局部文体，语气决定情绪与措辞，输出语言决定最终语言；问题仍为问题、请求仍为请求，不代答、不执行。文言文中文输出允许凝练压缩与古汉语疑问词，避免被普通文本的长度守门误拒绝。
- 保存中锁定交互；Mac 原子保存后回传完整 `polish.saved`，且值与请求一致，才表示成功。普通 `settings` 状态广播不能确认在途保存。断线、换机、失败不重放请求，重连后读取 Mac 权威状态。手机不持久化第二套偏好；Mac 本地修改同步广播。
- API Key、来源、模型与地址只在 Mac 配置，不进入这些消息。消息仍须经过六位码或令牌认证，使用会话密钥下的 AES-GCM combined 帧与逐帧随机 nonce；明文或未认证连接不能设置偏好。


### 手势就绪与清空（bit5）

- `IMicLink.gestureControlFeature = 1 << 5`。声明后 Mac 在连接完成、会话开始及最终结束/取消时发送加密 `input.state(seq, status)`；每次发布状态都推进 `seq`，租约仅在 `ready` 时有效。手机还要求本地不在录音/上传/识别中，才接受拉弦。旧 Mac 不声明 bit5 时手机停用弦控制并提示更新，不用计时猜测已完成。
- Mac 的 `busy` 覆盖录音、百炼、润色、OCR 定位、扫光动画、最终输入/确认以及写后释放收尾动画。只有这些处理清理完成、`result` 或 `failure` 已发送后才发布 `ready`；清空在执行期间也撤销租约。两端均拦截忙碌、旧代际及跨连接的手势；处理期间开始的触摸必须抬手后重新开始，不能等解锁后自动续拉。
- 新手机的全部 `input` 带当前 `seq`；`clear` 缺少非负 `seq` 拒绝解码。旧手机的四种单键命令仍可解码，但 Mac 忙碌时同样拒绝。`input.state` 缺少代际、代际为负或状态非法均拒绝；`input.result` 只接受 `clear`、非负 `seq` 和 `applied/rejected`。iPhone 不得伪造 Mac 的状态和确认。
- 用户上拉进入屏幕顶部清空区后，一次触摸只发送一次 `input(action=clear, seq)`。Mac 先撤销旧租约，只对当前前台、焦点未变化、内容可读且可编辑的文本控件执行整框清空。优先写空 AXValue；编辑器不支持或忽略写值时，发送全选后先核验选区从 0 开始、长度等于完整原文的 UTF-16 长度、原文仍未变化，才发送删除，并核验结果为空。这是用户明确请求的手动全框操作，与实时预览的尾部修订分离；用户按键、点击或切换应用会中止。拒绝密码框、只读字段、窗口、页面、终端输出区及不可核验的选区；无法核验时返回 `rejected`。读取到输入框为空后才返回 `applied`；手机仅处理与本次在途代际一致的确认，收到成功才清掉手机视觉文字，并等新 `ready` 再开放手势。
- 手势消息继续使用 AES-GCM combined 格式及逐帧随机 nonce；不修改配对、密钥或帧边界。断线清除租约和在途状态，不重发清空命令。


## 音频帧

解密后的负载：

```
u16 session
u32 seq        // 从 0 开始，必须严格连续
u16 samples    // PCM16 样本数
i16 pcm[samples] // 小端
```

固定 16 kHz、单声道、20ms（320 样本 / 640 字节）。iPhone 在按下时启动 AVAudioEngine，转换到 16 kHz PCM16，按 20ms 切帧；松开时把尾部不足一帧的偶数样本也发出，然后发 `audio.end`。

iPhone 会保留当前会话的完整音频日志（最多 600 秒）。Mac 发现首帧序号大于 0 或中间缺口时，发送 `audio.need(session, seq)`；iPhone 从日志重发该序号起的音频，Mac 在缺口补齐前忽略后续帧。`audio.end` 的样本数必须在 `1...9_600_000`，帧数必须等于 `ceil(samples / 320)`；两端复用 `IMicLink.isValidAudioEnd` 检查。合法结束计数与已收数据不一致时，Mac 请求补发并暂存结束消息，补齐后才完成识别。达到上限时 iPhone 明确提示并自动提交，不静默截掉开头。

## 会话时序

```
iPhone                         Mac
  | -- hello (pub, has_token) -> |
  | <- hello (pub, auth/pair) -- |
  | -- encrypted auth/pair ----> |
  | <- ready ------------------- |
  | -- audio.start ------------> |
  | -- audio frame 0..n -------> |  同时流式送百炼
  | <- audio.need(seq) --------- |  仅在检测到缺口时
  | -- audio replay(seq..n) ---> |
  | -- audio.end --------------> |
  | <- state(transcribing) ----- |
  | <- result(text, latency) --- |
```

`latency` 为 Mac 收到最后一帧到最终文字的毫秒数，不含网络排队时间。

## 蓝牙 GATT 兜底

当 Bonjour/TCP 不可用时，iPhone 可以切换到纯 BLE GATT 字节隧道。它不改变 iMic Link：

- UUID 统一定义在 `shared/iMicLink.swift`：服务 `7E570000-7F4A-4C7E-9A2B-1C0D5E6F7A80`，上行 `…0001`（write / writeWithoutResponse），下行 `…0002`（notify），身份 `…0003`（只读 Mac UUID）。
- iPhone 读取身份后才订阅，只接受当前明确选择的 Mac。身份特征仅用于筛选，不建立信任；仍须完成原有六位码或令牌握手。旧 Mac 缺少身份特征时须同步更新，不退化为连接任意外设。
- 音频按 `maximumWriteValueLength(for:)` 分片，允许无响应写入时持续排空；控制消息有序使用响应写入，最后分片收到 ATT 确认后才完成。Mac 串行向回环 TCP 写入后回复 ATT，不能在仅入队时假称送达。
- 下行按 `CBCentral.maximumUpdateValueLength` 分片，遇 `updateValue == false` 暂停，等待 ready 回调恢复；字节序列仍由同一个 `LinkFrameDecoder` 解析。EOF 前已收到的末尾数据先排空。
- 双向排队均有 64 MiB 上限，游标推进而非逐片移除数组首项；超限或链路错误明确失败，不跳帧继续。日志记录排队字节、速率与 MTU，不记录音频内容。
- 16 kHz PCM16 加上逐帧加密和帧头，持续上行至少约需 34,050 字节/秒（未计 ATT 开销）。BLE 实际吞吐受设备与环境影响，不能承诺始终实时；优先 TCP，积压时有界等待或明确失败。

## 断线与恢复

- 任意一端断开都会取消进行中的 ASR，避免半段文字落进输入框。
- iPhone 普通失败重连间隔 1.6^n 秒、封顶 8 秒；回到前台清除旧退避与重试任务。已就绪的旧连接先用既有加密 `ping/pong(ts)` 检查，只有本次 `ts` 的 `pong` 才确认存活；TCP 800ms、BLE 1500ms 未确认则立即重建，不再额外等一次重试间隔。没有可用旧连接时直接重连已选 Mac，并刷新 Bonjour，仍保留定向 BLE 兜底。
- 探测期间 UI 显示连接中并停用弦；已配对时仍允许先录后连。存活检查成功复用原会话，不重发 `audio.start`；真正断线先通知旧语音会话停止并保留本机文字，再开始新代际握手，不重发旧输入、清空或设置命令。新连接、再次后台与用户切换 Mac 均作废旧探测，避免迟到超时关闭新连接。
- 新连接会替换旧连接，保证重连不被僵尸链路阻塞。
- Mac 结束识别后不等待 WebSocket 关闭握手；最终文字仍需完成可选润色、扫光及输入确认后再回传并发布手势就绪。

上传与识别分别计时：iPhone 在 `audio.end` 的传输完成后才开始等结果；Mac 先等待百炼上传排空，再从 `finish-task` 发出后计算 60 秒最终识别期限，不从松手一刻固定等待 45 秒。百炼开启 `heartbeat` 防持续静音超时，WebSocket 总资源期限覆盖有界录音与排空。失败或断线保留本机已识别文字供复制，不把它自动发送给另一台 Mac。

### 显示语言与错误码（2026-10-31）

接收方用自己的语言翻译已知 `code`，未知或缺失 code 显示 `message`，再缺失才使用本地通用提示。Mac 继续按自己的语言发送完整 message，旧 iPhone 无需更新即可显示。`input.result` 的拒绝回复现在可使用已有的可选 `code` 字段；不增加字段，不改变消息验证、帧格式、HKDF、配对规则或 AES-GCM combined + 逐帧随机 nonce。

新增显示码：`clear_busy`、`clear_unsafe`、`recording_limit`、`audio_incomplete`、`audio_resend_timeout`、`audio_transfer_timeout`、`recognition_timeout`、`asr_model`、`asr_encoding`、`asr_audio`、`asr_upload_timeout`、`asr_upload`、`asr_end`、`asr_final_timeout`、`asr_event`、`asr_long`、`asr_early`，以及 `cloud_` 分类：`invalidKey`、`plan`、`permission`、`ip`、`billing`、`activation`、`quota`、`inspection`、`workspace`、`network`、`ambiguous`、`address`、`service`、`unsupported`。参数化 HTTP/地域详情保留在 Mac message，本地显示对应分类的操作建议。原有 `asr`、`busy`、`key`、握手错误码继续支持。完整映射见 `shared/LinkStatusText.swift`。

兼容测试覆盖新增 clear code 编解码、旧 Mac 无 code 回复、未来未知 code、旧 iPhone 读取 message 与两种语言的独立选择。识别文本、用户设备名称保持用户数据，不翻译。

握手/链路显示码进一步区分：`handshake_timeout`、`protocol_data`、`protocol_plaintext`、`protocol_key_missing`、`audio_end_invalid`、`protocol_settings_direction`、`handshake_frame`、`pair_invalid`、`pair_save_failed`、`handshake_required`、`handshake_invalid`、`connection_timeout`、`protocol_send`；占用状态区分 `clear_in_progress` 与 `input_in_progress`。影响旧客户端行为的 `auth`、`pair_code`、`pair_locked` 保持原值，确保旧 iPhone 能继续清除失效令牌并重新配对。
