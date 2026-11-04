# iMic 全量代码多维审计与复核报告（2026-11-04）

- **审计日期**：2026-11-04
- **审计快照**：`97b025b`（代码树与 `codex/ui-phosphor-wireframe` 上的 `fb07d1c` 完全一致，仅递增了 v1.4.7 版本号与发布说明）
- **目标分支**：`codex/ui-phosphor-wireframe`
- **子报告目录**：[`docs/reviews/2026-11-04-full-code-audit/`](./2026-11-04-full-code-audit/)

---

## 1. 审计范围与方法

本次审计针对 iMic 仓库全量源码（`shared/`、`mac/`、`ios/`、`tools/`、`scripts/`、`tests/` 及 `.github/workflows/`）按 **10 个正交工程维度** 启动 10 个独立 `codex exec -s read-only` 审计线程，随后在宿主机真实工具链环境下对全部发现逐项执行 **独立复现验证（独立编译最小复现程序 / 压力并发测试 / 源码调用链交叉核对）**：

1. **静态全覆盖扫描**：10 个专项线程分别覆盖协议与密码学、网络与重连状态机、并发与线程安全、iOS 音频采集与会话、Mac 文本输入与辅助功能（AX）、Mac 云端识别/润色与凭据管理、iOS UI 与会话状态机、Mac 生命周期/设置与自动更新、构建/发布与供应链、测试覆盖与可维护性。
2. **动态复现与交叉核验**：由於只读沙箱内 Codex 无法调用 `swiftc` 写临时缓存，我们在宿主机使用 `xcrun swiftc`、`swift test`（77/77 通过）及 Python 3.9/3.14 针对核心发现编写了独立复现程序（涵盖帧解码器混合分片、`PairingStore` 多线程读写竞争与 TSan 检测、ASR 引用环泄漏、内嵌终端换行过滤、自定义服务三字段保存死锁、超大凭据文件覆盖、`notarytool`/`release-network.py` 孤儿进程与 Python 3.9 兼容性、`Updater` 回归测试等），并结合完整调用链调整了最终严重度分级。
3. **证据分级原则**：
   - **已复现证实**：已通过独立编译程序、脚本或发布实测直接触发并观测到故障结果。
   - **已走读证实**：控制流与数据流路径单义闭合，无额外守卫拦截。
   - **部分成立（降级）**：代码缺陷或竞争窗口真实存在，但受上下游守卫、超时或重置机制限制，用户可见影响低于初报评级。
   - **待定**：依赖特定外部并发或系统时序，静态存在风险但尚未动态构造触发。

---

## 2. 严重度汇总与维度分布

10 份专项报告共提出 48 项原始发现，外加本次 v1.4.7 正式公证过程中实测捕获的 1 项发布恢复缺陷（`09-6`），合计 49 项；剔除 3 组跨专项重复识别的同一根因问题（`01-2 = 02-1`、`03-3 = 06-1`、`04-1 = 07-3`）后，共计 **46 项独立发现**。

### 2.1 按最终复核严重度统计

| 最终严重度 | 数量 | 定义与处置建议 |
| --- | ---: | --- |
| **P0（阻断/高危）** | 1 | 核心协议帧解析器在常见分片边界下重复投递已消费帧，可导致手势重复按键注入或配对后立即解密失败断线，建议最优先修复 |
| **P1（严重）** | 6 | 可导致进程崩溃（SIGSEGV/SIGABRT）、已撤销设备继续持有控制权、内嵌终端换行原样投递执行、VoiceOver 永久锁死、自定义服务无法保存、系统 Python 下公证崩溃 |
| **P2（中等）** | 18 | 特定条件下的功能退化、局域网/BLE 拒绝服务、状态残留阻塞更新、设备切换串音或关键路径测试缺失 |
| **P3（轻微/加固）** | 20 | 边界条件下的小窗口竞争、单次会话对象泄漏、极端输入处理或测试夹具改进 |
| **待定** | 1 | 测试脚本对共享生产日志轮换的潜在敏感性，待需要时隔离 |
| **合计** | **46** | — |

### 2.2 按 10 个审计维度统计（去重后归属主维度）

| 维度编号 | 审计维度 | 子报告 | P0 | P1 | P2 | P3 | 待定 | 小计 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 01 | 协议与密码学 | [01-crypto-protocol.md](./2026-11-04-full-code-audit/01-crypto-protocol.md) | 1 | 1 | 3 | 0 | 0 | 5 |
| 02 | 网络传输、发现与重连状态机 | [02-network-reconnect.md](./2026-11-04-full-code-audit/02-network-reconnect.md) | 0 | 0 | 4 | 0 | 0 | 4 |
| 03 | 并发与线程安全 | [03-concurrency.md](./2026-11-04-full-code-audit/03-concurrency.md) | 0 | 1 | 0 | 4 | 0 | 5 |
| 04 | iPhone 音频采集与会话 | [04-ios-audio.md](./2026-11-04-full-code-audit/04-ios-audio.md) | 0 | 0 | 2 | 2 | 0 | 4 |
| 05 | Mac 文本输入与辅助功能 | [05-mac-input-ax.md](./2026-11-04-full-code-audit/05-mac-input-ax.md) | 0 | 1 | 1 | 2 | 0 | 4 |
| 06 | Mac 识别/润色服务与凭据 | [06-mac-asr-cloud-credentials.md](./2026-11-04-full-code-audit/06-mac-asr-cloud-credentials.md) | 0 | 0 | 0 | 2 | 0 | 2 |
| 07 | iPhone UI 与会话状态 | [07-ios-ui-state.md](./2026-11-04-full-code-audit/07-ios-ui-state.md) | 0 | 1 | 1 | 1 | 0 | 3 |
| 08 | Mac App 生命周期、设置与自动更新 | [08-mac-app-lifecycle-updater.md](./2026-11-04-full-code-audit/08-mac-app-lifecycle-updater.md) | 0 | 1 | 2 | 2 | 0 | 5 |
| 09 | 构建、发布与供应链 | [09-release-supplychain.md](./2026-11-04-full-code-audit/09-release-supplychain.md) | 0 | 1 | 3 | 2 | 0 | 6 |
| 10 | 测试覆盖与可维护性 | [10-tests-quality.md](./2026-11-04-full-code-audit/10-tests-quality.md) | 0 | 0 | 2 | 5 | 1 | 8 |
| **合计** | — | — | **1** | **6** | **18** | **20** | **1** | **46** |

---

## 3. 全部发现总览表

