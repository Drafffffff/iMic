# 协议与密码学 审计

## 范围与方法

已读取 `AGENTS.md`，审查共享协议、Mac `LinkServer`/`BLEBridge`、iPhone `LinkClient`/`BLELinkClient`、协议文档，并追踪 `PairingStore`、Mac 撤销入口及相关测试，核对问题是否已有守卫或属于已知限制。

全程未修改仓库文件，未访问网络、真实 API、钥匙串或系统设置。尝试运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/imic-audit-protocol
```

工具链因只读沙箱拒绝临时文件及编译器操作而退出，**测试未执行**。以下结论来自静态代码与调用路径分析。

## 发现

### [P1] 增量解析器重复交付已消费的小帧

- 位置：[shared/iMicLink.swift:114](../../../shared/iMicLink.swift:114)、[shared/iMicLink.swift:132](../../../shared/iMicLink.swift:132)
- 证据：每次 `append` 都将 `offset` 重置为零；有残留尾帧时，仅在 `offset >= 4096` 才移除已消费前缀。小于该阈值的完整帧已返回给调用方，却仍留在缓冲区。
- 触发条件：令完整帧 A 的编码长度小于 4096，B 为下一帧。依次调用 `append(A + B.prefix(2))`、`append(B.dropFirst(2))`，返回结果分别为 `[A]`、`[A, B]`。正常 TCP 分段即可形成此边界。
- 后果：控制消息可能重复执行。例如单键 `delete` 不会推进手势租约，可多删除一个字符（[mac/main.swift:447](../../../mac/main.swift:447)）。若 A 是 `paired`，首次处理后客户端切换到会话密钥，再处理残留的同一配对密文会解密失败并断线。现有测试仅覆盖单帧逐字节拆分、多个完整帧，未覆盖完整帧加残帧。
- 建议修复：在 `LinkFrameDecoder.append` 中持久保存读取游标，或每次移除全部已消费字节；4096 阈值只能控制缓冲压缩，不能决定哪些帧算已消费。增加上述混合分段回归测试。
- 置信度：高。

### [P1] Mac 撤销当前 iPhone 时，存在其他配对记录便不会关闭其授权连接

- 位置：[mac/main.swift:1489](../../../mac/main.swift:1489)、[mac/LinkServer.swift:215](../../../mac/LinkServer.swift:215)
- 证据：`forgetDevice` 删除记录后，只在 `!store.isPaired` 时断线，即仅删除最后一个设备才关闭连接。已就绪连接继续使用缓存的 `peer.cipher`，不再查询设备是否仍受信任。
- 触发条件：Mac 保存 A、B 两台 iPhone 的配对，A 当前连接；在 Mac 设置中点击忘记 A，保留 B。
- 后果：A 从配对列表消失后，现有连接仍可发送音频、预览、编辑手势及设置请求，直到连接终止。等待认证的候选连接也可能继续使用撤销前缓存的密钥完成认证。这与 [docs/PRIVACY.md:34](../../../docs/PRIVACY.md:34) 的撤销承诺不符。
- 建议修复：增加按 `deviceID` 撤销的服务端接口，在 LinkServer 串行队列上关闭匹配的 active 和 pending peer；认证完成前复核授权是否仍有效。
- 置信度：高。

### [P1] 未认证的明文回复可以永久删除 iPhone 的有效配对令牌

- 位置：[ios/iMic/LinkClient.swift:934](../../../ios/iMic/LinkClient.swift:934)、[ios/iMic/LinkClient.swift:969](../../../ios/iMic/LinkClient.swift:969)、[ios/iMic/LinkClient.swift:1149](../../../ios/iMic/LinkClient.swift:1149)
- 证据：明文 `error(code=auth)` 无条件进入 `TokenStore.delete`；自动连接收到明文 `hello(status=pair_required)` 时也会删除令牌。这些操作发生在服务端证明持有令牌之前，且 `handlePlain` 没有拒绝 ready 后的明文消息。
- 触发条件：攻击者在真实 Mac 离线时广播相同 Bonjour UUID，待 iPhone 连接后直接发送明文 `{"t":"error","code":"auth"}`；不需要配对码或任何有效密文。路径上的攻击者也可在现有流中注入该帧。
- 后果：合法 Mac 的本地令牌被删除，用户必须重新配对；攻击效果在攻击连接结束后仍然存在。此问题不依赖文档已知的密文重放或首次配对中间人攻击。现有集成测试验证了真实服务器拒绝令牌后的清理，没有验证拒绝消息的真实性。
- 建议修复：未认证的拒绝消息只标记本次连接失败，不删除长期令牌；在用户明确忘记或成功重配时更新存储。认证后的错误应由 Mac 加密发送，iPhone 经加密消息路径处理，并拒绝 ready 后的明文帧。
- 置信度：高。

### [P1] 未配对 BLE 中心可以通过一次订阅长期占用唯一桥接槽位

- 位置：[mac/BLEBridge.swift:152](../../../mac/BLEBridge.swift:152)、[mac/BLEBridge.swift:326](../../../mac/BLEBridge.swift:326)
- 证据：首次订阅立即设置唯一 `self.central`；后续其他中心的订阅被忽略。LinkServer 握手超时关闭回环连接后，`failBridge` 仅设置 `failed` 并调用 `closeLocal`，二者均不清除 `central`。释放槽位依赖原中心取消订阅。
- 触发条件：Mac 开启 BLE 兜底，附近未配对设备订阅下行特征后保持连接，不发送握手。等待 12 秒握手超时后继续保持订阅。
- 后果：合法 iPhone 后续订阅不会取得桥接槽位，上行写入也因中心身份不匹配被拒绝。攻击者无需知道配对码，超时机制不能恢复服务；TCP 链路不受此问题直接影响。
- 建议修复：将订阅者与通过 Link 认证的占用者分开管理；握手失败后释放未认证占用，拒绝其后续写入，并允许其他候选建立独立握手。避免将整个桥接器的恢复条件绑定到失败中心主动退订。
- 置信度：高；未进行物理 BLE 验证。

### [P2] 撤销配对时吞掉持久化错误，重启后旧授权会恢复

- 位置：[mac/PairingStore.swift:150](../../../mac/PairingStore.swift:150)、[mac/PairingStore.swift:161](../../../mac/PairingStore.swift:161)、[mac/PairingStore.swift:39](../../../mac/PairingStore.swift:39)
- 证据：`forget`、`forgetAll` 先删除内存记录，再执行 `try? save()`，无论保存是否成功都通知 UI 刷新。下次启动直接加载原有 `paired.json`。
- 触发条件：已有配对文件可读，但原子写入因目录不可写、磁盘空间不足或文件系统只读而失败；用户执行忘记配对后重启 App。
- 后果：界面曾显示设备已被移除，但旧令牌仍在磁盘中，重启后恢复信任，可重新认证。
- 建议修复：让撤销接口传播保存错误，UI 明确显示持久撤销失败；将状态变更与磁盘提交串行化，提交成功后才报告完成。失败时仍应关闭相关连接。
- 置信度：高。

## 已检查且未发现问题的方面

- **长度与整数边界**：解码端将负载限制为 `1...128 KiB`；支持的平台使用 64 位 `Int`，解析 u32 长度不会整数溢出。音频解码检查头部长度、非空及样本数与字节数一致性。
- **AES-GCM 与 nonce**：使用 CryptoKit `AES.GCM.seal` 自动生成随机 nonce，保持 combined 格式；解密认证失败不会返回明文，未发现固定 nonce 或计数器重置造成的复用。
- **密钥派生**：配对与会话使用不同 HKDF 上下文，令牌严格要求 32 字节；TCP 和 BLE 新连接均重新生成临时私钥。
- **在线猜码限制**：配对失败按 Mac 全局计数，重连不清零；触发锁定后轮换代码并递增冷却，冷却期间不解密配对请求。
- **生产 iPhone 令牌存储**：使用 `AfterFirstUnlockThisDeviceOnly` 钥匙串；文件回退受模拟器编译条件限制。
- **已知安全边界**：同连接重放/反射、首次配对主动中间人离线猜码已在 `docs/PROTOCOL.md` 明确记录，本次未重复列为缺陷。