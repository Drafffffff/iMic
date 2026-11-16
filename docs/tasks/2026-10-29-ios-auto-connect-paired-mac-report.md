# iOS 自动连接已配对 Mac：交付记录

日期：2026-10-29。分支：`codex/ios-auto-connect-paired-mac`，基于已提交的 `43a2297`（1.4.3）。执行目录为独立工作区 `/Users/drafff/.codex/worktrees/imic-1-4-release/iMic`。原目录中正在进行的 TestFlight／Bundle ID 迁移未纳入本次提交，未修改其未提交文件。

## 文件清单

| 文件 | 改动 |
| --- | --- |
| `shared/MacSelection.swift` | 统一设备选择纯函数、1.5 秒宽限常量及已配对优先序。 |
| `ios/iMic/LinkClient.swift` | 将启动、前台恢复、失败重连和网络切换接入统一规则，记录 ready 时间、限制手动等待并按候选重试。 |
| `ios/iMic/BLELinkClient.swift` | 仅接受已配对身份白名单，并在收取 Link 数据前回传实际 Mac ID。 |
| `ios/iMic/DeviceSelectionView.swift` | 将手动等待与自动寻找已配对 Mac 的提示区分开。 |
| `tests/iMicLinkTests/MacSelectionTests.swift` | 11 组单元测试，覆盖任务书要求的选择规则及 BLE 白名单优先序。 |
| `tests/LinkSelection/ClientHarness.swift` | 仅在测试临时源文件中提供发现输入，不向生产构建加入测试入口。 |
| `tests/LinkSelection/main.swift` | 使用生产 LinkClient／LinkServer、真实 TCP 和加密认证测试多 Mac 选择及失败路径。 |
| `scripts/test-ios-mac-selection.sh` | 编译并运行上述集成回归，结束时清理临时文件。 |
| `scripts/test-ios-reconnect.sh` | 显式源文件列表加入 MacSelection，保留现有直连回归。 |
| `scripts/test-polish-link.sh` | 显式源文件列表加入 MacSelection，保留润色设置链路回归。 |
| `tests/LinkResume/main.swift` | 测试结束时也恢复新增的连接时间偏好，避免污染环境。 |
| `tests/PolishLink/main.swift` | 测试结束时也恢复新增的连接时间偏好。 |
| `docs/tasks/2026-10-29-ios-auto-connect-paired-mac.md` | 原任务书原样纳入本次提交。 |
| `docs/tasks/2026-10-29-ios-auto-connect-paired-mac-report.md` | 本交付记录、验证结果及真机验收清单。 |

## 最终规则

- 自动模式优先选择本机有令牌、且当前发现的 preferred；若 preferred 尚未发现且仍有令牌，从本轮浏览启动起最多等 1.5 秒。
- 宽限后从当前发现且有令牌的 Mac 中选择最近一次成功连接者；时间缺失或相同时按 ID 稳定排序。没有 preferred 或其令牌已丢失时立即选择，不等待。
- 只有本机没有任何已配对 Mac、且当前只发现一台时，才自动进入首次配对；仍需用户输入正确的六位配对码。
- 手动选择锁定当前前台期间的目标；离线就等这台，返回前台或冷启动后恢复自动规则。已经 ready 的连接不会因发现结果改变而切换；录音、补传及等待结果的链路会话继续保留。
- 每轮失败后跳过已尝试的目标；全部失败才由现有 `reconnectAttempts` 退避开启下一轮，Bonjour 更新不能绕过待执行的退避。
- `pair_required` 和 `auth` 拒绝均处理过期令牌；自动模式不弹配对，继续选择其他已配对 Mac，并在本次前台期间阻止被拒绝目标自动转入首次配对。手动选择及 DEBUG 直连保留原先的重新配对行为。
- 仅在通过加密认证、收到 `ready` 后更新 `imic.macLastConnected` 和自动 preferred；未认证的 hello、TCP 连通和失败握手不会更新成功记录。忘记 Mac 时删除相应时间记录。
- 握手身份校验继续要求服务端 ID 与本次实际选择的目标一致；不会为了切换目标而放宽身份校验、配对码或加密要求。
- `hasConnectedNetwork` 和非空 `connection` 都能阻止 BLE 定时后备抢占已开始的网络连接。
- 首页现有 `.connecting(name)`／`.ready(name)` 会显示实际目标名字，没有新增弹窗。

