# iMic TestFlight 提交协助说明

致 KE CHENG 团队负责人：

我们希望将 iMic 的 iPhone 客户端分发到 TestFlight，烦请协助完成团队账号侧的配置。本地已有 Release 归档和分发私钥，但当前操作账号没有证书与描述文件访问权限，且新建 App 的 Bundle ID 列表中未找到 iMic，因此暂未完成签名导出和上传。

**建议您先完成下文的账号配置，并将匹配的 `.mobileprovision` 描述文件和 App Store Connect 应用链接交回，我们继续在原 Mac 上签名、上传和测试。** 如果您希望自行完成上传，本包也包含归档、源码和操作工具。

日期：2026-10-29。联系及反馈邮箱：**i0.0ia@qq.com**。

## 应用信息

| 项目 | 内容 |
|---|---|
| 应用名称 | iMic |
| 平台及最低系统 | iPhone，iOS 17.0+ |
| 版本及构建号 | 1.4.4，Build 3 |
| Bundle ID | `art.malette.imic` |
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

SHA-1 在这里仅用于识别证书。包内 `Certificates/AppleDistribution-KECHENG.cer` 为对应的公开证书，**不包含私钥**。原 Mac 上已存在该证书对应的私钥，无需重新导出或传递私钥。

## 请负责人协助完成

### 1 核查团队协议

