# iMic TestFlight 发布

本文件只描述 iPhone 端 TestFlight 分发。Mac 配套客户端仍使用 Developer ID 签名、公证的 DMG。隐私说明见 [PRIVACY.md](PRIVACY.md)，测试者入门见 [TESTFLIGHT-QUICKSTART.md](TESTFLIGHT-QUICKSTART.md)。

## 应用资料

| 字段 | 值 |
|---|---|
| 应用名称 | iMic（若名称已占用，需要在 App Store Connect 选择可用名称） |
| 平台 | iOS / iPhone，iOS 17.0+ |
| Bundle ID | `art.malette.imic` |
| 发布团队 | KE CHENG / `5H39F98ND4` |
| 当前版本 / Build | `1.4.3` / `2` |
| 建议 SKU | `imic-ios` |
| 主要语言 | 简体中文 |
| 测试反馈邮箱 | `i0.0ia@qq.com` |
| Mac 配套客户端 | https://github.com/Drafffffff/iMic/releases/tag/v1.4.3 |

iOS 端 Bundle ID 已从 `com.drafffffff.imic` 改为 `art.malette.imic`：旧 ID 被 Personal Team `S889TFV5A4` 占用，无法在发布团队 `5H39F98ND4` 注册。新 ID 必须在上述发布团队中注册并与 App Store Connect 记录一致。Mac 端仍为 `com.drafffffff.imic`，现有签名和系统授权不受此次迁移影响。

新 App 会与旧开发包并存。新 App 的钥匙串和 UserDefaults 初始为空，会生成新的 deviceID，需要输入配对码与 Mac 重新配对；Mac 会保留旧设备的配对记录，不影响使用。不同 Bundle ID 之间没有共享容器或 App Group，不迁移旧 App 数据。请先复制旧 App 中需要保留的结果，再按需手动删除旧 App。

## 本地归档、校验和上传

```bash
# 协议与逻辑测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# 已有团队权限及有效 Xcode 登录：自动签名归档
./scripts/testflight.sh archive

# 无团队权限时：先编译一个未签名 Release 归档
./scripts/testflight.sh archive-unsigned

# 校验现有归档
./scripts/testflight.sh check

# 为现有归档获取分发描述文件、签名并导出 IPA（不上传）
./scripts/testflight.sh export

# 先本地签名导出并校验，再上传到 App Store Connect
./scripts/testflight.sh upload
```

`archive` 和 `archive-unsigned` 二选一，不要对同一路径重复归档。已有归档不会被脚本覆盖。签名归档因缺少账号失败且未生成归档时，可以直接运行 `archive-unsigned`。未签名归档不能安装或分发，`check` 通过也不代表分发签名通过；只有 `export` 的分发校验成功，才有可交给 Transporter 上传的 IPA。

默认输出目录为 `build/testflight.noindex/1.4.3-2/`；该路径下旧 Bundle ID 的历史归档不能用于本次分发。迁移验证使用 `IMIC_TESTFLIGHT_DIR=build/testflight-bundleid.noindex`，后续 `check/export/upload` 须使用相同目录。输出包括 `iMic.xcarchive`、构建日志、校验报告、归档源码快照 `source.zip`，以及成功导出后的 `export/iMic.ipa`。本地归档不修改开发工程、已安装的 Mac 应用或手机应用。应用许可证和第三方说明在签名前打入包内，图标由 `tools/icon.swift` 生成。

默认使用团队 `5H39F98ND4`；可以通过 `IMIC_TEAM_ID` 覆盖。`VERSION` 和 `ios/project.yml` 的 Marketing Version 必须一致。每次新的上传递增 `ios/project.yml` 的 `CURRENT_PROJECT_VERSION`；也可临时指定 `IMIC_BUILD_NUMBER=3 ./scripts/testflight.sh archive`，同一归档后续的 `check/export/upload` 也要使用同一覆盖值。输出目录可通过 `IMIC_TESTFLIGHT_DIR` 指定。

导出模板位于 `ios/TestFlightExportOptions.plist`：使用 `app-store-connect`，保留指定 Build 号，上传符号，不限制为 Internal Only，因此可继续用于外部测试。脚本不会把私钥、Apple 密码、配对令牌或服务 Key 写入仓库。

