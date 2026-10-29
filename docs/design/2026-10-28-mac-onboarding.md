# Mac 首次设置与安装流程

状态：已实现（`mac/Onboarding.swift`、`mac/Credentials.swift`）。不改 `shared/iMicLink.swift` 协议。

## 原则

用户只需要做两件事：打开权限、填一个百炼 Key。界面不出现存储方案、环境变量、来源标签等实现细节；这些只写在 README 的常见问题里。

## 改动前的问题

1. Key 写入 `~/.zshrc`：应用改写用户的 shell 配置，fish / bash 用户也被写进 zshrc。
2. 没有首次引导：未配对时主窗口只显示配对卡，「先配置百炼 API Key」藏在顶栏小字；Key 在一屏 9 个分区的设置页里，与 DeepSeek / 自定义服务混在一起。
3. Key 不校验：填错要等第一次说话才暴露；也没有告诉用户去哪里获取。
4. 润色来源默认是 DeepSeek 官方，只有百炼 Key 的用户开启润色会失败，「一个 Key 全功能」不成立。
5. 辅助功能授权成功后没有下一步；重建或升级后旧条目失效（列表显示开启但不生效）时没有修复路径；从磁盘映像或「下载」运行时授权会丢失，也没有提示。
6. `build-mac.sh` 默认要求完整 Xcode；README 把 XcodeGen 写成 Mac 端前置条件。

## 设置向导

独立小窗（480×420，墨黑背景）。顶部两段步进：`01 PERMISSIONS · 02 API KEY`（英文等宽标签，当前步骤橙色）。

### 01 权限

- 标题「允许 iMic 输入文字」，下面两张权限卡：
  - 辅助功能 —「把识别好的文字输入到当前应用」— 按钮「去开启」。
  - 屏幕录制 —「可选 · 润色完成时的扫光效果」— 按钮「去开启」。
- 「去开启」第一次弹出系统授权提示（同时把 iMic 加入列表），之后直接打开对应的系统设置页。授权只能由用户完成；iMic 不修改 TCC、不自动批准。
- 每 0.5 秒检测；辅助功能生效后卡片显示 `ON`，窗口回到前台并在 0.8 秒后自动进入第 2 步。
- 点过「去开启」后出现小链接「已经打开开关，仍未生效？」，15 秒仍未生效时自动展开：在列表中选中 iMic，点「−」删除，再点「去开启」。
- 从磁盘映像或 App Translocation 路径运行时，只显示「请先把 iMic 拖到『应用程序』」和「在 Finder 中显示 iMic」。
- 可「跳过」：未授权时文字仍显示在 Mac 窗口和 iPhone 上，可复制。

### 02 百炼 API Key

- 标题「填入百炼 API Key」，一句说明，按钮「获取百炼 API Key ↗」（`https://bailian.console.aliyun.com/?tab=model#/api-key`），输入框 +「粘贴」。
- 本机已有的 Key（环境变量或 shell 配置）自动填入并验证，用户直接点「完成」。
- 粘贴有效格式的 Key 立即验证；主按钮「验证并完成」。
- 验证：`GET https://<识别服务同主机>/compatible-mode/v1/models`，10 秒超时，不发送音频或文字。200 → 「Key 可用。」并保存；401/403 → 「这个 Key 无法使用…」；网络错误 → 「暂时连不上百炼…」。
- Key 步骤提供默认勾选的「同时启用 AI 润色（推荐）」，完成时保存选择并沿用现有偏好同步链路。
- 完成后记录 `setup.completedVersion = 1`，回到主窗口（显示配对码）。

### 何时出现

- 没有百炼 Key 时，每次启动都打开。
- 有 Key 但从未完成向导、且辅助功能未授权时打开；已授权的老用户静默标记为完成，不打扰。
- 菜单栏「设置向导…」、主窗口底部「继续设置…」（缺 Key 或缺权限时出现）、设置页「授权引导…」可随时重开。
- 步骤状态全部实时检测，关闭或重启后从第一个未完成的步骤继续。
- 配对不在向导里：主窗口本来就以配对码为主体。

