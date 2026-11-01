# 任务书：iOS Bundle ID 改为 `art.malette.imic.app`，并隔离本地开发签名

日期：2026-11-02
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件、`AGENTS.md`、`docs/TESTFLIGHT.md` 与 `docs/TESTFLIGHT-HANDOFF.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 最新提交新建分支 `codex/ios-bundle-id-app`，在专用 worktree 中工作。
2. 提交说明用简体中文。推送后用 `gh pr create` 向 `codex/ui-phosphor-wireframe` 提 PR，附第 6 节测试报告。不要自行合并。
3. **不要登录 Apple Developer 或 App Store Connect，不要注册 App ID、创建描述文件或 App 记录。** 这些由负责 TestFlight 的同事在团队 5H39F98ND4 中完成。
4. **不要用 Personal Team 对 `art.malette.imic.app` 或 `art.malette.imic.app.uitests` 做任何签名、构建到真机或自动签名操作**（原因见第 1 节）。不要覆盖 `/Applications/iMic.app`，不要改 `VERSION` / `MAC_BUILD`，不要动 Mac 端 Bundle ID（`com.drafffffff.imic` 保持不变）。
5. 在 `docs/releases/NEXT.md` 记录。

---

## 1. 背景与根因（已查明）

负责 TestFlight 的同事在团队 **5H39F98ND4（KE CHENG）** 注册 App ID 时，Apple 先后拒绝了 `com.drafffffff.imic` 与 `art.malette.imic`："An App ID with Identifier '…' is not available."

根因：本机 Xcode 只登录了一个**免费 Personal Team**（`S889TFV5A4`，"周龙飞 (Personal Team)"）。`scripts/install-ios-device.sh` 与 `scripts/site-demo.sh` 从 `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier` 读取团队并用 `CODE_SIGN_STYLE=Automatic` 构建到真机。自动签名会在 Personal Team 中注册当前 Bundle ID，从而在全球范围占用它，付费团队就无法再注册。之前两次真机安装分别占用了 `com.drafffffff.imic` 和 `art.malette.imic`。

所以本任务要同时做两件事：

1. 发布用 Bundle ID 改为一个**从未在本机签过名**的新 ID：`art.malette.imic.app`（测试运行器 `art.malette.imic.app.uitests`）。
2. **从机制上防止再次被占用**：本地 Personal Team 签名一律使用独立的开发专用 ID，发布 ID 只在团队 5H39F98ND4 中使用。

## 2. Bundle ID 方案

| 用途 | Bundle ID | 签名团队 |
|---|---|---|
| 正式 / TestFlight（Release、Archive） | `art.malette.imic.app` | 5H39F98ND4 |
| UI 测试运行器（正式团队） | `art.malette.imic.app.uitests` | 5H39F98ND4 |
| 本地开发：真机安装、官网演示录制（Personal Team 或任何非 5H39F98ND4 团队） | `art.malette.imic.dev` | 本机 Personal Team |
| 本地开发 UI 测试运行器 | `art.malette.imic.dev.uitests` | 本机 Personal Team |
| 模拟器（不需要签名） | 与正式相同即可，或使用 `.dev`，二选一并写清楚 | 无 |

Mac 端（`com.drafffffff.imic`）和官网演示采集工具（`art.malette.imic.democapture`，Mac 本地 ad-hoc 签名，不涉及 iOS 团队）不改。如果你判断 democapture 也会占用某个需要的 ID，在 PR 中说明，不要擅自改。

## 3. 要改的地方

用 `git grep -n "art.malette.imic"` 找全（`docs/tasks/`、`docs/releases/v*`、`docs/reviews/`、`docs/research/` 中的历史记录不改）。目前涉及：

- `ios/project.yml`：正式 ID 与 uitests ID。建议用一个 build setting（例如 `IMIC_BUNDLE_ID`）派生两者，方便脚本覆盖。运行 `xcodegen generate`。
- `scripts/install-ios-device.sh`、`scripts/site-demo.sh`：
  - 使用 Personal Team（或任何不是 5H39F98ND4 的团队）时，**强制**传入 `.dev` Bundle ID。
  - 如果检测到要用非 5H39F98ND4 团队签发布 ID，**直接报错退出**，并在错误信息中说明原因（会在个人团队占用发布 ID）。
  - 用 5H39F98ND4 签名时才允许使用发布 ID（目前本机没有该团队，所以实际都会走 `.dev`）。
- `scripts/site-demo-ios-capture.sh`、`scripts/site-demo-iphone-capture.sh`、`scripts/test-ios-standby.sh`、`scripts/test-link.sh`、`scripts/pull-ios-log.sh`、`scripts/build-ios.sh`：所有 `simctl launch`、`devicectl ... --domain-identifier`、`-bundle-id` 等引用，改为与上表一致（真机用 `.dev`，模拟器按你在第 2 节的选择）。最好集中定义在一处（例如一个被 source 的小脚本或统一的环境变量），不要四处硬编码。
- `scripts/testflight.sh`、`tools/testflight-export-options.py`、`tools/validate-testflight.py`：改为 `art.malette.imic.app`；`validate-testflight.py` 应校验归档中的 Bundle ID 正是 `art.malette.imic.app`，否则失败。
- 文档：`AGENTS.md`（启动预览命令中的 Bundle ID，以及新增一条规则：「iOS 发布 Bundle ID 只能在团队 5H39F98ND4 中签名；本地用 Personal Team 时必须用 `.dev`」）、`docs/DEVELOPMENT.md`、`docs/TESTFLIGHT.md`、`docs/TESTFLIGHT-HANDOFF.md`、`docs/TESTFLIGHT-QUICKSTART.md`、`docs/TESTFLIGHT-TEAM-REQUEST.md`、`docs/design/2026-10-29-ios-sound-design.md`。
- 如果代码中有依赖 Bundle ID 的地方（例如 Keychain access group、App Group、URL scheme、`Bundle.main.bundleIdentifier` 判断、日志子系统名），逐一检查并确认改动后行为一致。钥匙串中的配对令牌会因为是新 App 而不继承，这是预期的。

## 4. TestFlight 交接

更新 `docs/TESTFLIGHT-HANDOFF.md`，写清同事需要做的事，按顺序：

1. 在团队 5H39F98ND4 注册 App ID：`art.malette.imic.app`（explicit），能力与之前申请的保持一致（按 `ios/project.yml` 和 entitlements 列出需要勾选的能力，没有就写"无需额外能力"）。
2. 如需运行 UI 测试，另注册 `art.malette.imic.app.uitests`（可选）。
3. 用现有 Apple Distribution 证书生成 App Store 描述文件。**证书不用重新申请。**
4. 在 App Store Connect 用这个 Bundle ID 创建 App 记录。
5. 归档、导出、上传：按 `scripts/testflight.sh` 的步骤，`IMIC_PROFILE_PATH` 指向新描述文件。
6. 说明：这是新的 App 记录，旧的测试数据与 iPhone 上的配对不会继承，测试者需要重新配对。
7. **提醒同事**：不要在登录了个人 Apple ID 的 Xcode 中用自动签名构建 `art.malette.imic.app` 到真机，否则会再次被个人团队占用。

然后用 `scripts/testflight.sh` 的打包流程重新生成交接压缩包（参照 `build/testflight.noindex/handoff/` 中以往的命名，例如 `iMic-TestFlight-Handoff-1.4.5-build4-art.malette.imic.app.zip`），**只做未签名归档和源码打包，不签名、不上传**。压缩包放在 `build/testflight.noindex/handoff/`，不提交进仓库；在 PR 中写出路径、大小和 SHA-256。压缩包中不得包含任何私钥、证书、描述文件、`.claude/`、`build/` 中间产物或 Sparkle 私钥备份。

## 5. 不要做的事

- 不登录、不注册任何 Apple 账号或 App ID，不创建描述文件和 App 记录，不上传 TestFlight。
- 不用 Personal Team 签名新的发布 ID，不在真机上安装发布 ID 的构建。
- 不改 Mac 端、协议、版本号。
- 不删除本机钥匙串或 Xcode 中的任何证书、描述文件、账号。

## 6. 测试报告（附在 PR 里）

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-ios.sh
./scripts/test-ios-mac-selection.sh
./scripts/test-ios-reconnect.sh
./scripts/test-polish-link.sh
python3 tools/check-l10n.py
python3 tools/validate-testflight.py --help    # 或按脚本实际用法，对新生成的未签名归档做校验
bash -n scripts/*.sh
```

另外附上：

- `git grep -n "art.malette.imic"` 结果：除历史记录外，每一处都属于第 2 节表格中的某个 ID。
- `install-ios-device.sh` 与 `site-demo.sh` 的保护逻辑演示：用非 5H39F98ND4 团队尝试发布 ID 时报错退出的输出（**只运行到报错为止，不实际构建到真机**）；默认走 `.dev` 时解析出的 Bundle ID 与团队（可以用 dry-run 或打印参数的方式，不要真的安装到真机）。
- 未签名归档中 `Info.plist` 的 `CFBundleIdentifier`。
- 交接压缩包路径、大小、SHA-256、内容清单。
- 用模拟器 `--ui-preview=idle` 启动一次的截图，证明改动后 App 正常运行。
