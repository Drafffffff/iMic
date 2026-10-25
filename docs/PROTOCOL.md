# iMic Link 1.0

iMic 的传输层只做三件事：发现、认证、按序送音频。没有云中转，没有自定义 UDP 重传，也没有把音频 base64 塞进 JSON。

## 发现

Mac 通过 Bonjour 广播：

```
service type: _imic._tcp
instance:     iMic · <Mac 名称>
TXT:          id=<Mac UUID>, v=1
```

iPhone 用 `NWBrowser` 浏览同一服务类型，读取 TXT 中的 `id` 识别上次连接的 Mac；只有一台 Mac 时自动连接。

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

iPhone 会保留当前会话的完整音频日志（最多 60 秒）。Mac 发现首帧序号大于 0 或中间缺口时，发送 `audio.need(session, seq)`；iPhone 从日志重发该序号起的音频，Mac 在缺口补齐前忽略后续帧。会话结束时若 `frames` / `samples` 不一致，Mac 先请求补发并暂存 `audio.end`，补齐后继续识别，不再直接取消整次输入。

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

- Mac 外设服务 `7E570000-7F4A-4C7E-9A2B-1C0D5E6F7A80`，上行特征 `…0001`（write / writeWithoutResponse），下行特征 `…0002`（notify）。
- iPhone 中心端把 `LinkWire` 字节流按 ATT 写入上限切片；Mac 把字节流转发到 `127.0.0.1:<LinkServer 端口>` 的本机回环 TCP。
- Mac → iPhone 的响应按 180 字节通知切片；iPhone 重新拼成字节流后用同一个 `LinkFrameDecoder` 解析。
- 握手、AES-GCM、会话号、音频帧、`audio.need` 补发完全复用 TCP 路径；BLE 只是链路层。
- 音频帧超过 ATT payload 时会被切片；BLE 带宽低，可能触发 `audio.need` 重发，但不会放宽校验。

## 断线与恢复

- 任意一端断开都会取消进行中的 ASR，避免半段文字落进输入框。
- iPhone 在前台自动重连，间隔 1.6^n 秒、封顶 8 秒；回到前台立即重试。
- 新连接会替换旧连接，保证重连不被僵尸链路阻塞。
- Mac 结束识别后不等待 WebSocket 关闭握手，拿到最终文本立即回传并输入。
