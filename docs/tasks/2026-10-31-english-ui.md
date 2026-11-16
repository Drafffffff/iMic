# 任务书：支持英文界面（Mac、iOS、官网、README）

日期：2026-10-31
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 的最新提交新建分支 `codex/english-ui`，在这个分支上工作。**不要直接提交到 `codex/ui-phosphor-wireframe`。**
2. 提交说明用简体中文，可以分多次提交（建议按 Mac、iOS、官网、文档分开）。
3. 推送分支：`git push -u origin codex/english-ui`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**。
5. PR 描述必须附第 9 节要求的**全量测试报告和截图**。没有报告的 PR 不予审核。
6. 由 Claude 审核。**不要自行合并**，也不要开启自动合并。
7. 不改 `VERSION` 和 `MAC_BUILD`，不覆盖 `/Applications/iMic.app`，不发布，不改仓库设置。
8. 在 `docs/releases/NEXT.md` 记录：新增英文界面。

---

## 1. 目标与范围

iMic 目前只有简体中文界面。本任务增加**英文界面**，让不会中文的用户也能完成安装、配置和日常使用。

**要做：**

- Mac 和 iOS 两端的全部界面文字：按钮、标签、提示、错误信息、引导、设置、菜单、通知、权限说明（`Info.plist` 中的用途说明）。
- 官网英文版。
- README 英文版。
- 海外用户使用**百炼国际版**（阿里云国际站 Alibaba Cloud Model Studio，新加坡地域）的引导。

**不做：**

- 中、英以外的界面语言。但要把框架搭好，以后加一种语言只需要增加一份翻译文件。
- 不改识别和润色的逻辑，不改润色提示词（见 4.4）。

## 2. 现状（已核实）

- **没有任何本地化基础设施**：代码中没有 `NSLocalizedString`、`String(localized:)`，没有 `.lproj` 目录或 String Catalog。中文直接写在 Swift 字符串里。
- 含中文的字符串字面量大约有：Mac 398 处（16 个文件）、iOS 369 处（21 个文件）、`shared/` 89 处（4 个文件）。其中一部分是日志、注释、测试数据或者送给模型的提示词，**不是**界面文字，不需要翻译（见 4.4）。
- Mac 端没有 Xcode 工程，由 `scripts/build-mac.sh` 用 `swiftc` 编译，`Info.plist` 在脚本里生成。约定：**Mac 端只需要命令行工具即可构建**。
- iOS 用 XcodeGen（`ios/project.yml`）生成工程。
- **Mac 会把显示文字发给 iPhone**：协议消息里有 `message` 字段，Mac 在里面放中文句子（例如 `mac/main.swift` 中的"当前输入框无法安全清空，请在电脑端操作"、"Mac 忙碌或当前输入框不可用"），iPhone 直接显示（`ios/iMic/LinkClient.swift` 约 1005 行、`ios/iMic/SessionModel.swift` 约 147 行）。协议里同时有 `code` 字段。如果两台设备的系统语言不同，iPhone 会显示 Mac 那边的语言，必须处理（见 4.5）。
- 官网在 `site/`，一个 `index.html` 和一个 `404.html`，由 `tools/check-site.py` 和 `tools/test-site-browser.mjs` 检查。
- `AGENTS.md` 现在的规则是"界面语言：技术标签用英文像素字，操作说明用简体中文"，需要更新（见第 7 节）。

## 3. 语言选择规则

- **跟随系统语言**：系统首选语言是中文（简体，包括 `zh-Hans`、`zh-CN`，以及其他中文变体），显示简体中文；**其他任何语言都显示英文**。
- **开发语言（兜底语言）设为英文**：找不到某个翻译时显示英文，而不是中文。
- App 内**不做**单独的语言切换开关。用户可以在系统设置中给单个 App 指定语言（macOS：系统设置 → 通用 → 语言与地区 → 应用程序；iOS：设置 → iMic → 语言），这需要 App 正确声明支持的语言。
- 技术标签（`HOLD`、`STRING`、`LIVE`、`POLISH`、`SYS 01`、`RX / 01` 这类英文像素字）**两种语言下都保持英文，不翻译**。
- 两端语言各自独立，iPhone 和 Mac 可以显示不同的语言。

## 4. 实现要求

### 4.1 iOS

