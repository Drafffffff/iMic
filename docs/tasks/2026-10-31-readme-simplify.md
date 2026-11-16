# 任务书：README 大幅简化

日期：2026-10-31
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 在分支 `codex/readme-simplify` 上工作，这个分支从 `codex/ui-phosphor-wireframe` 的最新提交创建。如果启动时你已经处在为此准备好的 worktree 和分支里，直接使用。**不要直接提交到 `codex/ui-phosphor-wireframe`。**
2. 提交说明用简体中文。
3. 推送分支：`git push -u origin codex/readme-simplify`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**。
5. PR 描述必须附第 6 节要求的检查报告。
6. 由 Claude 审核。**不要自行合并**，也不要开启自动合并。
7. **只改文档**：`README.md`、新建的 `docs/DEVELOPMENT.md`，以及第 4 节列出的引用修正。不要改 `site/`、App 代码、脚本逻辑和 `docs/releases/NEXT.md`。另一个任务（`codex/landing-ia`）正在同时修改 `site/` 和 `NEXT.md`，不要和它冲突。

---

## 1. 目标

现在的 `README.md` 有 262 行，几乎全是技术细节：协议、加密、动画实现、待机节能参数、测试命令等。普通用户打开 GitHub 页面，看不出 iMic 是什么、怎么装。

新的 README 面向**普通用户**：

- 介绍内容与官网 https://drafffffff.github.io/iMic/ 保持一致（文案以 `site/index.html` 为准）。
- 重点是**安装教程**：从下载到第一次用 iPhone 输入文字。
- **不放任何技术性介绍**：不提协议、加密算法、Bonjour、GATT、Metal、采样率、帧格式、源码目录、构建命令、测试命令。
- 篇幅控制在 **120 行以内**（不含空行），读完不超过 3 分钟。

README 还会被 `scripts/package-release.sh` 复制进 Mac 的 DMG 安装包，所以它本身就应该是一份用户说明。

## 2. 新 README 结构

按下面的顺序写。标题和措辞可以调整，但内容不能缺。

### 2.1 开头

- 标题 `# iMic`，下面一行链接：官网 · 下载 Mac 版 · 隐私说明 · 反馈。
- 一句话介绍，与官网首屏一致："按住说话，松手即输入。iPhone 当 Mac 的麦克风，说完松手，文字直接打进你正在用的任何应用。"
- 可以放一张官网首屏海报图：`site/assets/img/hero.png`（相对路径），加上 alt 文字。**不要嵌入视频文件**。注意：`codex/landing-ia` 可能会重新生成这张图，但路径不变，直接引用即可。

### 2.2 亮点（与官网一致）

用 4–6 条短列表，每条一行，对应官网的这些内容：

- 按住说话，松手发射：文字落到 Mac 当前输入处。
- 弦手势：下拉发射回车、上拨删字、左右移光标、拉到顶清空。
- AI 润色：口语整理成书面文字，还有 Agent 指令、终端命令、文言文、废话文学、翻译腔几种模式；润色完成时有扫光提示。
- 8-bit 音效，可以关闭。
- 支持任何能打字的 Mac 应用，已测试 TextEdit、Safari、Chrome、Terminal、Cursor、Zed、iTerm、Otty。
- 隐私：直连自己的 Mac，Key 留在 Mac，没有自建服务器。

### 2.3 你需要准备

- 一台 Mac：macOS 13 或更高，Apple Silicon 和 Intel 都可以。
- 一部 iPhone：iOS 17 或更高。
- 一个阿里云百炼 API Key（识别和润色按量计费），附获取链接：https://bailian.console.aliyun.com/?tab=model#/api-key
- Mac 和 iPhone 连接同一个 Wi-Fi。

### 2.4 安装教程（重点，写得最细）

用编号步骤，每步一两句话，用户照着做就能完成。

**第一步：安装 Mac 版**