## Key 存储

- 用户在 iMic 中填写的 Key 统一写入 `~/Library/Application Support/iMic/credentials.json`（目录 0700、文件 0600、原子写入）。不使用钥匙串：ad-hoc 签名每次重建或升级都会改变签名，钥匙串会反复要求输入密码。不再写任何 shell 配置。
- 读取顺序：iMic 配置文件 → 进程环境变量 → shell 配置中的字面量赋值（`~/.zshenv`、`~/.zprofile`、`~/.zshrc`、`~/.bash_profile`、`~/.bashrc`、`~/.profile`、fish `config.fish`，只解析不执行）。从 Finder 打开的应用拿不到 shell 环境变量，所以需要解析 shell 配置。
- 变量：百炼 `DASHSCOPE_API_KEY` / `BAILIAN_API_KEY`；DeepSeek 官方 `DEEPSEEK_API_KEY`；自定义 `IMIC_CUSTOM_POLISH_API_KEY`。来源之间不互相兜底。
- 外部来源的 Key 直接使用，不复制到 iMic 配置文件；用户在 iMic 中更换后才写入。
- 润色来源默认百炼；从未选择过来源的老用户也采用百炼，已有明确选择保持不变。DeepSeek 与自定义服务只在设置页出现。

## 安装

- `build-mac.sh`：`DEVELOPER_DIR` 未设置时依次尝试 `/Applications/Xcode.app` 与 `xcode-select -p`；缺少 `swiftc` 或 macOS SDK 时提示 `xcode-select --install`（只需命令行工具）。ad-hoc 签名时用中文说明需要重新添加辅助功能。
- `install-mac.sh`：`--build` 先构建再安装，`--no-open`、`--dry-run`；检查 `/Applications` 写权限；安装后提示首次设置向导，ad-hoc 签名时提示删除旧的辅助功能条目。
- README：Mac 端只需命令行工具；一条命令安装；常见问题（权限失效、Translocation、Key 存放与读取顺序、找不到 Mac、卸载）。

## 主窗口与设置页精简

- 主窗口：未连接时只显示配对码卡片与一句说明（复制、重新生成在「···」菜单）；去掉三步列表与脚注、结果下方的 `TARGET / ms / CHARS` 调试信息；「复制文字」只在有文字时出现；「自动输入」移入设置页。缺 Key 或缺权限时底部显示「继续设置…」。
- 设置页从 9 个分区合并为 3 个：`GENERAL`（百炼 Key、自动输入、实时预览、输入权限、已配对 iPhone）、`AI POLISH`（关闭润色时隐藏模式 / 语气 / 语言 / 服务）、`ADVANCED`（默认折叠：蓝牙兜底、弦手势、扫光、识别模型与地址）。长说明移入悬停提示；实时预览的重复 / 误删风险仍保留一行可见说明。
- 修复设置窗口被未设宽度的换行文字撑到 874pt 的问题（改动前即存在）；设置页打开时从顶部开始。

## 验证

本机已验证：
- `./scripts/build-mac.sh` 构建通过；`./scripts/test-polish.sh`（含凭据文件权限、读取优先级、fish 解析、百炼校验请求构造与响应分类）与 `swift test` 通过。
- 百炼校验接口：有效 Key 返回 200，无效 Key 返回 401 `invalid_api_key`。
- 界面预览截图：主窗口 `idle` / `result`、设置页 `settings`，以及 `--ui-preview=setup`、`setup-move`、`setup-granted`、`setup-key`、`setup-key-detected`。

需要在全新 Mac / 全新用户账户验证：
- 只装命令行工具（无 Xcode）的构建。
- 真实首次授权：系统提示、自动前进、窗口回到前台；重建后失效条目的修复路径。
- 公开 DMG 的 Gatekeeper 与 Translocation 提示。
- 屏幕录制授权在 macOS 14/15 上是否需要重开 iMic 才能被检测到。
- 本地网络弹窗时机。