- 使用 String Catalog（`ios/iMic/Localizable.xcstrings`），源语言英文，包含简体中文翻译。在 `ios/project.yml` 中设置开发语言为 `en`，`knownRegions` 包含 `en` 和 `zh-Hans`。
- SwiftUI 中的 `Text("...")` 会自动查找本地化；非 `Text` 的地方（例如传给自定义组件的 `String`、`message` 变量、触感或语音提示）使用 `String(localized:)`。
- `Info.plist` 中的权限用途说明（麦克风、语音识别、本地网络、蓝牙等）用 `InfoPlist.xcstrings` 提供英文和中文。
- 首次引导（`ios/iMic/` 中的 Onboarding / Guide 相关文件）、设置页、连接电脑页、错误提示全部覆盖。
- `--ui-preview=*` 等 DEBUG 预览参数继续可用。可以用 `-AppleLanguages "(en)"` 启动参数切换语言做截图。

### 4.2 Mac

- 只能用命令行工具构建。两种方式任选，在 PR 中说明理由：
  - `en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings`，由 `build-mac.sh` 复制到 `iMic.app/Contents/Resources/`；或者
  - String Catalog（`.xcstrings`），由 `build-mac.sh` 在构建时编译成 `.strings`。注意：`xcstringstool` 随 Xcode 提供，**只装命令行工具时可能没有**，必须确认只装命令行工具也能构建，或者提供回退。
- 生成的 `Info.plist` 加上 `CFBundleDevelopmentRegion = en` 和 `CFBundleLocalizations = [en, zh-Hans]`。
- 代码中用 `NSLocalizedString` 或 `String(localized:)`（macOS 13 可用）。
- 覆盖：主窗口、菜单栏菜单、设置窗口全部分页、首次设置向导（`mac/Onboarding.swift`）、配对界面、所有错误提示，包括 `mac/CloudFailure.swift` 中刚加入的百炼错误提示、自动更新相关文字（`mac/Updater.swift`、设置「通用」页）、系统通知。
- Sparkle 自带的更新窗口有自己的本地化，确认它跟随系统语言即可。

### 4.3 `shared/` 中的文字

- `shared/` 中的界面文字（例如润色模式、语气、输出语言的显示名称）两端都会用到。iOS 和 Mac 的资源包不同，请设计一个两端都能工作的方式，例如在 `shared/` 中只定义**稳定的 key 或枚举**，显示名称由各端自己的本地化文件提供；或者让 `shared/` 的函数接收一个 `Bundle` 参数。不要在两端重复维护两套不一致的翻译。
- `swift test`（`tests/iMicLinkTests/`）必须继续通过。

### 4.4 不翻译的内容

以下内容**保持原样**，在 PR 中列出你判断为"不翻译"的字符串类别和数量：

- **送给模型的润色提示词**（`shared/PolishOptions.swift`、`mac/DeepSeek.swift` 等处的 system prompt）。文言文、废话文学、阴阳怪气、翻译腔这些模式是中文特色，提示词不变；输出语言仍由用户在中、英、日、韩中选择。**界面上显示的模式名称要翻译**，例如"文言文"在英文界面中显示为 Classical Chinese，并加一句简短说明。英文名称由你拟定，在 PR 中列出对照表。
- 日志（`IMicLog`）、调试输出、注释、单元测试中的样例文字。
- 演示脚本中的语音和文字（`ios/iMic/Demo/`，仅 DEBUG）。
- 协议字段名和错误码。

### 4.5 Mac 发给 iPhone 的显示文字

- iPhone 应该用**自己的语言**显示 Mac 返回的状态和错误，不能直接显示 Mac 发来的中文句子。
- 优先方案：iPhone 根据协议中已有的 `code` 字段，在本地查找对应的翻译显示；`message` 只作为没有对应 `code` 时的兜底。
- 先检查 Mac 现在发送的每一种 `message` 是否都带有可区分的 `code`。如果有的没有带，需要补上：
  - **只增加新的 `code` 值、不改帧格式和字段**，也属于协议改动。按 `AGENTS.md` 的要求，必须同时更新 `shared/iMicLink.swift`、`tests/iMicLinkTests/LinkTests.swift`、`docs/PROTOCOL.md`、Mac `LinkServer.swift` 和 iPhone `LinkClient.swift`。
  - 必须兼容旧版本：新 iPhone 连接旧 Mac 时（没有新 `code`），显示 `message` 兜底；旧 iPhone 连接新 Mac 时，`message` 仍然有内容。
  - 帧格式、密钥派生、配对码规则不改。
- 兜底的 `message` 文字由 Mac 按 Mac 自己的系统语言生成。

### 4.6 英文文案要求

