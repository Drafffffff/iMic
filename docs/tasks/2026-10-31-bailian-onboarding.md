# 任务书：新用户百炼 Key 接入不再卡住

日期：2026-10-31
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 的最新提交新建分支 `codex/bailian-onboarding`，在这个分支上工作。**不要直接提交到 `codex/ui-phosphor-wireframe`。**
2. 提交说明用简体中文，可以分多次提交。
3. 推送分支：`git push -u origin codex/bailian-onboarding`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**。
5. PR 描述必须附第 8 节要求的**调研结论和全量测试报告**。没有报告的 PR 不予审核。
6. 由 Claude 审核。**不要自行合并**，也不要开启自动合并。
7. 不改 `VERSION`，不覆盖 `/Applications/iMic.app`，不改仓库设置，不发布。
8. **不要注册阿里云账号，也不要用任何人的账号登录阿里云控制台。** 调研只读公开文档。实测只能使用本机已经配置好的 Key（`~/Library/Application Support/iMic/credentials.json` 或环境变量 `DASHSCOPE_API_KEY`），**不要把 Key 打印到日志、测试报告或 PR 中**，只显示前 6 位加 `…`。
9. 在 `docs/releases/NEXT.md` 记录本次改动。
10. 同时进行的任务 `codex/mac-auto-update` 会修改 `mac/SettingsWindow.swift` 的「通用」页、菜单和 `build-mac.sh`。本任务只改百炼相关的部分，避免冲突。

---

## 1. 背景

用户反馈：设置向导的第一步「填入百炼 API Key」会卡住新用户。同事作为新用户实际试过，发现**阿里云给新用户的接口和我们现在用的接口不完全一致**，Key 填进去验证不过，也不知道该怎么办。具体是哪一种不一致没有记录下来，所以本任务要**把所有可能的情况都覆盖到**。

目标：一个普通个人用户，从注册阿里云到 iMic 能识别出第一句话，整个过程不需要看技术文档；Key 有问题时，iMic 能告诉他**具体是什么问题、该怎么做**，而不是一句"请检查 Key 与地域"。

## 2. 现状（已核实）

iMic 目前使用两个百炼接口，都是"按量付费"的 DashScope 接口：

