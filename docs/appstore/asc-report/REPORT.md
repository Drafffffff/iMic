# VoxChord 首发商店资料执行报告

执行日期：2026-11-23。App `6829771739` / `art.malette.imic.app`。
仅填写商店资料；没有提交审核，没有合并分支。

## 已写入

### App 信息（旧值 → 新值）

| 字段 | zh-Hans | en-US |
|---|---|---|
| 名称 | `iMic` → `VoxChord 语音输入` | 无 → `VoxChord: Voice Typing` |
| 副标题 | 无 → `按住说话，字落进 Mac 输入框` | 无 → `Hold to speak. Type on Mac.` |
| 隐私政策网址 | 无 → https://github.com/Drafffffff/iMic/blob/main/docs/PRIVACY.md | 无 → 同一网址 |

主语言 `zh-Hans` → `zh-Hans`（保持）；主类别无 → `PRODUCTIVITY`；次类别无 → `UTILITIES`。
两个首选名称均可用，没有启用备选。

年龄问卷的 26 个未填写内容/功能项已设置为 `NONE` 或 `false`，包括广告、不受限网页访问、用户生成内容、聊天、赌博及医疗内容；两个覆盖选项保持 `NONE`。Apple 重新读取结果为 `FOUR_PLUS`（4+）。

价格：原先只有空价格计划壳，读取手动价格返回 404；已设 USA 为基础地区，价格 0，1 个手动价格与 174 个自动价格均免费。
销售范围：无配置 → 174 个国家和地区，不含 `CHN`；新地区自动加入：未设 → `true`。

版本复用原有可编辑条目 `284484cf-6c76-4821-9eab-568adbe8ea2e`，版本号 `1.0` → `1.4.9`，没有创建重复版本。版权无 → `2026 KE CHENG`。
构建未选 → `1.4.9 (11)`，ID `7b4a50ec-bbe3-4b44-b9eb-dc159d1002c3`；为目前最新已处理完成、未过期、可用于 App Store 的匹配 iOS 构建。未上传构建。

### 两种语言的版本资料（原值均为空）

| 字段 | zh-Hans 新值 | en-US 新值 |
|---|---|---|
| 描述 | listing.md 中文全文，629 字符 | listing.md 英文全文，1551 字符 |
| 关键词 | listing.md 中文逐字一致，56 字符 | listing.md 英文逐字一致，97 字符 |
| 推广文本 | listing.md 中文逐字一致，68 字符 | listing.md 英文逐字一致，166 字符 |
| 技术支持网址 | https://drafffffff.github.io/iMic/ | https://drafffffff.github.io/iMic/en/ |
| 营销网址 | https://drafffffff.github.io/iMic/ | https://drafffffff.github.io/iMic/en/ |
| 此版本新增内容 | Apple 拒绝首发填写，已跳过 | Apple 拒绝首发填写，已跳过 |

来源为 [listing.md](../listing.md)。长文本的前 40 个字符和总长度，以及所有字段的逐项旧值 → 新值，见首次 dry-run 和两段写入日志。最终只读验证对完整字符串比较，非只比较摘要。

### 截图与审核信息

截图按 `01` 至 `06` 文件编号排序，每种语言使用一个 `APP_IPHONE_67` 集合（Apple API 当前对应 6.9 英寸截图的枚举），尺寸均为 1320×2868。每张执行 reserve → 分片 PUT → 带 MD5 的 commit → 轮询。

最终重新读取：zh-Hans 6 张、en-US 6 张，均为 COMPLETE，无重复；顺序及服务端 MD5 与本地文件逐张一致。

| 文件（两种语言均同名） | zh-Hans MD5 / 状态 | en-US MD5 / 状态 |
|---|---|---|
| `01-listen.png` | `dcb025dcf5d6f060c35a144f0443f85a` / COMPLETE | `99db2d413d78ca769d1911113b2a9f09` / COMPLETE |
| `02-pull.png` | `bdedc01b3168417c39969ed1ee91444e` / COMPLETE | `dcf8581c94c7d6e8e3c3342fcddac492` / COMPLETE |
| `03-polish.png` | `7627d41a4684db6e6b2df8eb3f8c6924` / COMPLETE | `91b919619b265c35acfd6ee4cc480305` / COMPLETE |
| `04-settings.png` | `38afc9155d2e7bb3d2e59ee70f088323` / COMPLETE | `056a0c6c70c7cd4481d2a18cff122bf5` / COMPLETE |
| `05-devices-manage.png` | `8170978b4ac41291f5038862f4bb99c6` / COMPLETE | `3b467844b3e7db52ab95e088f572f9f8` / COMPLETE |
| `06-pairing.png` | `4f43c9f52449fdf69842ac23a9c8e2f2` / COMPLETE | `63bddf306f7dbf7a28a3e467038ecb60` / COMPLETE |