若账号没有证书/描述文件权限，但持有人能下载描述文件，可让持有人在自己的 Developer 账户创建 **App Store Connect / iOS** 分发描述文件，选择本 Bundle ID 和本机对应的 `Apple Distribution: KE CHENG (5H39F98ND4)` 证书，然后仅提供 `.mobileprovision` 文件：

```bash
IMIC_PROFILE_PATH=/绝对路径/iMic-AppStore.mobileprovision ./scripts/testflight.sh export
# 导出成功并检查结果后，使用同一描述文件上传：
IMIC_PROFILE_PATH=/绝对路径/iMic-AppStore.mobileprovision ./scripts/testflight.sh upload
```

脚本会先核验团队、Bundle ID、有效期、App Store 类型，以及描述文件中的证书是否对应本机已存在的可用私钥；通过后才安装描述文件并采用手动分发签名，不要求这个账号具备自动创建描述文件的权限。描述文件与私钥不同，无需再导出或发送私钥。上传仍需 App Store Connect 的应用访问权和有效登录。此备用流程须在拿到匹配的真实分发描述文件后完成实际导出验证。

## 账号持有人需要完成的操作

1. 在 App Store Connect 的「用户和访问」中确认操作账号属于 KE CHENG 团队，且能访问本应用。创建应用记录需要 Account Holder、Admin 或 App Manager。
2. 在 Apple Developer 的人员/权限设置中，允许该账号访问 **Certificates, Identifiers & Profiles**。只有 App Manager 角色并不证明具备这个权限；团队类型或账号政策若不允许授予，需 Account Holder 在自己的 Xcode 上签名导出，或提供与本 Bundle ID 匹配的 App Store 分发描述文件。无需向代码仓库提供私钥。
3. 在 Xcode → Settings → Apple Accounts 登录/刷新账号，确认团队资源访问可用。如有协议、验证码、钥匙串授权，须由账号持有人完成。
4. 在发布团队下注册 Bundle ID；在 App Store Connect → Apps 新建 iOS 应用，使用上表资料。若 Bundle ID 已被其他团队占用，不要擅自换成临时 ID；先确认账号所属团队和既有应用归属。
5. 接受必要的最新协议。付款、协议接受及账号安全验证由账号持有人完成。

## TestFlight 可直接使用的文案

### Beta App Description

把 iPhone 变成 Mac 的语音输入键。按住录音区域说话，松开后，识别文字会发送到配对的 Mac，并输入当前应用。支持实时文字预览、断线重连、可选文字润色以及波形复看。

本测试版需要 macOS 13+ 的配套 iMic 客户端，以及用户自行配置的阿里云百炼 API Key。建议 iPhone 与 Mac 处于同一 Wi-Fi。识别服务需要联网并可能产生服务商费用；可选润色也会把识别文字发送至选定服务。下载与设置说明：https://github.com/Drafffffff/iMic

### What to Test

请重点测试首次安装及权限提示、发现与配对 Mac、短句和长句识别、连续多轮输入、上滑取消、断线后重连，以及可选文字润色。Mac 端请在常用应用中检查输入位置是否正确；录音过程中切换应用或手动编辑时，确认不会误写或误删。遇到异常请附设备型号、系统版本和复现步骤，联系 i0.0ia@qq.com；不要发送 API Key 或配对令牌。

### Review Notes（英文）

iMic is an iPhone companion app for a macOS speech-input utility. A Mac running macOS 13 or later is required to test the complete workflow. There is no iMic account or iMic subscription.

1. Download the signed and notarized macOS companion from https://github.com/Drafffffff/iMic/releases/tag/v1.4.3 (the macOS universal DMG). Move iMic.app to Applications and open it.
2. Complete the Mac setup: grant Accessibility access for text input and configure a valid Alibaba Cloud Model Studio (DashScope/Bailian) API key. Screen Recording is optional and only supports a local visual effect. The key belongs in the Mac setup, not on the iPhone.
3. Connect both devices to the same Wi-Fi. Open the iPhone app, allow Local Network and Microphone access, select the Mac, and enter the six-digit code currently displayed by the Mac. Speech Recognition permission enables temporary Apple Speech previews; the Mac recognition path remains available if this permission is declined.
4. On the Mac, open a new TextEdit document and place the insertion point in it. On the iPhone, press and hold the bottom recording area, say a sentence, and release. The recognized text should appear in TextEdit and on the iPhone. Slide upward while recording to cancel.
5. Optional rewriting sends the transcript to the configured service. Keep it disabled when testing recognition alone. Switching foreground applications during a recording prevents final automatic insertion into the new application.

