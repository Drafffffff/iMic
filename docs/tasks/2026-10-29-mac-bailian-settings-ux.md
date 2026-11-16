# 任务书：Mac 端统一百炼 + 设置页重构 + 体验优化

日期：2026-10-29
仓库：`/Users/drafff/Desktop/iMic`
执行者：Codex
请先完整阅读本文件、仓库根目录的 `AGENTS.md` 和 `docs/design/2026-10-28-mac-onboarding.md`（上一轮首次设置向导的设计），再动手。

本任务分三个阶段，**每个阶段单独提交**，前一阶段验证通过后再进入下一阶段：

| 阶段 | 内容 | 优先级 |
|---|---|---|
| A | 统一百炼：一个 Key 搞定识别和润色，默认启用 | 必须 |
| B | 设置窗口按分页重构，统一保存方式 | 必须 |
| C | 体验设计走查发现的其他问题 | P0 必须，P1 建议，P2 可选 |

---

## 0. 开工前需要用户确认的决策

下面这一点 Codex **不要自行决定**。如果用户没有在任务里写明答案，就按"默认"执行，并在汇报里写明采用了默认。

**D1 · 百炼默认润色模型**
现状：来源是百炼，但模型是 `deepseek-v4.1-flash`，界面标题叫"百炼 DeepSeek"，用户看到的是 DeepSeek 字样，感觉"默认不是百炼"。

- **默认**：模型保持 `deepseek-v4.1-flash`（在百炼上调用，已调过提示词，结果稳定）。界面一律叫"百炼"，模型名只在「高级」里显示。
- 备选：改用百炼的通义千问 flash 系列模型。必须先用用户的 Key 调 `GET https://dashscope.aliyuncs.com/compatible-mode/v1/models`（参照 `BailianKeyCheck`），确认模型名真实存在；再用 `./scripts/test-polish.sh` 和第 A.6 节的提示词回归，跑完全部模式（Agent 指令、终端命令、文言文、废话文学、翻译腔）× 4 种语言，确认终端命令模式仍然只输出单行。**禁止凭记忆写模型名。**

---

## 1. 现状（已在代码中确认）

### 1.1 服务与 Key

- `mac/DeepSeek.swift`：`PolishProvider` 有 `deepseek`、`bailian`、`custom` 三种，标题分别是"DeepSeek 官方""百炼 DeepSeek""自定义"。`provider(in:)` 的默认值已经是 `.bailian`。
- `DeepSeekConfiguration.migrateDefaultProvider`（第 43 行，在 `main.swift:176` 调用）：老安装如果从未保存过来源，而本机能读到 DeepSeek Key（包括 shell 里的 `DEEPSEEK_API_KEY`），就会**被固定成 DeepSeek 官方**。这是"默认不是百炼"的一条来源。
- **AI 润色默认关闭**：`DeepSeekConfiguration` 第 48 行和 `Interface.swift:609` 的 `deepseekEnabled` 默认值都是 `false`。用户填好百炼 Key 后，只能用到识别，润色要自己去设置里找开关。这和"一个 Key 解决所有"的承诺不符。
- `MicCredentials`（`Credentials.swift:238`）：百炼 Key 同时用于识别和百炼润色，存放在 `~/Library/Application Support/iMic/credentials.json`。
- 识别模型固定为 `qwen-audio-3.1-asr-flash-message`（`ASR.swift:4`）。`saveSettings` 要求模型字段必须**等于**这个值，否则拒绝保存（`main.swift:1478`）。也就是说，设置里的"识别模型"输入框只是摆设，填别的都会报错。
- 首次设置向导（`Onboarding.swift`）只有两步：`01 PERMISSIONS`、`02 API KEY`。Key 这一步只验证百炼 Key，不涉及润色。

### 1.2 设置窗口（`Interface.swift` 的 `buildSettings()`，第 533–803 行）

