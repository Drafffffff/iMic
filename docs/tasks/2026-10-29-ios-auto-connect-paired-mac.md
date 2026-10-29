# 任务书：iOS 启动时自动连接"可用的已配对 Mac"

日期：2026-10-29
仓库：`/Users/drafff/Desktop/iMic`
执行者：Codex
请先完整阅读本文件和仓库根目录的 `AGENTS.md`，再动手。

---

## 1. 问题

用户反馈：iPhone 端每次打开 iMic，都只会去连"上一次选过的那台 Mac"，而不是去连"当前可用的已配对 Mac"。

典型场景：用户配对过公司的 Mac A 和家里的 Mac B，上次用的是 A。回到家打开 iMic，A 不在线、B 就在同一 Wi-Fi 下且已配对，但 App 一直停在"所选 Mac 离线或尚未发现，正在等待连接"，必须手动进入设备列表切换到 B。

## 2. 根因（已在代码中确认）

`ios/iMic/LinkClient.swift`：

```swift
// 537 行
private func autoConnect(_ discovered: [DiscoveredMac]) {
    guard !ready, connection == nil, !usingBLE else { return }
    if let preferred = preferredMacID {
        if let match = discovered.first(where: { $0.id == preferred }) {
            connectLocked(to: match)
        }
        return            // ← 记住的 Mac 不在场就直接 return，其他已配对 Mac 永远不会被考虑
    }
    if discovered.count == 1 { connectLocked(to: discovered[0]) }
}
```

相关的几处也都只认 `preferredMacID`：

- `restartForegroundLocked`（约 325 行）：`discoveredMacs.first(where: { $0.id == preferredMacID }) ?? lastMac ?? directMac`
- `reconnectUsingNetwork`（约 379 行）：只找 `preferredMacID`
- `startBLELocked`（962 行）：蓝牙后备只接受 `preferredMacID`。`BLELinkClient.start(targetMacID:)` 读到 Mac 身份后，只要不匹配就拒绝（`BLELinkClient.swift:301`）。
- `preferredMacID` 来自 `UserDefaults` 的 `imic.preferredMacID`，由 `rememberTarget(id:name:)`（1419 行）写入：手动选择或认证成功时都会写。

配对令牌按 Mac 存放：`TokenStore.load(for: macID)`。`pairedMacIDs` 是发现列表和记忆列表中有令牌的 Mac 的集合。

## 3. 目标行为（规格）

### 3.1 自动选择规则

启动、回到前台、断线重连时，按下面的顺序选择要连接的 Mac：

1. **上次连接的 Mac**（`preferredMacID`）在局域网中被发现，并且本机有它的令牌 → 连它。
2. 否则，在**已被发现、且本机有令牌**的 Mac 里，选**最近一次成功连接**的那台。
3. 否则，如果**本机一台已配对的 Mac 都没有**，并且局域网里**只发现一台** Mac → 连它，进入配对流程（这是现有行为，保留）。
4. 其他情况不自动连接，界面显示设备列表或"正在搜索"。

明确禁止：

- **只要本机有任何已配对的 Mac，就绝不自动连接未配对的 Mac**，否则会突然弹出配对码输入，让用户困惑。
- 已经连上某台 Mac 之后，就算"更优先"的 Mac 后来出现，也**不自动切换**。不打断正在使用的连接，尤其不能打断录音、补传、等待结果中的会话（参照 `activeLinkSession`）。
- 用户在设备列表里手动选择（`connect(to:)` / `selectRememberedMac`）后，就按用户的选择来。手动选择的 Mac 不在线时，**不要**在同一次前台期间又自动跳到别的 Mac。用户选了谁就等谁，直到下一次冷启动或回到前台时，才重新执行 3.1 规则。

### 3.2 等待窗口（避免抢跑）

Bonjour 的结果是陆续到达的。如果第一批结果里只有 B，就立刻连 B，那么 A 在 200ms 后才出现时就晚了，会选错。