| 用途 | 地址 | 位置 |
|---|---|---|
| 语音识别 | `wss://dashscope.aliyuncs.com/api-ws/v1/inference`，模型 `qwen-audio-3.1-asr-flash-message` | `mac/ASR.swift` |
| 文字润色 | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`，模型 `deepseek-v4.1-flash` | `mac/DeepSeek.swift` |
| Key 验证 | `GET /compatible-mode/v1/models`（由识别地址推算主机） | `mac/Credentials.swift` 约 204 行，`mac/SettingsValidation.swift` |

问题点：

- **Key 格式检查过严**：`ShellCredentials.valid` 要求以 `sk-` 开头，并且只能包含字母、数字、`-`、`_`（`mac/Credentials.swift` 约 20 行）。
- **向导只用默认地址验证**：默认是华北2（北京）的 `dashscope.aliyuncs.com`。地域和业务空间地址只能在「设置 → 高级」里改，**向导里没有办法改**。所以一个新加坡地域的 Key，在向导里永远验证不过。
- **错误提示太笼统**：401/403 一律显示"服务拒绝了这个 Key，请检查 Key 与地域"（`mac/SettingsValidation.swift`），用户不知道下一步该做什么。
- **地址白名单不完整**：润色地址只允许 4 个 DashScope 共享域名和 `{业务空间}.{地域}.maas.aliyuncs.com`（`mac/DeepSeek.swift` 约 141 行）。**试用域名 `trial.{地域}.maas.aliyuncs.com` 不在白名单里。**
- **验证不完整**：`/models` 验证通过只说明 Key 在这个地域有效，不能说明这个 Key 能调用语音识别模型（例如 Key 设置了"自定义权限"、只勾选了部分模型）。

## 3. 调研结论（Claude 已查阅官方文档，2026-10-31）

以下内容来自阿里云帮助中心，请你再核对一遍，看有没有更新，并在 PR 中附上链接和查阅日期。

- [获取与配置 API Key](https://help.aliyun.com/zh/model-studio/get-api-key)（更新于 2026-10-28）：
  - 在百炼控制台的 API Key 页面，**右上角先选地域**，每个地域的 Key、接入域名、模型列表都是独立的，**不能跨地域使用**。
  - 系统不会自动生成 Key，需要手动点「创建 API Key」。归属账号默认是主账号，归属业务空间默认是「默认业务空间」，权限建议选「全部」；选「自定义」时可以限制 IP 和可调用的模型。
  - 无法创建 Key 时，需要超级管理员或业务空间管理员操作。
- [Base URL 总览](https://help.aliyun.com/zh/model-studio/base-url)（更新于 2026-10-10）：**Key 和地址必须属于同一种计费方案、同一个地域，否则返回 401**。按量付费有三种域名：
  - DashScope 共享域名：北京 `dashscope.aliyuncs.com`、新加坡 `dashscope-intl.aliyuncs.com`、弗吉尼亚 `dashscope-us.aliyuncs.com`、香港 `cn-hongkong.dashscope.aliyuncs.com`。官方说法是"当前可继续使用，建议迁移至业务空间专属域名"。
  - 业务空间专属域名：`{WorkspaceId}.{cn-beijing|ap-southeast-1|ap-northeast-1|eu-central-1|us-east-1|cn-hongkong}.maas.aliyuncs.com`，**只能用这个业务空间自己的 Key**。
  - 试用域名：`trial.{cn-beijing|ap-southeast-1|cn-hongkong}.maas.aliyuncs.com`，用于临时测试，限流较小。
  - **另外还有两种套餐**，各有专属的 Key 和地址，并且**官方写明"仅限 Claude Code、Codex 等 AI 工具交互式使用，不能用于后端服务"**：
    - Token Plan：`https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`
    - Coding Plan：`https://coding.dashscope.aliyuncs.com/v1`
  - 第三方资料对这两种套餐 Key 前缀的说法不一致（`sk-sp-` / `sk-ws-` 分别对应哪种套餐有冲突）。**不要靠前缀判断套餐类型**，以接口实际返回为准。