| 编号 | 原始评级 | 最终评级 | 核验状态 | 核心位置 | 问题摘要 |
| --- | :---: | :---: | --- | --- | --- |
| **01-1** | P1 | **P0** | 已复现证实 | `shared/iMicLink.swift:114,132` | `LinkFrameDecoder.append` 在 `< 4096` 字节且带残帧尾部时不移除已消费帧，导致后续 `append` 重复交付同一帧 |
| **03-1** | P1 | **P1** | 已复现证实 | `mac/PairingStore.swift:145,164,186` | `PairingStore` 解锁后并发执行 `save()`，引发旧快照覆盖已撤销令牌及 `Dictionary` 跨线程访问崩溃 |
| **01-2 / 02-1** | P1 | **P1** | 已走读证实 | `mac/main.swift:1489`、`mac/LinkServer.swift:215` | Mac 删除当前 iPhone 配对时，若仍有其他已配对设备则不断开当前连接，旧连接继续享有完整操作权限 |
| **05-1** | P1 | **P1** | 已复现证实 | `mac/InputTarget.swift:145`、`mac/main.swift:670` | Electron 编辑器未暴露 AX 焦点元素（`nil`）时内嵌终端被判为非终端，漏过换行过滤直接投递 `\n` |
| **07-2** | P1 | **P1** | 已走读证实 | `ios/iMic/HomeView.swift:726,747,854` | VoiceOver 双击完成一次录音后未复位 `interactionStart`，导致后续所有录音触发被永久拦截 |
| **08-1** | P1 | **P1** | 已复现证实 | `mac/SettingsWindow.swift:466`、`mac/DeepSeek.swift:126` | 自定义服务首次保存时单字段草稿与其余已保存空字段组合验证，形成循环依赖导致无法通过 UI 保存 |
| **09-1** | P1 | **P1** | 已复现证实 | `tools/release-network.py:39,78` | 直接调用 Python 3.11+ 的 `hashlib.file_digest`，在系统 `/usr/bin/python3`（3.9.6）下阻断公证与恢复 |
| **01-3** | P1 | **P2** | 已走读证实 | `ios/iMic/LinkClient.swift:934,969,1149` | 未认证明文 `error(code=auth)` 及自动重连 `pair_required` 无条件删除本地有效配对令牌 |
| **01-4** | P1 | **P2** | 已走读证实 | `mac/BLEBridge.swift:152,326` | 首次订阅即占用唯一 `central` 槽位，握手超时 `failBridge` 后不释放，未配对中心保持订阅可阻塞 BLE |
| **01-5** | P2 | **P2** | 已走读证实 | `mac/PairingStore.swift:150,157,165` | `forget` / `forgetAll` 使用 `try? save()` 忽略写盘失败并刷新 UI，重启后被删配对静默恢复 |
| **02-2** | P1 | **P2** | 已走读证实 | `ios/iMic/LinkClient.swift:1233,1363,1396` | 目标 Mac 持续可发现但 TCP 不通时，每轮 TCP 重试（`delay`）总在 BLE 兜底（`delay+2`）前取消 BLE 定时器 |
| **02-3** | P1 | **P2** | 已走读证实 | `ios/iMic/LinkClient.swift:400`、`BLELinkClient.swift:102` | 前台探测从 `ping` 入队时即启动 1.5s/0.8s 计时，未等待前方排队的音频块发完，可能误断开正常传输 |
| **02-4** | P1 | **P2** | 已走读证实 | `ios/iMic/LinkClient.swift:1113`、`mac/LinkServer.swift:400` | iPhone 缺少持续接收超时检查，持续前台遭遇静默半开连接时仍显示 `ready` 直至下次发送超时 |
| **02-5** | P2 | **P2** | 已走读证实 | `ios/iMic/LinkClient.swift:786,1191,1734` | 普通断线异步发布 `onLost` 期间，手动选机下 Bonjour 回调可抢先重连推进 epoch 并丢弃断线通知 |
| **04-1 / 07-3** | P1 | **P2** | 已走读证实 | `ios/iMic/HomeView.swift:730`、`SessionModel.swift:413` | 首次麦克风授权弹窗期间松手不触发 `endListening()`，授权返回后在已松手状态下自动开启录音 |
| **04-2** | P1 | **P2** | 已走读证实 | `ios/iMic/SessionModel.swift:402,573`、`AudioCapture.swift:73` | 音频冷启动仅异步入队便立即触发 `.recordingStarted` 触感，早于采集真正就绪时间 |
| **05-2** | P1 | **P2** | 已走读证实 | `mac/InputTarget.swift:268,283`、`mac/main.swift:1139` | 未检测 `IsSecureEventInputEnabled()`，Secure Input 使按键监视失效后仍允许兼容模式自动退格与追加 |
| **07-1** | P1 | **P2** | 已走读证实 | `ios/iMic/PairingSheet.swift:345`、`SessionModel.swift:1087` | 设置页切换设备未调用 `cancelForDeviceSwitch()`，旧目标离线缓冲录音会在新设备就绪后补发给新 Mac |
| **08-2** | P2 | **P2** | 已复现证实 | `mac/Onboarding.swift:81,266`、`mac/Updater.swift:139` | 已完成引导的用户重开向导后直接关窗，`setup.inProgressStep` 残留导致持续阻塞自动与手动更新 |
| **08-5** | P2 | **P2** | 已走读证实 | `mac/SettingsWindow.swift:284,630`、`mac/main.swift:1284` | 设置页点击“重新生成”配对码后未调用 `refreshPairCode()`，界面继续显示已失效的旧码 |
| **09-4** | P2 | **P2** | 已复现证实 | `tools/release-network.py:44,49,200` | 子进程使用 `start_new_session=True`，`KeyboardInterrupt` 退出时未 `killpg` 清理签名或公证子进程 |
| **09-5** | P2 | **P2** | 已复现证实 | `tests/Updater/test_appcast.py:22,41,65` | 更新回归测试直接复制生产 `appcast.xml` 与 `VERSION` 断言初始状态（5/8 失败，无 `build/` 时 8/8 报错） |
| **09-6** | — | **P2** | 发布实测捕获 | `tools/release-network.py:137-190` | `notarytool submit` 服务端已建单但客户端连接超时时，检查点 `id` 保持 `null`，需手工查 `history` 才能恢复 |
| **10-1** | P2 | **P2** | 已走读证实 | `.github/workflows/pages.yml:3`、`Package.swift:11` | 仓库仅有官网部署工作流，缺少针对 App 与共享代码的 PR 编译与测试 CI |
| **10-2** | P2 | **P2** | 已走读证实 | `tests/ASRStreaming/main.swift:8,63`、`mac/ASR.swift:176` | ASR 回归测试从未调用 `recognizer.append(pcm)`，音频上传队列与排空期限完全未覆盖 |
| **03-2** | P2 | **P3** | 部分成立 | `ios/iMic/LinkClient.swift:514,548,1705` | 换机入口在主线程调用 `invalidateEpoch()` 无锁修改网络队列状态（新连接 `ready` 会重置租约，仅影响保存提示） |
| **03-3 / 06-1** | P2 | **P3** | 已复现证实 | `mac/main.swift:710`、`mac/ASR.swift:320` | `recognizer.onError` 闭包内读取 `recognizer.failureCode` 形成强引用环，每轮云识别泄漏一个 `BailianASR` 对象 |
| **03-4** | P2 | **P3** | 已走读证实 | `ios/iMic/PhosphorCompositor.swift:75,173` | `replaceArtwork()` 对 `.shared` 纹理原地替换，未与在途 GPU command buffer 同步 |
| **03-5** | P2 | **P3** | 部分成立 | `ios/iMic/SoundDesign.swift:37,49,55` | 媒体服务重置后旧后台 `registerAll()` 完成回调无代际检查，可能覆盖重置后的新 `SystemSoundID` |
| **04-3** | P1 | **P3** | 部分成立 | `ios/iMic/SessionModel.swift:359,645`、`IMicAudioInputBridge.m:258` | 松手提交未等待 `IMicAudioInputBridge` 异步转换队列排空，末尾约 10–30ms 音频可能落入下一轮 `preRoll` |
| **04-4** | P2 | **P3** | 已走读证实 | `ios/iMic/SessionModel.swift:278,286`、`MicrophoneTestView.swift:32` | 等待识别结果期间打开 `MIC TEST`，结果返回触发 `updateAudioStandby()` 会在 5 秒后关闭自检采集 |
| **05-3** | P2 | **P3** | 部分成立 | `mac/main.swift:1106,1228,1252` | 兼容模式 `typeText` 同步循环发送退格与分块按键期间无中止点（实测 2400 字约 44ms） |
| **05-4** | P2 | **P3** | 已走读证实 | `mac/TextPolishEffect.swift:935,959,979` | 扫光采样在队列头命中目标输入框后立即返回，跳过同窗口其他兄弟节点的 `AXProtectedContent` 检查 |
| **06-2** | P2 | **P3** | 已复现证实 | `mac/Credentials.swift:44,125,134` | 自定义服务 Key 无长度上限，保存 `> 64_000` 字节 token 会导致凭据文件不可读并在下次写入时清空其他 Key |
| **06-3** | P2 | **P3** | 已复现证实 | `mac/ASR.swift:281,298` | `task-finished` 直接按 `results.keys.sorted()` 拼接最终文本，未检查 `confirmedThrough` 是否有缺句 |
| **07-4** | P2 | **P3** | 部分成立 | `ios/iMic/HoldControl.swift:57,65` | `touchesEnded` 使用末次 `touchesMoved` 的 `translation` 判断上滑取消，未用最终松手坐标重算纵向位移 |
| **08-3** | P2 | **P3** | 已走读证实 | `mac/main.swift:1504`、`mac/SettingsWindow.swift:680` | 菜单退出或 `Cmd+Q` 直接调用 `NSApp.terminate(nil)`，绕过设置窗口未保存草稿的确认弹窗 |
| **08-4** | P2 | **P3** | 已走读证实 | `mac/main.swift:150,1731` | 第二实例发送的分布式重开通知无观察者注册，`reopenFromAnotherInstance` 无调用点 |
| **09-2** | P2 | **P3** | 已走读证实 | `scripts/package-release.sh:165`、`tools/release-network.py:67` | DMG 在 iOS 打包前移入 `build/release/`，而 `.notarization.json` 留在原目录，后续失败需手动配对恢复 |
| **09-3** | P2 | **P3** | 部分成立 | `scripts/testflight.sh:57`、`tools/testflight-handoff.py:66` | 归档时 `ditto` 复制整目录源码，但交接校验仅比对 Git 已跟踪文件集合，忽略归档后删除的未跟踪源文件 |
| **10-3** | P2 | **P3** | 已走读证实 | `tests/PolishEffect/main.swift:448`、`mac/main.swift:854` | 输入与润色测试聚焦局部状态机，缺少 `AppDelegate` 级“用户接管冻结 + 润色超时/迟到响应”编排测试 |
| **10-4** | P2 | **P3** | 已走读证实 | `tests/iMicLinkTests/LinkTests.swift:294`、`shared/iMicLink.swift:504` | 加密测试仅验证同版本动态往返，缺少固定 HKDF 测试向量与重复加密 nonce 独立性检查 |
| **10-5** | P2 | **P3** | 已走读证实 | `scripts/test-ios-reconnect.sh:17`、`ios/iMic/BLELinkClient.swift:112` | TCP 集成脚本显式禁用 BLE，生产 BLE 分片、ACK 续传与背压排空缺少自动化行为测试 |
| **10-6** | P2 | **P3** | 已走读证实 | `scripts/test-link.sh:39,53,79` | `test-link.sh` 重编客户端但直接启动既有 `build/mac.noindex/iMic.app`，未自动重编或校验二进制版本 |
| **10-7** | P2 | **P3** | 已走读证实 | `tests/iOSUI/DisplayUITests.swift:9`、`PolishUITests.swift:8` | 部分 UI 测试未固定 `-AppleLanguages (zh-Hans)` 即硬编码查找中文元素 |
| **10-8** | P2 | **待定** | 待定 | `tests/LinkResume/main.swift:127,155`、`shared/IMicLog.swift:37` | 练习模式回归依赖共享生产日志的字节偏移，日志轮换或并行写入可能引发误报 |