登录 [App Store Connect Business](https://appstoreconnect.apple.com/business) 和 [Apple Developer](https://developer.apple.com/account/)，选择 KE CHENG 团队。当前 App Store Connect 显示 “Review the updated Paid Applications Schedule”，请 Account Holder 核查并亲自处理适用的待签协议。

本次目标是 TestFlight 测试分发，不涉及为 iMic 新建内购项目。是否需要接受某项协议，以账户实际提示及使用范围为准。

### 2 注册 iMic 的 Bundle ID

进入 Apple Developer → Certificates, Identifiers & Profiles → Identifiers，确认当前 Team ID 为 **`5H39F98ND4`**。

注册显式 App ID，Bundle ID 填写 **`art.malette.imic`**，描述可填写 iMic。当前版本不需要为了提交增加推送、App Groups、iCloud 等能力。

如果提示 Bundle ID 已占用，请先确认是否已在本团队注册、是否属于其他团队。请将具体结果反馈给我们，暂不改成随机或临时 Bundle ID。

### 3 创建 App Store Connect 分发描述文件

在同一团队的 Profiles 中新建分发描述文件，类型选择 **App Store Connect / iOS**，名称可用 `iMic-AppStore`。

选择刚注册的 iMic App ID，以及与上方 SHA-1 匹配的 **Apple Distribution** 证书。生成并下载 `.mobileprovision` 文件，交回我们即可。

请勿选择开发、Ad Hoc 或 Enterprise 类型。本次不需要收集测试者的设备 UDID，也不需要提供设备列表。

组织团队也可授权当前操作账号访问 Certificates, Identifiers & Profiles。若团队是个人开发者账号，受邀 App Manager 通常只有 App Store Connect 访问权，使用持有人生成描述文件的方式更直接。[Apple 账号角色说明](https://developer.apple.com/help/account/access/roles/)

### 4 创建 App Store Connect 应用记录

在 [App Store Connect Apps](https://appstoreconnect.apple.com/apps) 点击新建 App，使用上方应用信息：iOS、iMic、简体中文、`art.malette.imic`、SKU `imic-ios`。

如果名称 iMic 已占用，请先告知可用名称选项。请确认 `i0.0ia@qq.com` 对该应用具有 App Manager 访问权，以便我们继续上传和管理 TestFlight。

## 完成后请交回

1. **iMic 的 App Store Connect 分发描述文件**，扩展名为 `.mobileprovision`，且包含上述证书。
2. **App Store Connect 应用链接或 Apple ID**，以及最终使用的 Bundle ID。
3. **协议处理情况**。如有无法完成的步骤，请附具体提示或截图；无需提供账户密码、验证码或私钥。

拿到以上材料后，我们会继续校验描述文件、完成本机分发签名、导出 IPA、上传，并在 Apple 处理完成后安排内部测试。

## 本包内容

| 路径 | 用途 |
|---|---|
| `README.md` | 用户说明 |
| `docs/DEVELOPMENT.md` | 开发者说明 |
| `iOS/iMic.xcarchive/` | iPhone 1.4.4 Build 3 的未签名 Release 归档，含调试符号 |
| `iOS/ArchiveSource.zip` | 与最终归档对应的隔离构建源码快照 |
| `iOS/ExportOptions.plist` | App Store Connect 导出配置，支持后续外部测试 |
| `Mac/iMic-1.4.4-macOS-universal.dmg` | 配套 Mac 客户端，Developer ID 签名，已验证公证票据 |
| `Certificates/AppleDistribution-KECHENG.cer` | 用于核对签名身份的公开证书 |
| `Source/` | 当前项目源码、测试、许可证与发布工具，含本次尚未提交 Git 的准备改动 |
| `Docs/TESTFLIGHT.md` | Beta 描述、What to Test、英文 Review Notes 和完整发布步骤 |
| `Docs/PRIVACY.md` | 隐私说明，供核对和发布为公开网址 |
| `Docs/TESTFLIGHT-QUICKSTART.md` | 给测试者的安装及配对说明 |
| `Checks/VALIDATION.md` | 自动检查结果和真机待验收项 |
| `MANIFEST.sha256` | 包内文件的 SHA-256 校验清单 |
| `testflight.sh` | 操作本包归档的入口，`check`、`export`、`upload` |

**当前归档未签名，也没有已经成功上传的 TestFlight 构建。** 签名导出成功后才能得到可用于提交的分发 IPA。包内没有服务 API Key、配对令牌、个人设备描述文件或签名私钥。

## 如果负责人希望自行提交

解压整个 ZIP，保持目录结构。在安装 Xcode 和 Python 3 的 Mac 上进入解压后的根目录，先检查归档：

```bash
bash ./testflight.sh check
```

使用已有团队登录及签名资源自动导出，然后上传：

```bash
bash ./testflight.sh export
bash ./testflight.sh upload
```

如使用下载好的描述文件，并且本机钥匙串已有该描述文件对应的有效分发私钥，可采用手动签名：

```bash
IMIC_PROFILE_PATH=/绝对路径/iMic-AppStore.mobileprovision bash ./testflight.sh export
IMIC_PROFILE_PATH=/绝对路径/iMic-AppStore.mobileprovision bash ./testflight.sh upload
```

`upload` 会先本地导出并校验，再尝试上传。若您的 Mac 没有匹配的签名私钥，公开 `.cer` 文件不足以完成签名；可以在团队权限允许时使用自己的分发签名资源，或按建议方式将描述文件交回，由原 Mac 继续处理。手动分发导出尚待匹配的真实描述文件验证，不能把脚本准备完毕等同于上传成功。

若需重新构建，进入 `Source/`，参考其中发布说明；从源码生成工程另需 XcodeGen。完整审核文案请查看 `Docs/TESTFLIGHT.md`。

## 上传后需要完成

上传后等待 Apple 处理构建，先安排内部测试，再提交首次外部测试的 Beta 审核；审核通过后才分享外部邀请链接。**请先不要直接开放外部测试。**

本地已通过 53 项协议/逻辑测试、Mac 构建、iPhone Release 归档、包内容检查以及真实百炼识别联调。模拟器 UI 测试 7 项中有 6 项通过，1 项录音手势测试反复收到取消回调，根因尚未确定；外测前必须用真实 iPhone 确认“正常松手提交，上滑取消”。详细结果在 `Checks/VALIDATION.md`。

外部测试审核还需确认联系人真实姓名、电话和隐私说明网址。iMic 依赖配套 Mac 和有效百炼 API Key，审核员需要可用的测试环境；如要提供专用限额测试 Key，请通过审核信息安全提供，不要写入源码或本 ZIP。

任何账号配置或提交问题，请联系 **i0.0ia@qq.com**。