- 窗口固定 500×640，不能调整大小，所有内容放在**一列长滚动**里：GENERAL（Key、输入、iPhone 设备）→ AI POLISH（开关、模式、语气、语言、服务来源、Key、模型与地址）→ ADVANCED（蓝牙兜底、弦手势、扫光、识别模型和地址）→ 底部"保存"按钮。
- **两套保存方式并存**：复选框、分段控件即时生效（`toggleXxx`、`changePolishOptions`），而 Key、服务地址、来源切换要点底部的"保存"才生效（`saveSettings`）。切换来源时提示"来源切换将在保存后生效"。用户无法判断哪些改了已经生效、哪些还没生效。
- 润色区里，"服务来源"下拉框之后，又跟着一个 Key 输入框。选中百炼时这个输入框是灰的，提示"请在上方修改"，造成困惑。
- 橙色使用过多：所有复选框（`checkbox()` 里的 `contentTintColor = .imicOrange`）、所有链接按钮、分组标题都是橙色。AGENTS.md 规定"橙色只用于状态、交互与强调"，现在橙色太多，已经没有强调效果。
- 说明文字时隐时现：长说明被放进 tooltip，又另写一份短说明（`previewShort`），同一含义有两份文案。
- 权限状态分散在各处：辅助功能写在 INPUT 里，屏幕录制在 ADVANCED → POLISH SWEEP 里，蓝牙在 CONNECTION 里。

### 1.3 主窗口与菜单栏

- 每次启动都会 `show()` 主窗口（`main.swift` 的 `applicationDidFinishLaunching`），即使已经完成设置。菜单栏常驻应用每次开机都弹窗，会打扰用户。
- 没有"登录时启动"选项（代码里没有 `SMAppService`）。
- 主窗口在"等待 iPhone 连接"时，只有顶部一张配对码卡片，下面一大片空白（已用 `--ui-preview=settings` 截图确认）。即使已经配对过 iPhone，也照样把配对码作为主角展示。
- 菜单栏菜单：打开 iMic、设置向导…、复制配对码、重新生成配对码、设置…、退出。高频操作（润色开关、切换模式、查看连接状态）都不在菜单里，低频的配对操作反而占了两项。

---

## 阶段 A：统一百炼（必须）

### A.1 默认来源永远是百炼

- 修改 `migrateDefaultProvider`：从未保存过来源的安装，一律写入 `bailian`，**不再因为读到 DeepSeek Key 就固定成 DeepSeek**。理由：识别本来就必须有百炼 Key，所以凡是能用 iMic 的人都有百炼 Key。
- 用户**明确选过**的来源（`polishProvider` 已有值）保持不变，不迁移，不覆盖。
- 同步修改 `tests/PolishProviders/main.swift` 里的 `testNewInstallsDefaultToBailianPolish`：新增断言 `migrateDefaultProvider(hasDeepSeekKey: { true })` 在未选择过来源时，结果也是 `bailian`。

### A.2 有百炼 Key 时默认启用润色

- `deepseekEnabled` 的默认值改为：**当前能解析到百炼 Key 时为开启**。只改"没有存过值时"的默认值，用户明确关过的保持关闭。
- 注意 `deepseekEnabled` 会同步给 iPhone（`LinkPolishPreferences`，见 `main.swift:382` 附近的 `applyPolishPreferences`），iPhone 端设置页能远程开关。默认值变化后，确认 Mac 首次连上 iPhone 时，推送的是正确的开启状态。**协议和帧格式不改。**
- UserDefaults 的键名（`deepseekEnabled`、`deepseekStrength`、`polishProvider`、`polish.bailian.model` 等）**全部保留**，不重命名。重命名就得写迁移，收益不大。界面文案可以随意改。

### A.3 向导的 Key 步骤顺带启用润色

在 `Onboarding.swift` 的 `02 API KEY` 步骤，Key 验证通过后，增加一行：

- 复选框"同时启用 AI 润色（推荐）"，默认勾选。说明写一行："同一个百炼 Key，识别后自动整理口语、去重复。可随时在设置中关闭。"
- 不在向导里放模式、语气、语言选择，保持两步就完成。
- 用 `--ui-preview=setup-key` 和 `--ui-preview=setup-key-detected` 截图确认排版。

### A.4 界面文案统一

- `PolishProvider.title`：`bailian` 改为"百炼（推荐）"，`deepseek` 改为"DeepSeek 官方 API"，`custom` 改为"自定义 OpenAI 兼容服务"。
- 所有"百炼 DeepSeek"字样改为"百炼"，涉及界面和 README 第 202 行附近。模型名只在高级区域显示，例如"模型：deepseek-v4.1-flash（在百炼上运行）"。
- 设置和向导里关于 Key 的说明统一为一句："一个百炼 Key 同时用于语音识别和 AI 润色。"