- 简洁、友好，与中文版的口吻一致，不要逐字直译。按钮用动词开头（"Paste"、"Verify"、"Open Console"）。
- 术语统一，在 PR 中附一张术语对照表，至少包括：百炼 → Alibaba Cloud Model Studio（首次出现时写 "Model Studio (Bailian)"）、API Key、配对码 → pairing code、弦 → string、润色 → polish、实时预览 → live preview、辅助功能 → Accessibility、业务空间 → workspace、地域 → region。
- 警告和风险说明**必须完整翻译**，不能省略：实时预览可能重复或误删、清空可能被拒绝、切换应用后不自动输入、终端中多行变一行、费用说明、隐私说明。
- 中文文案**不要改动**，除非为了抽取到本地化文件而必须调整（例如拼接字符串改为带参数的格式化字符串）。
- 带参数的文字用格式化占位符（例如 `%@`、`%lld`），不要用字符串拼接，以便英文语序正确。数字、时长用 `Formatter` 按语言格式化。

### 4.7 百炼国际版引导

海外用户应该使用阿里云**国际站**的 Model Studio，而不是中国站的百炼控制台。

- 先查阅公开文档确认（**不要注册或登录任何账号**）：
  - 国际站 Model Studio 控制台和 API Key 页面的地址；
  - 国际站账号可以使用哪些地域，是否包括新加坡；
  - 国际站新用户是否有免费额度；
  - `qwen-audio-3.1-asr-flash-message` 和 `deepseek-v4.1-flash` 在新加坡地域是否可用（之前的调研显示语音模型在北京和新加坡可用，请再确认润色模型）。
- 英文界面的 Key 引导步骤改为指向国际站控制台，并提示选择新加坡地域。中文界面保持现在的北京引导，另加一行小字："海外账号请使用阿里云国际站，在新加坡地域创建 Key。"
- 地域自动识别（`BailianDiscovery`，PR #8 已实现）已经包含新加坡，确认国际站的 Key 能被正确识别。如果国际站的 Key 使用不同的域名，或者需要不同的验证方式，在 PR 中说明，并**另行列出需要改动的地方，不要在本任务中改识别逻辑**。
- 如果润色模型 `deepseek-v4.1-flash` 在新加坡不可用：在 PR 中说明，并给出建议，但不要在本任务中更换默认模型。

### 4.8 官网英文版

- 新建 `site/en/index.html`（以及 `site/en/404.html`，或者让 404 页面同时提供两种语言的链接）。结构、视频、动画与中文版完全一致，只翻译文字。
- 共用 `site/assets/` 下的 CSS、JS、视频和图片，**不要复制资源**。JS 中如果有中文文字（例如分享成功提示、下载按钮模板），改为从页面的 `data-*` 属性读取，或者按 `<html lang>` 选择。
- 页头加语言切换链接："中文 / EN"。
- 首次访问时，如果浏览器语言不是中文，并且当前在中文页，在页面顶部显示一条可关闭的提示"English version available →"。**不要自动跳转**，不要用 Cookie（官网承诺"无 Cookie"），关闭状态最多存到 `sessionStorage`；如果官网目前完全不使用存储，就每次都显示，在 PR 中说明你的选择。
- `<link rel="alternate" hreflang="zh-Hans">`、`hreflang="en"`、`hreflang="x-default"`，以及英文版各自的 `og:` 和 `twitter:` 元数据。
- iPhone 引导里使用的深链接 `?from=ios#download` 在英文版也要能用（`site/en/?from=ios#download`）。英文界面的 iPhone App 应链接到英文版。
- 英文版的"任意输入框"示意动画中的示例句子改用英文。
- 更新 `tools/check-site.py` 和 `tools/test-site-browser.mjs`，覆盖英文页：引用、锚点、无障碍属性、语言切换链接、hreflang、下载逻辑、`from=ios`、提示条不自动跳转。

### 4.9 README

- 新建 `README.en.md`，内容与中文 `README.md` 对应，同样简洁，使用同一个演示动图 `docs/media/demo.gif`。
- 在中文 `README.md` 标题下方的链接行中加一个 "English" 链接，指向 `README.en.md`。中文 README 其他内容不改。
- `README.en.md` 中的百炼步骤写国际站。
- 注意：`main` 分支的 README 是单独同步的，**本任务只改 `codex/ui-phosphor-wireframe` 上的文件**，同步到 `main` 由 Claude 审核后处理。

## 5. 不要做的事

