# iOS 快速切换 Mac：测试与实现报告

## 范围与基线

- 基线：`origin/codex/ui-phosphor-wireframe`，`a8363e9bb898077046d05d92592aeb64a90104eb`，已 fetch 核实。
- 分支：`codex/ios-quick-mac-switch`，独立 worktree，不在原目录切分支。
- 未修改 Mac、协议、版本号或签名配置；未安装或覆盖公证版，不发布 Release。
- `LinkClient` 的正式路径只增加最近连接时间的只读 UI 快照；手动选机仍调用现有 `connect(to:)` / `selectRememberedMac(_:)`。新模拟状态完全位于 DEBUG 预览分支。

## 规格对照

- 主入口使用原生 `Menu`，固定条目顺序，已连接优先，其余在线优先并复用 `MacSelection.orderedPaired` 的最近连接排序。当前目标勾选；附近新 Mac 单独分组，管理入口保留。
- 已配对目标点选后留在主页；没有可选设备时直接进入管理页。当前已连接目标为无操作，不取消语音。
- 两个入口共用 `MacSwitchCoordinator` 的会话保护、确认文案和手动连接分派。录音、等待结果或补传期间，确认前不取消语音、不连接新目标。
- `MacSwitchReturn` 只允许同一目标连续 connecting 满 0.35 秒后返回；ready 即返回。滚动、改选、重试、失败或离开会取消旧计时；未配对目标等待真正 ready。
- 菜单中的新 Mac 进入设备页现有 `PairingSheet(embedded: true)`，不自动配对、不绕过配对码。
- HomeView 返回后恢复波形可见性；原生入口及 Metal 展示层使用相同的向下箭头。

## 操作步数

| 场景 | 改动前 | 改动后 |
|---|---|---|
| 切到另一台已配对 Mac | 3 | 2（菜单，留在主页） |
| 在设备页选择在线已配对 Mac | 3 | 2（自动返回） |

## 全量命令报告

日志位于本 worktree 的 `build/quick-switch-checks/`，不提交构建产物。

| 命令 | 结果 | 耗时（秒） | 日志 |
|---|---|---:|---|
| `swift test` | 通过 | 14.33 | `01.log` |
| `./scripts/test-ios-mac-selection.sh` | 通过 | 25.06 | `02.log` |
| `./scripts/test-ios-reconnect.sh` | 通过 | 19.36 | `03.log` |
| `./scripts/test-polish-link.sh` | 通过 | 10.65 | `04.log` |
| `./scripts/test-screen-idle.sh` | 通过 | 4.31 | `05.log` |
| `./scripts/test-polish-effect.sh` | 通过 | 8.93 | `06.log` |
| `./scripts/test-polish.sh` | 通过 | 2.41 | `07.log` |
| `./scripts/test-mac-settings.sh` | 通过 | 20.82 | `08.log` |
| `./scripts/test-input.sh` | 通过 | 1.77 | `09.log` |
| `./scripts/test-clear-input.sh` | 通过 | 3.14 | `10.log` |
| `./scripts/build-mac.sh` | 通过 | 30.04 | `11.log` |
| `./scripts/build-ios.sh` | 通过 | 9.81 | `12.log` |
| `xcodebuild test …` | 待执行：用户暂停前台测试 | — | — |
| `./scripts/testflight.sh archive-unsigned` | 初次预检通过；最终版归档复验待执行 | — | `14.log`（预检） |
| `./scripts/testflight.sh check` | 待最终版归档复验 | — | — |

额外检查：`./scripts/test-ios-quick-mac-switch.sh` 通过。直接编译正式协调器、返回计时器和菜单模型；仅替换连接／会话／触感的边界对象，不模拟协议或放宽认证。覆盖：

- 录音、等待结果、补传的确认与取消；确认仅执行一次；当前已连接目标无操作；离线目标走已记住入口。
- 已连接／在线／最近使用排序，未配对过滤，当前目标勾选，以及 Bonjour 消失时健康 TCP／BLE 的状态。
- 0.35 秒计时、用户取消、连接失败、配对成功立即返回及目标身份隔离。

## UI 与干净基线复现

按照最新的前台协调要求，UI 测试暂未启动，也未把任务书中记载的失败冒充为已在本地复现。

干净基线来自 `git archive a8363e9bb898077046d05d92592aeb64a90104eb`，保存于 `build/quick-switch-clean-base/`；其 iOS build 与 build-for-testing 已通过。前台恢复后先执行该基线 UI 套件，复现已知失败，再运行本分支全量 UI 套件。

新增 `QuickMacSwitchUITests` 共七项：两次点击留在主页、管理设备、新 Mac 嵌入配对、设备页自动返回、录音中取消切换、离线目标、录音中点击当前目标无操作。每项都保留截图附件。既有 `DisplayUITests` 仅调整“管理设备”导航路径；不修改已知录音失败的断言。

## 截图

待 UI 测试生成；将导出到 `build/ux-shots/quick-switch/`，不提交这些构建产物。

## 真机手测边界

- 仍需两台已配对且在线的真实 Mac，验证实际无线环境下一秒内连上；DEBUG 模拟器的 0.6 秒完成仅为可重复 UI 预览，不是性能测量。
- 仍需真实录音／补传时切换并确认或取消，验证实体设备与实际网络上的体验。
- Release 归档只用于排除调试入口，未签名、未分发，不替换已安装的公证版。