- 当 `preferredMacID` 有值、但还没被发现时，开一个**宽限窗口**，从浏览器启动算起 **1.5 秒**，做成一个常量，便于调整。窗口内只要发现了 preferred，就立即连接；窗口结束仍未发现，再按 3.1 第 2 步回退。
- 如果 `preferredMacID` 为空，或者 preferred 已经没有令牌，就不等待，直接按第 2 步选。
- 宽限窗口必须和现有的 `scheduleBLEFallback(after: 3)` 协调：网络回退选中了别的 Mac 并开始连接后，`hasConnectedNetwork` 和 `connection != nil` 会阻止蓝牙抢占，确认这条路径成立。

### 3.3 "最近一次成功连接"的记录

- 新增 `UserDefaults` 键 `imic.macLastConnected`，类型 `[String: Double]`（macID → `Date().timeIntervalSince1970`）。
- 在**认证成功、链路进入 ready** 时写入，就在调用 `rememberTarget` 的同一处（约 691 行附近，状态为 `auth` 或 `paired` 并成功的分支，请找准位置）。仅 TCP 连接成功但没通过认证时**不写**。
- `forgetMac()` 删除某台 Mac 时，同步删掉它在这个字典里的记录。
- 自动回退连上另一台 Mac 并认证成功后，照常调用 `rememberTarget`，让它成为新的 `preferredMacID`。这和"上次用的是谁"的含义一致。

### 3.4 回退连接失败时

- 回退目标连接失败（`.failed`、握手超时）时，在本轮内把它标记为已尝试，再试下一个候选（按最近连接时间排序）。所有候选都试过后，回到"正在搜索"，等待下一次 Bonjour 变化或重连计时。
- 不要在两台 Mac 之间无限快速来回重试，沿用现有的 `reconnectAttempts` 退避机制。
- 令牌被 Mac 拒绝（Mac 端已解除配对）时，沿用现有的 `forcePair` 和 `reconnectAfterReset` 逻辑。但这台 Mac 现在等于未配对，按 3.1 的禁止规则，**不要**因为它自动进入配对，而是继续找下一个已配对的候选；如果是用户手动选的这台，则保持现有行为。

### 3.5 蓝牙后备

- 现状：蓝牙只认 `preferredMacID`。
- 目标：网络上找不到任何已配对 Mac、触发蓝牙后备时，蓝牙接受**任意一台本机有令牌的 Mac**，按 preferred 优先、再按最近连接时间排序。
- 做法建议：`BLELinkClient.start(targetMacID:)` 改为 `start(acceptedMacIDs: [String])`，按顺序表示优先级。读到身份后，只要在集合里就接受，并通过新回调或已有回调把**实际连上的 macID** 交给 `LinkClient`，由它设置 `currentMacID` 和 `currentMacName`（名字从 `knownNames` 取）。之后的 hello/auth 必须使用这台 Mac 的令牌（`sendHello` 用的是 `currentMacID`，务必确认顺序正确）。
- 扫描时同时发现多台候选的情况：现有实现是"第一个通过身份校验的就用"。可以接受这一点，不必为了优先级再等待。
- 安全底线不变：**蓝牙绝不连接本机没有令牌的 Mac**（保留 964 行那句注释的原则）。
- 如果这一部分改动牵扯太大（例如 `BLELinkClient` 的状态机需要大改），可以先只完成网络部分，蓝牙保持只认 preferred，并在汇报里说明，作为后续任务。

### 3.6 界面反馈

- 自动回退连上另一台 Mac 时，用户必须能看出来连的是哪台。现有 `phase` 是 `.connecting(name)` 和 `.ready(name)`，名字会显示，确认首页能看到。
- 在 `DeviceSelectionView.swift:137` 附近，"所选 Mac 离线或尚未发现，正在等待连接"这条文案只适用于"用户手动选择、正在等待"的情况。自动模式下没有任何可用的已配对 Mac 时，改成"正在寻找已配对的 Mac"之类的说法。文案用简体中文，技术标签维持英文像素字的风格（参照 AGENTS.md）。
- 不新增弹窗。