- 不改帧格式、密钥派生、配对码规则；新增 `code` 值必须按 `AGENTS.md` 同步更新五处（见 4.5）。
- 不改润色提示词，不改识别和润色的逻辑与默认模型。
- 不改中文文案的意思。
- 不在 App 内加语言切换开关。
- 不引入第三方本地化库。
- 不注册、不登录阿里云账号。

## 6. 防止遗漏

- 写一个检查脚本（例如 `tools/check-l10n.py`），在 Mac 和 iOS 的界面代码中找出**仍然直接写死的中文字符串**，排除日志、注释、测试、提示词、Demo 等白名单路径或标记。PR 中附上脚本输出，剩余的每一处都要说明理由。
- 检查两份翻译的 key 完全一致，没有缺失，没有多余；格式化占位符的数量和类型一致。
- 把这个检查加进 `scripts/` 中现有的某个测试脚本，或者新建 `scripts/test-l10n.sh`。

## 7. 文档更新

- `AGENTS.md`「品牌与版本」中的界面语言规则改为："界面语言：技术标签用英文像素字；操作说明支持简体中文和英文，跟随系统语言，兜底为英文。新增或修改界面文字时，必须同时提供中英文。"
- `docs/DEVELOPMENT.md` 增加一节"本地化"：文件在哪里、怎么加新文字、怎么检查、怎么用英文启动做截图。

## 8. 截图（附在 PR 里）

放在 `docs/reviews/english-ui/`，**每张都要中英文各一张**：

- iOS：首次引导的每一页、主页（idle、录音中、结果）、连接电脑页、配对、设置页、至少两种错误提示。用 `--ui-preview=*` 和 `-AppleLanguages "(en)"` 在专用模拟器上截取（自己创建，用完删除，不要动其他模拟器）。
- Mac：设置向导两步（包括百炼 Key 页的一种错误提示）、主窗口、设置窗口全部分页、菜单栏菜单。可以用 `scripts/test-mac-settings.sh` 现有的截图能力或 DEBUG 预览参数。
- 官网：英文版 1440×900 首屏、390×844 首屏、整页长截图，以及中文页上的"English version available"提示条。
- 检查英文较长导致的截断、换行和重叠，尤其是按钮、菜单、设置页标签、iOS 小屏（用 iPhone SE 尺寸模拟器至少截一组）。

## 9. 测试报告（附在 PR 里）

逐项写出命令、结果（PASS/FAIL）、耗时和关键输出：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-mac.sh
./scripts/test-mac-settings.sh
./scripts/test-polish.sh
./scripts/test-input.sh
./scripts/test-asr.sh
./scripts/build-ios.sh
./scripts/test-ios-mac-selection.sh
./scripts/test-ios-reconnect.sh
./scripts/test-polish-link.sh
python3 tools/check-site.py
node tools/test-site-browser.mjs     # 用本 worktree 自己起的 HTTP 服务（IMIC_SITE_URL），不要用 8000 端口上别人的服务
python3 tools/check-l10n.py          # 或你新建的检查脚本
```

另外附上：

- 只装命令行工具时 Mac 能否构建的说明（如果用了 `xcstringstool`）。
- 协议改动（如果有）：新增了哪些 `code`，新旧版本兼容的测试结果。
- 术语对照表、润色模式英文名称对照表。
- 第 4.7 节百炼国际版的调研结论（链接和查阅日期；查不到的写"文档未说明"）。
- 第 6 节检查脚本的输出。

## 10. 验收清单

- [ ] Mac、iOS 跟随系统语言：中文显示中文，其他语言显示英文，缺失翻译时兜底英文。
- [ ] 两端全部界面文字（包括错误提示、引导、设置、权限说明、更新相关文字）都有英文。
- [ ] 技术标签保持英文像素字；润色提示词未改；中文文案意思未改。
- [ ] iPhone 按自己的语言显示 Mac 返回的状态和错误；协议改动（如果有）按规定同步，新旧版本兼容。
- [ ] Mac 只用命令行工具仍可构建。
- [ ] 英文界面的百炼引导指向国际站并提示新加坡地域，调研结论附在 PR 中。
- [ ] 官网英文版完整，语言切换、hreflang、`from=ios`、提示条都正常，不自动跳转、不用 Cookie。
- [ ] `README.en.md` 已建，中文 README 只加一个链接。
- [ ] 遗漏检查脚本通过，翻译 key 一致。
- [ ] `AGENTS.md` 和 `docs/DEVELOPMENT.md` 已更新。
- [ ] 截图（中英文对照、小屏）和全量测试报告附在 PR 里。