---

## 4. P0 与 P1 级发现详细报告

### [P0] `01-1`：增量帧解码器 `LinkFrameDecoder.append` 在 `< 4096` 字节且带残帧尾部时不移除已消费帧，导致重复交付

- **位置**：[`shared/iMicLink.swift:111-138`](../../shared/iMicLink.swift)
- **调用点**：
  - Mac 端 TCP / BLE 回环接收：[`mac/LinkServer.swift:194`](../../mac/LinkServer.swift)（`peer.decoder.append(data)`）
  - iPhone 端 TCP 接收：[`ios/iMic/LinkClient.swift:898`](../../ios/iMic/LinkClient.swift)（`self.decoder.append(data)`）
  - iPhone 端 BLE 接收：[`ios/iMic/LinkClient.swift:1333`](../../ios/iMic/LinkClient.swift)（`decoder.append(data)`）
- **根因证据**：
  ```swift
  public mutating func append(_ data: Data) throws -> [LinkFrame] {
      buffer.append(contentsOf: data)
      var frames: [LinkFrame] = []
      var offset = 0
      while buffer.count - offset >= 5 {
          ...
          guard buffer.count - offset >= total else { break }
          ...
          frames.append(LinkFrame(kind: kind, payload: payload))
          offset += total
      }
      if offset > 0 {
          if offset == buffer.count {
              buffer.removeAll(keepingCapacity: true)
          } else if offset >= 4096 {
              buffer.removeFirst(offset)
          }
      }
      return frames
  }
  ```
  `offset` 是每次调用 `append` 时的局部变量（每次从 `0` 开始），而当 `0 < offset < buffer.count`（即本次读取解出了完整帧 A，同时缓冲区末尾还带有下一帧 B 的不完整头部/前缀）且 `offset < 4096` 时，`buffer` **完全没有移除已消费的 `offset` 字节**。下一次 `append` 到来时，`offset` 重新从 `0` 扫描，会将已交付过的帧 A 再次解析并返回给上层。
- **复现验证**：
  使用 `xcrun swiftc shared/*.swift` 独立编译验证程序：构造编码长度小于 4096 字节的完整帧 `A`（`"hello"`）与帧 `B`（`"world"`）：
  1. 第一次调用 `decoder.append(A + B.prefix(2))` → 返回 `[A]`；
  2. 第二次调用 `decoder.append(B.dropFirst(2))` → 返回 **`[A, B]`**（帧 `A` 被重复交付）。
- **实际触发路径与严重后果**：
  1. **BLE 链路高频触发**：`BLELinkClient` 与 `BLEBridge` 按 BLE MTU（通常 182～512 字节）对字节流切片传输，且 `BLEBridge` 通过本机 TCP 回环套接字写入 `LinkServer`，极易在单次读取中同时收到“上一帧末尾 + 下一帧前几个字节”。
  2. **配对完成后立即解密失败断线**：Mac 在配对成功时连续发送 `paired`（使用 `pairingCipher` 加密）与 `ready` + `inputState`（使用 `sessionCipher` 加密，见 [`mac/LinkServer.swift:281-283`](../../mac/LinkServer.swift)）。若 iPhone 单次读取收到完整的 `paired` 帧加上 `ready` 帧的前几个字节，首次处理 `paired` 后 `LinkClient` 将 `self.cipher` 切换为 `sessionCipher`；下一次读取补齐 `ready` 时，`decoder.append` 再次吐出旧的 `paired` 帧，此时用 `sessionCipher` 解密 `paired` 必然抛出 `LinkError.decryptionFailed`，导致配对刚成功即断线。
  3. **单键手势重复注入按键**：Mac 端的 `handleInput`（[`mac/main.swift:447-506`](../../mac/main.swift)）通过 `gestureLease.permits(message.seq)` 校验手势租约，但与 `clearInput` 不同，`return`、`delete`、`left`、`right` 四个单键手势执行后 **不会调用 `sendGestureState()` 推进 `gestureLease.revision`**。因此当 `input` 控制帧与后续 `ping` 等帧粘包并跨分片到达时，重复吐出的 `input` 帧仍能通过 `gestureLease.permits(message.seq)`，向用户当前聚焦应用重复注入退格、回车或方向键。（音频帧因 [`mac/main.swift:526,544`](../../mac/main.swift) 有 `seq < expected` 去重而未受音频翻倍影响。）
- **修复建议**：
  无论 `offset` 是否达到 4096，只要 `offset > 0` 就必须推进消费位置：要么直接 `buffer.removeFirst(offset)`，要么将 `readOffset` 作为 `LinkFrameDecoder` 的持久化成员变量并在 `readOffset == buffer.count` 或 `readOffset >= 4096` 时统一压缩缓冲区。同时在 `tests/iMicLinkTests/LinkTests.swift` 中补充“完整小帧 + 下一帧部分头部”的回归测试。

---

### [P1] `03-1`：`PairingStore` 未串行化持久化，并发配对与撤销导致旧快照覆盖与内存访问冲突崩溃

- **位置**：[`mac/PairingStore.swift:145,164,186`](../../mac/PairingStore.swift)；调用点 [`mac/LinkServer.swift:319`](../../mac/LinkServer.swift)、[`mac/main.swift:1491`](../../mac/main.swift)
- **根因证据**：
  1. `trust(deviceID:name:token:)`（运行在 `LinkServer` 网络串行队列）与 `forget(deviceID:)` / `forgetAll()`（运行在主线程 UI）在修改 `stored` 时持有 `lock`，但在 **解锁之后** 才调用 `save()`。
  2. `save()` 内部 **完全未加锁**，直接读取 `self.stored` 执行 `JSONEncoder().encode(stored)` 并写入磁盘：
     ```swift
     private func save() throws {
         let directory = fileURL.deletingLastPathComponent()
         try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
         stored.updatedAt = Date() // 无锁写结构体属性！
         let data = try JSONEncoder().encode(stored) // 无锁并发读 Dictionary！
         ...
     }
     ```
- **复现验证**：
  编写并发复现程序模拟网络队列调用 `trust` 与主线程调用 `forget`：
  1. **状态回滚与崩溃统计**：在 300 次独立运行中，观察到 **5 次已撤销令牌在磁盘上被旧快照恢复**、**3 次新配对记录丢失**、**5 次进程直接崩溃**。
  2. **压力复现与 TSan 报告**：400 轮并发迭代下 **6/6 次必现崩溃**（退出码 139 `SIGSEGV` / 134 `SIGABRT`，调用栈位于 `NSTaggedPointerString countByEnumerating` ← `PairingStore.save` ← `forget`），ThreadSanitizer 明确捕获对 `PairingStore.stored` 的并发读写数据竞争。
- **修复建议**：
  将 `stored.updatedAt = Date()`、`JSONEncoder().encode(stored)` 及原子落盘全部纳入同一个 `lock.withLock` 临界区（例如改为锁内 `saveLocked()`），确保内存修改、快照编码与磁盘替换顺序严格串行一致。

---

### [P1] `01-2 / 02-1`：Mac 删除当前 iPhone 配对时，只要存在其他配对记录便不会关闭其活动连接

- **位置**：[`mac/main.swift:1489-1495`](../../mac/main.swift)、[`mac/LinkServer.swift:215-224`](../../mac/LinkServer.swift)
- **根因证据**：
  ```swift
  @objc private func forgetDevice(_ sender: NSMenuItem) {
      guard let id = sender.representedObject as? String else { return }
      store.forget(deviceID: id)
      if !store.isPaired {
          link.disconnect()
      }
      setStatus(L10n.text("Removed paired iPhone"), transient: true)
      refreshUI()
  }
  ```
  `store.isPaired` 的定义是 `!stored.devices.isEmpty`。当 Mac 同时配对了 iPhone A 和 iPhone B，且当前活动连接为 A 时，用户在菜单或设置中移除 A：
  1. `store.isPaired` 仍为 `true`（因为 B 仍在列表中），`link.disconnect()` **不会被调用**；
  2. `LinkServer` 在会话进入 `.ready` 阶段后，仅使用连接建立时缓存的 `peer.cipher` 解密帧（`LinkServer.swift:215`），不再查询 `PairingStore` 中该 `deviceID` 是否仍受信任。