1. 从官网下载区或 [GitHub Releases](https://github.com/Drafffffff/iMic/releases/latest) 下载 `iMic-<版本号>-macOS-universal.dmg`。README 里**不要写死版本号**，用"最新版本"或通配写法。
2. 打开 DMG，把 iMic 拖进「应用程序」。
3. 从「应用程序」打开 iMic。安装包已通过 Apple 公证，可以直接打开。
4. 按设置向导操作：先填入百炼 API Key，再开启「辅助功能」权限（向导里点「去开启」，在系统设置里打开 iMic 的开关）。
5. 完成后，iMic 会常驻在菜单栏。

**第二步：安装 iPhone 版**

- TestFlight 公开测试即将开放，开放后从官网下载区获取链接（与官网下载卡片的说法一致）。
- 高级用户可以下载 Releases 中未签名的 IPA，用 AltStore、Sideloadly 等工具自行签名安装。这一条用一句话带过，不展开签名细节。

**第三步：配对**

1. 打开 iPhone 上的 iMic，按引导操作（引导里可以先练习手势）。
2. 在 iPhone 上选择你的 Mac，输入 Mac 窗口里显示的 6 位配对码。
3. 配对完成后，以后打开就会自动连接。

**第四步：开始输入**

1. 在 Mac 上点进任意输入框。
2. 按住 iPhone 底部的橙色横条说话，松开后文字就会输入进去。上滑后松开可以取消。
3. 下拉中间的弦再松开，相当于按回车；往上拨删除一个字；左右滑动移动光标。

每一步的说法以 App 的实际界面和官网文案为准。如果不确定某个按钮的名称，查看 `mac/Onboarding.swift`、`ios/iMic/` 中的引导界面文字，**不要编造界面上没有的名称**。

### 2.5 常见问题

写 5–8 条，每条一个问题加一两句回答。从现有 README 的「Mac 常见问题」和「已知边界」，以及官网 FAQ 中挑选，改写成普通用户能看懂的话：

- iPhone 找不到 Mac：确认在同一 Wi-Fi，在「系统设置 → 隐私与安全性 → 本地网络」允许 iMic。访客网络或公司网络可能禁止设备互相访问，这时可以在 Mac 设置里开启蓝牙兜底（速度会慢一些）。
- 辅助功能开关已打开但没有效果：在系统设置的列表中选中 iMic，点「−」删除，再回到 iMic 重新开启。
- 文字没有输入进去：识别完成时如果你已经切换到别的应用，iMic 不会自动输入，文字会保留，可以复制。
- 实时预览会不会改错字：**这一条必须保留**（`AGENTS.md` 要求向用户说明这个风险）。用一两句大白话说明：实时预览默认关闭；部分应用无法核实输入结果，可能出现重复或误删；你自己动了键盘或鼠标后，本轮就不再自动修改。
- 要花多少钱：识别和润色按百炼的用量计费，以阿里云官网为准。
- 语音会被上传吗：音频由你自己的 Mac 发送给百炼识别；开启润色时文字会发给你选择的服务。iMic 没有自己的服务器。链接到 `docs/PRIVACY.md`。
- 如何卸载：退出 iMic，删除「应用程序」中的 iMic，以及 `~/Library/Application Support/iMic` 文件夹。（这里的路径是用户操作必需的，可以保留。）

### 2.6 结尾

- 反馈：邮件 `i0.0ia@qq.com` 或 GitHub Issue；提醒不要在公开反馈里贴 API Key。
- 一行小字："开发者请看 [开发文档](docs/DEVELOPMENT.md)。" 这是 README 中唯一指向技术内容的地方。
- 许可：GPL-3.0，一行。

## 3. 技术内容迁移到 `docs/DEVELOPMENT.md`

现有 README 中所有技术内容**不能直接删除**，要原样迁移到新文件 `docs/DEVELOPMENT.md`，包括：

- 源码构建环境、快速开始里的构建与安装步骤（Mac、iPhone）
- Mac 常见问题中的技术细节（Key 的读取顺序、环境变量名、App Translocation、`defaults delete` 等）
- 设计（协议、加密、音频、输入、隐私实现）
- 目录结构
- 开发验证的全部命令
- 重新打包发布文件
- 蓝牙兜底、实时预览与润色、波形复看、调试日志、音频可靠性等章节
- 官网演示视频的重新生成说明（`./scripts/site-demo.sh`）
- 开头那段关于中心弦、实时文字与波形、待机节能、文字转换的详细技术描述
- Mac 设置分页
- 原 README「下载与安装」中关于签名、公证主体、IPA 签名方式、TestFlight 发布流程的技术说明

要求：

- `docs/DEVELOPMENT.md` 开头写一段简短说明（这是开发者文档，用户说明见 README），并加一个目录。
- 内容按主题重新排列分组即可，**不要改动技术事实和命令**。迁移完成后逐条核对，确保原 README 的每一段都能在新 README 或 `DEVELOPMENT.md` 中找到对应内容（见第 6 节）。
- 原 README 中有些描述可能已经过时（例如第一步安装说"两步设置窗口"、用了"WELCOME → MAC → …"这样的引导步骤名）。迁移时保持原文；如果你发现明显与代码不符的地方，在 PR 里列出来，**不要擅自修改**。

## 4. 引用修正

以下文件引用了 README 中的技术内容，需要改为指向 `docs/DEVELOPMENT.md`（只改引用，不改其他内容）：

- `docs/ARCHITECTURE.md` 第 114 行附近："此风险在设置和 README 明示"。新 README 的常见问题里仍有这条风险说明，所以这句话可以保留；如果你调整了措辞，确保它仍然准确。
- `docs/TESTFLIGHT-TEAM-REQUEST.md` 第 79 行附近：`README.md` 的描述改为"用户说明"，并补一行 `docs/DEVELOPMENT.md`（开发者说明）。
- 用 `grep -rn "README" docs scripts tools AGENTS.md --include=*.md --include=*.sh --include=*.py` 检查其他引用，例如"见 README 的 xx 章节"这类写法，改为指向 `DEVELOPMENT.md` 的对应章节。`docs/tasks/` 和 `docs/releases/` 中的历史文件不要改。

## 5. 写作要求

- 简体中文，口吻与官网一致：简洁、友好，不卖弄。
- 技术标签（如 macOS、iOS、API Key、Wi-Fi）保持英文，说明文字用中文。
- 不使用 emoji，不用徽章（badge）堆砌。
- 所有链接都要可用：官网、Releases、百炼控制台、`docs/PRIVACY.md`、`docs/DEVELOPMENT.md`、Issue 页面。
- 不写死版本号（`VERSION` 会变）。

## 6. 检查报告（附在 PR 里）

1. **行数**：新 README 的非空行数（`grep -cv '^\s*$' README.md`），必须 ≤ 120。
2. **无技术词**：运行下面的命令，结果必须为空。如果某个词确实是用户操作必需的，在报告中逐条说明理由：
   ```bash
   grep -niE 'bonjour|tcp|gatt|curve25519|hkdf|aes|nonce|metal|pcm|khz|swift|xcode|xcodegen|swift test|scripts/|帧|协议|采样' README.md
   ```
3. **迁移完整性**：列一张表，左边是原 README 的每个二级、三级标题（以及开头的每个要点），右边写它在新 README 或 `docs/DEVELOPMENT.md` 中的位置。不能有遗漏。
4. **链接检查**：列出 README 和 `DEVELOPMENT.md` 中的所有链接，相对路径要确认文件存在，外部链接用 `curl -sI` 确认返回 200 或 3xx。
5. **与官网一致**：列出 README 中的亮点和要求，以及对应的 `site/index.html` 原文。
6. **渲染预览**：用 `gh markdown-preview` 或把 README 推送后在 GitHub 分支页面查看渲染效果，附一张截图。
7. **疑似过时内容清单**（见第 3 节），没有就写"无"。
8. `bash -n scripts/package-release.sh` 通过（确认没有误改脚本）。

## 7. 验收清单

- [ ] README 面向普通用户，非空行 ≤ 120，没有技术性介绍。
- [ ] 介绍内容与官网一致，安装教程覆盖：准备、Mac 安装、iPhone 安装、配对、开始输入。
- [ ] 常见问题里有实时预览风险说明。
- [ ] 原有技术内容完整迁移到 `docs/DEVELOPMENT.md`，技术事实和命令没有改动。
- [ ] 引用已修正，历史任务书和发布说明未改动。
- [ ] 没有改动 `site/`、`docs/releases/NEXT.md`、App 代码和脚本。
- [ ] PR 附完整检查报告。
