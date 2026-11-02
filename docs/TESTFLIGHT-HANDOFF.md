# TestFlight 交接：新发布 ID 与本地签名隔离

日期：2026-11-02。反馈邮箱：**i0.0ia@qq.com**。

iPhone 端版本为 **1.4.5（Build 4）**，发布 ID 为 **`art.malette.imic.app`**。本次只生成未签名 Release 归档与源码交接包，没有登录 Apple 账号、注册 ID、创建描述文件/App 记录、签名、安装真机或上传。ID 是否可用由负责 TestFlight 的同事在正式团队中确认。

前两次真机自动签名将旧 iOS ID 占用在免费 Personal Team 中。因此本地真机安装、官网录制默认使用 `art.malette.imic.dev`，测试运行器为 `art.malette.imic.dev.uitests`；模拟器使用发布 ID，禁用签名。非 `5H39F98ND4` 团队请求发布 ID 时脚本会直接退出。Mac Bundle ID 保持 `com.drafffffff.imic`。

## 同事需要按顺序完成

1. 在 **KE CHENG / `5H39F98ND4`** 团队注册 explicit App ID：**`art.malette.imic.app`**。检查 `ios/project.yml` 和 `ios/Info.plist`：没有 iOS entitlements 文件、App Groups、iCloud、推送或共享 Keychain access group，**无需额外能力**。麦克风、本地网络/Bonjour、语音识别、蓝牙仅使用现有 Info.plist 权限说明。若 ID 被占用，停下来反馈，不要自行换 ID。
2. 如需在正式团队运行 UI 测试，可选注册 **`art.malette.imic.app.uitests`**。本地开发测试使用 `.dev.uitests`。
3. 使用**现有 Apple Distribution 证书**生成新的 **App Store Connect / iOS** 分发描述文件，选择新的 App ID。**证书不用重新申请，也不用导出或传递私钥。** 已知签名身份为 `Apple Distribution: KE CHENG (5H39F98ND4)`，历史证书 SHA-1 为 `80941B8B1EBA7E68B2D94B13E2D3BF4FFA3C7849`；持有人核对证书与本机私钥是否匹配。本包不包含证书或描述文件。
4. 在 App Store Connect 创建新的 iOS App 记录，Bundle ID 使用 **`art.malette.imic.app`**。名称 iMic，主要语言简体中文，SKU 可用 `imic-ios`（若已用则选新的唯一 SKU）。补齐应用权限、适用协议和审核联系人。账号操作由同事或持有人亲自完成。
5. 按下面的 `scripts/testflight.sh` 步骤归档、导出、上传，**`IMIC_PROFILE_PATH` 指向新 ID 的描述文件**。旧 ID 的归档和描述文件不能复用。导出成功并通过分发校验才有可上传 IPA；`upload` 会先本地导出校验再上传。
6. 这是新的 App 记录，旧 TestFlight 测试数据和 iPhone 配对不会继承，测试者需要重新配对。旧应用可并存，请先复制需要保留的结果。
7. **不要在登录了个人 Apple ID 的 Xcode 中自动签名构建 `art.malette.imic.app` 或其 UI 测试运行器到真机，否则会再次在个人团队占用发布 ID。** 本地真机只用 `.dev`；正式 ID 只允许 `5H39F98ND4`。

## 交接包和使用方法

源码准备者运行（不签名、不上传）：

```bash
./scripts/testflight.sh archive-unsigned
# 将源码修改提交后打包；归档目录覆盖值须保持一致
./scripts/testflight.sh check
./scripts/testflight.sh handoff
```

默认归档为 `build/testflight.noindex/1.4.5-4/iMic.xcarchive`，已有归档不会覆盖；可用 `IMIC_TESTFLIGHT_DIR` 隔离目录。交接 ZIP 为 `build/testflight.noindex/handoff/iMic-TestFlight-Handoff-1.4.5-build4-art.malette.imic.app.zip`，同目录生成 `.sha256` 和 `.contents.txt`。ZIP 不提交仓库，实际路径、大小、SHA-256 和验证结果附于 PR。

| 包内路径 | 用途 |
|---|---|
| `iOS/iMic.xcarchive/` | 未签名 iPhone Release 归档及符号 |
| `Source/` | 已提交的完整源码、测试、许可证与脚本 |
| `Source/docs/TESTFLIGHT.md` | 发布、Beta 描述、What to Test、英文 Review Notes |
| `Source/docs/TESTFLIGHT-QUICKSTART.md` | 测试者安装与配对说明 |
| `Source/docs/PRIVACY.md` | 隐私说明 |
| `SOURCE-REVISION.txt` | 源码提交号 |
| `README.txt` | 解压后的具体命令 |
| `MANIFEST.sha256` | 包内每个文件的 SHA-256 |

打包工具只读取 Git 跟踪且已提交的文件，检查未签名状态，拒绝私钥、证书、描述文件、`.claude/`、构建中间目录与 Sparkle 私钥备份；不会读取钥匙串签名材料或账号。归档和源码使用相同的提交版本。没有附带 Mac 安装包，配套 Mac 仍从 [现有 Release](https://github.com/Drafffffff/iMic/releases/tag/v1.4.4) 获取。

解压整个 ZIP，保持目录结构。在已安装 Xcode 和 Python 3 的 Mac 上进入 `Source/`，先检查随包归档：

```bash
IMIC_TESTFLIGHT_DIR=../iOS ./scripts/testflight.sh check
# 以下仅由有正式团队权限和已有分发私钥的同事执行
IMIC_TESTFLIGHT_DIR=../iOS IMIC_PROFILE_PATH=/绝对路径/新ID-AppStore.mobileprovision ./scripts/testflight.sh export
IMIC_TESTFLIGHT_DIR=../iOS IMIC_PROFILE_PATH=/绝对路径/新ID-AppStore.mobileprovision ./scripts/testflight.sh upload
```

若要从源码重新归档，另需 XcodeGen，选一个尚不存在归档的输出目录：

```bash
IMIC_TESTFLIGHT_DIR=../new-archive ./scripts/testflight.sh archive-unsigned
IMIC_TESTFLIGHT_DIR=../new-archive IMIC_PROFILE_PATH=/绝对路径/新ID-AppStore.mobileprovision ./scripts/testflight.sh export
IMIC_TESTFLIGHT_DIR=../new-archive IMIC_PROFILE_PATH=/绝对路径/新ID-AppStore.mobileprovision ./scripts/testflight.sh upload
```

未签名校验通过不代表签名/分发成功。手动导出需新描述文件与可用的匹配分发私钥；上传需正式团队的 App Store Connect 访问权。包中没有私钥，证书不需要重新申请。

## 上传后验收

等待 Apple 处理构建，安排内部测试，再提交首次外部 Beta 审核。审核通过后再分享外部邀请链接。审核联系人真实姓名/电话、公开隐私说明网址和可用的 Mac + 百炼识别环境由负责人确认；测试 Key 通过审核信息安全提供，不能放入仓库或交接包。

本次测试结果见 PR 的第 6 节报告。模拟器预览用于确认新 ID 可启动，不能替代真机验收。历史 UI 测试中曾出现“正常松手被当成取消”的情况，外测前仍须用真实 iPhone 确认“正常松手提交，上滑取消”，以及权限、配对、重连、用户接管和升级行为。完整清单见 [TESTFLIGHT.md](TESTFLIGHT.md#真机验收)。
