# 任务书：iOS 快速切换 Mac

日期：2026-10-30
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 的最新提交新建分支 `codex/ios-quick-mac-switch`。**不要直接在 `codex/ui-phosphor-wireframe` 上提交。**
2. 在新分支上开发、提交，提交说明用简体中文。
3. 推送：`git push -u origin codex/ios-quick-mac-switch`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**，不要选 `main`（`main` 停在 1.4.0）。
5. PR 描述必须附第 7 节规定的**全量测试报告**，没有报告的 PR 不予审核。
6. 由 Claude 审核，**不要自行合并**，不要开自动合并。
7. 不改 `VERSION` 和版本号，不发 Release。
8. 在 `docs/releases/NEXT.md` 的 iPhone 小节（没有就新建）记录本次改动。

> 另一份任务书 `2026-10-30-polish-sweep-follow-resizing-field.md` 可能同时进行，它只改 Mac 端扫光，和本任务的文件不重叠。

---

## 1. 问题

用户反馈：在 iPhone 上切换接收语音的 Mac 需要三步：

1. 点主页顶部的连接状态（`HomeView.swift:415` 附近的按钮，`showDevices = true`）。
2. 在推入的设备页 `DeviceSelectionView` 里点一台 Mac。
3. 手动点返回回到主页。

切换 Mac 是高频操作（公司和家里各一台、同时开着台式机和笔记本），目标是**减少操作、快速切换**。

## 2. 设计方案

### 2.1 主入口：点连接状态弹出快速切换菜单（2 次点击）

- 主页顶部连接状态按钮改为 SwiftUI 原生 `Menu`（点一下就弹出，不需要长按）。菜单内容自上而下：
  1. **已配对的 Mac**：每台一项，显示名称和状态，例如"MacBook Pro · 局域网"、"Mac Studio · 离线"。当前目标打勾（`checkmark`），已连接的排最前，其余按"在线优先、最近连接时间倒序"排列。最近连接时间用 `imic.macLastConnected`，见 `LinkClient` 和 `MacSelection.orderedPaired`。
  2. **附近未配对的 Mac**（如果有）：放在一个分组里，标题为"新的 Mac · 需要配对"。点击后进入设备页，并直接展开该 Mac 的配对码输入（现有的 `PairingSheet(embedded: true)`）。
  3. 分隔线。
  4. **"管理设备…"**：进入现有的设备页。
- 点击一台已配对的 Mac，**立即切换**，菜单自动收起，留在主页。这时：
  - 调用与设备页相同的切换入口：附近的用 `link.connect(to:)`，不在附近的用 `link.selectRememberedMac(_:)`，属于手动选择，见 `LinkClient.manualSelection`。
  - 主页连接状态立刻显示"连接中 · 目标名称"，连上后显示正常状态。
  - 触感用 `Haptics.shared.play(.selection)`，连上后照常播放已有的 `.connected` 事件。不要新增音效，音效方案由另一个会话负责。
- 点击当前已经连着的那台：只收起菜单，什么都不做。
- 菜单只有"管理设备…"一项（没有任何已配对的 Mac）时，点连接状态直接进入设备页，跳过菜单。
- 文案：技术标签用英文像素字风格，操作说明用简体中文（见 AGENTS.md）。系统原生 `Menu` 的条目用系统字体即可，不需要像素字。

### 2.2 设备页：选中已配对的 Mac 后自动返回（2 次点击）

- 在 `DeviceSelectionView` 中点击一台**已配对**的 Mac 后：开始切换，并在下面两种情况先发生的那一刻**自动返回主页**：
  - 连接状态进入 `.connecting` 并持续 0.35 秒，让用户看到"已经在切了"的反馈；
  - 或者直接 `.ready`。
- 点击**未配对**的 Mac：留在设备页，展开配对码输入（现有行为）。配对成功后自动返回主页。
- 用户在等待期间主动操作了页面（滚动、点其他行），就取消这次自动返回，以用户为准。

### 2.3 录音进行中的保护（不能放宽）

- 现在设备页在有进行中的语音时会弹出确认框"取消当前语音并切换 Mac？"（`DeviceSelectionView` 的 `confirmSwitch` / `pendingSelection`）。**菜单切换必须走同一套确认**：录音中、补传中、等待结果时选择另一台 Mac，先弹同样的确认框；用户确认后才切换。
- 把这套判断抽成共用的方法（例如放到 `SessionModel` 或一个小的 `MacSwitchCoordinator` 里），供菜单和设备页共用，不要复制两份。

### 2.4 不做的事

- **不加左右滑动切换**：主页已经有弦手势，左右滑动用于移动光标，会冲突。
- 不新增常驻浮层或弹窗，也不在主页增加新的大按钮。
- 不改自动连接规则（`MacSelection`），不改配对、加密或协议。

## 3. 实现要点

- `HomeView.swift` 顶部连接状态按钮（约 415–436 行），以及 `connectionLabel` 和 `connectionColor`：改成 `Menu`。保留现有的可访问性标签，改为"连接电脑，当前 X，点击切换 Mac"，并给每个菜单项加清晰的 `accessibilityLabel`，例如"MacBook Pro，已配对，局域网可用，当前目标"。
- `Menu` 里的项要由 `link.rememberedMacs`、`link.macs`、`link.pairedMacIDs`、`link.selectedMacID`、`link.phase` 实时生成。菜单打开时如果列表变化，系统会自动刷新，不需要额外处理。
- 进入设备页并直接展开某台 Mac 的配对：给 `DeviceSelectionView` 增加一个可选参数，例如 `pairing: DiscoveredMac?`。
- 自动返回：在 `DeviceSelectionView` 里用 `@Environment(\.dismiss)`，或由 `HomeView` 把 `showDevices` 设为 `false`。注意 `HomeView` 的 `.onChange(of: showDevices)` 里有波形显示的可见性逻辑，返回后要恢复正常。
- `#if DEBUG` 预览：新增 `--ui-preview=devices-multi`，在 `LinkClient` 的 preview 分支里构造 3 台 Mac：已连接的 "MacBook Pro"、在线已配对的 "Mac Studio"、离线已配对的 "Office iMac"，外加 1 台附近未配对的 "Mac mini"。用于截图和 UI 测试。只能在 DEBUG 下生效，`tools/validate-testflight.py` 会检查 Release 包里没有 `--ui-preview=`。