纯函数较建议签名多一个 `preferredIsPaired` 参数：preferred 离线时，无法从发现列表推断其令牌是否存在；传入此信息才能准确区分“需等待”与“令牌已丢失，无需等待”。这不改变任务规格。

## 蓝牙

3.5 已实现，无需修改 Mac BLEBridge 或协议。LinkClient 按 preferred、最近成功时间、ID 生成已配对列表；BLE 对读到的身份做白名单检查，通过通知订阅回调将实际 Mac ID 送回 LinkClient，再设置 `currentMacID`／名字并调用 `sendHello`。因此令牌取自实际连接的 Mac，而非旧 preferred。

按任务书允许的取舍，实际采用扫描中第一台通过身份校验的已配对 Mac，不为多个无线候选增加等待窗口。蓝牙无线扫描和两台物理 Mac 的切换仍需真机验收；自动化覆盖了共享优先序、白名单生成规则、代码编译及网络侧真实认证，未模拟 CoreBluetooth 无线链路。

## 验证

| 验证项 | 结果 |
| --- | --- |
| 修改前、干净 `43a2297` 上的 `test-ios-reconnect.sh` | 通过，未触发任务书第 8 节的既有失败停止条件。 |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | 64 项通过，0 失败，包含新增 MacSelectionTests。 |
| 修改后的 `./scripts/test-ios-reconnect.sh` | 通过：健康连接保持、静默黑洞替换、保留本地录音、前台绕过退避及旧任务取消。 |
| `./scripts/build-ios.sh` | 通过，Debug iOS Simulator arm64／x86_64 构建成功。 |
| idle／pairing UI 预览 | 通过；独立 iPhone 18 Pro／iOS 27.0 模拟器启动并截图复核，首页显示 READY，配对页显示六位输入及数字键盘。 |
| `./scripts/test-ios-mac-selection.sh` | 10 组集成场景通过；发现输入由测试夹具提供，TCP、握手、令牌和加密均走生产实现。 |
| `./scripts/test-polish-link.sh` | 通过，润色设置及能力协商没有回归。 |
| `git diff --check` 与受限文件检查 | 通过；无 Mac 端、协议文件、版本号或 `.claude/` 改动。 |

多目标集成场景：1.5 秒宽限和最近连接回退；preferred 延后 200ms 仍获优先；候选连接失败后继续；端点冒认其他 Mac 身份被拒绝；候选耗尽进入退避；Mac 已撤销配对的回退；错误令牌认证被拒绝的回退；手动离线等待／前台解锁／忘记记录；存在离线配对时不连接陌生 Mac；全新安装唯一候选仍需显式配对。

本分支的当前 Bundle ID 为 `com.drafffffff.imic`，版本保持 `1.4.3`；未引入原目录未提交的 `art.malette.imic` 迁移。预览截图位于 `build/auto-connect-review/idle.png` 和 `pairing.png`。原共享模拟器正在被另一线程使用，因此预览改用临时隔离模拟器。

## 双 Mac 真机验收清单

以下需要 iPhone 和两台实际 Mac，尚未替用户执行：

1. A、B 均已配对，上次用 A；关闭 A 的 iMic，冷启动手机 App：浏览宽限结束后应自动连 B，首页显示 B 的名字。
2. A、B 均在线，上次用 A：即使 B 先被发现，1.5 秒内出现的 A 仍应优先。
3. 只配对 A，A 离线，附近只有未配对 C：不连 C，不弹配对码。
4. 全新安装且没有任何配对，附近只有 C：连接 C 后要求六位配对码，正确提交后才 ready。
5. 正连接 B 时启动 A：不切换；尤其在录音、补传、等待结果期间保持 B。
6. 在设备列表手动选离线 A：持续等待 A，不跳回 B；切后台再回来后可按自动规则连 B。
7. 关闭 Wi-Fi、启用蓝牙后备；preferred A 不在附近、已配对 B 在附近：应通过蓝牙连接 B 并显示 B 的名字。

所有改动在一次中文提交中保存，不 push，不创建 Release，也不安装到物理手机。
