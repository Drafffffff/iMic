# 任务书：iMic 1.4.5 (4) 签名导出并上传 TestFlight

日期：2026-11-02
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex（Claude 监督）
动手前请完整阅读本文件、`AGENTS.md`、`docs/TESTFLIGHT.md`、`docs/TESTFLIGHT-HANDOFF.md` 和 `scripts/ios-bundle-id.sh`。

---

## 0. 授权与规则

用户已明确要求：用同事提供的描述文件签名 iMic 1.4.5 (4)，导出并上传到 TestFlight。

- **不输入任何密码、验证码或 App 专用密码，不登录或注册任何 Apple 账号，不创建 App Store Connect API 密钥。** 需要认证而本机没有可用凭据时，停止并报告（见第 4 节）。
- **只能用团队 5H39F98ND4 签名 `art.malette.imic.app`。** 不要使用 Personal Team，不要开启自动签名，不要加 `-allowProvisioningUpdates`，不要构建到真机。归档使用未签名归档，导出时使用同事提供的描述文件手动签名。
- 不导出、复制或移动私钥；不修改钥匙串信任设置；不删除任何证书或描述文件。
- 不改 `VERSION`、`MAC_BUILD`、iOS 版本号与构建号（应为 1.4.5 / 4）。
- 不开放外部测试，不提交 App 审核，不修改 App Store Connect 中的任何设置。
- 描述文件和导出的 IPA 不进入 git。

## 1. 已知材料（Claude 已核对）

- 描述文件：用户下载的 `~/Downloads/iMic-Signing-Handoff-20261102.zip` 内的 `iMic-AppStore.mobileprovision`。
  - Name `iMic-AppStore`，团队 KE CHENG / 5H39F98ND4，`application-identifier` 为 `5H39F98ND4.art.malette.imic.app`，App Store 类型，无设备列表，到期 2027-10-27。
  - 同事给出的 SHA-256：`f8be5f0585c03ebed1350bf72706dcef0b1f2905408d20646dbc7a203c01bb8e`，UUID `30a12efe-f392-43c8-9daa-67eee7520d7d`。
- 本机钥匙串已有匹配的签名身份：`Apple Distribution: KE CHENG (5H39F98ND4)`，SHA-1 `80941B8B1EBA7E68B2D94B13E2D3BF4FFA3C7849`（与描述文件内嵌证书一致）。
- App Store Connect 已有 App 记录：iMic，Apple ID 6829771739，SKU `imic-ios`。

## 2. 步骤

1. 从 `codex/ui-phosphor-wireframe` 最新提交新建 worktree（分支 `codex/testflight-1.4.5-b4`），确认 `ios/project.yml` 中版本为 1.4.5、构建号 4、发布 Bundle ID 为 `art.malette.imic.app`。
2. 把描述文件解压到 `~/Documents/iMic-Signing/iMic-AppStore.mobileprovision`（仓库外），核对 SHA-256 与上文一致，再用 `security cms -D` 核对 UUID、团队、application-identifier、到期日，以及内嵌证书 SHA-1 为 `80941B8B…`。任何一项不一致就停止。
3. 运行与上传前测试（失败就停止）：
   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
   ./scripts/build-ios.sh
   python3 tools/check-l10n.py
   ```
4. `./scripts/testflight.sh archive-unsigned`（未签名归档），然后 `./scripts/testflight.sh check`。
5. `IMIC_PROFILE_PATH=~/Documents/iMic-Signing/iMic-AppStore.mobileprovision ./scripts/testflight.sh export`：导出签名 IPA 并通过 `tools/validate-testflight.py --require-distribution`。另外独立核对 IPA：`codesign -dvv` 显示 `Apple Distribution: KE CHENG (5H39F98ND4)`，`CFBundleIdentifier=art.malette.imic.app`，版本 1.4.5，构建号 4，嵌入的描述文件 UUID 为 `30a12efe-…`，`get-task-allow=false`，`beta-reports-active=true`。
   - 如果 `codesign` 访问私钥时弹出钥匙串授权对话框导致卡住，停止并报告，不要尝试绕过。
6. 上传前再确认 App Store Connect 中**没有**已存在的 1.4.5 (4) 构建（如果无法在不登录的情况下确认，就跳过这一步，上传失败时 Apple 会提示重复构建号）。
7. 上传：`IMIC_PROFILE_PATH=~/Documents/iMic-Signing/iMic-AppStore.mobileprovision ./scripts/testflight.sh upload`。它通过 Xcode 已登录的 Apple 账号上传。**只尝试一次**。

## 3. 成功时

- 记录 `upload.log` 中 Apple 返回的结果（成功信息、Delivery UUID 等）。
- 在 `docs/releases/v1.4.5.md` 或 `docs/TESTFLIGHT.md` 中补一行：1.4.5 (4) 于何时上传到 TestFlight（只写事实）。提交到分支并提 PR，**不要合并**。
- 输出：IPA 路径、SHA-256、大小、签名信息、上传结果。提醒用户：Apple 处理构建通常需要几分钟到一小时，处理完成后在 App Store Connect 的 TestFlight 页加入内部测试组；外部测试需要另行提交 Beta 审核。

## 4. 认证失败时（预期可能发生）

本机 Xcode 目前只登录了个人 Apple ID（Personal Team）。如果它不是团队 5H39F98ND4 中有上传权限的成员，上传会失败。此时：

- **立即停止**，不要重试、不要尝试其他账号或凭据。
- 保留已导出并校验过的 IPA（`build/testflight.noindex/export/iMic.ipa`）。
- 在输出中给出 Apple / Xcode 的原始错误信息，并列出用户可选的两种方式（由用户自己操作）：
  1. 在 Xcode → Settings → Accounts 中登录一个属于团队 5H39F98ND4、角色为 App Manager 或以上（或 Developer 且有上传权限）的 Apple ID，然后重新运行 `testflight.sh upload`。
  2. 由团队管理员在 App Store Connect → 用户和访问 → 集成 → App Store Connect API 创建一个「App Manager」角色的 API 密钥，把 `.p8` 文件放到 `~/.appstoreconnect/private_keys/`，并告知 Key ID 与 Issuer ID；之后用 `xcrun altool --upload-app` 或 `xcodebuild -exportArchive` 的 `-authenticationKeyPath` 系列参数上传（由 Claude 另行安排）。
- 已签名的 IPA 也可以由有权限的人用 Transporter App 直接上传。

## 5. 不要做的事

- 不输入或保存任何密码；不读取钥匙串中的密码类条目。
- 不使用 Personal Team 或自动签名；不安装到真机。
- 不重复上传同一构建号；不改构建号来"绕过"重复。
- 不修改 App Store Connect、测试组、外部测试或审核设置。