### A.5 识别模型不再是可编辑字段

- 识别模型只有一个合法值，所以把输入框改为**只读文本**，显示 `qwen-audio-3.1-asr-flash-message`。`saveSettings` 里对模型字段的校验随之删除，`asrModel` 仍然写入固定值，以兼容 `ASRConfiguration.current`。
- 识别服务地址（`wss://…/api-ws/v1/inference`）保留可编辑，但移到「高级」（见阶段 B）。它用于切换地域或业务空间，并且必须和 Key 的地域匹配。

### A.6 验证

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/test-polish.sh            # 含 PolishProviders 单测
./scripts/build-mac.sh
build/mac.noindex/iMic.app/Contents/MacOS/iMic --ui-preview=settings &   # 截图后关闭
build/mac.noindex/iMic.app/Contents/MacOS/iMic --ui-preview=setup-key &
```

- 用一个全新的 UserDefaults 域验证默认值：参照 `tests/PolishProviders` 里构造临时 `UserDefaults(suiteName:)` 的方式写单测，**不要**清空用户真实的 `com.drafffffff.imic` 偏好。
- 如果 D1 选了备选方案，还要跑真实的提示词回归（需要用户的 Key，Key 由脚本从本机配置读取，**不要把 Key 写进任何文件或日志**）。

提交说明示例："Mac 统一百炼：默认来源与润色开启，识别模型只读"。

---

## 阶段 B：设置窗口重构（必须）

### B.1 信息架构

把一列长滚动改为**顶部工具栏分页**的标准 macOS 设置窗口：用 `NSTabViewController`，`tabStyle = .toolbar`，每页配一个 SF Symbol。每页在默认窗口尺寸下**不需要滚动**；内容确实放不下时，才允许这一页内部滚动。

| 分页 | 图标建议 | 内容（自上而下） |
|---|---|---|
| **通用** | `gearshape` | 识别后自动输入到当前应用、实时预览与逐字输入（附一行风险说明）、登录时启动（C.P0-2）、启动时显示主窗口（C.P0-1）、测试输入 |
| **百炼** | `key` | Key 输入框 + 来源说明（APP CONFIG、ENV、shell 文件）+ 「验证」按钮和验证结果 + 「获取百炼 Key ↗」；分隔线；AI 润色开关；开启后显示：转换模式、表达语气、输出语言 |
| **iPhone** | `iphone` | 已配对设备列表（名称、配对日期、解除）、"配对新 iPhone"（显示配对码，可复制、可重新生成）、解除全部配对；分隔线；弦手势三个开关；蓝牙兜底开关 + 打开蓝牙设置 |
| **权限** | `lock.shield` | 每项一行：状态圆点 + 名称 + 一句用途 + 按钮。包括**辅助功能**（必需，用于自动输入）、**屏幕录制**（可选，用于扫光定位）、**蓝牙**（可选，用于兜底连接）。下方放扫光开关和说明（扫光依赖屏幕录制，所以放这里） |
| **高级** | `slider.horizontal.3` | 润色服务来源（百炼 / DeepSeek 官方 / 自定义），选非百炼时才出现对应的 Key、模型、Chat Completions 地址；百炼模型名和地址（用于地域或业务空间）；识别模型（只读）和识别服务地址；"重新打开设置向导" |

要点：

- 百炼页是**一个 Key 管全部**的主场，不出现其他服务商；其他服务商只放在「高级」。
- 选了非百炼来源时，在百炼页的润色区顶部显示一行提示："当前润色使用：DeepSeek 官方 API · 在「高级」中更改"。
- 打开设置时，默认显示上次停留的分页（存进 UserDefaults）。第一次打开时显示「百炼」页（如果还没有 Key）或「通用」页。

### B.2 统一保存方式：去掉全局「保存」按钮

- **开关、分段控件、下拉框**：改了即时生效（大多已经如此）。
- **Key 和地址等文本字段**：每个字段旁边放一个「验证并保存」按钮（百炼 Key 用 `BailianKeyCheck.run`；DeepSeek 和自定义来源，沿用 `DeepSeekClient.validatedURL` 的校验，再做一次轻量请求）。按回车等同于点这个按钮。验证通过才写入，结果就地显示在字段下方：✓ 已保存，或者红字错误。
- 字段内容改了但还没保存时，按钮高亮。关闭窗口时如果还有未保存的文本字段，就弹一个系统 sheet："百炼 Key 尚未保存。保存 / 放弃 / 取消"。
- **来源切换即时生效**：切到某个来源，但它的 Key 不可用时，下拉框旁边显示警告"此来源缺少有效 Key，润色将保留原文"，**不阻止切换**。
- 现有 `saveSettings()` 的各项校验逻辑（Key 格式、只把**变化的** Key 写入文件、从环境变量读到的 Key 保持外部来源不改写）**必须完整保留**，只是拆到各字段的保存动作里。特别注意 `main.swift:1486` 的注释：从环境变量或 shell 读到的 Key 不能被悄悄写进 iMic 配置文件。
- 删除 `previewShort` 这类重复文案，每个选项只保留一处说明：控件下方一行灰字，或者 tooltip，二选一。必要的风险说明（实时预览可能重复或误删）必须**直接可见**，不能只放进 tooltip。

### B.3 视觉规范

- 橙色只用于：分段控件的选中项、主要按钮、状态指示（连接中、错误除外）、分页工具栏的选中项。**复选框和链接按钮恢复系统默认的强调色或象牙色**，不再整片橙色。`Interface.swift:164` 的 `checkbox()` 是统一入口，在这里改。
- 分组标题沿用英文像素字或等宽大写风格（AGENTS.md："技术标签用英文像素字，操作说明用简体中文"），但去掉"MODE · 转换模式"这种中英重复的写法，二选一：标签用英文，紧接着的说明用中文。
- 窗口宽 560，各页高度自适应内容（切换分页时窗口高度做动画调整，这是 `NSTabViewController` 的 toolbar 样式的标准行为）。
- 保持深色外观（`darkAqua`），这是品牌约定。

### B.4 代码组织

- 新建 `mac/SettingsWindow.swift`，可以按页再拆成 `SettingsGeneralPane.swift` 等文件，把 `buildSettings()` 迁移过去。`Interface.swift` 里只保留主窗口。
- **新文件必须加进 `scripts/build-mac.sh` 第 38 行开始的 `swiftc` 文件列表**，否则不会被编译。确认没有其他脚本按文件列表编译 Mac UI（目前只有 `build-mac.sh`）。
- 仍然使用 AppKit，**不要整体改成 SwiftUI**，避免和现有 `label()`、`row()`、`column()` 工具函数风格分裂。
- 远程同步：iPhone 端修改润色偏好后，Mac 设置页的控件要实时更新（现有 `applyPolishPreferences` 会更新 `deepseekCheck`、`polishModeButtons` 等，见 `main.swift:389–394`）。重构后这些引用必须继续有效，设置窗口开着时也要同步。
- `--ui-preview=settings` 继续可用；新增 `--ui-preview=settings-<pane>`（例如 `settings-bailian`、`settings-permissions`），直接打开对应分页，便于截图。这些入口只在现有的 preview 机制里生效。

### B.5 验证

- `./scripts/build-mac.sh` 通过。
- 每个分页各截一张图（`screencapture -l <windowID>`，用 `CGWindowListCopyWindowInfo` 按 PID 找窗口），放进 `build/ux-shots/`，不提交。在汇报里附上路径。
- 手动走查清单（Codex 能做的就自己做，做不了的列出来交给用户）：
  1. 改 Key → 回车 → 显示"验证中…" → ✓；填错 Key → 红字"百炼拒绝了这个 Key"。
  2. 改 Key 不保存就关窗口 → 弹出 sheet。
  3. 切换来源到 DeepSeek（无 Key）→ 出现警告，润色时保留原文。
  4. iPhone 上切换模式 → Mac 设置页的分段控件同步变化。
  5. 从环境变量读到的 Key：不修改的情况下关闭设置，确认 `credentials.json` 没有被写入。
- **不要运行 `./scripts/install-mac.sh`**：用户本机装的是 Developer ID 公证版，覆盖安装会换掉签名，导致需要重新授权辅助功能。验证用 `build/mac.noindex/iMic.app` 的 preview 模式即可。

提交说明示例："Mac 设置改为分页并统一即时保存"。

---

## 阶段 C：体验走查发现的问题

以下是站在体验设计角度的走查结论，按优先级排列。P0 必须做；P1 建议做，若时间不足可只做部分，汇报里说明；P2 写出方案即可，**先不实现**，除非用户明确要求。

### P0-1 · 启动时不再总是弹出主窗口

- 现状：每次启动都会 `show()` 主窗口。菜单栏应用开机自启时也弹窗，会打扰用户。
- 改为：**首次设置未完成**（`shouldShowSetupOnLaunch()` 为真）时，照常显示设置向导；**设置已完成**时，启动后只出现在菜单栏，不弹窗。
- 「通用」页提供"启动时显示主窗口"开关，默认关闭。
- 用户手动从 Finder 或 Launchpad 再次打开 iMic 时（`applicationShouldHandleReopen` 或现有的 reopen 通知），照常显示主窗口。

### P0-2 · 登录时启动

- 用 `SMAppService.mainApp`（macOS 13+，项目最低版本正好是 13）实现"登录时启动"开关，放在「通用」页。
- 读取 `SMAppService.mainApp.status` 来显示真实状态（可能是 `.requiresApproval`，这时显示"需要在系统设置 → 通用 → 登录项中允许"，并提供打开按钮）。
- **不要默认开启**，也不在向导里强制。可以在向导完成页提示一句"可在设置中开启登录时启动"。
- 只在从 `/Applications` 运行时才可用；从磁盘映像或被系统随机化路径（translocated）运行时，禁用这个开关并说明原因。复用 `Onboarding.swift` 里已有的位置检测（`location: .applications / .translocated`）。

### P0-3 · 主窗口在"已配对、等待连接"时不该把配对码当主角

- 现状：只要没连上，主窗口就是一张大号配对码卡片，下面一大片空白。
- 改为区分两种状态：
  - **从未配对**：保持现在的配对码卡片，并在下方补一段三步说明，填掉空白：①在 iPhone 安装 iMic；②和 Mac 连同一 Wi-Fi；③在 iPhone 输入配对码。
  - **已有配对设备**：主区域显示"等待 iPhone 连接"，列出已配对设备的名称和"打开 iPhone 上的 iMic 即可自动连接"。配对码收起成一个次要按钮"配对新 iPhone"，点开再显示。
- 状态文字（顶部橙色 `stateLabel`）保持现有逻辑。

### P0-4 · 菜单栏菜单以高频操作为主

把菜单改为（自上而下）：

1. 状态行（禁用的菜单项，仅显示）：`● 已连接 iPhone 17 Pro` / `○ 等待 iPhone 连接` / `需要设置：辅助功能`。
2. `AI 润色` 开关（勾选状态）。
3. `转换模式` 子菜单：列出 `PolishMode` 各项，当前项打勾。改动走和设置页同一个入口（`applyPolishPreferences`），这样能同步给 iPhone。
4. 分隔线。
5. `打开 iMic`、`设置…`（⌘,）。
6. `配对新 iPhone…`（打开主窗口并展开配对码）。
7. 分隔线。
8. `退出 iMic`（⌘Q）。

删除顶层的"复制配对码"和"重新生成配对码"，它们移到 iPhone 设置页和配对卡片里。"设置向导…"移到「高级」页。

### P1-1 · Key 字段可查看、可验证

- 百炼 Key 输入框增加"显示/隐藏"眼睛按钮（`NSSecureTextField` 和 `NSTextField` 互相切换）。
- 显示 Key 的来源（已有 `CredentialSource.label`：APP CONFIG / ENV / shell 文件路径）和最后一次验证结果、时间。
- 来源是环境变量或 shell 文件时，字段默认只读，旁边放一个"改用 iMic 保存的 Key"按钮。点击后字段才变为可编辑，避免用户以为改了，实际上环境变量优先生效。先确认 `PolishCredentials.resolve` 的优先级：iMic 文件 → 环境变量 → shell 文件。如果 iMic 文件优先，就照实说明"保存后将优先使用 iMic 中的 Key"。

### P1-2 · 失败状态可行动

- 识别或润色失败时，主窗口和菜单状态行要给出原因和一个动作，不要只写"失败"：
  - 401/403 → "百炼拒绝了 Key" + 「打开设置」
  - 网络不可达 → "无法连接百炼，检查网络" + 「重试」
  - 地域不匹配（Key 和地址的地域不一致，常见报错可以从现有日志归纳）→ 提示检查「高级」里的地址
- 润色失败时保留原文并照常输入（现有行为），只在主窗口显示一行灰字提示"润色失败，已输入原文"。

### P1-3 · 权限页的实时状态

- 「权限」页打开时，以及应用回到前台时，刷新各项状态（辅助功能用现有的 `refreshInputPermission`，屏幕录制用现有检测）。
- 遵守 AGENTS.md："自动输入只使用辅助功能授权，不修改 TCC，不自动批准权限"。按钮只能**打开系统设置的对应面板**或触发系统的标准请求，不做其他操作。

### P1-4 · 可访问性

- 所有自定义按钮和图标按钮都要有 `setAccessibilityLabel`（大部分已有，重构时不要丢）。
- 设置窗口全程可用键盘操作：Tab 顺序合理，分页可以用 ⌘1…⌘5 切换。
- 灰色说明文字（`.imicMuted`）和深色背景的对比度至少达到 4.5:1。如果不够，就微调 `.imicMuted` 的颜色值，品牌色定义在 `Brand.swift`。

### P2-1 · 最近记录（只出方案）

主窗口目前只显示最后一次结果。可以考虑提供"最近 20 条"本地记录，方便找回没有成功输入的文字。必须先评估隐私影响，对照 `docs/PRIVACY.md`：默认关闭或仅保存在内存，提供一键清除，不上传。只写方案，不实现。

### P2-2 · 首次成功的引导（只出方案）

用户第一次成功输入后，主窗口给一个简短提示，介绍弦手势（下拉回车、上拉删除、左右移动光标）和润色模式切换的位置。只出现一次。只写方案。

### C 阶段验证

- `./scripts/build-mac.sh` 通过，`swift test` 和 `./scripts/test-polish.sh` 通过。
- 主窗口两种状态都截图：从未配对，以及已配对但未连接。已配对的状态如果现有 preview 模式没有覆盖，就新增 `--ui-preview=paired-waiting`。
- 菜单栏菜单截图（展开菜单后用 `screencapture` 截全屏再裁剪即可）。
- 登录项开关：在 `/Applications` 运行时测试开关，**测试完恢复用户原来的状态**。如果不方便在用户机器上测试，就说明并交给用户手测。

提交说明示例："Mac 体验优化：静默启动、登录项、主窗口状态与菜单栏"。P1 如果单独完成，可以另起一个提交。

---

## 2. 全局硬性约束

- **不修改协议**（`shared/iMicLink.swift`、`docs/PROTOCOL.md`、`LinkServer.swift`、`LinkClient.swift` 的帧格式、加密、配对码规则）。润色偏好仍然通过现有的 `LinkPolishPreferences` 同步。
- **不修改 TCC，不自动批准权限**，只引导用户自己去系统设置里授权。
- Key 只存放在现有位置（`credentials.json`，权限 0600），**不写进 UserDefaults、日志、截图文件名或提交内容**。截图里如果出现 Key 字段，必须是遮挡状态。
- 不修改 Mac 的 Bundle ID（`com.drafffffff.imic`）和签名脚本。
- **不运行 `install-mac.sh`**，不覆盖 `/Applications/iMic.app`。
- 不修改 `VERSION` 和版本号。发版由用户决定。
- 不提交 `.claude/`、`build/`。
- 文档同步：README 里的设置说明（第 200 行附近的润色服务说明、首次使用说明）、`docs/POLISH.md` 中涉及来源和默认值的部分，要随阶段 A、B 一起更新。
- `--ui-preview=*` 和 `--debug-*` 只用于预览和调试，发布行为不能依赖它们。

## 3. 遇到以下情况时停下来报告

- 发现 iPhone 端的设置页（`ios/iMic/PolishPreferencesView.swift`）也需要跟着改，才能保持一致。本任务只改 Mac，iPhone 端的改动另开任务。
- `SMAppService` 在当前签名方式下注册失败（例如 ad-hoc 本地构建）。如实记录，不要为此修改签名。
- 重构后 `applyPolishPreferences` 的同步链路无法保持，或者需要改协议。
- D1 选了备选方案，但提示词回归中终端命令模式出现多行或控制字符输出。

## 4. 交付汇报（每个阶段一份）

1. 改动文件清单，每个文件一句话。
2. 截图路径（`build/ux-shots/…`）。
3. 验证命令和结果。
4. 和本任务书的偏离之处及原因。
5. 需要用户手测的项目清单。
6. 提交哈希。**不要 push。**