## 4. 实现建议

### 4.1 把"选择"写成纯函数，放进 `shared/`，用单元测试覆盖

新建 `shared/MacSelection.swift`（**不要**写进 `shared/iMicLink.swift`。这不是协议内容，不触发 AGENTS.md 的四处同步规则）：

```swift
public struct MacCandidate: Equatable {
    public let id: String
    public let paired: Bool          // 本机有令牌
    public let lastConnected: Double? // imic.macLastConnected
}

public enum MacSelection {
    public static let preferredGrace: TimeInterval = 1.5

    /// 返回应自动连接的 macID；nil 表示不自动连接。
    /// - discovered: 当前局域网发现的 Mac（已合并去重）
    /// - preferredID: imic.preferredMacID
    /// - graceExpired: 宽限窗口是否已结束
    /// - hasAnyPairedMac: 本机是否存在任何有令牌的 Mac（不论是否在线）
    /// - excluded: 本轮已尝试失败的 macID
    /// - manualSelection: 当前是否是用户手动指定且仍在等待
    public static func choose(discovered: [MacCandidate], preferredID: String?,
                              graceExpired: Bool, hasAnyPairedMac: Bool,
                              excluded: Set<String>, manualSelection: Bool) -> String?
}
```

`LinkClient.autoConnect`、`restartForegroundLocked`、`reconnectUsingNetwork` 都改为调用它，统一行为。因为 `shared/` 也会编进 iOS 工程（`ios/project.yml` 已包含 `../shared`），iOS 侧可以直接使用；Mac 构建不需要这个文件，`build-mac.sh` 按显式文件列表编译，不用改。

> 如果 `Package.swift` 的 `iMicLink` target 把整个 `shared/` 编进去，新文件会自动被 `swift test` 覆盖。请确认 `public` 修饰符和现有 shared 文件的风格保持一致（现有文件如果没用 `public`，测试是用 `@testable import` 访问的，照现有方式写即可）。

### 4.2 单元测试 `tests/iMicLinkTests/MacSelectionTests.swift`

至少覆盖：

1. preferred 在线且已配对 → 选 preferred（不管宽限窗口）。
2. preferred 不在线，宽限窗口**未结束** → nil。
3. preferred 不在线，宽限窗口已结束，B 和 C 都已配对且在线，C 最近连接过 → 选 C。
4. preferred 不在线，宽限窗口已结束，在线的只有**未配对**的 D，且 `hasAnyPairedMac == true` → nil（禁止自动配对）。
5. 没有任何配对，在线只有一台 D → 选 D。
6. 没有任何配对，在线有两台未配对 → nil。
7. preferredID 为 nil，B 已配对且在线 → 立即选 B（不需等待）。
8. `excluded` 包含 C → 跳过 C，选下一个。
9. `manualSelection == true` 且所选 Mac 不在线 → nil（不自动跳走）。
10. preferred 在线但**没有令牌**（已被解除配对），另有已配对 B 在线 → 选 B。
11. `lastConnected` 都为 nil 的已配对候选 → 结果稳定（例如按 id 排序），不能随机。

### 4.3 `LinkClient` 改动要点

