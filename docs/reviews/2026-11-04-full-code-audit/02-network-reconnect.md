# 网络传输、发现与重连状态机 审计

## 范围与方法

先读取了 `AGENTS.md`，完整审阅指定的五个文件，并追踪 `SessionModel`、Mac 配对删除入口及 `PairingStore`。对照了协议、架构、已知限制、PR #31/#32 的验证报告，以及选择和前台恢复测试源码。

使用 `rg`、带行号源码读取及 `git log` 进行静态审计。尝试运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/imic-audit-network
```

测试未启动：沙箱拒绝 `/tmp` 缓存及编译器访问，退出码为 1。以下未声称完成动态复现；未修改仓库、访问网络服务或操作系统配置。

## 发现

### [P1] 删除当前 iPhone 配对时，只要还有其他配对，旧连接仍保有操作权限

- 位置：[mac/main.swift:1489](../../../mac/main.swift:1489)、[mac/LinkServer.swift:215](../../../mac/LinkServer.swift:215)
- 证据：`forgetDevice` 删除令牌后，仅在 `!store.isPaired` 时断开连接；该属性表示“配对列表为空”。已认证连接继续使用缓存的 `peer.cipher`，处理消息时不检查信任是否已撤销。`store.onChange` 也只刷新 UI。
- 触发条件：Mac 记住 A、B 两台 iPhone，A 当前在线；在 Mac 设置中删除 A，保留 B。
- 后果：A 的连接不会关闭，仍可发送音频、编辑命令和润色设置；正常心跳可持续维持连接。这与 `docs/PRIVACY.md:34` 的解除配对承诺不符。
- 建议修复：增加 `LinkServer.disconnect(deviceID:)`，撤销该身份的活动连接及待认证连接；认证完成前再次核对令牌仍有效。
- 置信度：高。

### [P1] 持续可发现但无法建立 TCP 的 Mac，会让 BLE 兜底持续饥饿

- 位置：[ios/iMic/LinkClient.swift:1363](../../../ios/iMic/LinkClient.swift:1363)、[同文件:1233](../../../ios/iMic/LinkClient.swift:1233)、[同文件:1396](../../../ios/iMic/LinkClient.swift:1396)
- 证据：失败后，TCP 重试安排在 `delay` 秒，BLE 安排在 `delay + 2` 秒。前者重新选择发现列表中的同一 Mac，进入 `connectLocked → closeConnectionLocked`，取消后者。初始 BLE 定时器到期时，若 TCP 尚在尝试，又因 `connection != nil` 直接返回。
- 触发条件：已配对目标持续广播 Bonjour，但 TCP 被防火墙拒绝或丢弃；同一目标的 BLE 可用且已启用。
- 后果：客户端持续尝试 TCP，无法自动进入可用的 BLE。退避达到八秒后仍保持上述先后关系。这超出了文档记录的 BLE 吞吐限制，直接影响兜底功能。
- 建议修复：为同一目标维护独立的传输失败状态；TCP 尝试超时后允许先尝试 BLE，避免每轮 TCP 重试都重置兜底期限。
- 置信度：高。现有选择集成脚本显式传入 `--debug-no-ble-fallback`，未覆盖此路径。

### [P1] 前台探测从 ping 入队时计时，会误断开仍在正常补传的 BLE 会话

- 位置：[ios/iMic/LinkClient.swift:400](../../../ios/iMic/LinkClient.swift:400)、[ios/iMic/BLELinkClient.swift:102](../../../ios/iMic/BLELinkClient.swift:102)
- 证据：`probeForegroundLocked` 调用 `sendSealed(.ping)` 后立即启动 1.5 秒期限。BLE 将 ping 追加到 FIFO，必须先发送此前排队的音频和控制帧；探测没有等待发送完成。超时进入 `restartForegroundLocked`，关闭传输并清空发送队列。
- 触发条件：BLE 录音松手后仍在补传，短暂切到后台再返回；ping 前方的数据需要超过 1.5 秒才能排空。
- 后果：即使音频持续正常传输，也会被判为失联，导致本轮上传失败、剩余队列被清除。文档中的实测吞吐为 18–22 KB/s，约 33 KB 的积压就足以触发。
- 建议修复：给探测 ping 接入发送完成回调，从实际送达传输层后开始等待 pong；排队阶段另设与队列进度相关的期限，保留帧顺序。
- 置信度：高。

### [P1] iPhone 缺少持续的接收超时检查，前台半开连接无法及时恢复

- 位置：[ios/iMic/LinkClient.swift:1113](../../../ios/iMic/LinkClient.swift:1113)、[mac/LinkServer.swift:400](../../../mac/LinkServer.swift:400)
- 证据：40 秒无数据检查仅存在于 Mac。iPhone 只响应服务器 ping；自身的 pong 超时仅在后台返回时创建。握手完成后，没有接收时间记录或持续存活定时器。
- 触发条件：已连接时网络变为静默黑洞，连接暂未产生失败回调，App 一直停留前台。现有黑洞测试通过主动调用 `activate()` 恢复，没有覆盖持续前台场景。
- 后果：Mac 超时关闭后，其错误和关闭通知也可能被黑洞丢弃；iPhone 仍显示 ready，并把后续录音交给失效连接，直到上传/结果期限或系统 TCP 超时才失败。
- 建议修复：在客户端记录当前代际最后一次有效接收时间，增加持续存活检查；超时通过统一断线路径通知会话并重连。后台挂起与 BLE 积压需单独处理期限。
- 置信度：高。

### [P2] 普通断线的主线程交接仍可能被 Bonjour 回调抢先推进 epoch

- 位置：[ios/iMic/LinkClient.swift:1191](../../../ios/iMic/LinkClient.swift:1191)、[同文件:786](../../../ios/iMic/LinkClient.swift:786)、[同文件:1734](../../../ios/iMic/LinkClient.swift:1734)
- 证据：`connectionLost` 清空 `ready`、连接及活动会话后，异步发布 `onLost`，但保留浏览器，且尚未设置重连任务。手动选择状态下，失败目标不会加入 `attemptedThisRound`；此时发现回调可再次连接，推进 epoch，使尚未执行的断线发布被 `publish` 丢弃。
- 触发条件：**[推测，待故障注入验证]** 手动选机成功后录音，发生普通断线；主线程尚未消费断线通知时，Bonjour 更新包含同一目标并触发重连。
- 后果：`SessionModel` 收不到 `onLost`，旧录音仍保持 streaming 状态，可能继续向替换后的 socket 发送旧会话音频。PR #32 对前台恢复交接做了隔离，普通断线路径没有同等保护。
- 建议修复：为所有断线路径增加交接状态，阻止 `autoConnect` 在断线通知交付前启动新连接；统一 TCP、BLE 和前台恢复的通知顺序。
- 置信度：中。

## 已检查且未发现问题的方面

- **固定目标策略**：`MacSelection.choose` 和 BLE 白名单均限制为选定身份；离线或失败不会自动跳到另一台 Mac。
- **iPhone 删除配对隔离**：删除当前目标先关闭连接并推进 epoch，再删除令牌；删除非当前目标不关闭当前链路。持久暂停恢复的守卫也已覆盖。
- **迟到传输回调**：TCP 接收、发送错误及 BLE 数据回调普遍核对当前连接对象；BLE 桥的 loopback 回调同时核对 generation。
- **服务端候选隔离**：候选连接有数量上限和握手超时，只有认证成功后才能替换活动连接。
- **BLE 帧完整性与背压**：队列有容量限制；预览只替换尚未开始的帧；控制帧等待 ATT 确认；桥接端在背压时保留待发送数据，并先排空 EOF 前收到的末尾数据。