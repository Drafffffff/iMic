# App Store 审核材料

适用版本：VoxChord iOS 1.4.9 起的正式提交。表单字段按 App Store Connect 的顺序排列。

## 1. App 审核信息（App Review Information）

| 字段 | 填写 |
|---|---|
| 需要登录 | 否（取消勾选 Sign-in required；VoxChord 没有账号体系） |
| 联系人 | 周龙飞 |
| 电话 | +86 13818611371 |
| 邮箱 | i0.0ia@qq.com |
| 附件 | 建议上传 1 段真机演示视频（见第 6 节） |

### 审核备注（Notes，英文，直接粘贴）

```
VoxChord is the iPhone companion of a free, open-source macOS voice-input utility. The iPhone captures speech while the user holds the bar; the paired Mac recognizes it and types the text at the Mac's cursor. There is no account, subscription or in-app purchase.

A Mac (macOS 13 or later) on the same Wi-Fi network is required for the full workflow.

1. On the Mac, download the signed and notarized VoxChord DMG from https://github.com/Drafffffff/iMic/releases/latest, move VoxChord to Applications and open it.
2. In the Mac setup, grant Accessibility (used only to type text into the front app) and paste the Model Studio (Bailian) API key provided below. Screen Recording is optional and only drives a local visual effect.
   API key for review: <<粘贴审核专用 Key，见 review.md 第 2 节>>
3. On the iPhone, allow Local Network and Microphone, select the Mac and enter the 6-digit code shown on the Mac.
4. On the Mac, open a new TextEdit document. On the iPhone, press and hold the orange bar at the bottom, say a sentence, and release. The text appears in TextEdit. Pull the string down to press Return; slide up while recording to cancel.

Speech Recognition permission only powers a temporary on-screen preview; declining it does not block the main workflow. Bluetooth is used only as a fallback link to the user's own Mac when Wi-Fi is unavailable.

Privacy: the iPhone sends audio only to the user's own paired Mac over an encrypted local link (CryptoKit, AES-GCM). The developer operates no server and collects no data. The Mac sends audio to the speech service configured by the user.
```

## 2. 审核用识别 Key（持有人操作）

没有可用的识别服务，审核员无法体验完整流程，最常见的结果是被以 2.1（信息不完整）拒审。

- 在百炼控制台为审核**新建一个独立 Key**，设置额度上限，审核结束后删除。不要复用日常或测试 Key。
- 只把它填在 App Store Connect 审核备注里，不写进仓库、文档或聊天。
- 之前在对话里出现过的测试 Key 应视为已泄露，请在控制台**轮换**。

## 3. App 隐私（App Privacy 问卷）

建议回答：**不收集数据（Data Not Collected）**。

理由（逐项对照 Apple 定义：「收集」指数据离开设备后，开发者或其合作方可以在实时处理之外访问）：

| 数据 | 去向 | 是否属于开发者收集 |
|---|---|---|
| 录音 | 经加密局域网链路发送到**用户自己的 Mac**，Mac 再发给**用户自己配置**的百炼服务 | 否：开发者无服务器、无法访问；第三方服务由用户自行选择、自行开户 |
| 实时预览文字 | Apple Speech（系统框架） | 否：Apple 系统服务，不算 App 的第三方合作方 |
| 配对令牌、偏好 | 仅保存在本机（钥匙串 / 应用容器） | 否 |
| 诊断日志 | 仅本地，用户主动导出 | 否 |
| 使用统计、广告、崩溃上报 SDK | 无 | 否 |

隐私清单 `ios/iMic/PrivacyInfo.xcprivacy` 已声明 Required Reason API，无跟踪域名，与上述回答一致。
持有人提交前请再确认一次：iOS 端没有新增任何第三方 SDK 或开发者服务器请求。

## 4. 其他问卷

- **出口合规**：使用加密，但只用 Apple 系统提供的标准加密（CryptoKit）保护用户自己设备间的数据，符合豁免条件；`Info.plist` 已有 `ITSAppUsesNonExemptEncryption = NO`，构建不会再弹出合规问题。
- **年龄分级**：所有内容问题选「无」；无不受限网页访问、无用户生成内容社交功能、无赌博、无医疗内容 → **4+**。
- **内容版权**：不包含第三方内容 → 选「否」。
- **广告标识符（IDFA）**：不使用。
- **价格与销售范围**：**2.99 美元**（2026-11-23 由免费改为付费；基准地区美国，其他地区按 Apple 自动换算，无内购）。付费 App 需要「协议、税务和银行业务」中的付费 App 协议处于有效状态。**已决定（2026-11-16）：不上中国大陆**。在「价格与销售范围」中取消勾选中国大陆，其余国家和地区全选。中国大陆商店需要 ICP 备案号，以后要上时再办理。

## 5. 审核风险与应对

| 风险 | 对应指南 | 应对 |
|---|---|---|
| 审核员没有 Mac 或识别 Key，无法测试 | 2.1 | 演示视频 + 审核专用 Key + 备注中的分步说明 |
| 被认为「只是配件，功能太少」 | 4.2 | 描述与截图突出 iPhone 端的完整交互（实时预览、琴弦手势、润色模式、多 Mac 管理） |
| 需要另一款 App 才能用 | 2.1 / 4.2 | 写明 Mac 客户端免费、已公证、可公开下载；描述第一屏即说明前置条件 |
| 名称含 Apple 商标 | 5.2.5 | 名称不含 Mac / iPhone，只在副标题和描述中描述性提及 |
| 隐私政策页只有中文 | 5.1.1 | 见第 7 节「待补」 |
| 蓝牙权限用途不清 | 5.1.1 | 备注中已说明蓝牙只用于连接用户自己的 Mac |

## 6. 演示视频（建议持有人录制，约 60 秒）

真机录屏 + Mac 屏幕同框（或分屏剪辑），按顺序：

1. 打开 iPhone App → 选择 Mac → 输入配对码（5 秒）
2. Mac 打开备忘录或 TextEdit，iPhone 按住说一句话，松手后文字出现在 Mac（15 秒）
3. 下拉琴弦发送回车；上拨删字（10 秒）
4. 打开润色，说一句口语化的话，展示润色结果（15 秒）
5. 设备页切换另一台 Mac（可选，10 秒）

导出 MP4，上传到「App 审核信息 → 附件」。也可以把同一段剪成 15–30 秒的 App 预览视频（需 886×1920 竖屏）。

## 7. 待补（上架前必须完成）

- [ ] 隐私政策网址：目前 `docs/PRIVACY.md` 的 App 部分只有中文，英文商店最好有英文版。建议在官网新增 `/privacy/` 中英双语页面，并把网址改成官网地址。
- [ ] 审核专用百炼 Key：持有人已准备，提交时由持有人粘贴到审核备注，不进入仓库（第 2 节）。
- [ ] 演示视频（第 6 节）。
- [x] 中国大陆销售范围：已决定不上，销售范围中取消勾选中国大陆。
- [ ] App Store Connect 的「App 信息」中确认名称可用（重名时用 listing.md 中的备选）。
