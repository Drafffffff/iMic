# Mac Key 输入回归报告

日期：2026-11-03。基线：`codex/ui-phosphor-wireframe` 的 `c817e36`。
环境：Apple Silicon，macOS 26.6.2 (25G83)，Xcode 27.1 (27A9275)。

## 根因与修复

1. `ShellCredentials.valid` 原先只允许字母、数字、`-`、`_`，带点号的 Key 会在请求前被拒绝；`literal` 的未加引号 shell 分支也有相同限制。现统一允许 ASCII 字母、数字和 `- _ . + / =`，保留 `sk-` 前缀、至少 11 字节，并限制最多 512 字节。空白、控制字符、引号、反斜杠、`$`、反引号、分号等仍拒绝。向导原来的“以 sk- 开头”提示无法描述字符集错误，现与设置页共用准确的中英文格式提示。
2. `MacExperience.buildStatusMenu` 原先只把状态菜单接入 `NSApp.mainMenu`，没有 Edit 子菜单及剪贴板动作的 key equivalent。现通过标准 Edit 菜单将撤销、重做、剪切、拷贝、粘贴、全选交给第一响应者，由 AppKit 决定安全输入框的拷贝/剪切行为。重做使用标准大写 `Z` key equivalent 配合 Command+Shift，原生事件测试覆盖。
3. 向导 `NSSecureTextField` 和 `SettingsField` 原先只限制控件高度，没有禁用 cell 的 wrapping。现同时设置单行、禁止折行、水平滚动和 clipping；明文显示也保持单行，深色模式使用明确的前景/背景颜色。原生测试还检查编辑器实际排版仅一行。

`sk-ws-` 不再触发套餐猜测；全部地域 401 时返回普通无效 Key。`sk-sp-` 仅在全部 401 时保留套餐提示。任一唯一可用地域返回 200 时继续正常处理；套餐地址仍拒绝。未修改地域探测范围、域名白名单、计费逻辑、iOS 代码或传输协议。`ios/iMic/Localizable.xcstrings` 仅承载仓库共用的字符串目录新增项，Mac `.strings` 按现有生成机制同步。

## 自动化覆盖

`tests/PolishProviders/main.swift`：

- 合成 Key 由 `sk-ws-`、`AAAA.BBBB.CCCC.`、90 个重复构造的 base64 字符及 `==` 组成；不使用任何真实凭据。
- 验证带点号 Key 通过格式检查；清理首尾空白、单双/中文引号与 `export DASHSCOPE_API_KEY=` 后内容不变。
- 覆盖全部七种 shell 启动文件、带引号及未加引号的赋值、环境变量、应用配置的保存和读取。
- 检查模型列表验证、识别前 Key 检查、润色请求及地域探测使用完整的 `Authorization: Bearer` 头。
- 空格、制表符、CR/LF、NUL、DEL、单双/中文引号、反斜杠、`$`、反引号、分号、管道符等仍被拒绝；覆盖最小长度与 512/513 字节边界。
- 模拟北京 200、其他地域 401；模型列表只有润色模型时仍成功，并显示“首次识别时确认”语音模型访问权限的提示。
- 覆盖 `sk-ws-` 全部 401 的普通无效提示，以及 `sk-sp-` 全部 401 的套餐提示；两种前缀在北京 200 时都通过；套餐地址不发出携带凭据的请求。

`tests/MacSettings/main.swift` / `scripts/test-mac-settings.sh`：

- 在 accessory 应用的真实 AppKit 窗口中，经 `NSApplication.sendEvent` 发送 Cmd+A / Cmd+V，由生产主菜单分发到原生 field editor，未直接调用 paste 或手工触发文本变化 delegate。
- 向导和设置页使用注入的临时 `URLSession` + `URLProtocol`，执行生产 `BailianDiscovery`。北京返回 200、其他地域返回 401；合成 Key 不发送到真实网络。
- 两处均检查自动清理、0.45 秒 debounce 后自动验证、北京地域、保存/采用结果、格式错误不发请求、单行安全掩码及原有输入高度。
- 普通地址输入检查 Cmd+V/A/C/X/Z 和 Cmd+Shift+Z。
- 每次运行分别测试英文、简体中文；截图仅来自原生测试窗口。测试不修改真实 credentials.json 或真实偏好；剪贴板原有数据仅在内存暂存，完成后恢复。

## 截图

每种语言均包含向导与设置页各三个状态：长 Key 粘贴后（验证前）、格式错误、北京验证成功。长 Key 全部是合成内容并以安全掩码显示。

| 状态 | English | 简体中文 |
|---|---|---|
| 向导：长 Key 单行 | [截图](en/setup-long-key.png) | [截图](zh-Hans/setup-long-key.png) |
| 向导：格式错误 | [截图](en/setup-format-error.png) | [截图](zh-Hans/setup-format-error.png) |
| 向导：验证成功 | [截图](en/setup-success.png) | [截图](zh-Hans/setup-success.png) |
| 设置：长 Key 单行 | [截图](en/settings-long-key.png) | [截图](zh-Hans/settings-long-key.png) |
| 设置：格式错误 | [截图](en/settings-format-error.png) | [截图](zh-Hans/settings-format-error.png) |
| 设置：验证成功 | [截图](en/settings-success.png) | [截图](zh-Hans/settings-success.png) |

生成截图：

```bash
./scripts/test-mac-settings.sh --capture-key-fields=docs/test-reports/mac-key-field
```

## 测试结果

| 命令 | 结果 |
|---|---|
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | PASS，74 项测试，0 失败 |
| `./scripts/test-polish.sh` | PASS，30 项测试，0 失败 |
| `./scripts/test-mac-settings.sh`（附加截图参数） | PASS，英文与简体中文原生回归全部通过，生成并逐张复核 12 张截图 |
| `./scripts/test-input.sh` | PASS，21 项测试，0 失败 |
| `./scripts/build-mac.sh` | PASS，worktree 内构建，代码签名与严格校验通过 |
| `python3 tools/check-l10n.py` | PASS，中英文键、格式参数、生成资源及中文排除项检查通过 |

测试不调用实际云服务，不需要输入或输出真实 Key。构建产物为 `build/mac.noindex/iMic.app`，未执行 `scripts/install-mac.sh`。

## 用户手动验证

1. 从 worktree 的 `build/mac.noindex/iMic.app` 打开新构建，先退出其他正在运行的 iMic；不要运行安装脚本或覆盖 `/Applications/iMic.app`。
2. 重新打开设置向导，在 Key 页用 Cmd+V 粘贴自己的真实 Key。应只显示一行圆点，自动清理并验证，识别为“华北2（北京）”，可以进入下一步。真实 Key 只输入 App，不放入报告、日志、截图或 PR。
3. 如果模型列表不含语音模型，应显示“首次识别时确认”，不会阻止继续；实际语音权限仍以首次识别结果为准。
4. 到设置的百炼页确认 Key 可以正常显示、全选、修改与重新自动验证；眼睛按钮切换的明文输入也不应折行。普通地址输入检查 Cmd+C/X/Z；安全框按系统规则限制拷贝/剪切。

本次不执行真实服务识别，不安装、不发布、不改变 `VERSION` / `MAC_BUILD`，不合并 PR。