- 新增状态：`graceDeadline`（或用 `DispatchWorkItem` 到点后重新评估一次 `autoConnect(discoveredMacs)`）、`attemptedThisRound: Set<String>`、`manualSelection: Bool`。
- 什么时候重置：`start()`、`activate()` 走 `restartForegroundLocked` 时、`forgetMac()` 时，重置宽限窗口和 `attemptedThisRound`，并把 `manualSelection` 设为 false。`connect(to:)` 和 `selectRememberedMac` 把 `manualSelection` 设为 true。认证成功后清空 `attemptedThisRound`。
- 所有状态只在 `queue` 上读写，遵守现有的线程约定（`*Locked` 后缀方法都在 `queue` 上执行）。UI 发布走 `publish {}`。
- 只改选择逻辑，不改帧格式、握手、加密、`TokenStore` 存储格式。
- 日志：沿用 `IMicLog.write("iphone.link", …)`。在选择处打一行，例如 `auto select chosen=<id|-> reason=<preferred|recent|single_unpaired|none|grace> candidates=<n>`，方便用 `scripts/pull-ios-log.sh` 排查。**日志里不得出现令牌。**

## 5. 硬性约束

- 不修改协议：`shared/iMicLink.swift`、`docs/PROTOCOL.md`、`mac/LinkServer.swift` 的帧格式、密钥派生、配对码规则都不动（AGENTS.md）。
- 配对和安全底线不放宽：不自动批准配对，不跳过配对码，蓝牙不连接未配对的 Mac。
- `--debug-*` 参数只在 DEBUG 下生效；`directMac`（`--debug-host`）路径的行为保持不变。
- 不修改 Mac 端代码。
- 不修改版本号。
- 不提交 `.claude/`。

## 6. 验证

```bash
# 1. 单元测试（含新增 MacSelectionTests）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# 2. 现有重连回归（直连路径，确认没被破坏）
./scripts/test-ios-reconnect.sh

# 3. iOS 构建
./scripts/build-ios.sh

# 4. UI 预览不受影响
xcrun simctl launch --terminate-running-process booted <iOS bundle id> --ui-preview=idle
xcrun simctl launch --terminate-running-process booted <iOS bundle id> --ui-preview=pairing
```

> iOS Bundle ID 可能正在从 `com.drafffffff.imic` 迁移到 `art.malette.imic`（另一份任务书）。以 `ios/project.yml` 里的当前值为准。

**手动场景**：需要真机和两台 Mac，无法在本机自动化。请在汇报里列出建议的手测步骤，供用户执行：

1. 两台 Mac 都已配对，上次用 A。关掉 A 的 iMic，冷启动 iPhone App → 约 1.5 秒后自动连上 B，首页显示 B 的名字。
2. A 和 B 都在线，上次用 A → 连 A（即使 B 先被发现）。
3. 只配对过 A，A 不在线，局域网里有未配对的 C → 不自动连 C，不弹配对码。
4. 全新安装，没有任何配对，局域网只有 C → 自动连 C，进入配对。
5. 连着 B 时打开 A → 不自动切换。
6. 在设备列表手动选 A（离线）→ 一直等 A，不跳回 B；把 App 切到后台再回来 → 重新按自动规则选择。
7. 关闭 Wi-Fi，打开蓝牙后备，上次用 A、A 不在附近、B 在附近且已配对 → 通过蓝牙连上 B（如果 3.5 已实现）。

## 7. 提交

- 一次提交，提交说明用简体中文，例如"iOS 启动时自动连接可用的已配对 Mac"。正文简述规则和宽限窗口。
- 本任务书一并提交。
- **不要 push。**
- 提交前 `git status`，不夹带无关改动，不碰用户自己未提交的文件。

## 8. 遇到以下情况时停下来报告

- 发现选择逻辑还散落在 `SessionModel.swift` 等别处，并且会和新规则冲突。
- 蓝牙改动需要改 Mac 端 `BLEBridge.swift`，或者需要改协议。
- `test-ios-reconnect.sh` 在你改动前就已经失败。请先在干净的工作区确认是否为既有问题。

## 9. 交付汇报

1. 改动文件清单，每个一句话。
2. 选择规则的最终实现说明，如有偏离本规格，说明原因。
3. 第 6 节每一步的结果。
4. 3.5 蓝牙部分是否完成。
5. 给用户的手测清单。
6. 提交哈希。
