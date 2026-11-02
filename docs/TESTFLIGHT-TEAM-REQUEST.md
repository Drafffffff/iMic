# iMic TestFlight 提交协助说明

致 KE CHENG 团队负责人：

我们希望将 iMic 的 iPhone 客户端分发到 TestFlight，烦请协助完成团队账号侧的配置。本地已有 Release 归档和分发私钥，但当前操作账号没有证书与描述文件访问权限，且新建 App 的 Bundle ID 列表中未找到 iMic，因此暂未完成签名导出和上传。

**建议您先完成下文的账号配置，并将匹配的 `.mobileprovision` 描述文件和 App Store Connect 应用链接交回，我们继续在原 Mac 上签名、上传和测试。** 如果您希望自行完成上传，本包也包含归档、源码和操作工具。

日期：2026-11-02。联系及反馈邮箱：**i0.0ia@qq.com**。

## 应用信息

| 项目 | 内容 |
|---|---|
| 应用名称 | iMic |
| 平台及最低系统 | iPhone，iOS 17.0+ |
| 版本及构建号 | 1.4.5，Build 4 |
| Bundle ID | `art.malette.imic.app` |
| 开发团队 | KE CHENG |
| Team ID | `5H39F98ND4` |
| 主要语言 | 简体中文 |
| 建议 SKU | `imic-ios` |
| 操作账号及反馈邮箱 | `i0.0ia@qq.com` |

本机已有的分发签名身份：

```text
Apple Distribution: KE CHENG (5H39F98ND4)
证书 SHA-1: 80941B8B1EBA7E68B2D94B13E2D3BF4FFA3C7849
证书有效期截止: 2027-10-27 12:56:57 UTC
```

SHA-1 仅用于识别已有证书。原 Mac 已有对应的私钥，**证书不用重新申请，也不要重新导出或传递私钥**。新交接包不附带证书、描述文件或私钥；由持有人核对已有签名身份。

## 请负责人协助完成

### 1 核查团队协议

登录 [App Store Connect Business](https://appstoreconnect.apple.com/business) 和 [Apple Developer](https://developer.apple.com/account/)，选择 KE CHENG 团队。当前 App Store Connect 显示 “Review the updated Paid Applications Schedule”，请 Account Holder 核查并亲自处理适用的待签协议。

本次目标是 TestFlight 测试分发，不涉及为 iMic 新建内购项目。是否需要接受某项协议，以账户实际提示及使用范围为准。

### 2 注册 iMic 的 Bundle ID

进入 Apple Developer → Certificates, Identifiers & Profiles → Identifiers，确认当前 Team ID 为 **`5H39F98ND4`**。

注册显式 App ID，Bundle ID 填写 **`art.malette.imic.app`**，描述可填写 iMic。按 `ios/project.yml` 和 Info.plist，当前没有 iOS entitlements 文件，无需额外能力。UI 测试需要时可选注册 `art.malette.imic.app.uitests`。

**不要在个人 Apple ID 的 Xcode 中对发布 ID 自动签名或构建到真机；发布 ID 只允许团队 `5H39F98ND4`，本地签名使用 `art.malette.imic.dev`（测试为 `.dev.uitests`）。旧 iOS ID 已因 Personal Team 自动签名被占用，新 ID 不能重蹈覆辙。**

如果提示 Bundle ID 已占用，请先确认是否已在本团队注册、是否属于其他团队。请将具体结果反馈给我们，暂不改成随机或临时 Bundle ID。

### 3 创建 App Store Connect 分发描述文件

在同一团队的 Profiles 中新建分发描述文件，类型选择 **App Store Connect / iOS**，名称可用 `iMic-AppStore`。

选择刚注册的 iMic App ID，以及与上方 SHA-1 匹配的 **Apple Distribution** 证书。生成并下载 `.mobileprovision` 文件，交回我们即可。

请勿选择开发、Ad Hoc 或 Enterprise 类型。本次不需要收集测试者的设备 UDID，也不需要提供设备列表。

组织团队也可授权当前操作账号访问 Certificates, Identifiers & Profiles。若团队是个人开发者账号，受邀 App Manager 通常只有 App Store Connect 访问权，使用持有人生成描述文件的方式更直接。[Apple 账号角色说明](https://developer.apple.com/help/account/access/roles/)

### 4 创建 App Store Connect 应用记录

在 [App Store Connect Apps](https://appstoreconnect.apple.com/apps) 点击新建 App，使用上方应用信息：iOS、iMic、简体中文、`art.malette.imic.app`、SKU `imic-ios`。

如果名称 iMic 已占用，请先告知可用名称选项。请确认 `i0.0ia@qq.com` 对该应用具有 App Manager 访问权，以便我们继续上传和管理 TestFlight。

## 完成后请交回

1. **iMic 的 App Store Connect 分发描述文件**，扩展名为 `.mobileprovision`，且包含上述证书。
2. **App Store Connect 应用链接或 Apple ID**，以及最终使用的 Bundle ID。
3. **协议处理情况**。如有无法完成的步骤，请附具体提示或截图；无需提供账户密码、验证码或私钥。

拿到以上材料后，我们会继续校验描述文件、完成本机分发签名、导出 IPA、上传，并在 Apple 处理完成后安排内部测试。

## 交接包与执行步骤

本次只提供未签名 1.4.5 Build 4 归档、已提交源码、说明与 SHA-256 清单。包内没有证书、描述文件、私钥、Mac 安装包或构建中间目录。具体内容和解压后 `check/export/upload` 命令见 [TESTFLIGHT-HANDOFF.md](TESTFLIGHT-HANDOFF.md)。导出时必须让 `IMIC_PROFILE_PATH` 指向新 ID 的描述文件。

这是新的 App 记录，旧测试数据与 iPhone 配对不会继承，测试者需要重新配对。签名、上传与账号侧操作均待负责同事完成。

## 上传后需要完成

上传后等待 Apple 处理构建，先安排内部测试，再提交首次外部测试的 Beta 审核；审核通过后才分享外部邀请链接。**请先不要直接开放外部测试。**

本次自动验证结果见 PR 的第 6 节测试报告。外测前仍须用真实 iPhone 确认“正常松手提交，上滑取消”；未签名归档校验和模拟器预览不能替代真机验收。

外部测试审核还需确认联系人真实姓名、电话和隐私说明网址。iMic 依赖配套 Mac 和有效百炼 API Key，审核员需要可用的测试环境；如要提供专用限额测试 Key，请通过审核信息安全提供，不要写入源码或本 ZIP。

任何账号配置或提交问题，请联系 **i0.0ia@qq.com**。
