# 任务书：Mac 自动更新

日期：2026-10-31
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 的最新提交新建分支 `codex/mac-auto-update`，在这个分支上工作。**不要直接提交到 `codex/ui-phosphor-wireframe`。**
2. 提交说明用简体中文，可以分多次提交。
3. 推送分支：`git push -u origin codex/mac-auto-update`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**。
5. PR 描述必须附第 9 节要求的**全量测试报告**。没有报告的 PR 不予审核。
6. 由 Claude 审核。**不要自行合并**，也不要开启自动合并。
7. **不要发布**：不创建或修改 GitHub Release，不上传 appcast，不改 `VERSION`，不覆盖 `/Applications/iMic.app`（不要运行 `install-mac.sh`），不改仓库设置。
8. **私钥绝不进仓库。** 更新签名私钥只存在发布者的钥匙串或本机文件里；仓库里只放公钥。测试用的临时密钥对只能放在 `build/` 下，用完删除。
9. 在 `docs/releases/NEXT.md` 记录：Mac 自动更新。
10. 同时进行的任务 `codex/bailian-onboarding` 会修改 `mac/Onboarding.swift`、`mac/Credentials.swift`、`mac/SettingsWindow.swift` 的百炼页。本任务尽量只在 `SettingsWindow.swift` 的「通用」页和菜单里加入口，不要改百炼相关代码。

---

## 1. 目标

用户安装 iMic 后，有新版本时 App 能自己发现、下载、校验并完成替换，不需要再手动去官网下载 DMG。

- 只做 **Mac 端**。iPhone 端通过 TestFlight 或 App Store 更新，不在本任务范围内。
- 更新过程必须安全：只接受由发布者签名的更新包，下载内容被篡改时必须拒绝。
- 更新后**辅助功能授权不能失效**。这是 iMic 的核心权限，失效会让用户以为软件坏了。

## 2. 现状（已核实）

- Mac 端没有 Xcode 工程，由 `scripts/build-mac.sh` 直接调用 `swiftc` 编译，`Info.plist` 也在脚本里生成。约定是：**Mac 端只需要命令行工具即可构建**（脚本里的提示语）。
- `CFBundleIdentifier` 是 `com.drafffffff.imic`。`CFBundleShortVersionString` 读取 `VERSION`（当前 1.4.4）。**`CFBundleVersion` 固定为 `1`**。
- 发布由 `scripts/package-release.sh` 完成：Developer ID（团队 5H39F98ND4）签名、公证、生成 `iMic-<版本>-macOS-universal.dmg` 和 `SHA256SUMS.txt`，上传到 GitHub Releases（最新为 `v1.4.4`）。
- 官网在 GitHub Pages：https://drafffffff.github.io/iMic/ ，源码在 `site/`，由 `.github/workflows/pages.yml` 部署。
- **发布习惯**：项目还没正式发布，经常**原地覆盖**同一个版本号（例如多次重新发布 1.4.4）。这对自动更新是个问题，见第 4 节。

## 3. 方案：Sparkle 2

