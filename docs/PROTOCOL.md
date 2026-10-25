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
   - 错误配对码最多尝试 3 次，随后断开。配对成功后配对码立即轮换。

安全边界：

- ECDH 临时密钥每次连接重新生成，前向保密。
- 六位码只用于首次信任；之后的连接依赖 32 字节令牌，离线猜解不可行。
- 每帧 AES-GCM 使用独立随机 nonce，任何篡改、重放都会失败并断开。
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
| `error` | 双向 | `code, message` | `pair_code` 可重试，其余通常断开 |
| `audio.start` | iPhone → Mac | `session` | 开始一段输入 |
| audio 帧 | iPhone → Mac | 二进制 | 见下 |
| `audio.end` | iPhone → Mac | `session, samples, frames` | 结束并提交识别 |
| `audio.cancel` | iPhone → Mac | `session` | 取消 |
| `audio.need` | Mac → iPhone | `session, seq` | 请求从 `seq` 开始补发本会话音频 |
| `input` | iPhone → Mac | `action` | 中心弦手势：`return` / `delete` / `left` / `right` |
| `preview` | iPhone → Mac | `text` | Apple Speech 的临时转写，用于实时输入预览 |
| `settings` | Mac → iPhone | `features` | 功能位：bit0 预览、bit1 回车、bit2 删除、bit3 光标 |
| `state` | Mac → iPhone | `session, phase` | `listening` / `transcribing` |
| `result` | Mac → iPhone | `session, text, latency, pasted, target` | 最终文字 |
| `failure` | Mac → iPhone | `session, code, message` | 识别失败 |
| `ping` / `pong` | 双向 | `ts` | 10 秒心跳，40 秒无数据断开 |

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
- iPhone 在前台自动重连，间隔 1.6^n 秒、封顶 8 秒；回到前台立即重试。
- 新连接会替换旧连接，保证重连不被僵尸链路阻塞。
- Mac 结束识别后不等待 WebSocket 关闭握手，拿到最终文本立即回传并输入。

上传与识别分别计时：iPhone 在 `audio.end` 的传输完成后才开始等结果；Mac 先等待百炼上传排空，再从 `finish-task` 发出后计算 60 秒最终识别期限，不从松手一刻固定等待 45 秒。百炼开启 `heartbeat` 防持续静音超时，WebSocket 总资源期限覆盖有界录音与排空。失败或断线保留本机已识别文字供复制，不把它自动发送给另一台 Mac。
