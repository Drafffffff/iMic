# 实现说明与对照表

## 本地化实现

唯一文案来源为 `ios/iMic/Localizable.xcstrings` / `InfoPlist.xcstrings`，源语言英文。Mac 的 en / zh-Hans `.strings` 由脚本生成并提交，构建时复制到资源包；不使用 xcstringstool，已用真实 Command Line Tools 目录构建成功。共享 `L10n` 在 iOS 使用 String(localized:)，Mac 使用 NSLocalizedString，按首选系统/单 App 语言选择：所有中文变体使用简体中文，其余语言英文；缺失条目退回英文。

Mac 和 iPhone 独立本地化；共享的模式枚举从同一个 Catalog 取显示名称。提示词使用独立的固定中文属性。全部 80 个模式 × 语气 × 输出语言组合的提示词 SHA-256 与基线一致。没有改变模型、识别/润色行为、帧格式、密钥派生或配对规则。

官网共用原有资源，新增 /en/ 页面与 hreflang。提示条不自动跳转、不用 Cookie 或任何存储；关闭仅在当前页面有效，再次访问会重新显示。from=ios 在英文窄屏定位 Mac 下载卡，确保分享按钮可见。

Sparkle 2.10.1 的原生资源完整保留。Foundation 的 preferredLocalizations 实测：en → en，zh-Hans → zh_CN，zh-Hant → zh_TW。Sparkle 使用系统本地化，未修改第三方框架。正式更新公钥仍为占位值，因此没有对正式 feed 发起安装更新；测试验证更新设置和录音/输入/向导期间的延后逻辑。

## 术语

| 中文 | English |
| --- | --- |
| 百炼 | 首次 Model Studio (Bailian)，后续 Alibaba Cloud Model Studio / Model Studio |
| API Key | API Key（Key） |
| 配对码 | pairing code |
| 弦 | string |
| 润色 | polish |
| 实时预览 | live preview |
| 辅助功能 | Accessibility |
| 业务空间 | workspace |
| 地域 | region |
| 屏幕录制 | Screen Recording |
| 终端命令 | terminal command |
| 清空输入框 | clear text field |

## 润色模式与语气

| 中文模式 | 英文名称 | 英文说明 |
| --- | --- | --- |
| Agent 指令 | Agent instructions | Remove repetition and smooth phrasing. Keep your words without expanding the task. |
| 终端命令 | Terminal command | Turn actions into a single zsh command. Type it without executing it. |
| 文言文 | Classical Chinese | Keep the meaning and sentence order in concise classical prose. |
| 废话文学 | Playful repetition | Keep the original sentence, adding a short, playfully redundant phrase. |
| 翻译腔 | Movie dub | Keep the original sentence with a touch of vintage movie-dub wording. |

| 中文语气 | English |
| --- | --- |
| 正经说话 | Natural |
| 阴阳怪气 | Sarcastic |
| 萌系暴击 | Extra cute |
| 暴躁吐槽 | Full rant |

输出语言显示名称：中文 → Chinese，英文 → English，日文 → Japanese，韩文 → Korean。输出语言选择与界面语言完全独立，提示词中的 languageName 保持原值。

## 保留不翻译的中文

以下为检查脚本按完整 Swift 字符串字面量统计（多行提示词作为一个字面量，重复出现计数）。注释由词法扫描器跳过，不算字符串；测试目录的样例也不属于扫描的界面代码。

| 类别 | 字面量数量 | 理由 |
| --- | ---: | --- |
| DEBUG 演示语音与样例 | 18 | 既有演示脚本，不改变录制素材 |
| DEBUG 待机诊断样例 | 1 | 合成验证输入，非界面说明 |
| OCR 定位校准样例 | 1 | 仅供本机测量，不显示 |
| 识别/输入行为匹配词 | 30 | DeepSeekPolicy 与 TextRevision 中的语义/终端匹配逻辑 |
| 模型提示词与固定中文输入 | 31 | 包括 promptTitle、promptExample、instruction、languageName 和 system prompt |
| 解码诊断 | 3 | 非用户界面的 DecodingError.debugDescription |
| 日志原因（非界面） | 9 | 仅用于连接重试等日志，保持原样；其他日志模板也保持原样 |

协议字段名、错误码、技术标签（HOLD、STRING、LIVE、POLISH、SYS 01、RX / 01 等）均保持英文。它们不属于“保留中文”计数。每个保留字面量的精确 SHA-256、路径、数量和理由见 tools/l10n-exclusions.json；检查结果附完整报告。

## 兼容性与测试边界

新增 code 只承担显示分类，`message` 始终保留供旧 iPhone 显示。影响旧客户端行为的 auth / pair_code / pair_locked 保持原值。新 iPhone 对未知/缺失 code 仍显示 message。协议测试覆盖每个已知显示码、旧回复、未来码、两端语言独立与英文兜底。原 AES-GCM、随机 nonce、帧校验与配对测试继续通过。

截图全部使用合成凭据、DEBUG 预览或模拟网络响应，没有真实录音、Key 或用户文字。官网视频/海报按任务书共用原中文素材；英文 ANYWHERE 动画示例单独改为英文。Pro 与 SE 都是本任务创建的专用设备，收尾删除。没有安装覆盖 /Applications/iMic.app，没有修改版本号、发布或更改仓库设置。