审核联系人：未填 → 周龙飞（姓 `周`、名 `龙飞`），`+86 13818611371`，`i0.0ia@qq.com`。
需要登录：未填 → `false`。审核备注：未填 → review.md 第 1 节英文全文（1627 字符），仅将审核 Key 行替换为 `API key for review: <TO BE ADDED BY OWNER>`。没有填写任何服务 API Key。未上传附件。

## 失败或跳过

两种语言的首发 `whatsNew` 均返回以下 Apple 原始错误（HTTP 409），依任务书明确允许的例外跳过，并保存至 `exceptions.json`：

```json
{
  "code": "STATE_ERROR",
  "title": "The request cannot be fulfilled because of the state of another resource.",
  "detail": "Attribute 'whatsNew' cannot be edited at this time"
}
```

首次正式写入在中文该字段处保守停止；随后收窄为“确认只有首发可编辑版本 + 精确匹配此 Apple 错误”才跳过，并幂等续跑。中文已有错误记录，英文现场记录后继续。没有重试其他 4xx，没有猜答协议或其他持有人问题。初始可选资源的 404 表示类别、价格或销售配置尚未创建，完整 code/title/detail 保留在日志。

## 需用户在网页完成

- App 隐私问卷：核对后选择「不收集数据」。
- 审核备注中由持有人粘贴审核专用 Key。
- 上传演示视频附件。当前备注按要求原文保留了“demo video ... is attached”一句，提交前应实际附上视频。
- 出口合规：核对所选构建的自动豁免声明；脚本不更改此答案。
- 核对全部资料后，由持有人点击「提交审核」。

隐私政策按 listing.md 保留现有 GitHub 地址；review.md 已提醒该页面的 App 部分目前只有中文，英文版本仍由持有人后续处理。

## 验证

| 命令 | 耗时 | 结果 |
|---|---|---|
| `python3 tools/asc/metadata.py --dry-run`（首次） | 22.00 秒 | 73 项待改动；0 次写入；21 次读取 |
| `python3 tools/asc/metadata.py --apply`（首次） | 约 42.82 秒（日志时间戳） | 已完成基本资料、分级问卷、价格、销售范围及版本/构建；在中文 whatsNew 的 409 处停止 |
| `python3 tools/asc/metadata.py --apply`（幂等续跑） | 195.79 秒 | 29 次成功 API 写入、88 次读取；完成双语文案、12 张截图及审核资料；PUT 单独记录 |
| `python3 tools/asc/metadata.py --dry-run`（最终） | 22.80 秒 | `pending=0, writes=0, reads=23` |
| `python3 tools/asc/metadata.py --verify --json-report docs/appstore/asc-report/verification.json` | 24.15 秒 | `pending=0, writes=0, reads=24`；完整字段比较通过 |
| `python3 -m unittest discover -s tools/asc -p 'test_*.py'` | 0.036 秒 | 12 项通过，覆盖范围/只读保护、错误停止、429/5xx 有限重试、POST 恢复、截图幂等与 MD5、首发字段例外 |

最终验证重新从 Apple 读取各资源，再与 Markdown 来源的完整字段比较；随后对 verification.json 的文本 SHA-256/长度和截图 MD5 重新从源文件计算并比对，全部通过。名称/副标题/推广文本/关键词/描述字符数如下：

| 语言 | 名称 ≤30 | 副标题 ≤30 | 推广 ≤170 | 关键词 ≤100 | 描述 ≤4000 |
|---|---|---|---|---|---|
| zh-Hans | 13 | 16 | 68 | 56 | 629 |
| en-US | 22 | 27 | 166 | 97 | 1551 |

所选构建 `usesNonExemptEncryption=false`，未更改出口合规；App 信息和版本仍为 `PREPARE_FOR_SUBMISSION`。没有调用审核提交、用户、协议/税务/银行、证书/Bundle ID/描述文件、TestFlight 删除接口。私钥只由本地 CryptoKit 签名进程内部载入，JWT 仅在该进程内部使用，无 `iss`，有效期 10 分钟。日志仅包含 Key ID，没有私钥或 JWT。没有改动应用代码、协议、签名、VERSION 或构建号，因此未运行 App 构建/安装。

实现为 [metadata.py](../../../tools/asc/metadata.py) + [request.swift](../../../tools/asc/request.swift)，说明和复跑方法见 [README](../../../tools/asc/README.md)。脚本固定 App ID，所有写入前核对 bundleId，含重试与截图 PUT；写入资源必须来自该 App 的已验证关系。源码和交付资料的凭据内容扫描通过。

完整证据：

- [首次 dry-run](01-dry-run.txt)
- [首次写入及 Apple 原始错误](02a-apply.txt)
- [幂等续跑及上传日志](02b-apply-resume.txt)
- [最终 dry-run](03-dry-run.txt)
- [独立只读验证](04-verify.txt)
- [离线测试](05-tests.txt)
- [过滤后的验证事实（长文本保存 SHA-256 与长度）](verification.json)
- [首发 whatsNew 例外及 Apple 原始错误](exceptions.json)