The iPhone–Mac transport is encrypted using Apple's CryptoKit. The Mac sends audio to the user's configured transcription provider. Apple Speech previews may use Apple's online speech service. No developer-operated server receives audio, transcripts, or API keys.

Contact: i0.0ia@qq.com.

### 仍须由持有人填写的审核资料

- Review Contact 的真实姓名和电话号码；邮箱使用 `i0.0ia@qq.com`。不要用证书显示名猜测联系人。
- 若审核员需要可用的百炼测试配置，应由持有人准备可撤销、限额、用于审核的测试凭据，并通过 App Store Connect 的审核信息安全提供。当前应用不内置共享 Key；本仓库和上述文案都不包含凭据。没有可用的识别服务配置，审核员不能体验完整流程。
- 如审核员无法同时使用 Mac，可补充完整真机演示视频作为辅助材料；视频不能保证替代可复现的测试环境。

## 隐私与加密声明核对

`PrivacyInfo.xcprivacy` 已声明应用本地偏好（CA92.1）、事件间隔/计时（35F9.1）、应用容器内文件元数据（C617.1）用途，无跟踪域名。

隐私清单的 Required Reason API 声明与 App Store Connect 的 App Privacy 问卷是两件事。清单未虚构第三方的数据保留承诺，也未替持有人勾选「不收集任何数据」：Apple Speech 可能联网，Mac 会向用户配置的识别和润色服务发送内容。提交问卷前，应按实际服务及其保留政策核对音频、用户内容、标识和诊断信息。隐私说明可发布为公开网页后填写相应 URL；本地文件并不等于已有可访问的公开隐私政策网址。

Info.plist 现有 `ITSAppUsesNonExemptEncryption=NO` 只表示不使用非豁免加密，不表示链路未加密。本项目通过 Apple 系统 CryptoKit 使用 Curve25519/HKDF/AES-GCM；签名和 TestFlight 准备不改动协议或降低加密强度。由持有人按 App Store Connect 的出口合规问题确认实际使用情况，不为绕过问卷改变该值。

## 上传后的顺序

1. 等待 Apple 处理构建，检查邮件和构建状态，处理上传错误或 Missing Compliance。
2. 在 TestFlight 建立内部组，分配构建并加入有应用访问权的内部测试账号，先完成下方真机验收。
3. 填写 Beta 描述、What to Test、反馈邮箱和审核联系方式。建立外部测试组，提交首次 Beta 审核。
4. 审核通过后，创建并分享外部邀请链接。不要把普通朋友加成管理员来绕过外部测试。
5. 每个构建最多测试 90 天。后续上传继续递增 Build；新构建仍可能需要审核，不承诺固定审核时长。

## 真机验收

- [ ] TestFlight 首次安装与启动，无开发者模式或本地签名安装步骤。
- [ ] 麦克风、本地网络和语音识别权限分别允许/拒绝，提示与恢复路径正确。
- [ ] 同 Wi-Fi 配对、错误配对码、断线重连、切换 Mac；蓝牙回退如实际使用也需验收。
- [ ] 短句、长句、连续录音、上滑取消；静音/来电/锁屏/切后台后行为符合预期。
- [ ] Mac 常用应用输入；录音时切换应用，不向新应用自动输入。
- [ ] 实时预览中手动打字/点击后冻结本轮，最终回写也不绕过用户接管。
- [ ] 键盘兼容模式按本轮已投递文字计算尾部，不能独立核验目标应用自行改稿或吞键，仍有重复/误删风险；用测试文档验收。
- [ ] 关闭润色、启用润色、服务错误时保留原文；复制和波形缓存清理正常。
- [ ] 旧开发团队到新发布团队首次安装、重新配对，以及后续同团队 TestFlight 升级。

## Apple 参考

- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/