使用 [Sparkle 2](https://sparkle-project.org/)（MIT 许可，与 GPL-3.0 兼容），不要自己从零写更新器。Sparkle 已经处理好了 EdDSA 签名校验、下载、替换、App Translocation、权限和重启这些容易出错的环节。

### 3.1 引入方式

- 只用命令行工具构建，不引入 Xcode 工程：
  - 新建 `scripts/fetch-sparkle.sh`：下载**固定版本**的 Sparkle 官方发布包（GitHub Releases 上的 `Sparkle-<版本>.tar.xz`），**校验 SHA-256**（哈希写死在脚本里）后解压到 `build/vendor/Sparkle/`。版本号和哈希写在脚本开头，方便以后升级。
  - `build-mac.sh` 用 `-F build/vendor/Sparkle -framework Sparkle` 编译，并加上 `-Xlinker -rpath -Xlinker @executable_path/../Frameworks`；把 `Sparkle.framework` 复制到 `iMic.app/Contents/Frameworks/`。
  - `build/` 已在 `.gitignore` 中，**不要把 Sparkle 二进制提交进仓库**。
  - 第三方声明：在 `THIRD_PARTY_NOTICES.md` 中加上 Sparkle 的许可声明。
- 签名：`package-release.sh` 目前用 `codesign --options runtime` 签整个 App。嵌入 Sparkle 后，要先按 Sparkle 文档的要求由内向外签名：`Autoupdate`、`Updater.app`、XPC 服务（如果使用）、`Sparkle.framework`，最后签 `iMic.app`。**不要使用 `--deep`**。签完运行 `codesign --verify --deep --strict` 和 `spctl -a -vv`。
- iMic 没有开启 App Sandbox，所以**不需要** Sparkle 的 Installer XPC 服务。如果你判断需要，在 PR 里说明理由。

### 3.2 App 内集成

- 新建 `mac/Updater.swift`，用 `SPUStandardUpdaterController` 启动。
- `Info.plist`（在 `build-mac.sh` 中生成）新增：
  - `SUFeedURL` = `https://drafffffff.github.io/iMic/appcast.xml`
  - `SUPublicEDKey` = 公钥（见 3.3）
  - `SUEnableAutomaticChecks` = `true`
  - `SUScheduledCheckInterval` = `86400`（每天检查一次）
  - `SUAutomaticallyUpdate` 默认 `false`：发现新版本时**询问用户**，不静默安装。
- 入口：
  - 菜单栏右键菜单加「检查更新…」。
  - 「设置 → 通用」加两项：「自动检查更新」（默认开启）、「自动下载并安装更新」（默认关闭），以及一行当前版本号，格式为「1.4.4 (12)」。
  - 文案：技术标签用英文像素字，说明用简体中文，遵守 `AGENTS.md`。
- **不能打断用户输入**：
  - 正在录音、识别、润色、扫光或输入文字时（`currentSession != nil`、`inserting`、`clearingInput`、`polishEffect` 正在进行等，以 `mac/main.swift` 中的实际状态为准），**不弹更新窗口，也不重启**。用 Sparkle 的 delegate（例如 `SPUUpdaterDelegate` / `SPUStandardUserDriverDelegate` 的相关方法）推迟到空闲时再处理。
  - 用户选择「安装并重启」时，如果 iPhone 正在连接，先断开会话，再退出。
- 首次启动的设置向导没完成时（`mac/Onboarding.swift`），不弹更新提示，避免和向导叠在一起。

### 3.3 更新签名密钥

- 用 Sparkle 自带的 `generate_keys` 生成 EdDSA 密钥对。**这一步由发布者在本机执行**，私钥保存在发布者的登录钥匙串里（这是 `generate_keys` 的默认行为）。
- 你需要：
  1. 在 `docs/RELEASING.md`（新建，或者并入现有的发布文档）中写清楚发布者一次性的操作步骤：运行 `generate_keys`，把输出的公钥填到哪里，如何备份私钥（`generate_keys -x` 导出到安全位置，**不要放进仓库或云盘的公开目录**）。
  2. 公钥写在 `build-mac.sh` 读取的一个文件里（例如 `mac/sparkle-public-key.txt`）。**这次 PR 先放一个占位值**，并让 `package-release.sh` 在检测到占位值时直接报错退出，防止发出没有正确公钥的版本。开发构建（`build-mac.sh`）遇到占位值时可以继续构建，但要关闭自动检查更新。
- 测试时用你自己生成的临时密钥对（放在 `build/` 下，测完删除），不要动发布者的钥匙串。

## 4. 版本号与原地覆盖的问题

Sparkle 用 `CFBundleVersion` 判断哪个版本更新。现在它固定是 `1`，而且发布者经常原地覆盖同一个版本号，这样用户的 App 永远不会认为有新版本。

要求：

- 新增仓库根目录文件 `BUILD`，内容是一个整数构建号，从 `1` 开始。`build-mac.sh` 把它写进 `CFBundleVersion`。
- **每次发布（包括原地覆盖同一个 `VERSION`）都必须把 `BUILD` 加 1。** `package-release.sh` 在发布前检查：如果 `BUILD` 不大于 appcast 中已有的最大构建号，就报错退出并提示先把 `BUILD` 加 1。
- iOS 的 `CURRENT_PROJECT_VERSION` 不在本任务范围内，不要修改。
- 在 `AGENTS.md` 的「品牌与版本」中加一行：`BUILD` 是 Mac 构建号，每次发布都加 1，原地覆盖也不例外。

## 5. appcast 与发布流程

- appcast 托管在 GitHub Pages：`site/appcast.xml`，地址 `https://drafffffff.github.io/iMic/appcast.xml`。
- 每个条目的下载地址指向 GitHub Releases 上的 DMG（`https://github.com/Drafffffff/iMic/releases/download/v<版本>/iMic-<版本>-macOS-universal.dmg`），并带上 EdDSA 签名（`sparkle:edSignature`）、文件长度、`sparkle:version`（= BUILD）、`sparkle:shortVersionString`（= VERSION）、`sparkle:minimumSystemVersion`（13.0）。
- 更新说明：appcast 条目的 `<description>` 或 `sparkle:releaseNotesLink` 指向 `docs/releases/v<版本>.md` 渲染后的内容。如果用链接，确认在 Sparkle 窗口里能正常显示；最简单可靠的做法是在 appcast 里内嵌一小段 HTML。
- `package-release.sh` 新增一步（只在设置了发布身份时执行）：用 Sparkle 的 `sign_update` 对最终公证过的 DMG 签名，然后生成或更新 `site/appcast.xml` 的条目。可以用 Sparkle 的 `generate_appcast`，也可以写一个小脚本，**但签名必须针对最终上传的那个 DMG**（公证、staple 之后）。
- **原地覆盖同一版本时**：DMG 内容变了，签名和长度也会变。appcast 中同一版本的条目必须替换为新的签名、长度和新的 BUILD，不能保留旧签名，否则用户会下载失败。
- `site/appcast.xml` 的改动会随官网部署。在 `docs/RELEASING.md` 中写清楚顺序：**先上传 DMG 到 Release，再推送 appcast**，避免 appcast 指向还不存在的文件。
- `tools/check-site.py` 加一项检查：如果 `site/appcast.xml` 存在，它必须是合法的 XML，每个条目都有 `sparkle:edSignature`、`length`、`sparkle:version`，下载地址都以 `https://github.com/Drafffffff/iMic/releases/download/` 开头。本 PR 提交的 `site/appcast.xml` 可以是一个**没有条目**的空 channel；第一个真实条目由发布者发布时生成。

## 6. 辅助功能授权在更新后保持有效

- macOS 的 TCC 按代码签名的 designated requirement（团队 ID + Bundle ID）识别 App。只要新版本用**同一个 Developer ID 证书**签名、Bundle ID 不变，辅助功能授权就会保留。
- 你需要验证这一点（见第 8 节），并在 `docs/RELEASING.md` 中写明：**发布版必须用 Developer ID（5H39F98ND4）签名**；用 ad-hoc 签名的开发构建（`IMIC_SIGNING_IDENTITY=-`）自动更新后会丢失授权，这是预期行为。
- 遵守 `AGENTS.md`：不修改 TCC，不自动批准权限。如果更新后检测到授权丢失，沿用现有的提示和修复流程（README 和 `docs/DEVELOPMENT.md` 里「移除后重新添加」的说明）。

## 7. 隐私与官网

- 检查更新会访问 GitHub Pages 和 GitHub Releases。**关闭 Sparkle 的系统信息上报**（`SUEnableSystemProfiling` = `false`），不发送任何设备信息。
- 更新 `docs/PRIVACY.md`：说明 App 每天会访问一次 `drafffffff.github.io` 检查更新，可以在设置里关闭；不发送任何个人信息或使用数据。
- 官网 FAQ（`site/index.html`）加一条「怎么更新？」：iMic 会自动检查更新，也可以在菜单中手动检查。**只加这一条**，不要改官网的其他部分。
- README 不用改。

## 8. 验证方案（必须真实跑通，不能只看单元测试）

在你自己的测试环境中，用临时密钥对和本地 appcast 完成一次完整的更新：

1. 用临时密钥构建两个版本：A（`BUILD=100`，`VERSION` 不变）和 B（`BUILD=101`），都用 ad-hoc 签名即可。如果本机钥匙串中有 Developer ID 证书可用，**另外**用 Developer ID 签名再做一轮，用来验证辅助功能授权在更新后保留（见第 6 节）。如果没有证书或不方便使用，在 PR 中写明"未验证 Developer ID 下的授权保留"，交给发布者手动验证。
2. 本地起一个 HTTP 服务（`python3 -m http.server`，只监听 `127.0.0.1`），提供 appcast 和 B 的 DMG。用 `defaults write` 或调试参数把 A 的 `SUFeedURL` 指向本地（**只在 DEBUG 或测试构建中允许覆盖 feed 地址**，发布构建不得依赖它，遵守 `AGENTS.md` 对 `--debug-*` 的规定）。
3. 把 A 放到一个临时目录（不要放进 `/Applications`，不要覆盖已安装的 iMic），运行 A，点「检查更新…」，确认发现 B、下载、校验、替换、重启，并且重启后版本显示为 B。
4. 篡改测试：把 B 的 DMG 改一个字节，或者在 appcast 中放一个错误的签名，确认 A **拒绝**更新，并给出清楚的提示。
5. 忙碌测试：在 A 模拟"正在输入"的状态时触发检查，确认不弹窗、不重启，空闲后才提示。可以用现有的测试钩子或新增一个 DEBUG 钩子。
6. 占位公钥测试：`package-release.sh` 遇到占位公钥时报错退出；`BUILD` 没有增加时报错退出。用 dry-run 方式验证，**不要真的发布**。
7. 测试结束后：退出测试 App，删除临时目录、临时密钥和本地 appcast，恢复 `defaults` 中的修改。

## 9. 测试报告（附在 PR 里）

逐项写出命令、结果（PASS/FAIL）、耗时和关键输出：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/fetch-sparkle.sh            # 校验通过
./scripts/build-mac.sh                # 构建通过；Frameworks 中有 Sparkle
codesign --verify --deep --strict build/mac.noindex/iMic.app
./scripts/test-mac-settings.sh        # 设置页新增项
./scripts/test-polish.sh
./scripts/test-input.sh
python3 tools/check-site.py           # 包括 appcast 检查
node tools/test-site-browser.mjs
./scripts/build-ios.sh                # 确认 iOS 不受影响
```

另外附上：

- 第 8 节每一步的结果，以及关键截图：发现更新的窗口、更新完成后的版本号、篡改后的拒绝提示、设置页新增项。
- Developer ID 下辅助功能授权是否保留：已验证，或者明确写"未验证"并说明原因。
- `otool -L` 和 `otool -l | grep -A2 LC_RPATH` 的输出，证明 Sparkle 从 `@rpath` 正确加载。
- App 体积变化（构建前后的 `du -sh iMic.app`）。
- `docs/RELEASING.md` 中发布者需要执行的一次性操作清单。

## 10. 验收清单

- [ ] Sparkle 2 固定版本、校验哈希后引入，只用命令行工具即可构建，二进制不进仓库。
- [ ] `BUILD` 构建号写入 `CFBundleVersion`；发布脚本强制每次发布都增加 `BUILD`。
- [ ] 菜单「检查更新…」、设置中的两个开关和版本号显示正常。
- [ ] 忙碌时和设置向导进行中不弹窗、不重启。
- [ ] 本地完整更新流程跑通；篡改的更新包被拒绝。
- [ ] 私钥不在仓库中；占位公钥会阻止发布。
- [ ] appcast 托管在官网，`check-site` 校验格式；发布顺序写入文档。
- [ ] 隐私说明和官网 FAQ 已更新；关闭了系统信息上报。
- [ ] 全量测试报告附在 PR 里。