- **后果**：
  被用户明确移除的 iPhone A 不会断开连接，仍可持续发送语音、实时预览、编辑手势和润色偏好修改，直到连接因其他原因断开为止，直接违背 [`docs/PRIVACY.md:34`](../../docs/PRIVACY.md) 中关于解除配对立即生效的承诺。
- **修复建议**：
  在 `Peer` 上记录已认证或待认证的 `deviceID`，为 `LinkServer` 增加 `disconnect(deviceID:)` 接口并在 `forgetDevice` 时调用，在 `LinkServer` 队列上关闭所有匹配该 `deviceID` 的活动连接与候选连接；同时在完成认证切换至 `.ready` 前再次复核令牌仍在 `PairingStore` 中。

---

### [P1] `05-1`：AX 焦点元素缺失时，编辑器内嵌终端漏过换行与 Tab 过滤

- **位置**：[`mac/InputTarget.swift:145-167`](../../mac/InputTarget.swift)、[`shared/TextRevision.swift:66`](../../shared/TextRevision.swift)、[`mac/main.swift:670,1096`](../../mac/main.swift)
- **根因证据**：
  - `InputTarget.isTerminal(bundleID:element:)` 判断目标是否为终端时，若宿主 Bundle ID 不在纯终端集合（如 Terminal、iTerm2、Otty 等）中，则完全依赖 `element` 的 AX 属性标签（是否包含 `"terminal"` / `"xterm"`）。
  - 对于 VS Code、Cursor 等 Electron 编辑器，当应用刚启动或尚未通过 `AXManualAccessibility` 暴露 AX 树时，`focusedElement` 为 `nil`，此时 `isTerminal(bundleID: "com.todesktop.230313mzl4w4u92", element: nil)` 直接返回 `false`。
  - `mac/main.swift:670` 在会话启动时将 `targetIsTerminal` 固定为该返回值；随后 `TextRevision.sanitize(text, isTerminal: false)` 保留所有 `\n` 和 `\t`。
- **复现验证**：
  独立编译调用 `InputTarget.isTerminal` 与 `TextRevision.sanitize` 验证：当 `bundleID` 为 VS Code（`com.microsoft.VSCode`）或 Cursor（`com.todesktop.230313mzl4w4u92`）且 `element == nil` 时，`isTerminal` 返回 `false`，多行文本 `"git status\nrm -rf build"` 经 `sanitize` 后原样保留 `\n`。
- **后果**：
  用户在 VS Code / Cursor 内嵌终端中语音输入时，若 AX 焦点元素未能读取，识别或润色产生的换行符会被原样投递到终端并立即执行前一行命令，与 [`docs/releases/v1.4.3.md:10`](../../docs/releases/v1.4.3.md) 声明的“含编辑器内置终端换行转空格防护”不符。
- **修复建议**：
  对已知可承载内嵌终端的宿主应用（VS Code、Cursor、Zed、Windsurf、JetBrains IDE 等），当 `focusedElement == nil` 或无法确认焦点角色为普通编辑器正文时，先激活 `AXManualAccessibility` 重试读取焦点元素；若仍无法判定，则按保守策略默认过滤 `\n` / `\r` / `\t`（转为空格），并在投递时刻再次复核当前焦点是否为终端。

---

### [P1] `07-2`：iPhone VoiceOver 完成一次录音后无法再次开始录音

- **位置**：[`ios/iMic/HomeView.swift:726-733,747-755,854-861`](../../ios/iMic/HomeView.swift)
- **根因证据**：
  1. 录音条的 `.accessibilityAction` 在非录音状态下调用 `beginInteraction()`（`HomeView.swift:858`），该函数检查 `guard !interactionStart else { return }` 并将 `interactionStart = true`（`HomeView.swift:748-749`）。
  2. 在物理触摸路径中，手指抬起会触发 `HoldControl.onEnded` 闭包（`HomeView.swift:726-732`），其中执行 `interactionStart = false`。
  3. 但在 VoiceOver 辅助功能路径中，用户再次双击结束录音时，`.accessibilityAction` 直接调用 `session.endListening(cancelled: false)`（`HomeView.swift:856`），**从未将 `interactionStart` 复位为 `false`**。
  4. 此外，若首次 VoiceOver 双击时因未连接或无权限在 `beginInteraction()` 内提前返回（`HomeView.swift:752`），`interactionStart` 同样保持为 `true`。
- **后果**：
  VoiceOver 用户在完成第一次录音（或第一次点击因未连接失败）后，后续所有双击录音条操作均被 `guard !interactionStart` 静默拦截，除非重启应用或触发一次真实物理触摸抬起，否则完全无法再次录音。
- **修复建议**：
  将 `interactionStart` 严格限定给 `HoldControl` 物理按压生命周期使用，或为 VoiceOver `.accessibilityAction` 在结束录音及 `beginInteraction()` 提前返回分支中同步复位 `interactionStart = false`。

---

### [P1] `08-1`：Mac 设置页首次配置自定义服务（Custom Provider）存在循环依赖，无法通过界面保存

- **位置**：[`mac/SettingsWindow.swift:466-515`](../../mac/SettingsWindow.swift)、[`mac/DeepSeek.swift:26,126-148`](../../mac/DeepSeek.swift)
- **根因证据**：
  - 自定义服务（`.custom`）的默认 `defaultModel` 与 `defaultEndpoint` 均为空字符串 `""`。
  - `PolishConfig.validateCredential` 在校验自定义服务时，要求 **API Key、模型名称（`model`）、服务地址（`endpoint`）三者同时非空且有效**。
  - 然而 `SettingsWindowController` 在保存任一字段时，仅将 **当前正在保存的那一个字段** 替换为输入框草稿值，其余两个字段仍从 `PolishConfig.load()`（已落盘配置）读取：
    - 先保存 Key → 已保存的 `model` 与 `endpoint` 为空 → 校验失败（缺模型/地址）；
    - 先保存模型 → 已保存的 `endpoint` 与 Key 为空 → 校验失败；
    - 先保存地址 → 已保存的 `model` 与 Key 为空 → 校验失败；
    - 关闭窗口选择“保存”时，按顺序逐字段调用同一套单字段保存逻辑，同样全部失败。
- **复现验证**：
  在干净配置下对 `.custom` 枚举全部 6 种字段保存排列顺序进行复现测试，6 种顺序返回结果全部为 `false`，没有任何一条UI路径能完成首次保存。
- **修复建议**：
  对同一服务下的待保存草稿（Key、模型、地址）按服务整体构造候选 `PolishConfig` 快照进行联合校验，校验通过后一次性持久化该服务的全部已修改草稿字段。

---

### [P1] `09-1`：`tools/release-network.py` 使用 Python 3.11+ `hashlib.file_digest`，在系统 Python 3.9 下阻断公证与恢复

- **位置**：[`tools/release-network.py:39,78`](../../tools/release-network.py)、[`scripts/package-release.sh:154`](../../scripts/package-release.sh)
- **根因证据**：
  `tools/release-network.py:39` 定义：
  ```python
  def digest(path: pathlib.Path) -> str:
      with path.open("rb") as handle:
          return hashlib.file_digest(handle, "sha256").hexdigest()
  ```
  `hashlib.file_digest` 是 Python 3.11 新增标准库函数，而 macOS 系统自带 `/usr/bin/python3` 为 **Python 3.9.6**。当未将 Homebrew Python 置于 `PATH` 首位时，执行 `./scripts/package-release.sh`（无论新建公证还是 `--resume-notarization`）都会在初始化检查点 `save()` 时直接抛出 `AttributeError: module 'hashlib' has no attribute 'file_digest'`。`--check-only` 因不进入公证阶段而无法提前暴露该崩溃。
- **复现验证**：
  本次 v1.4.7 正式打包首次运行时直接触发该异常（日志见 `build/logs/release-1.4.7.log`），切换 `PATH=/opt/homebrew/bin:$PATH`（Python 3.14）后才得以继续。
- **修复建议**：
  将 `digest()` 改为使用兼容 Python 3.8+ 的分块读取 `hashlib.sha256()`（每次读取 1 MiB `update`），并在 `package-release.sh --check-only` 中加入对 `release-network.py` 的自检覆盖。

---

## 5. P2 级发现详细报告（18 项）

