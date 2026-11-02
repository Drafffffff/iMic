# 任务书：Mac 百炼 Key 输入——新格式 Key、键盘粘贴与输入框显示

日期：2026-11-03
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请阅读本文件、`AGENTS.md`、`mac/Credentials.swift`、`mac/CloudFailure.swift`、`mac/SettingsValidation.swift`、`mac/Onboarding.swift`、`mac/SettingsWindow.swift`、`mac/SettingsField.swift`、`mac/main.swift`。

---

## 0. 交付方式

1. 从 `codex/ui-phosphor-wireframe` 最新提交新建分支 `codex/mac-key-field`，在专用 worktree 中工作。
2. 提交说明用简体中文。推送后用 `gh pr create` 向 `codex/ui-phosphor-wireframe` 提 PR，附第 5 节测试报告与截图。不要自行合并。
3. 不覆盖 `/Applications/iMic.app`，不改版本号，不发布。
4. **不要在任何文件、日志、测试、截图或 PR 中出现真实 Key。** 测试使用合成 Key。
5. 在 `docs/releases/NEXT.md` 记录。

## 1. 用户报告与已核实的事实（Claude 已用用户提供的测试 Key 做过只读请求）

用户在 Mac 设置向导的百炼 Key 页粘贴了一个新格式的 Key，向导提示「百炼 API Key 以 sk- 开头，请检查是否复制完整」，无法继续。

已核实：

- 该 Key 以 `sk-ws-` 开头，**包含点号 `.`**，形如 `sk-ws-<段>.<段>.<段>.<较长的 base64 段>`，总长约 120 字符。
- 用它请求**北京**共享域名 `https://dashscope.aliyuncs.com/compatible-mode/v1/models` 返回 **200**，列出 184 个模型；新加坡、香港、弗吉尼亚共享域名返回 401（`invalid_api_key` / `InvalidApiKey`）；Token Plan 地址返回 401；Coding Plan 地址 `https://coding.dashscope.aliyuncs.com/v1/models` 返回 200（6 个模型）。
- 结论：这是一个**北京地域可用的按量付费 Key**，只是新格式带点号。iMic 本地格式检查 `ShellCredentials.valid`（`mac/Credentials.swift` 约 35 行）只允许 `[A-Za-z0-9_-]`，所以在本地就被拒绝，并显示了误导性的提示。
- 模型列表中有 `deepseek-v4.1-flash`，**没有** `qwen-audio-3.1-asr-flash-message`（列表中有 `qwen-audio-3.0-asr-flash`、`fun-asr-flash-…`、`qwen3-asr-flash-realtime` 等）。可能是 `/models` 不列出该消息式语音模型，也可能是该 Key 的业务空间没有开通。现有逻辑在缺少语音模型条目时会提示「首次识别时确认」，不直接拒绝；请确认这条路径对这个 Key 生效，提示文字准确。
- 用户另外报告：
  - **输入框显示有问题**：粘贴长 Key 后，安全输入框里的圆点折成两行显示（见用户截图描述）。
  - **不支持键盘粘贴**：在输入框中按 Cmd+V 没有反应，只能点旁边的「粘贴」按钮。

## 2. 根因判断（请自行核实）

1. **格式检查过严**：`ShellCredentials.valid` 的字符集不含 `.`（新格式 Key 还可能含 `+`、`/`、`=` 等 base64 字符）。
2. **Cmd+V 无效**：iMic 是 `LSUIElement` 菜单栏应用，很可能没有主菜单中的「编辑」菜单。macOS 中 Cmd+V/C/X/A/Z 等快捷键依赖主菜单的 Edit 菜单项（或 `performKeyEquivalent` 处理）分发给第一响应者，没有 Edit 菜单时文本框收不到粘贴。请检查 `mac/main.swift` 中 `NSApp.mainMenu` 的设置。
3. **两行显示**：安全输入框的 cell 允许折行，或者用了多行控件，导致长 Key 换行。

## 3. 要做的事

### 3.1 Key 格式