## 4. 测试

### 4.1 UI 测试（新增到 `tests/iOSUI`）

用 `--ui-preview=devices-multi`：

1. 点连接状态弹出菜单，菜单里有 "Mac Studio"，点它 → 仍在主页（"HOLD TO SPEAK" 可见），连接状态显示 Mac Studio。**全程 2 次点击。**
2. 菜单点"管理设备…" → 进入设备页（"LINK" 标题可见）。
3. 菜单点未配对的 "Mac mini" → 进入设备页，并且配对码输入框可见。
4. 设备页点 "Mac Studio" → 自动回到主页。
5. 预览中模拟录音进行中（可加 `--ui-preview=devices-multi-recording`），菜单点另一台 Mac → 出现确认框"取消当前语音并切换 Mac？"；点"继续当前语音"后，目标不变。

每个用例 `XCTAttachment` 截图，`lifetime = .keepAlways`。

### 4.2 已知问题

`DisplayUITests/testRecordingTouchPassesThroughMetalAndResultRemainsUsable` 在改动前就失败（按住 0.8 秒后没有出现"录音太短"），是**既有失败**。不要放宽它的断言；在报告中注明即可。如果你的改动意外让它通过或产生了新的失败，要写清楚。

## 5. 硬性约束

- 不修改协议（`shared/iMicLink.swift`、`docs/PROTOCOL.md`、`mac/LinkServer.swift`）。
- 不修改 Mac 端代码。
- 配对和安全底线不放宽：不自动配对、不跳过配对码。
- 录音中切换必须经过确认（2.3）。
- `--ui-preview=*`、`--debug-*` 只在 DEBUG 下生效。
- 不提交 `.claude/`、`build/` 下的产物。

## 6. 视觉

- 菜单使用系统原生样式，深色外观下跟随系统，不自绘浮层。
- 主页连接状态在"连接中"时，小方块颜色沿用现有 `connectionColor` 的逻辑；橙色只用于状态和强调（AGENTS.md）。
- 截图：主页菜单展开、设备页自动返回前后，各一张，放在 `build/ux-shots/quick-switch/`，PR 里附路径和结论。

## 7. 全量测试（PR 必须附报告）

依次执行以下全部命令，每条记录：通过或失败、耗时、关键输出（失败时附最后 20 行）。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
./scripts/test-ios-mac-selection.sh
./scripts/test-ios-reconnect.sh
./scripts/test-polish-link.sh
./scripts/test-screen-idle.sh
./scripts/test-polish-effect.sh
./scripts/test-polish.sh
./scripts/test-mac-settings.sh
./scripts/test-input.sh
./scripts/test-clear-input.sh
./scripts/build-mac.sh
./scripts/build-ios.sh
# iOS UI 测试（模拟器）
xcodebuild test -project ios/iMic.xcodeproj -scheme iMic \
  -destination 'platform=iOS Simulator,name=<可用的 iPhone 模拟器>' \
  -derivedDataPath build/ios-uitest.noindex \
  -resultBundlePath build/ios-uitest.noindex/quick-switch.xcresult
# Release 包不含调试入口
./scripts/testflight.sh archive-unsigned   # 若默认输出目录已存在，用 IMIC_TESTFLIGHT_DIR 指定新目录
./scripts/testflight.sh check
```

如果某条命令因环境原因无法执行，**如实写明原因**，不要写成"通过"。改动前就失败的测试，先在干净的 `codex/ui-phosphor-wireframe` 上复现，并标注为"既有失败"。

### PR 描述模板

```markdown
## 改动
- …（每个文件一句话）

## 规格对照
- 2.1 快速切换菜单：…
- 2.2 设备页自动返回：…
- 2.3 录音中确认：…
- 偏离之处及原因：…

## 操作步数对比
| 场景 | 改动前 | 改动后 |
|---|---|---|
| 切到另一台已配对的 Mac | 3 | 2（菜单） |
| 在设备页选择已配对的 Mac | 3 | 2（自动返回） |

## 全量测试报告
| 命令 | 结果 | 耗时 | 备注 |
|---|---|---|---|
| … | | | |

## UI 测试
- xcresult 路径：…
- 新增用例 1–5：…
- 既有失败：testRecordingTouchPassesThroughMetalAndResultRemainsUsable（改动前已失败）

## 截图
- build/ux-shots/quick-switch/…

## 需要用户真机手测
- 两台都已配对的 Mac 在线时，从菜单切换，确认 1 秒内连上
- 录音中切换会弹出确认框

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## 8. 遇到以下情况时停下来说明

- SwiftUI `Menu` 和主页的 Metal 显示层或弦手势冲突，导致点击无法触发或手势被吞。附复现步骤，并给出替代方案，例如改用 `confirmationDialog` 或小型 popover。
- 切换需要修改 `LinkClient` 的连接状态机，而不仅仅是调用现有入口。
- 测试中发现与本任务无关的失败：标注为既有失败即可，不要顺手修。