### [P2] `01-3`：未认证的明文错误或配对要求可永久删除 iPhone 的有效配对令牌
- **位置**：[`ios/iMic/LinkClient.swift:920-938,969-975,1149-1155`](../../ios/iMic/LinkClient.swift)
- **证据与后果**：`LinkClient.handle` 在任何阶段（包括会话已 `ready` 后）都接受 `.json` 明文帧并交由 `handlePlain` 处理；收到明文 `{"t":"error","code":"auth"}` 时无条件调用 `TokenStore.delete(for: macID)`；自动连接模式下收到明文 `hello(status=pair_required)` 也会删除本地令牌。同局域网攻击者无需知道配对码或会话密钥，仅靠广播相同 Bonjour UUID 或注入明文错误帧，即可抹除 iPhone 上已保存的合法 Mac 令牌，迫使用户重新配对（局域网持久拒绝服务，不会泄露音频或绕过认证，故由初报 P1 调整为 P2）。
- **修复建议**：拒绝在 `ready` 状态下处理明文 `.json` 帧；未经过会话密钥认证的 `auth` 拒绝或 `pair_required` 只应将当前候选连接标记为失败并提示需重新配对，不应自动删除钥匙串中已保存的长期令牌（仅在用户主动点击“忘记此电脑”或成功完成新配对覆盖时更新存储）。

### [P2] `01-4`：未配对 BLE 中心可通过单次订阅长期占用唯一 `BLEBridge` 槽位
- **位置**：[`mac/BLEBridge.swift:152-180,326-333`](../../mac/BLEBridge.swift)
- **证据与后果**：`BLEBridge` 在首个 BLE 中心订阅下行特征时立即将 `self.central` 设为该中心，并拒绝后续其他中心的订阅。当该中心不发送有效握手导致 12 秒后 `LinkServer` 关闭回环连接时，`failBridge` 仅设置 `failed = true` 并关闭本地回环套接字，**不清除 `self.central`**（直到该中心主动取消订阅才恢复）。物理邻近的未配对设备只需保持 BLE 订阅不退订，即可使 Mac 的 BLE 兜底通道持续不可用（TCP 链路不受影响，故评为 P2）。
- **修复建议**：在 `failBridge`（如 12 秒握手超时或本地回环被服务端关闭）时将 `failed` 中心加入短期拒绝集并释放 `self.central = nil`，允许其他候选中心订阅并发起新的回环握手。

### [P2] `01-5`：`PairingStore` 撤销配对时吞掉磁盘持久化错误，重启后旧信任会恢复
- **位置**：[`mac/PairingStore.swift:150-166`](../../mac/PairingStore.swift)
- **证据与后果**：`forget(deviceID:)` 与 `forgetAll()` 先修改内存字典，随后调用 `try? save()` 吞掉任何写盘异常并立即调用 `onChange?()` 刷新界面。若因磁盘满、权限变更或只读导致写盘失败，UI 显示设备已移除，但下次启动 App 时仍会从旧 `paired.json` 恢复该设备的配对信任。
- **修复建议**：记录并向上传播 `save()` 错误，写盘失败时弹出明确错误提示，且即使写盘失败也应立即断开对应设备的活动网络连接。

### [P2] `02-2`：持续可发现但无法建立 TCP 的 Mac 会让 BLE 兜底持续饥饿
- **位置**：[`ios/iMic/LinkClient.swift:1233-1246,1363-1385,1396`](../../ios/iMic/LinkClient.swift)
- **证据与后果**：连接失败进入 `scheduleReconnect` 时，TCP 重试安排在 `delay` 秒（上限 8 秒），而 BLE 兜底安排在 `delay + 2` 秒。当目标 Mac 的 Bonjour 广播可见但 TCP 端口被防火墙拒绝或黑洞丢弃时，`delay` 到期后执行 `autoConnect → connectLocked → closeConnectionLocked()`，后者第 1396 行直接调用 `bleFallbackWork?.cancel()` 取消了 2 秒后原本要触发的 BLE 兜底；若初始 3 秒 BLE 定时器到期时 TCP 尚在握手，又因 `self.connection == nil` 守卫（第 1241 行）直接返回。结果导致客户端无限循环重试不通的 TCP，无法切入可用的 BLE 兜底。
- **修复建议**：记录同一目标的连续 TCP 失败次数（例如连续 1～2 次 TCP 握手失败后），在下一轮重试中优先尝试 BLE 兜底，或不在新一轮 TCP 尝试启动时重置已排队的 BLE 回退计时。

### [P2] `02-3`：前台探测从 `ping` 入队时即开始计时，可能误断开正在正常补传音频的会话
- **位置**：[`ios/iMic/LinkClient.swift:400-417`](../../ios/iMic/LinkClient.swift)、[`ios/iMic/BLELinkClient.swift:96-108`](../../ios/iMic/BLELinkClient.swift)
- **证据与后果**：App 从后台回到前台时，`probeForegroundLocked()` 调用 `sendSealed(.ping(stamp))` 后立即启动 1.5 秒（BLE）/ 0.8 秒（TCP）超时定时器。然而 `sendSealed` 将 `ping` 追加在发送队列末尾，必须等待此前排队的音频帧发送完毕后才能发出。若用户在松手提交后（`.transcribing` 阶段不会被后台入口取消）切后台再迅速切回前台，且队列中仍有超过 1.5 秒传输量的积压音频（BLE 实测 18–22 KB/s 下仅需约 30 KB 积压），即使底层正在全速正常上行，前台探测也会判定超时并调用 `restartForegroundLocked`，主动断开连接并清空剩余发送队列。
- **修复建议**：在探测期间若底层仍在持续完成发送写入（uplink bytes 递增）或收到任何下行加密帧，则推迟或视作连接存活；或者通过 `sendSealed` 的发送完成回调从 `ping` 真正写出到传输层后再启动 RTT 计时。

### [P2] `02-4`：iPhone 缺少持续的接收超时检查，持续前台的半开连接无法及时自愈
- **位置**：[`ios/iMic/LinkClient.swift:1113-1127`](../../ios/iMic/LinkClient.swift)、[`mac/LinkServer.swift:400-415`](../../mac/LinkServer.swift)
- **证据与后果**：Mac 端 `LinkServer` 每 15 秒发送 `ping` 并检查 40 秒无接收超时；而 iPhone 端 `LinkClient` 仅被动回复 `pong`，只在从后台返回前台时发起一次 `probeForegroundLocked`，握手完成后没有任何持续接收看门狗。若 iPhone 一直停留在前台期间网络变为静默黑洞（无 RST/FIN），iPhone 会一直显示 `ready`，直到用户下一次录音触发上传/结果超时才会报错重连。
- **修复建议**：在 `LinkClient` 中记录当前连接代际最后一次收到有效帧的时间戳，配合固定周期检查（如超过 40 秒未收到服务器心跳或任何帧时主动发起一次 `ping` 探测，超时未回则走 `connectionLost`）。

### [P2] `02-5`：普通断线的主线程交接期间，手动选机模式下可能被 Bonjour 回调抢先推进 epoch
- **位置**：[`ios/iMic/LinkClient.swift:787-799,1191-1225,1734-1738`](../../ios/iMic/LinkClient.swift)
- **证据与后果**：`connectionLost` 清空 `ready` 与 `connection` 后，通过 `publish` 异步到主线程通知 `self.onLost?()`，再在主线程回调里回到 `queue` 执行 `continueAfterLossLocked`。在主线程尚未执行该闭包的时间窗口内，`browser` 仍在运行且 `reconnectWork` 仍为 `nil`；若处于 `manualSelection == true` 模式，刚断线的目标不会加入 `attemptedThisRound`（第 1199 行），此时若恰好到达一次 `browseResultsChangedHandler` 回调，会立即通过 `autoConnect` 发起重连并调用 `closeConnectionLocked() → invalidateEpoch()` 推进 `transportEpoch`，导致尚在主线程排队的旧 `publish` 闭包因 `currentEpoch() == epoch` 不成立（第 1736 行）被静默丢弃，`SessionModel` 漏收 `onLost`。
- **修复建议**：对齐 PR #32 在 `restartForegroundLocked` 中引入的 `foregroundRestartEpoch` 保护机制，在普通 `connectionLost` 等待主线程完成 `onLost` 交接期间同样设置交接门控，阻止 `autoConnect` 在交接完成前抢先开启新连接。

### [P2] `04-1 / 07-3`：首次麦克风授权等待期间松手不会撤销录音请求（含未接线死代码）
- **位置**：[`ios/iMic/HomeView.swift:726-732`](../../ios/iMic/HomeView.swift)、[`ios/iMic/SessionModel.swift:47,373,399-425,622`](../../ios/iMic/SessionModel.swift)
- **证据与后果**：首次录音尚未决定麦克风权限时，`startHoldToTalk` 先设 `wantsRecording = true` 再异步等待系统权限弹窗，此时 `phase` 仍为 `.idle`。若用户在弹窗期间松手，`HomeView` 的松手回调因 `if session.phase == .listening` 不成立而不调用 `endListening()`，`wantsRecording` 保持为 `true`。一旦授权回调返回且应用处于 `.active` 状态，程序会在用户早已松手的情况下自动启动录音与传输。此外，核查发现 `SessionModel.swift:373` 的 `prepareFirstUsePermissions` 与第 47 行的 `audioAuthorizationTask` 在全仓中从未被赋值或调用，属于死代码。
- **修复建议**：`HomeView` 在松手或触摸取消时只要 `session.phase == .listening || session.isAwaitingPermission`（或无条件在松手时清除 `wantsRecording`）就调用取消逻辑；同时清理或正确接线 `audioAuthorizationTask`。