- 放宽 `ShellCredentials.valid`：保留 `sk-` 前缀与最小长度要求；字符集允许 `A-Z a-z 0-9 - _ . + / =`。**仍然拒绝**空白、控制字符、引号、反斜杠、`$`、反引号、分号等任何 shell 或 HTTP 头注入相关字符（这个函数也用于从 shell 配置中解析 Key，安全性不能降低）。设一个合理的最大长度（例如 512）。
- 检查所有调用 `ShellCredentials.valid` / `PolishCredentials.valid` 的地方（向导、设置页、shell 配置解析、外部 Key 来源、`BailianDiscovery`），确保新格式 Key 在每条路径上都能被接受、保存、读取和用作 `Authorization: Bearer` 头。
- Key 清理（`PR #8` 加的去空白、引号、`export` 前缀）对带点号的 Key 不应误删任何字符。
- 本地格式不通过时的提示改为准确的说法，例如「这不像百炼 API Key，请检查是否复制完整」/「This doesn't look like a Model Studio API Key. Check that you copied all of it.」，不要再说「以 sk- 开头」（除非确实不是 `sk-` 开头，此时可以说明）。中英文都写进本地化文件。

### 3.2 `sk-ws-` 前缀

`PR #8` 中有一条规则：所有地域都返回 401 且前缀是 `sk-sp-` 或 `sk-ws-` 时，提示「这看起来是 Token Plan 或 Coding Plan 套餐的 Key」。实测 `sk-ws-` Key 可以在北京按量付费接口通过，所以：

- 只要有地域返回 200，就按正常 Key 处理，不显示套餐提示（现有逻辑应已如此，请确认）。
- 所有地域都 401 时，`sk-ws-` 不应再被直接认定为套餐 Key；套餐提示只在 Key 前缀为 `sk-sp-`，或者用户粘贴的是套餐地址时显示。`sk-ws-` 全部 401 时按普通无效 Key 提示。

### 3.3 键盘粘贴

- 确认 Cmd+V 无效的原因，并修复：为应用添加标准的主菜单（至少包含「编辑」菜单：撤销、重做、剪切、拷贝、粘贴、全选），菜单栏应用不显示菜单栏也能让这些快捷键生效；或者在窗口层面正确处理 `performKeyEquivalent`。优先采用标准做法（主菜单 Edit 菜单）。
- 所有文本框（向导 Key 页、设置页百炼 Key、自定义服务地址、Base URL、配对相关输入等）都要支持 Cmd+V、Cmd+C、Cmd+X、Cmd+A、Cmd+Z。安全输入框按 macOS 惯例禁止拷贝/剪切即可，但必须允许粘贴和全选。
- 粘贴后同样触发现有的自动清理与自动验证（与点「粘贴」按钮一致）。

### 3.4 输入框显示

- 安全输入框保持单行：长 Key 不换行，水平滚动或截断显示；高度与其他输入框一致。
- 检查向导与设置页两处，深色主题下文字、光标、占位符清晰可见。

## 4. 不要做的事

- 不降低格式检查对注入字符的防护。
- 不在任何地方写入或打印真实 Key。
- 不改地域探测、白名单与计费相关逻辑（除第 3.2 节明确要求的部分）。
- 不改 iOS 端和协议。

## 5. PR 中必须附上

1. 根因确认：三个问题各自的原因与依据。
2. 新增或更新的单元测试：带点号的合成 Key（形如 `sk-ws-AAAA.BBBB.CCCC.` 加约 90 个 base64 字符）通过格式检查、清理不变、作为 Bearer 头正确；包含空白、引号、`$`、反引号、分号、换行的 Key 仍被拒绝；`sk-ws-` 有地域 200 时正常通过、全部 401 时显示普通无效提示；`sk-sp-` 全部 401 时仍显示套餐提示。
3. Cmd+V 的验证：原生 UI 测试或 `scripts/test-mac-settings.sh` 中的检查，模拟 Cmd+V 粘贴到向导 Key 输入框与设置页 Key 输入框成功并自动验证（使用合成 Key 与模拟网络响应）。
4. 截图（中英文）：向导 Key 页粘贴长 Key 后单行显示、格式错误提示、验证成功；设置页百炼页同样状态。
5. 测试报告：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/test-polish.sh
./scripts/test-mac-settings.sh
./scripts/test-input.sh
./scripts/build-mac.sh
python3 tools/check-l10n.py
```

6. 用户手动验证步骤：在新构建的 App 中，向导 Key 页用 Cmd+V 粘贴真实 Key，应单行显示、自动识别为「华北2（北京）」并通过；验证后再到设置页确认可以正常显示与修改。
