# TestFlight 交接：先处理账号侧两项

日期：2026-10-29。反馈邮箱：**i0.0ia@qq.com**。

## 当前结果

已准备 iPhone 端 **1.4.3（Build 2）**、隐私清单、无 alpha 图标、独立的归档/导出/上传脚本，以及中英文测试和审核说明。

旧 Bundle ID 的历史归档位于 `build/testflight.noindex/1.4.3-2/iMic.xcarchive`，不能用于新 App 分发。新 ID 的未签名归档已生成并通过包内容校验，位于独立目录 `build/testflight-bundleid.noindex/iMic.xcarchive`。**这是未签名的 Release 归档，目前没有可安装的 TestFlight IPA，没有上传成功，也没有创建成功的 App Store Connect 应用记录。**

## 1. 请 KE CHENG 团队持有人处理 Bundle ID 和描述文件

实际检查到：

- 发布证书与私钥在这台 Mac 上可用：`Apple Distribution: KE CHENG (5H39F98ND4)`，证书 SHA-1：`80941B8B1EBA7E68B2D94B13E2D3BF4FFA3C7849`。
- Xcode 中 `i0.0ia@qq.com` 是该团队的 App Manager，但「Certificates, Identifiers & Profiles」显示不可访问。
- iOS 发布端已改用 `art.malette.imic`，下一步需在发布团队注册该显式 App ID，再在 App Store Connect 创建对应的新应用记录。
- 自动归档报团队资源不可用；实际导出报缺少对应的 iOS App Store 描述文件。

请持有人在 [Apple Developer](https://developer.apple.com/account/resources/identifiers/list) 中：

1. 选择团队 **5H39F98ND4**。
2. 注册显式 App ID，Bundle ID 为 **`art.malette.imic`**。已确认 `com.drafffffff.imic` 被旧 Personal Team `S889TFV5A4` 占用，因此改用新 ID；如果新 ID 也被占用，停下来报告，不要自行换 ID。
3. 在 Profiles 中新建 **App Store Connect / iOS** 分发描述文件，选择上述 App ID 和与本机证书 SHA-1 匹配的 Apple Distribution 证书。
4. 下载 `.mobileprovision`，保存到这台 Mac。**只需要描述文件，不需要再发送私钥或账号密码。**

如果这是组织团队，也可以由持有人授权当前账号访问 Certificates, Identifiers & Profiles，再刷新 Xcode 登录。若是个人开发者团队，受邀 App Manager 只有 App Store Connect 访问权，通常不能通过增加角色获得 Developer 资源权限；使用持有人提供描述文件的方式即可。参见 [Apple 账号角色说明](https://developer.apple.com/help/account/access/roles/)。

拿到匹配的文件后，使用新 ID 的归档导出（不要使用旧 Bundle ID 的历史归档）：

```bash
IMIC_TESTFLIGHT_DIR=build/testflight-bundleid.noindex IMIC_PROFILE_PATH=/绝对路径/iMic-AppStore.mobileprovision ./scripts/testflight.sh export
```

脚本先校验描述文件，再用本机已有私钥签名；导出通过后才有可上传的 IPA。此手动签名分支尚待匹配的真实描述文件验证。

## 2. 请持有人核查协议，补齐应用记录

App Store Connect 当前显示 **Review the updated Paid Applications Schedule**，明确要求 Account Holder 处理。请持有人在 [Business](https://appstoreconnect.apple.com/business) 及 Developer 账户中核查适用的待签协议；协议的审阅和接受由持有人亲自完成，不要为发布免费测试版误开购买项目。

Bundle ID 注册完成后，刷新已保留的 App Store Connect「新建 App」表单：

| 字段 | 填写内容 |
|---|---|
| 平台 | iOS |
| 名称 | iMic（如占用需选择可用名称） |
| 主要语言 | 简体中文 |
| Bundle ID | `art.malette.imic` |
| SKU | `imic-ios` |

应用记录创建后，且签名导出成功，即可上传：

```bash
IMIC_TESTFLIGHT_DIR=build/testflight-bundleid.noindex IMIC_PROFILE_PATH=/绝对路径/iMic-AppStore.mobileprovision ./scripts/testflight.sh upload
```

`upload` 会先完成本地分发签名校验，成功后才尝试提交。上传成功仍需要等待 Apple 处理构建，再进行内部测试和首次外部测试审核。

## 后续需要你确认的内容

- 审核联系人的真实姓名、电话。邮箱已确定为 `i0.0ia@qq.com`。
- 首次外测审核所需的可用识别环境。当前不内置公共 API Key；如需给审核员提供专用限额测试 Key，请通过审核信息安全提供，勿提交到仓库。
- 阅读 [隐私说明](PRIVACY.md)，按实际服务商处理方式确认隐私问卷，并将说明发布为可公开访问的网址。本地 Markdown 尚不是公开隐私政策 URL。
- 收到内部测试邀请后，用自己的 iPhone 和 Mac 完成 [真机验收清单](TESTFLIGHT.md#真机验收)。主要检查权限、配对、真实录音、常用应用输入、用户接管和升级；不要在重要文档里首次测试编辑手势。

## 自动验证结果与一项待确认问题

已通过：53 项协议/逻辑测试、Mac 构建及签名校验、iPhone Release 归档与包内容校验、原有未签名 IPA 打包流程、真实百炼识别联调。最终归档的 iPhone 平台、版本、Build、隐私清单、许可证和调试入口检查均通过；9 张 iOS 图标已确认为无 alpha 的 RGB PNG，Mac 图标生成结果保持一致。

现有 7 项模拟器 UI 测试中 **6 项通过、1 项失败**。失败项为 `DisplayUITests/testRecordingTouchPassesThroughMetalAndResultRemainsUsable`：按住 0.8 秒后预期看到「录音太短，再说一次」，实际日志显示 `cancelled=true`。单独重跑及固定坐标触摸复查仍出现取消回调；尚不能确定是模拟器/自动化触摸行为还是实际设备也会发生的问题。没有放宽断言；用于诊断的临时测试改动已恢复。

请把 **真实 iPhone 按住录音、正常松开应提交，上滑应取消** 作为进入外部测试前的优先验收项。若真机正常，后续再改进模拟器触摸测试；若真机也自动取消，应先修复再开放外部测试。模拟器自动检查不能替代这一项。

可直接复制的 Beta 描述、What to Test 和英文 Review Notes 都在 [TESTFLIGHT.md](TESTFLIGHT.md)。发给朋友的安装步骤在 [TESTFLIGHT-QUICKSTART.md](TESTFLIGHT-QUICKSTART.md)。

自动检查及产物证据见 `build/testflight.noindex/`。本次没有替换 `/Applications/iMic.app`，没有卸载手机上的旧应用，也没有修改系统权限数据库。