### [P2] `04-2`：音频引擎冷启动尚未完成就提前发出“可以说话”触感
- **位置**：[`ios/iMic/SessionModel.swift:402,573`](../../ios/iMic/SessionModel.swift)、[`ios/iMic/AudioCapture.swift:73-120`](../../ios/iMic/AudioCapture.swift)
- **证据与后果**：`startAudioEngine()` 将耗时的 `AVAudioSession` 激活、VPIO 配置与 `AVAudioEngine.start()` 异步派发到 `lifecycleQueue` 后便立即返回 `true`；调用方随即执行 `Haptics.shared.play(.recordingStarted)` 给出“可以说话”的触感反馈。在首次录音或 5 秒热麦窗口过期后的冷启动场景下，用户感觉到触感立即开口时硬件采集尚未就绪，句首语音会被截断，与 [`docs/ARCHITECTURE.md:34`](../../docs/ARCHITECTURE.md) 明确承诺的“采集准备好后给开始录音触感”不符。
- **修复建议**：按下瞬间保留轻触反馈（`.press`），将表示“采集已就绪可说话”的 `.recordingStarted` 移至 `AudioCapture` 启动成功回调中（热麦复用路径则在确认引擎已在运行时立即触发）。

### [P2] `05-2`：Secure Input 使按键监视失效后，仍允许键盘兼容模式自动退格与追加
- **位置**：[`mac/InputTarget.swift:268-290,429`](../../mac/InputTarget.swift)、[`mac/main.swift:1139`](../../mac/main.swift)
- **证据与后果**：实时预览与修订依赖 `NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, ...])` 检测用户是否手动按键接管并冻结自动输入。根据 macOS Carbon `IsSecureEventInputEnabled()` 机制，当目标应用开启 Secure Keyboard Entry（如终端开启安全键盘输入，或焦点位于密码框）时，全局键盘监视器不会收到任何按键事件，但 `inputMonitor != nil` 依然为真。此时用户在兼容模式下手动打字或移动光标不会触发 `userIntervened` 冻结，后续识别更新仍会继续发送退格和文本块，打乱用户输入。
- **修复建议**：在 `InputTarget` 捕获焦点、切换兼容模式及每次执行 `insert` 前调用 `IsSecureEventInputEnabled()`（并检查焦点元素的 `AXRole == kAXSecureTextFieldRole` / `AXProtectedContent`）；一旦检测到 Secure Input 开启，禁止实时增量退格修订，仅在会话结束时保留可复制结果或执行一次性安全投递。

### [P2] `07-1`：iPhone 设置面板切换设备绕过会话取消，可把旧目标的离线缓冲录音补发给另一台 Mac
- **位置**：[`ios/iMic/PairingSheet.swift:345`](../../ios/iMic/PairingSheet.swift)、[`ios/iMic/LinkClient.swift:514`](../../ios/iMic/LinkClient.swift)、[`ios/iMic/SessionModel.swift:1087`](../../ios/iMic/SessionModel.swift)
- **证据与后果**：正式设备选择页（`DeviceSelectionView.swift:279,328`）在切换 Mac 前会弹窗确认并调用 `session.cancelForDeviceSwitch()` 清空当前缓冲语音；但设置面板（`PairingSheet.swift:345`）中的附近设备按钮直接调用 `link.connect(to: mac)`，未调用 `cancelForDeviceSwitch()`。若用户在目标 Mac A 离线时录了一段话（处于等待连接补发的缓冲状态），随后打开设置面板点击在线的 Mac B，B 连接就绪后 `handleLinkReady()` 会将原本对 A 录制的语音直接补发并输入到 B 上。
- **修复建议**：统一设置面板与设备页的切换入口，切换前必须经过 `session.cancelForDeviceSwitch()`（或在 `SessionModel` 中将缓冲录音与会话启动时的目标 `macID` 强绑定，目标变更时拒绝跨设备补发）。

### [P2] `08-2`：已完成引导的用户重开向导后关闭窗口，`setup.inProgressStep` 残留导致持续阻塞更新
- **位置**：[`mac/Onboarding.swift:81,266`](../../mac/Onboarding.swift)、[`mac/Updater.swift:139`](../../mac/Updater.swift)
- **证据与后果**：已完成过首次引导的用户通过菜单“重新打开设置向导”时，`Onboarding` 会写入 `setup.inProgressStep`。若用户未走完最后一页“完成”而是直接关闭向导窗口，该键值不会被清除：
  1. 在当次运行会话中，`Updater` 的 `isSetupInProgress` 恒为 `true`，后台自动检查更新被持续跳过；
  2. 重启应用后，启动策略因 `completedVersion` 已存在而直接 `.skip` 不弹出向导，但 `Updater` 仍因 `inProgressStep != nil` 永久阻止自动与手动更新，直到用户再次手动打开向导并点完最后一页。
- **复现验证**：独立编译测试证实重开向导后关闭窗口，`isSetupInProgress` 立即变为 `true` 且重启后 `launchDecision` 为 `.skip` 而更新门控持续返回忙碌阻塞。
- **修复建议**：当 `completedVersion` 已存在（即重开向导场景）时，关闭向导窗口即清除 `setup.inProgressStep`；或者在启动策略决定 `.skip` 时同步清理残留的 `inProgressStep`。

### [P2] `08-5`：Mac 设置页重新生成配对码后界面仍显示已失效的旧码
- **位置**：[`mac/SettingsWindow.swift:284,630`](../../mac/SettingsWindow.swift)、[`mac/main.swift:1284`](../../mac/main.swift)
- **证据与后果**：`SettingsWindowController` 虽然定义了 `refreshPairCode()` 方法（第 630 行），但在全仓中没有任何调用点。用户在设置页点击显示六位配对码后再点击“重新生成”，底层 `PairingStore` 已轮换为新配对码（点击“复制配对码”复制的也是新码），但窗口标签仍显示旧码，用户照着屏幕输入会导致配对失败并累加全局错误次数。
- **修复建议**：在 `refreshUI()` 及“重新生成”按钮回调中调用 `settingsWindow?.refreshPairCode()`。

### [P2] `09-4`：中断发布脚本（Ctrl+C）不会终止已隔离会话的签名或公证子进程
- **位置**：[`tools/release-network.py:44-62,200`](../../tools/release-network.py)
- **证据与后果**：`release-network.py` 使用 `subprocess.Popen(..., start_new_session=True)` 启动 `codesign`、`notarytool` 与 `stapler`，使子进程脱离终端进程组（不会直接收到终端的 `SIGINT`）。代码中仅在 `subprocess.TimeoutExpired` 分支调用了 `os.killpg(proc.pid, signal.SIGTERM)`，而在 `KeyboardInterrupt` 分支未终止子进程组便直接退出。
- **复现验证**：启动模拟子进程并向 `release-network.py` 发送 `SIGINT`，证实父进程退出后子进程变为 `PPID=1` 的孤儿进程继续运行。若遗留的是 `notarytool submit` 或 `stapler`，会在后台偷偷完成公证提交或改写 DMG 字节导致检查点 SHA-256 失配。
- **修复建议**：在 `run()` 的 `except BaseException:`（含 `KeyboardInterrupt`）或 `finally:` 块中，若 `proc.poll() is None` 则对 `proc.pid` 发送 `os.killpg(..., signal.SIGTERM)` 并 `wait()` 回收。

### [P2] `09-5`：`tests/Updater/test_appcast.py` 依赖已失效的仓库初始状态且要求 `build/` 预先存在
- **位置**：[`tests/Updater/test_appcast.py:22,41,44,65`](../../tests/Updater/test_appcast.py)
- **证据与复现**：
  1. 测试在 `setUp()` 中直接复制仓库当前的 `site/appcast.xml`、`VERSION`（`MAC_BUILD=4`）和生产公钥，却断言初始 `appcast.xml` 为空、公钥为全零占位符、并尝试生成 `build=1` 和 `build=2` 的更新（被当前已存在 `build=3` 的单调递增守卫直接拒绝）。实测运行 `python3 -m unittest discover -s tests/Updater` **8 个测试中 5 个失败**。
  2. 此外，`TemporaryDirectory(dir=ROOT / "build")` 假定仓库根目录下已存在 `build/` 目录；在干净检出（无 `build/`）下运行，**8 个测试全部因 `FileNotFoundError` 报错**。
