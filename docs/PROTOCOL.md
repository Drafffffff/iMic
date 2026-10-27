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
| `settings` | Mac → iPhone | `features, polish` | 完整功能状态；bit0 预览、bit1 回车、bit2 删除、bit3 光标、bit4 润色偏好设置、bit5 手势就绪与清空 |
| `polish.settings` | iPhone → Mac | `polish` | 请求当前 Mac 保存完整润色偏好；仅认证完成后的加密链路可用 |
| `polish.saved` | Mac → iPhone | `features, polish` | 本次保存请求的明确确认，携带实际保存值；不以普通状态广播代替确认 |
| `state` | Mac → iPhone | `session, phase` | `listening` / `transcribing` |
| `result` | Mac → iPhone | `session, text, latency, pasted, target` | 最终文字；`pasted` 表示所选输入通路已完成，键盘兼容模式仅确认事件投递，不表示目标正文经独立核验 |
| `failure` | Mac → iPhone | `session, code, message` | 识别失败 |
| `ping` / `pong` | 双向 | `ts` | 10 秒心跳，40 秒无数据断开 |

### 润色偏好与能力协商

协议版本仍为 `1`，不改变握手、密钥派生或帧格式。Mac 在 `ready` 后通过加密 `settings` 发送当前功能位与已保存的完整润色偏好：

```json
{"t":"settings","features":31,"polish":{"enabled":true,"options":{"strength":"medium","scenario":"agent"}}}
```

- `IMicLink.polishPreferencesFeature = 1 << 4`：声明支持手机设置润色偏好。声明 bit4 的 `settings` 必须携带非空、完整且合法的 `polish`，否则拒绝解码；旧 Mac 不声明 bit4 且省略 `polish` 的 `settings` 仍可解码，手机明确显示不支持，不推断默认值。
- `polish.enabled` 为必填布尔值。`polish.options` 必填，其 `strength` 只允许 `light` / `medium` / `heavy`，`scenario` 只允许 `general` / `chat` / `email` / `notes` / `agent`。即使关闭润色也必须提供完整选项；缺失、`null`、类型错误或非法枚举均拒绝，不做静默降级。
- iPhone 仅在链路已 `ready`、Mac 声明 bit4 且没有在途保存时发送 `{"t":"polish.settings","polish":{...}}`。命令必须包含完整 `polish`，不支持局部更新。保存期间禁用控件；Mac 保存后回传完整 `polish.saved`，且值与请求一致，才表示保存成功，不能仅凭发送成功或普通 `settings` 广播显示已保存。确认必须携带 bit4 与完整偏好；若实际保存值不同，手机显示 Mac 的实际值并明确提示。断线则等待重连读取状态，不自动重发旧 Mac 的修改。
- 偏好归当前连接的 Mac 所有。手机不持久化第二套偏好，切换 Mac 后以新 Mac 的状态为准；Mac 本地更改也通过完整 `settings` 回显。
- 手机只接触开关、强度与场景。API Key、AI 服务来源和地址不进入这些消息。命令必须经过原有六位码或令牌认证，使用会话密钥下的 AES-GCM combined 帧及逐帧随机 nonce；明文或未认证连接不能设置偏好。


### 手势就绪与清空（bit5）

- `IMicLink.gestureControlFeature = 1 << 5`。声明后 Mac 在连接完成、会话开始及最终结束/取消时发送加密 `input.state(seq, status)`；每次发布状态都推进 `seq`，租约仅在 `ready` 时有效。手机还要求本地不在录音/上传/识别中，才接受拉弦。旧 Mac 不声明 bit5 时手机停用弦控制并提示更新，不用计时猜测已完成。
- Mac 的 `busy` 覆盖录音、百炼、润色、OCR 定位、扫光动画、最终输入/确认以及写后释放收尾动画。只有这些处理清理完成、`result` 或 `failure` 已发送后才发布 `ready`；清空在执行期间也撤销租约。两端均拦截忙碌、旧代际及跨连接的手势；处理期间开始的触摸必须抬手后重新开始，不能等解锁后自动续拉。
- 新手机的全部 `input` 带当前 `seq`；`clear` 缺少非负 `seq` 拒绝解码。旧手机的四种单键命令仍可解码，但 Mac 忙碌时同样拒绝。`input.state` 缺少代际、代际为负或状态非法均拒绝；`input.result` 只接受 `clear`、非负 `seq` 和 `applied/rejected`。iPhone 不得伪造 Mac 的状态和确认。
- 用户上拉进入屏幕顶部清空区后，一次触摸只发送一次 `input(action=clear, seq)`。Mac 先撤销旧租约，再只对当前前台、焦点未变化且 AXValue 可写的文本输入控件执行整框清空；这是用户明确请求的手动全框操作，与实时预览的尾部修订分离。不盲发全选删除，不回退到窗口、页面或终端输出区；无法核验时返回 `rejected`。读取到输入框为空后才返回 `applied`；手机仅处理与本次在途代际一致的确认，收到成功才清掉手机视觉文字，并等新 `ready` 再开放手势。
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