- [Qwen-Audio-ASR-Message 接入方式](https://help.aliyun.com/zh/model-studio/qwen-asr-message-model-access)：支持 WebSocket 和 AOQ 接入。根据同系列文档，这个模型在**华北2（北京）和新加坡**两个地域可用，WebSocket 地址为 `wss://{WorkspaceId}.{cn-beijing|ap-southeast-1}.maas.aliyuncs.com/api-ws/v1/inference`，共享域名也可以用。**其他地域是否可用，请你确认。**
- [新人免费额度](https://help.aliyun.com/zh/model-studio/new-free-quota)：新人免费额度**只在华北2（北京）地域**提供，有效期 90 天。未实名认证的用户，免费额度用完后就不能再调用；已实名认证的用户，额度用完后自动转为按量付费（可以开启「免费额度用完即停」）。

### 推测：同事遇到的可能是以下几种情况之一

1. **在新加坡或其他地域创建了 Key**（例如控制台默认地域不是北京，或者用的是国际站账号）。用北京地址验证时返回 401。
2. **买了 Token Plan 或 Coding Plan 套餐**，拿到的是套餐专属 Key。这种 Key 在按量付费地址上返回 401，而且按官方条款不能用于 iMic 这样的应用。
3. **控制台引导他使用业务空间专属域名或试用域名**，Key 属于某个子业务空间，而 iMic 只用共享域名验证，或者试用域名被我们的白名单拒绝。
4. **Key 设置了自定义权限**：没有勾选语音识别模型，或者设置了 IP 白名单。`/models` 能通过，但识别时失败。
5. **账号没有实名认证，或者免费额度用完了**：Key 有效，但调用时返回欠费或配额相关的错误。
6. **复制 Key 时带了多余的空格、换行或引号**，或者复制不完整。

## 4. 要做的事

### 4.1 自动识别地域（核心）

用户只粘贴 Key，iMic 自动找出这个 Key 属于哪个地域：

- 按顺序用这个 Key 请求各地域的 `GET /compatible-mode/v1/models`：北京 → 新加坡 → 香港 → 弗吉尼亚（DashScope 共享域名）。**并发请求**，总超时不超过 8 秒。
- 只有一个地域返回 200 时，自动选用这个地域，并同时设置识别地址和润色地址（`asrEndpoint` 和润色 endpoint 必须一致，见 `mac/ASR.swift` 和 `mac/DeepSeek.swift`）。界面显示"已识别：华北2（北京）"之类的结果。
- 识别出的地域不支持语音识别模型时（见第 3 节，可能只有北京和新加坡支持），直接告诉用户："这个 Key 属于 xx 地域，该地域暂不支持 iMic 使用的语音识别模型。请在百炼控制台右上角切换到「华北2（北京）」，重新创建一个 Key。"并附上打开控制台的按钮。
- 不要让用户在向导里手动选地域。自动识别失败时，在"高级选项"里提供"手动填写服务地址"的折叠入口（见 4.3）。
- 这是**只读**请求：不发送录音或文字，不调用付费推理。验证请求的超时、重定向策略沿用 `SettingsValidation.swift` 现有的做法（目前禁止跨主机重定向，保持不变）。

### 4.2 Key 能否真正用来识别

`/models` 通过以后，再确认这个 Key 能调用 iMic 使用的模型：

- 先检查 `/models` 返回的列表里是否包含识别模型 `qwen-audio-3.1-asr-flash-message` 和润色模型 `deepseek-v4.1-flash`。如果列表中**没有**这些模型，可能是因为 Key 设置了自定义权限，也可能是因为 `/models` 不列出语音模型。**请你实测确认**，用本机现有的 Key 请求一次，看返回内容。
- 如果 `/models` 不能可靠地反映识别模型的权限：建立一次 WebSocket 连接并发送 `run-task`，收到 `task-started` 后**立刻**发送 `finish-task`，**不发送任何音频**，然后断开。确认这样做不会产生计费（查文档，在 PR 里说明依据）。如果无法确认不产生计费，就**不要做**这一步，改为在第一次真正识别失败时给出准确的提示（见 4.4）。
- 只有识别模型能用、润色模型不能用时：向导可以继续，但把 AI 润色默认关闭，并提示"这个 Key 暂时不能使用润色模型，可以稍后在设置中开启"。

### 4.3 地址与 Key 格式放宽，但保持安全

- **Key 的输入清理**：去掉首尾的空格、换行、制表符、成对的引号（`"…"`、`'…'`、`“…”`），以及粘贴整行 `export DASHSCOPE_API_KEY=...` 或 `DASHSCOPE_API_KEY=...` 时前面的部分。清理后再检查格式。
- **前缀检查**：保留 `sk-` 前缀要求。不要扩大允许的字符集，除非你在官方文档中找到了依据。
- **识别套餐 Key**：如果用户粘贴的是套餐地址（包含 `token-plan.` 或 `coding.dashscope`）或者在各地域都返回 401，并且 Key 前缀是 `sk-sp-` 或 `sk-ws-`，提示："这看起来是 Token Plan 或 Coding Plan 套餐的 Key。套餐 Key 只能用于 Claude Code 等编程工具，iMic 需要按量付费的 API Key。请在百炼控制台的「API Key」页面创建一个新的 Key。"**不要**尝试让 iMic 调用套餐地址：官方条款不允许。
- **地址白名单**：`mac/DeepSeek.swift` 的百炼白名单加入试用域名 `trial.{cn-beijing|ap-southeast-1|cn-hongkong}.maas.aliyuncs.com`。识别地址（`mac/ASR.swift` / `SettingsValidation.asrURL`）同样要接受这三类按量付费域名，并保持只允许 `wss://` 和 HTTPS、端口 443、固定路径。**不接受任意主机**。
- **手动填写地址**：在向导 Key 页的"高级选项"折叠区里，允许粘贴百炼控制台给出的 Base URL（例如 `https://xxxx.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`）。iMic 从中解析出主机，自动推算识别地址和润色地址。如果主机不在白名单里，就拒绝并说明原因。

### 4.4 错误提示要具体

把现在笼统的"服务拒绝了这个 Key，请检查 Key 与地域"替换为按情况区分的提示。每条提示都要说明**原因**和**下一步**，需要去控制台的配一个按钮。至少覆盖：

| 情况 | 提示要点 |
|---|---|
| 所有地域都返回 401 | Key 无效、已被删除，或者复制不完整；如果是套餐 Key，按 4.3 提示 |
| 某个地域通过，但该地域不支持识别模型 | 按 4.1 提示切换到北京地域重新创建 |
| 403 / 没有模型权限 | Key 设置了自定义权限，请把权限改为「全部」，或者勾选所需的模型（给出模型名） |
| IP 白名单拒绝 | Key 设置了 IP 白名单，请关闭或加入当前网络 |
| 欠费、额度用完或未实名认证 | 免费额度只在北京地域提供；额度用完后需要完成实名认证并充值 |
| 网络不通 | 检查网络；公司网络可能拦截了阿里云的域名 |
| 子业务空间的 Key 用在了共享域名上 | 提示粘贴控制台给出的 Base URL（4.3 的手动地址） |

DashScope 的错误响应体里有 `code` 字段，例如 `InvalidApiKey`、`AccessDenied`、`Arrearage`、`DataInspectionFailed` 等。请查阅官方[错误码文档](https://help.aliyun.com/zh/model-studio/error-code)，按 `code` 区分，不要只看 HTTP 状态码。**识别过程中出现这些错误时**（`mac/ASR.swift` 和 `mac/CloudFailure.swift`），也使用同一套提示。

### 4.5 向导 Key 页的引导文案

新用户最大的障碍是"不知道去哪里拿 Key"。Key 页改成三个短步骤（简体中文，每步一行）：

1. 打开百炼控制台（按钮），用阿里云账号登录。没有账号的话，需要先注册并完成实名认证。
2. 确认右上角的地域是「华北2（北京）」（新人免费额度只在北京地域提供），点「创建 API Key」，权限选「全部」。
3. 复制 Key，粘贴到下面。

- 控制台按钮继续打开 `https://bailian.console.aliyun.com/?tab=model#/api-key`（`mac/Onboarding.swift` 约 88 行）。如果你在文档中发现了更准确的地址（例如能直接定位到北京地域的地址），可以替换，并在 PR 中说明。
- 粘贴后**自动开始验证**，不需要再点「验证」按钮。验证过程中显示当前在做什么（"正在识别地域…"、"正在确认模型权限…"）。
- 费用说明保持一行："识别和润色按百炼用量计费，新用户在北京地域有免费额度。"
- 遵守 `AGENTS.md` 的界面语言规则：技术标签用英文像素字，操作说明用简体中文；橙色只用于状态、交互和强调。

### 4.6 设置页与官网同步

- 「设置 → 百炼」页的 Key 验证使用同一套自动识别和错误提示。
- 「设置 → 高级」中现有的地域和业务空间地址配置保留，但显示"已自动识别"的当前值。
- 官网 FAQ「百炼 API Key 怎么获取？要花多少钱？」（`site/index.html`）按 4.5 的三步更新，并加一句："请在北京地域创建，套餐 Key（Token Plan、Coding Plan）不能用于 iMic。"**只改这一条**。
- README 的「开始使用」第 1 步加一句提醒："在百炼控制台创建 Key 时，请选择「华北2（北京）」地域。"**只加这一句**。

## 5. 不要做的事

- 不修改帧格式、加密、配对协议（`shared/iMicLink.swift`）。
- 不把 Key 发给除百炼官方域名以外的任何地方。自动识别只请求第 4.1 节列出的官方域名。
- 不调用 Token Plan 或 Coding Plan 的地址。
- 不在日志、崩溃信息、测试报告中输出完整的 Key。`IMicLog` 中只记录地域和错误码。
- 不引入新的第三方依赖。

## 6. 单元测试

在现有测试（`tests/` 下的 Mac 设置、润色相关测试，以及 `scripts/test-polish.sh`、`scripts/test-mac-settings.sh`）中补充：

- Key 清理：空格、换行、各种引号、`export X=...` 整行、Windows 换行。
- 地址白名单：接受共享域名、业务空间域名、试用域名；拒绝套餐地址、非 443 端口、HTTP、任意其他主机、带用户名密码的 URL、路径不对的 URL。
- 粘贴 Base URL 后推算出的识别地址和润色地址。
- 自动识别地域：用 `URLProtocol` 模拟各地域的返回（只有一个 200、多个 200、全部 401、部分超时、网络错误），确认选择结果和提示文字。
- 错误码到提示文字的映射，覆盖第 4.4 节表格中的每一种情况。
- 识别出的地域不支持识别模型时的提示。

## 7. 真实接口实测

用本机已经配置好的 Key（**不要打印 Key**）：

1. 对四个共享域名逐个请求 `/models`，记录每个地域的 HTTP 状态码和 `code`。
2. 记录 `/models` 返回的列表中是否包含 `qwen-audio-3.1-asr-flash-message` 和 `deepseek-v4.1-flash`。
3. 如果实现了 4.2 的 WebSocket 空任务检查，实测一次并确认计费依据。
4. 用一个**故意写错**的 Key（例如把现有 Key 的最后一个字符改掉）验证 401 的提示。
5. 用 `./scripts/test-link.sh` 跑一次真实识别，确认改动后识别正常。

如果本机没有可用的 Key，在 PR 中写明"未实测"，只交单元测试结果，**不要**想办法从别处获取 Key。

## 8. PR 中必须附上

1. **调研结论**：第 3 节每一条是否仍然准确，有更新的地方给出新的结论、链接和查阅日期。特别回答：
   - 新注册的个人账号进入百炼控制台时，默认地域是哪个？
   - 新用户默认会看到哪种域名（共享域名、业务空间专属域名还是试用域名）？
   - `qwen-audio-3.1-asr-flash-message` 支持哪些地域？
   - 套餐 Key 的前缀到底是什么？
   - 没有实名认证、免费额度用完时，接口分别返回什么 `code`？
   - 查不到的就写"文档未说明"，不要猜。
2. **第 7 节实测结果**（不含 Key）。
3. **测试报告**：逐项写出命令、结果、耗时和关键输出：
   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
   ./scripts/test-polish.sh
   ./scripts/test-mac-settings.sh
   ./scripts/test-input.sh
   ./scripts/build-mac.sh
   ./scripts/test-link.sh          # 需要真实 Key；没有就写明跳过
   python3 tools/check-site.py
   node tools/test-site-browser.mjs
   ```
4. **界面截图**：向导 Key 页（初始、验证中、成功并显示地域、各类错误提示至少 3 种），可以用 `--ui-preview=setup-key` 等现有的预览参数，或者新增 DEBUG 预览状态。
5. 第 4.4 节每一种错误情况对应的实际提示文字清单。

## 9. 验收清单

- [ ] 只粘贴 Key 就能自动识别地域，不需要用户手动选择。
- [ ] 新加坡地域的 Key 能被正确识别（如果该地域支持识别模型），或者得到"请到北京地域重新创建"的明确提示。
- [ ] 套餐 Key、权限不足、IP 白名单、欠费或未实名认证、网络问题，各有具体的提示和下一步操作。
- [ ] 粘贴时多余的空格、引号、`export` 前缀会被自动清理。
- [ ] 试用域名、业务空间域名可用；套餐地址和任意主机仍然被拒绝。
- [ ] 识别过程中出现的同类错误使用同一套提示。
- [ ] 向导 Key 页有三步引导，粘贴后自动验证。
- [ ] 官网 FAQ 和 README 各只改一处。
- [ ] 不打印完整 Key，不调用非官方地址，不注册账号。
- [ ] 调研结论、实测结果、测试报告和截图都附在 PR 里。
