# iOS 前后台断联、Mac 改名 VoxChord、Mac 文本历史：调查与验证

日期：2026-11-23。分支 `claude/reconnect-rename-history`，基线 `origin/main`（`dfc1783`）。

## 1. iOS 切后台再回前台后断联

### 现象

后台一段时间回到前台后，iPhone 一直停在“搜索中”，只有从后台划掉 App 重开才恢复。之前的 #32 / #39 修复了六种前台恢复时序，但没有覆盖下面这条路径。

### 根因

`LinkClient` 用 `foregroundRestartEpoch` 标记“丢失通知正在交给主线程”。在此期间：

1. `activate()`（回到前台）一看到该标记就 **直接 return**，只清掉 `backgroundAt`。前台恢复（重建 Bonjour 发现器、重置本轮选择、`restartForegroundLocked`）被整体丢弃，之后也不会补做。
2. 交接完成后走普通断线路径 `continueAfterLossLocked → scheduleReconnect`。退避任务只在 `browser == nil` 时新建发现器，否则只拿缓存的 `discoveredMacs` 调 `autoConnect`。挂起前创建的 `NWBrowser` 在挂起/网络切换后可能不再回调（#39 已确认），缓存也可能为空。这时 `autoConnect` 一无所获；该链路又不会再安排下一次重试（只等发现器回调），状态机永久停住。只有冷启动会新建发现器，与“只能杀进程”的现象一致。

触发条件就是真实挂起后的常见时序：挂起期间 Mac 因 40 秒心跳超时关闭 socket（Mac 日志中多次出现 `close connection notify=true active=true phase=ready`，紧接着 iPhone 很久之后才以新端口重连）。恢复时，死 socket 的回调先于 `scenePhase == .active` 进入链路队列，于是 `connectionLost` 先设置标记，随后 `activate()` 被吞掉。

### 修复

- `activate()` 在交接期间不再丢弃前台信号，改为记录 `foregroundResumePending`。`connectionLost` / `bleLost` 的交接完成后，如有挂起的前台信号，执行与直接回前台相同的 `restartForegroundLocked`（重建发现器与传输，保留手动配对目标）。`restartForegroundLocked` 自身完成时清除该标记；`closeConnectionLocked`（用户手动换机等）也会清除。
- 重连退避在发现器为空、未处于 `.ready` 或没有任何结果时重建发现器，不再永久依赖挂起前的实例。

未改动协议、帧格式、密钥派生、配对码规则、Mac 选择策略和 Mac 端 `LinkServer` 的连接语义（Mac 端已能让通过认证的新候选替换旧连接，日志也表明它会主动关掉旧连接，不存在“占着旧连接”的问题）。

### 证据

`tests/LinkResumeLifecycle` 新增两条回归，直接驱动生产 `LinkClient` 私有队列，两端都使用真实 `LinkServer`、真实令牌认证和 AES-GCM：

- **断线交接期间回到前台**：先在链路队列处理死 socket 的 `connectionLost`，再处理 `activate()`，此时主线程尚未消费丢失通知；发现器换成永不回调的实例。要求 8 秒内重新认证、换新 socket、换掉旧发现器，且丢失回调只触发一次。
- **静默发现器下的退避**：前台运行中断线，发现器同样永不回调。要求退避能重建发现器并重连。

| 源码 | 结果 |
|---|---|
| `origin/main` 的 `LinkClient.swift` + 新回归 | 7/9，两条新回归均 `Timed out`（卡在搜索） |
| 本分支 | 9/9 |

复现：

```bash
git show origin/main:ios/iMic/LinkClient.swift > /tmp/baseline-LinkClient.swift
IMIC_LINK_CLIENT_SOURCE=/tmp/baseline-LinkClient.swift ./scripts/test-ios-foreground-lifecycle.sh   # 7/9
./scripts/test-ios-foreground-lifecycle.sh                                                          # 9/9
```