- **修复建议**：在 `setUp()` 中先 `mkdir(parents=True, exist_ok=True)` 创建临时父目录，并用合成的空白 appcast 模板、`MAC_BUILD=1` 及测试专用密钥对初始化夹具，不读取随版本演进的生产 `site/appcast.xml`。

### [P2] `09-6`（发布实测新增）：`notarytool submit` 上传成功但等待响应时客户端连接超时，检查点 `id` 保持 `null`
- **位置**：[`tools/release-network.py:137-190`](../../tools/release-network.py)
- **证据与触发（本次 v1.4.7 发布实测）**：`submit --wait` 将“上传获取 submission ID”与“长轮询等待公证结果”耦合在单次命令中。本次公证期间，DMG 已成功上传且 Apple 服务端已创建任务 `72032ae0-5996-4bbb-8ed8-c6d453070530`，随后 `notarytool` 在等待期间遇到网络抖动报错 `HTTPClientError.connectTimeout` 并以非零退出且未输出 JSON。此时 `release-network.py` 无法从 stdout 解析出 `id`，导致 `.notarization.json` 中 `"id": null`，报错要求人工排障而无法自动转入 `notarytool wait`。
- **修复建议**：将公证拆分为两步：先执行 `xcrun notarytool submit <dmg> --no-wait --output-format json` 立即拿到 `id` 并写入 `.notarization.json` 持久化保存，随后再调用 `notarytool wait <id>` / `info <id>` 轮询状态。这样即便等待期间发生超时或断网，检查点也始终持有确切的 submission ID。

### [P2] `10-1`：App 与共享代码改动缺少仓库内 GitHub Actions CI 保护
- **位置**：[`.github/workflows/pages.yml:3,19`](../../.github/workflows/pages.yml)、[`Package.swift:11`](../../Package.swift)
- **证据与后果**：仓库唯一的 GitHub Actions 工作流仅监听 `site/**` 路径并执行 `tools/check-site.py`。针对 `shared/`、`mac/`、`ios/`、`tools/` 的 PR 不会在 CI 中触发 `swift test`、`check-l10n.py` 或任何离线回归测试。
- **修复建议**：新增 macOS PR 工作流（触发条件覆盖 `push` 与 `pull_request`），自动执行 `swift test`、`python3 tools/check-l10n.py`、`python3 tools/check-site.py` 及无需硬件/TCC 权限的离线单元测试。

### [P2] `10-2`：ASR 回归测试从未调用 `recognizer.append`，音频上传队列与排空期限无测试覆盖
- **位置**：[`tests/ASRStreaming/main.swift:8,63`](../../tests/ASRStreaming/main.swift)、[`mac/ASR.swift:176,227`](../../mac/ASR.swift)
- **证据与后果**：`tests/ASRStreaming/main.swift` 全文没有任何一处调用 `recognizer.append(pcm)`，且替身 `send` 无条件同步回调成功。因此 `BailianASR` 中音频分块排队、单飞发送、队列排空后再发 `finish-task` 以及上传超时与最终识别超时的边界切换完全未被自动化测试覆盖。
- **修复建议**：在 `tests/ASRStreaming` 中扩展可手动释放 `send` 回调的传输替身，覆盖多块音频积压期间调用 `end()`、发送失败及排空后启动最终识别倒计时的用例。

---

## 6. P3 级发现与待定项（21 项）

1. **[P3] `03-2` 换机入口在主线程清理网络队列拥有的可变状态**（[`ios/iMic/LinkClient.swift:514,548,1705`](../../ios/iMic/LinkClient.swift)）：`connect(to:)` 等入口在 `queue.async` 之外调用 `invalidateEpoch()`，无锁修改 `pendingPolishPreferences`、`remoteGestureRevision` 等网络队列属性。虽然新连接 `ready` 时会重新同步租约，仍应将协议状态重置移入 `queue` 串行执行，主线程仅原子递增 `transportEpoch`。
2. **[P3] `03-3 / 06-1` ASR 错误回调形成强引用环导致每轮识别泄漏一个实例**（[`mac/main.swift:710-714`](../../mac/main.swift)、[`mac/ASR.swift:320`](../../mac/ASR.swift)）：`recognizer.onError` 捕获列表仅写了 `[weak self]`，闭包内访问 `recognizer.failureCode` 造成 `recognizer → onError → recognizer` 强引用环。独立复现已证实每次识别结束后 `recognizer` 均无法释放；改为 `[weak self, weak recognizer]` 即可消除。
3. **[P3] `03-4` UI 纹理原地补丁未与在途 GPU 读取同步**（[`ios/iMic/PhosphorCompositor.swift:75,173,184`](../../ios/iMic/PhosphorCompositor.swift)）：`replaceArtwork()` 对 `.shared` 纹理直接调用 `artwork.replace(...)`，而渲染管线最多允许 3 个 command buffer 在途，极端 GPU 负载下可能在同一帧采样到新旧混合图素。建议改用 staging buffer 通过 Blit 编码更新或双缓冲纹理轮换。
4. **[P3] `03-5` 媒体服务重置后旧声音初始化任务可能覆盖新结果**（[`ios/iMic/SoundDesign.swift:37,49,55`](../../ios/iMic/SoundDesign.swift)）：`warmUp()` 的后台 `registerAll()` 完成回调无代际校验，极窄窗口下重置前的旧异步任务晚于重置后的新任务完成时会覆盖 `ids`。建议增加整型 `generation` 校验。
5. **[P3] `04-3` 松手提交未排空 `IMicAudioInputBridge` 异步转换队列**（[`ios/iMic/SessionModel.swift:359,645`](../../ios/iMic/SessionModel.swift)、[`ios/iMic/IMicAudioInputBridge.m:258`](../../ios/iMic/IMicAudioInputBridge.m)）：`endListening()` 立即 flush 主线程缓冲并切至 `.transcribing`，仍在 bridge worker 队列中转换的最后 1～2 个回调块（约 10–30ms）随后到达主线程时会落入 `preRoll` 而非当前录音。
6. **[P3] `04-4` 识别结果返回会将正在运行的 `MIC TEST` 当作热麦关闭**（[`ios/iMic/SessionModel.swift:278,286`](../../ios/iMic/SessionModel.swift)、[`ios/iMic/MicrophoneTestView.swift:32`](../../ios/iMic/MicrophoneTestView.swift)）：录音松手后若在等待结果返回前进入设置打开 `MIC TEST`，当结果返回使 `phase` 变回 `.idle` 时，`updateAudioStandby()` 会在 5 秒后调用 `audio.stop()` 停掉自检正在使用的共享 `AudioCapture`。
7. **[P3] `05-3` 兼容模式长文本同步投递循环内缺少中止检查点**（[`mac/main.swift:1106,1228,1252`](../../mac/main.swift)）：`typeText` 在单次主线程调用中同步循环发送全部退格和 20 字符分块 `CGEvent`（实测 2400 字符约耗时 44ms），期间无法响应异步到达的用户按键或应用切换通知。
8. **[P3] `05-4` 扫光采样提前返回目标输入框，跳过同窗口其他受保护控件检查**（[`mac/TextPolishEffect.swift:935,959,979,1015`](../../mac/TextPolishEffect.swift)）：`inspectWindow` 将目标输入框放在候选队列首位并在命中后立即返回 `allowsCapture: !protectedSeen`，未继续遍历同窗口兄弟节点是否包含密码框或 `AXProtectedContent`，而后续截图采样先截取整个窗口再裁剪。
9. **[P3] `06-2` 超长自定义服务 Key 会写出无法读取的凭据文件并在后续保存时丢失其他凭据**（[`mac/Credentials.swift:44,125,134`](../../mac/Credentials.swift)）：自定义服务 `validToken()` 无长度上限，而 `CredentialFile.read()` 将超过 `64_000` 字节的文件当作空配置返回；已复现证实写入 `64_001` 字符 token 后所有凭据失效，再保存任一正常 Key 会永久清空原有其他服务凭据。建议对 token 增加合理长度上限（如 4096 字节）并在读取超限/损坏时报错而非视作空文件。
10. **[P3] `06-3` 最终识别结果绕过句子连续性检查，缺句仍按成功提交**（[`mac/ASR.swift:281,298`](../../mac/ASR.swift)）：实时阶段通过 `confirmedThrough` 保证句子序号连续，但收到 `task-finished` 时直接将 `results.keys.sorted()` 拼接提交；已复现证实若只收到第 1、3 句而缺失第 2 句，会静默拼成 `"第一句。第三句。"` 当作成功返回。
11. **[P3] `07-4` 上滑取消使用末次 `touchesMoved` 坐标而非 `touchesEnded` 最终坐标**（[`ios/iMic/HoldControl.swift:57,65`](../../ios/iMic/HoldControl.swift)）：快速上滑抬手时，若末次 `touchesMoved` 尚未越过 `-64pt` 而 `touchesEnded` 触点已越过，会因未在 `touchesEnded` 中更新纵向 `translation` 而误判为正常发送。
12. **[P3] `08-3` 菜单或 `Cmd+Q` 退出应用绕过设置窗口草稿保存确认**（[`mac/main.swift:1504`](../../mac/main.swift)、[`mac/SettingsWindow.swift:680`](../../mac/SettingsWindow.swift)）：未保存草稿拦截仅在 `windowShouldClose` 实现，直接退出应用时未通过 `applicationShouldTerminate` 提示保存。
13. **[P3] `08-4` 第二实例发送的分布式重开通知未注册观察者**（[`mac/main.swift:150,1731`](../../mac/main.swift)）：已有实例运行时再次执行 `iMic --show-permissions` 会发送分布式通知并退出，但主实例从未向 `DistributedNotificationCenter` 注册观察者，`reopenFromAnotherInstance` 为死代码。
14. **[P3] `09-2` `package-release.sh` 在 iOS 打包前移走 DMG 但未同步移动 `.notarization.json`**（[`scripts/package-release.sh:165`](../../scripts/package-release.sh)）：若公证钉合成功后 iOS 打包或发布说明检查失败，DMG 已被移至 `build/release/` 而检查点仍在 `build/notarization-pending/`，需手动归位才能恢复。
15. **[P3] `09-3` `testflight-handoff.py` 仅校验已跟踪文件，忽略归档时混入的未跟踪源文件**（[`scripts/testflight.sh:57`](../../scripts/testflight.sh)、[`tools/testflight-handoff.py:66`](../../tools/testflight-handoff.py)）：归档使用 `ditto` 拷贝目录且 XcodeGen 按目录通配收集源码，交接比对应双向检查快照文件集合与 Git 跟踪列表一致。
16. **[P3] `10-3` 输入与润色测试缺少 `AppDelegate` 编排层级的安全回归**（[`tests/PolishEffect/main.swift:448`](../../tests/PolishEffect/main.swift)）：建议补充“用户接管后迟到润色响应仍被冻结”等跨模块编排测试。
17. **[P3] `10-4` 加密测试缺少固定 HKDF 测试向量与逐帧随机 nonce 独立性断言**（[`tests/iMicLinkTests/LinkTests.swift:294`](../../tests/iMicLinkTests/LinkTests.swift)）：建议锁定一组固定密钥派生向量并断言同一明文连续加密两次的密文头部 nonce 不同。
18. **[P3] `10-5` 集成测试默认关闭 BLE，缺少 BLE 分片与背压排空单元测试**（[`scripts/test-ios-reconnect.sh:17`](../../scripts/test-ios-reconnect.sh)）：建议为 `BLELinkClient` / `BLEBridge` 的分片队列与预览帧替换抽取纯内存单测。
19. **[P3] `10-6` `scripts/test-link.sh` 未自动重编或校验 `build/mac.noindex/iMic.app` 是否与当前源码一致**（[`scripts/test-link.sh:39,53`](../../scripts/test-link.sh)）。
20. **[P3] `10-7` `DisplayUITests` 与 `PolishUITests` 硬编码查找中文元素但未固定启动语言 `-AppleLanguages (zh-Hans)`**（[`tests/iOSUI/DisplayUITests.swift:9`](../../tests/iOSUI/DisplayUITests.swift)）。
21. **[待定] `10-8` `tests/LinkResume` 依赖共享且会在 2MB 轮换的生产日志字节偏移**（[`tests/LinkResume/main.swift:127`](../../tests/LinkResume/main.swift)）：若测试期间恰好跨越 2MB 日志轮换或有并行实例写日志，偏移量切片可能失效。

