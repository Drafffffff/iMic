# 测试覆盖与可维护性 审计

## 范围与方法

读取了 `AGENTS.md`，核对了 `Package.swift`、全部工作流、19 个 `scripts/test-*.sh`、SwiftPM 测试及主要回归 harness，并追踪协议、ASR、重连、输入修订、润色与更新相关生产代码。交叉检查了 `docs/DEVELOPMENT.md`、`docs/PROTOCOL.md` 和已有验证报告。

验证结果：

- 已运行指定命令：
  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/imic-audit-tests
  ```
  **未能执行测试**：环境拒绝创建 `/tmp/xcrun_db-*`，随后 SwiftPM 获取编译器信息失败，退出码为 1。不能据此判断测试通过或失败。
- 静态统计：SwiftPM 包含 4 个测试文件、77 个测试方法。
- 19 个测试脚本均通过 `bash -n`；两个 Python 回归文件均通过 AST 解析。
- 未执行会联网、写钥匙串、安装 App 或操作输入目标的 harness。

以下均为 **P2 测试保护或确定性问题**；没有据此认定生产功能已发生故障。

## 发现

### [P2] App 改动没有仓库内 CI 测试保护

- 位置：`.github/workflows/pages.yml:3`、`.github/workflows/pages.yml:19`、`Package.swift:11`
- 证据：仓库仅有官网部署工作流，按官网路径触发，只运行 `tools/check-site.py`；没有 `pull_request` 测试任务。SwiftPM 也仅包含 `shared/`。
- 触发条件：提交协议、Mac、iOS 或回归测试改动。
- 后果：仓库工作流不会编译这些改动，也不会执行现有协议、凭据、输入、重连及发布回归测试；官网任务成功不能提供 App 验证证据。
- 建议修复：增加 macOS PR 工作流，运行 SwiftPM 和无需真实设备、云端、权限的测试；将 GUI、硬件及真实 API 验证保留为独立任务。
- 置信度：高。

### [P2] ASR 回归测试没有发送音频，上传队列与排空期限完全未被覆盖

- 位置：`tests/ASRStreaming/main.swift:8`、`tests/ASRStreaming/main.swift:63`、`mac/ASR.swift:176`、`mac/ASR.swift:227`
- 证据：替身 `send` 无条件同步调用 `completion(nil)`；整个测试文件没有调用 `recognizer.append`。现有用例主要注入识别事件，再直接结束任务。
- 触发条件：修改 PCM 分批发送、积压队列、上传错误处理或 `finish-task` 时序。
- 后果：音频发送分支没有进入，无法检测丢块、乱序、提前发送 `finish-task`，以及把最终识别期限提前算入上传时间的回归。
- 建议修复：替身记录音频并允许手动释放发送 completion；测试多块积压、排空期间 `end()`、发送失败、取消后的迟到 completion，并断言 `finish-task` 仅发送一次、最终期限在其发送完成后启动。
- 置信度：高。

### [P2] 输入与润色测试验证了局部状态机，缺少生产业务编排的安全回归

- 位置：`tests/PolishEffect/main.swift:448`、`tests/InputRange/main.swift:74`、`mac/main.swift:854`、`mac/main.swift:942`、`mac/main.swift:1093`
- 证据：名为 `testTimeoutWinsOverLateResponse` 的测试直接依次调用 `PolishFinalChoice.settle`；输入测试主要调用范围匹配和事务辅助逻辑。实际期限、会话隔离、接管冻结、最终输入及结果发送由 `AppDelegate` 串联；联调脚本使用 `--no-input`。
- 触发条件：修改润色超时、最终回写、输入重试或取消清理的调用顺序。
- 后果：现有局部测试不能验证“接管后最终回写仍被冻结”“超时与迟到响应竞争只提交一次”“旧会话回调不影响新会话”等跨模块约束。生产守卫存在，但这些组合行为缺少自动断言。
- 建议修复：给会话编排注入时钟、润色客户端及输入投递接口；覆盖接管后返回结果、超时后迟到成功、取消后新会话、AX 等待期间切换应用，断言投递次数、保留文本及结果状态。
- 置信度：高。

### [P2] 加密测试只验证同版往返，未锁定密钥派生兼容性与逐帧 nonce 独立性

- 位置：`tests/iMicLinkTests/LinkTests.swift:294`、`tests/iMicLinkTests/LinkTests.swift:330`、`shared/iMicLink.swift:504`、`shared/iMicLink.swift:542`
- 证据：两端都调用当前 `pairingCipher`／`sessionCipher`，再验证解密；没有固定派生向量，也没有重复加密同一明文的 nonce 检查。
- 触发条件：误改 HKDF 的 salt、info、输出长度，或向 `AES.GCM.seal` 引入固定 nonce。
- 后果：静态可确认，这些往返断言无法区分“两端共同改变派生规则”；固定 nonce 也不会破坏现有往返和篡改测试。测试无法保护旧版互通及项目明确要求的逐帧随机 nonce。
- 建议修复：增加固定私钥、配对码和令牌的派生向量；使用独立 CryptoKit 调用校验 combined 格式，并重复加密同一明文，检查 nonce 不重复。
- 置信度：高。

### [P2] TCP 集成测试明确关闭 BLE，分片与背压逻辑没有行为测试

- 位置：`scripts/test-ios-reconnect.sh:17`、`ios/iMic/BLELinkClient.swift:112`、`mac/BLEBridge.swift:245`、`mac/BLEBridge.swift:267`
- 证据：重连、选择和润色链路 harness 使用 `--debug-no-ble-fallback`；测试中没有驱动 BLE 写入确认、可发送通知或订阅背压。生产 BLE 层则维护分片偏移、队列、预览替换和关闭前排空状态。
- 触发条件：修改 MTU 分片、ACK 后续传、队列合并或断线清理。
- 后果：TCP 测试通过不能验证 BLE 的字节完整性，也不能验证结果帧遇到背压并紧随连接关闭时仍被排空。
- 建议修复：抽取可注入的 BLE 队列／分片逻辑，测试小 MTU、暂停后恢复、控制帧分片确认、已发送预览不可替换，以及末帧排空后才关闭。
- 置信度：高。

### [P2] `test-link.sh` 可以测试旧 Mac 二进制并报告当前代码验证成功

- 位置：`scripts/test-link.sh:39`、`scripts/test-link.sh:53`、`scripts/test-link.sh:79`
- 证据：脚本重新编译客户端，但直接启动现存的 `build/mac.noindex/iMic.app`；没有构建 Mac 或核验产物对应源码。通过条件是客户端成功收到非空结果。
- 触发条件：修改 Mac 源码后，未重新构建就运行脚本，或 `IMIC_BUILD_DIR` 指向旧产物。
- 后果：Mac 改动实际未参与执行，脚本仍可能输出 `PASS`，形成错误的回归验证证据。
- 建议修复：默认构建待测 Mac 产物；允许显式跳过构建时，校验并输出源码指纹与产物身份，拒绝不匹配产物。
- 置信度：高。

### [P2] 部分 UI 测试硬编码中文，却没有固定启动语言

- 位置：`tests/iOSUI/DisplayUITests.swift:9`、`tests/iOSUI/PolishUITests.swift:8`、`shared/Localization.swift:7`、`ios/project.yml:51`
- 证据：启动参数只有预览模式，随后查找“设置”“关闭”“已选择”等中文；产品跟随系统语言，工程测试配置没有统一语言覆盖。
- 触发条件：在英语或其他非中文系统的模拟器上运行这些测试。
- 后果：应用正确显示英文，测试仍因找不到中文元素而失败，结果依赖运行机器语言。
- 建议修复：启动时显式传入 `-AppleLanguages (zh-Hans)` 和 locale；行为定位优先使用稳定 accessibility identifier，文案另做中英文参数化断言。
- 置信度：高。

### [P2] 练习模式回归依赖共享且会轮换的生产日志

- 位置：`tests/LinkResume/main.swift:127`、`tests/LinkResume/main.swift:155`、`shared/IMicLog.swift:14`、`shared/IMicLog.swift:37`
- 证据：测试记录生产日志的字节偏移，45 秒后读取同一路径并 `dropFirst(logOffset)`，搜索 `timeout` 和七类拦截记录；日志超过 2 MB 会被移走重建。
- 触发条件：测试期间发生日志轮换，或并行运行的 Mac App 向同一文件写入含 `timeout` 的记录。
- 后果：轮换会令原偏移失效，拦截记录可能已进入归档文件；其他进程记录也会触发失败。正确的练习隔离行为因此可能被误报。
- 建议修复：允许注入每次测试独立的日志目录或内存 sink；通过明确的队列屏障等待日志完成，按测试会话收集事件。
- 置信度：高。

## 已检查且未发现问题的方面

- **协议边界已有实质断言**：覆盖逐字节拆帧、多帧合并、超长帧、未知类型、损坏音频及消息字段兼容性。
- **配对基础保护已有测试**：错误配对码、篡改密文、ASCII 六位码、限速升级与冷却封顶均有断言；限速测试使用固定时间。
- **选择与重连测试并非空壳**：生产 TCP 两端通过代理模拟黑洞与迟到回复，检查认证、目标身份、删除设备后的持久化行为。
- **输入局部事务保护较扎实**：覆盖 UTF-16、emoji、原稿归属、失败后恢复，以及“写入生效但报告失败时不能重放”。
- **凭据校验可离线验证**：使用 `URLProtocol` 替身、独立临时目录和随机 defaults 域，覆盖地址边界、重定向、凭据隔离与错误脱敏。
- **未发现 XCTest harness 永远成功的出口**：检查的脚本化 XCTest 入口验证执行数量大于零，并按失败数返回非零退出码。
- **更新已有分层验证**：appcast／构建号、公证重试使用独立回归；设置测试检查真实忙碌门，另有本地 Sparkle 安装及篡改拒绝的历史验证报告。
- **文件规模本身不列为缺陷**：`LinkClient.swift` 1932 行、`main.swift` 1755 行、`TextPolishEffect.swift` 1709 行；项目已抽出多项可测试策略，问题主要在剩余异步编排的覆盖。