### 边界

回归模拟的是挂起恢复后的回调顺序与“失效发现器”，没有模拟真实的 iOS 进程冻结、真实多网卡或 CoreBluetooth。模拟器没有挂起冻结和蓝牙，`--debug-host` 直连路径也不走 Bonjour，无法复现这个问题，因此用的是上述进程内生产代码回归。仍建议真机复验：后台 1–5 分钟（超过 Mac 40 秒心跳）后返回，应在约 1–2 秒内重新显示已连接，无需重开 App。

## 2. Mac 用户可见名称统一为 VoxChord

`CFBundleName` / `CFBundleDisplayName`、菜单、界面文案和中英文 `Localizable.strings` 已经是 VoxChord（`check-l10n` 无旧名）。仍显示旧名的地方已修改：

- 构建产物 `build/mac.noindex/iMic.app` 改为 `VoxChord.app`（Finder 与「应用程序」文件夹按文件名显示），并删除旧名产物。
- `install-mac.sh` 安装到 `/Applications/VoxChord.app`。如存在 Bundle ID 相同的旧 `/Applications/iMic.app`，先备份到 `~/Library/Application Support/iMic/backups/` 再替换；Bundle ID 不同的同名应用不会被动。
- 发布 DMG 改为 `VoxChord-<版本>-macOS-universal.dmg`，卷名为 `VoxChord <版本>`，包内为 `VoxChord.app`；`tools/appcast.py` 的下载地址同步。官网按后缀 `macOS-universal.dmg` 匹配，不受影响。
- Bonjour 实例名 `iMic · <Mac>` 改为 `VoxChord · <Mac>`（已上架的 iOS 1.4.9 两种前缀都会去掉）；BLE 广播名改为 `VoxChord · BLE`（iPhone 按服务 UUID 扫描，不看名称）。
- 脚本提示、开发/发布/隐私文档相应更新。

未改动：Bundle ID `com.drafffffff.imic`、可执行文件名 `iMic`（避免影响单实例锁、pkill 匹配与 Sparkle）、`_imic._tcp` 服务类型、HKDF info、支持目录 `~/Library/Application Support/iMic`、内部类型与错误域。Sparkle 原地更新会保留用户现有的 `iMic.app` 路径，因此老用户的文件名要等重新安装后才会变；这符合 Sparkle 的默认行为，界面显示名早已是 VoxChord。

## 3. Mac 文本历史

- `mac/TextHistoryStore.swift`：只追加的 JSON Lines，写入 `~/Library/Application Support/iMic/history.jsonl`，目录权限 0700、文件权限 0600；不联网、不同步、不设上限。每条记录：时间（毫秒 ISO 8601）、目标应用名与 Bundle ID、原始识别、最终文字、润色模式/语气/输出语言/是否回退、结果（已输入 / 未输入已保留 / 已中断）。遇到损坏的行只跳过该行；删除前会重新读盘，不会用过期缓存覆盖文件。
- 记录时机：`completeSession` 确定是否已输入之后记录一次（重试投递只会到这里一次）；`abortSession` 记录中断前已识别的文字，这正是最容易丢字的情况。`--headless` 不写入；`--ui-preview=history` 使用临时目录和示例数据。
- `mac/TextHistoryWindow.swift`：菜单「文本历史…」（⌘Y）和主窗口左下角都能打开。左侧是列表（时间 · 应用；未输入的条目用橙点标出），右侧是详情（元信息、最终文字、原始识别，可分别复制，⌘C 复制最终文字），另有搜索（多词同时匹配，忽略大小写、全半角和变音符）、删除单条、清空全部（需二次确认）。
- 新增 25 条中英文文案，按项目规则写入 `ios/iMic/Localizable.xcstrings` 并生成 Mac `.strings`。

## 测试结果

见 PR 描述中的完整表格。日志在本 worktree 的 `build/reconnect/`，不提交。