---

## 7. 已核查且未发现问题的安全与工程边界

10 个专项审计线程在审查过程中同时核验了以下关键安全与可靠性机制，确认其实现稳健：

- **密码学原语与密钥派生**：配对与会话采用独立 HKDF 上下文（`info` 分离），令牌严格校验 32 字节；TCP 与 BLE 每次连接均重新生成临时 Curve25519 私钥；`AES.GCM.seal` 每次自动生成随机 96-bit nonce 并校验认证标签，解密失败绝不返回明文。
- **在线配对猜码限速与冷却**：配对失败按 Mac 全局计数，客户端断开重连不会清零计数；触发阈值后自动轮换六位配对码并指数递增冷却时间，冷却期内拒绝解密配对请求。
- **协议帧长度与内存边界**：`LinkFrameDecoder` 严格限制单帧负载在 `1...128 KiB`，音频包校验头部长度与样本数字节数一致性，无整数溢出或越界切片路径。
- **固定目标选机与 iPhone 端删机隔离**：`MacSelection.choose` 与 BLE 白名单严格锁定用户选定的 Mac UUID，离线或失败不会静默跳往其他已配对 Mac；iPhone 删除当前设备会先关闭连接并推进 epoch，删除非当前设备不打断活动链路。
- **云端服务地址与凭据权限隔离**：官方服务严格校验 HTTPS、主机名、端口并拒绝 URL 用户信息/查询串/重定向；自定义 HTTP 仅放行显式回环地址；不同服务间不混用 API Key；`credentials.json` 以 `0600` 权限原子创建并写入，日志对 API Key 与正文脱敏。
- **局部文本修订与原稿保护**：AX 范围修订在替换前核验本轮起点、正文与焦点，一旦尝试写入但结果未知则先回读确认、绝不盲目退格重放；预览阶段绝不全选或覆盖整框 `AXValue`。
- **发布签名链与供应链完整性**：Sparkle 二进制包固定版本与 SHA-256 校验；GitHub Actions 全部第三方 Action 固定完整 commit SHA；Release 打包严格执行由内到外 Developer ID 签名、hardened runtime、公证钉合及 Ed25519 更新包验签；未签名 iOS IPA 打包显式拒绝混入描述文件与签名目录。

---

## 8. 建议修复优先级路线图

### 第一阶段：阻断性协议缺陷、并发崩溃与核心功能死锁（P0 + P1，建议立即修复）
1. **修复 `LinkFrameDecoder.append` 已消费字节未移除问题（`01-1`）**：每次 `offset > 0` 时移除已消费前缀或持久化读取游标，消除分片下控制帧重复执行与配对后断连，并补齐混合分片单测。
2. **串行化 `PairingStore` 状态修改与磁盘保存（`03-1` + `01-5`）**：将 `stored.updatedAt` 更新、JSON 编码与原子文件写入纳入同一锁临界区，并向 UI 反馈写盘错误，彻底消除并发崩溃与已撤销令牌回滚。
3. **补齐 Mac 按设备 ID 断开活动与待认证连接（`01-2 / 02-1`）**：在 `LinkServer` 中记录连接对应的 `deviceID`，`forgetDevice` 时精确断开被移除设备的连接。
4. **加固编辑器宿主内嵌终端换行过滤（`05-1`）**：对可承载内嵌终端的宿主在 AX 焦点元素为 `nil` 时先触发 `AXManualAccessibility` 并默认过滤换行/Tab，防止命令误执行。
5. **修复 VoiceOver `interactionStart` 锁死（`07-2`）** 与 **自定义服务首次保存死锁（`08-1`）**。
6. **替换 `tools/release-network.py` 中的 `hashlib.file_digest`（`09-1`）**：兼容 macOS 系统 Python 3.9。

### 第二阶段：重连可靠性、安全边界与发布自愈（重点 P2）
1. **认证前明文消息不抹除钥匙串令牌（`01-3`）**、**BLE 握手超时释放未认证中心槽位（`01-4`）**。
2. **修复 TCP 重试取消 BLE 兜底定时器（`02-2`）**、**前台探测等待发送完成或统计上行进度（`02-3`）**、**iPhone 前台持续接收存活检查（`02-4`）** 与 **普通断线主线程交接门控（`02-5`）**。
3. **设置面板切换设备接入 `cancelForDeviceSwitch()`（`07-1`）**、**首次麦克风授权松手取消（`04-1 / 07-3`）**、**冷启动就绪后再发开始触感（`04-2`）**。
4. **输入链路增加 `IsSecureEventInputEnabled()` 检查（`05-2`）**、**重开向导关窗清理 `inProgressStep`（`08-2`）**、**设置页重生成配对码刷新 UI（`08-5`）**。
5. **公证脚本拆分 `--no-wait` 先持久化 submission ID 并支持 Ctrl+C 清理子进程组（`09-4`、`09-6`）**，**修复 `tests/Updater/test_appcast.py` 夹具并补齐 PR CI 工作流（`09-5`、`10-1`、`10-2`）**。

### 第三阶段：细节打磨与测试确定性提升（P3）
- 修复 `BailianASR` 错误回调引用环（`03-3 / 06-1`）、任务结束连续性核验（`06-3`）、自定义 Key 长度上限（`06-2`）以及其余 UI/音频/测试脚本边界项。
