# 构建、发布与供应链 审计

## 范围与方法

读取了 `AGENTS.md`，重点审查指定构建、签名、打包及 TestFlight 脚本，发布相关 Python/Swift 工具、Pages workflow、`Package.swift`，并对照发布文档及现有回归测试排除已知边界。

执行了只读搜索、39 个 shell 脚本的逐文件 `bash -n`、13 个 Python 工具的 Python 3.9 语法检查及标准库 API 检查。系统 Python 实测为 **3.9.6**。未运行构建或测试，未访问网络，未修改仓库及系统状态。以下发布路径通过静态控制流核对。

## 发现

### [P1] 系统 Python 3.9 仍会阻断正式公证及恢复

- 位置：`tools/release-network.py:39`、`tools/release-network.py:78`、`scripts/package-release.sh:154`
- 证据：`digest()` 直接调用 `hashlib.file_digest()`；新建公证任务时，构造函数立即通过 `save()` 调用它。当前 `/usr/bin/python3` 实测不存在该 API。
- 触发条件：发布脚本的 `python3` 解析到系统 Python 3.9，执行正式发布或恢复公证。
- 后果：抛出 `AttributeError`，新发布在提交公证前退出，恢复流程也无法继续。`--check-only` 不经过该调用，不能提前发现问题。
- 建议修复：将 `digest()` 改为分块读取并调用 `hashlib.sha256().update()`，兼容系统 Python；增加针对最低支持版本的检查。
- 置信度：高。除这一处外，所审工具未发现其他明确的 Python 3.11+ 标准库依赖；语法均兼容 3.9。

### [P2] DMG 提前移走，后续失败时无法直接恢复公证流程

- 位置：`scripts/package-release.sh:165`、`scripts/package-release.sh:168`、`tools/release-network.py:67`、`tools/release-network.py:73`
- 证据：脚本先将 DMG 从待恢复目录 `mv` 到输出目录，再执行 iOS 打包及 appcast 更新；`.notarization.json` 没有随之移动。恢复时却固定从传入 DMG 的同目录读取该检查点。
- 触发条件：公证及 Sparkle 签名成功后，iOS 打包失败，例如缺少 XcodeGen、编译失败；或随后发现缺少发布说明。
- 后果：旧位置只剩检查点，输出目录只剩 DMG。使用任一位置直接执行文档中的恢复命令，都会因缺少 DMG 或检查点失败，需要人工重新配套文件。
- 建议修复：全部后续步骤成功前保留待恢复 DMG，向输出目录复制；或将 DMG 与检查点作为一组移动，并更新检查点路径和恢复提示。
- 置信度：高。

### [P2] TestFlight 源码比对会忽略实际参与归档的未跟踪文件

- 位置：`scripts/testflight.sh:57`、`ios/project.yml:25`、`tools/testflight-handoff.py:40`、`tools/testflight-handoff.py:66`
- 证据：归档时 `ditto` 复制整个源码目录，XcodeGen 按目录收集源文件；交接时忽略未跟踪状态，且仅在快照路径存在于已跟踪源码集合中时比较内容：
  ```python
  if 'Source/' + name in entries and snapshot.read(item) != entries['Source/' + name]:
  ```
- 触发条件：归档前在 `ios/iMic/` 放入一个未跟踪、能编译的 Swift 文件；归档后删除它，保持已跟踪文件不变，再执行 `handoff`。
- 后果：该文件已参与二进制构建，却不会出现在交接源码中，也不会触发不一致错误。交接包仍记录当前提交号，违反文档“归档和源码使用相同提交版本”的保证。
- 建议修复：从明确的 Git 提交生成归档源码；或对参与构建的路径集合及内容进行双向比对，拒绝快照中无法解释的额外源文件和资源。
- 置信度：高。

### [P2] 中断发布不会终止已隔离的签名或公证子进程

- 位置：`tools/release-network.py:44`、`tools/release-network.py:49`、`tools/release-network.py:200`
- 证据：子进程使用 `start_new_session=True`，脱离终端信号组；仅 `TimeoutExpired` 分支执行 `killpg()`。`KeyboardInterrupt` 路径只输出恢复信息并退出，没有终止和回收子进程。
- 触发条件：`codesign`、`notarytool` 或 `stapler` 正在运行时按 Ctrl+C。
- 后果：父流程退出时，不能保证子进程已经停止，发布操作可能在后台继续。[推测] 若遗留的 `stapler` 继续改写 DMG，会使未更新的检查点哈希失配，阻止恢复。
- 建议修复：在 `run()` 的异常退出路径终止并回收整个子进程组，同时处理 SIGTERM；涉及 DMG 修改的操作应在子进程结束后保存最终检查点。
- 置信度：中；进程清理缺口明确，DMG 后果未动态复现。

### [P2] 更新回归测试依赖已失效的仓库初始状态

- 位置：`tests/Updater/test_appcast.py:22`、`tests/Updater/test_appcast.py:41`、`tests/Updater/test_appcast.py:44`、`tests/Updater/test_appcast.py:65`
- 证据：测试复制真实 appcast、公钥及构建号，却断言 feed 为空、公钥为占位值，并尝试从构建号 1 开始更新。当前 feed 已包含构建号 **3、2**，公钥为有效的 32 字节值，`MAC_BUILD` 为 **4**。
- 触发条件：按 `docs/RELEASING.md:54` 执行更新回归测试。
- 后果：空 feed 断言必然失败；占位公钥测试实际会通过发布预检；从构建号 1 开始的更新被递增守卫拒绝，多项测试无法验证其目标行为。
- 建议修复：在 `setUp()` 中创建独立的空 appcast、明确的占位公钥和固定构建号，避免复制随发布变化的生产数据。
- 置信度：高；根据当前夹具与断言静态确认，未执行该测试。

## 已检查且未发现问题的方面

- **依赖完整性**：Sparkle 固定版本及 SHA-256，校验后才解压，并重新提取工具和框架；`Package.swift` 无远程依赖。
- **Actions 固定**：现有 workflow 的四个直接 action 均固定完整提交 SHA；没有 PR 触发的发布路径，也未发现显式注入秘密。
- **签名要求**：正式发布要求指定团队、Developer ID 和公证配置；网络重试没有降级到无时间戳签名，嵌套代码按由内到外顺序签名。
- **更新产物一致性**：正常成功路径对 staple 后的最终 DMG 签署 Ed25519，并使用仓库公钥独立验签；appcast 替换前会验证临时 XML。
- **iOS 身份隔离**：真机入口调用共享团队守卫，App 与 UI 测试 ID 同源派生；模拟器禁用签名，公开未签名 IPA 会拒绝描述文件及签名目录。
- **秘密处理**：所审发布路径使用钥匙串配置名称，不直接传递凭据；未发现 `set -x`、环境变量整体输出或明确将私钥写入公开产物的代码。