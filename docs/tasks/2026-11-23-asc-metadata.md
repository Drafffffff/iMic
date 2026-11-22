# 任务书：用 App Store Connect API 填写 VoxChord 首发商店资料

日期：2026-11-23
执行者：Codex
审核与合并：Claude

动手前阅读：`AGENTS.md`、`docs/appstore/listing.md`、`docs/appstore/review.md`、`docs/appstore/screenshots/README.md`。

## 0. 交付方式

- 在本 worktree 的分支 `codex/asc-metadata` 上工作，基于 `main`。
- 新增可复用脚本（建议 `tools/asc/`，Swift 单文件或 Python 标准库，不引入第三方依赖），用来读取和写入商店资料。脚本必须先支持 `--dry-run`：只读、打印计划改动、不写入。
- 推送后用 `gh pr create --base main` 提 PR，PR 描述附第 5 节的完整报告。**不要自行合并**。

## 1. 凭据与范围（硬性规则）

- 密钥：App Store Connect **个人 API 密钥**，Key ID `0N62MERQLNT3`，私钥 `~/.appstoreconnect/private_keys/AuthKey_0N62MERQLNT3.p8`。
- 个人密钥的 JWT：header `{"alg":"ES256","kid":"0N62MERQLNT3","typ":"JWT"}`，payload `{"sub":"user","iat":…,"exp":≤20 分钟,"aud":"appstoreconnect-v1"}`，**没有 `iss`**。可参考 `/tmp/asc/check.swift`（CryptoKit 签名，已验证 HTTP 200）。
- **不得**读取、打印、复制、提交私钥内容或 JWT；日志里只出现 Key ID。私钥不得进入仓库、PR 或日志。
- 这个密钥能访问该账号下的所有 App。**只能操作 App `6829771739`（`art.malette.imic.app`）**。脚本必须写死这个 App ID，每次写入前核对 bundleId，不一致就退出。
- 禁止：
  - 提交审核（不创建 `appStoreVersionSubmissions` / `reviewSubmissions`）
  - 改价格协议或税务银行信息
  - 管理用户
  - 改证书、Bundle ID 或描述文件
  - 删除或覆盖其他 App 的任何东西
  - 删除 TestFlight 构建或测试组
- 不填写任何 API Key（包括百炼）。审核备注里的审核 Key 保留占位行，由用户本人粘贴。
- 有 Apple 返回需要人工确认的协议、出口合规以外的新问题时，停下来报告，不要猜。

## 2. 要填写的内容（来源：`docs/appstore/listing.md`、`review.md`）

先 `--dry-run` 读出现状并打印，再写入。

1. **App 信息（appInfos / appInfoLocalizations）**
   - 主语言保持简体中文（`zh-Hans`）。新增英文（美国）`en-US` 本地化。
   - 名称：zh-Hans `VoxChord 语音输入`，en-US `VoxChord: Voice Typing`。名称被占用时，依次换用 listing.md 中的备选，并在报告里写明。
   - 副标题、隐私政策网址：按 listing.md 填写。
   - 主类别「效率」（PRODUCTIVITY），次类别「工具」（UTILITIES）。
2. **年龄分级（ageRatingDeclarations）**：所有内容项选无或否，不受限网页访问选否，目标为 4+。
3. **价格与销售范围**
   - 免费：若尚无价格计划，设为免费的基础价格。
   - 销售范围：除中国大陆（CHN）外的全部国家和地区。新地区默认自动加入。
4. **App Store 版本（appStoreVersions，iOS）**
   - 若没有可编辑的版本，创建 `1.4.9`（与 `VERSION` 一致）；已有可编辑版本则直接用它。
   - 两种语言的本地化：描述、关键词、推广文本、技术支持网址、营销网址、此版本新增内容（首发版本若不允许填「新增内容」，就跳过并记录）。
   - 版权：`2026 KE CHENG`。
   - 构建：选择 App Store Connect 中最新的、已处理完成的 1.4.9 构建（有就选，没有就记录，不要上传新构建）。
5. **截图（appScreenshotSets / appScreenshots）**
   - `docs/appstore/screenshots/zh-Hans/*.png` 上传到 zh-Hans，`en/*.png` 上传到 en-US，显示类型用 6.9 英寸 iPhone 对应的类型（1320×2868），按文件编号排序。
   - 走完整上传流程：reserve → 分片 PUT → commit（带 MD5 校验），然后轮询到 `COMPLETE`。重跑时不得重复上传：先删除本脚本此前在同一集合里上传的截图，或者检测到相同文件名就跳过。
6. **App 审核信息（appStoreReviewDetails）**
   - 联系人：周龙飞，`+86 13818611371`，`i0.0ia@qq.com`。
   - 不需要登录账号（demo account required = false）。
   - 备注：`review.md` 第 1 节的英文全文。其中 `API key for review:` 一行保留为 `API key for review: <TO BE ADDED BY OWNER>`。
   - 附件：不上传（演示视频尚未录制）。

**不在本任务范围内**（API 不支持或需要用户本人处理）：App 隐私问卷（Data Not Collected）、出口合规（构建 Info.plist 已声明）、审核 Key、演示视频、提交审核。在报告里列为「需用户在网页完成」。

## 3. 实现要求

- 所有请求加超时和有限重试（429 和 5xx 退避重试；4xx 不重试，直接打印 Apple 返回的 `errors[].code/title/detail`）。
- 写入要幂等：重复运行不产生重复本地化、重复截图或重复版本。
- 打印每一步「字段：旧值 → 新值」，长文本只打印前 40 个字符和长度。

## 4. 验证

1. `--dry-run` 一次，附输出。
2. 正式写入一次。
3. 再 `--dry-run` 一次，应显示没有待改动。
4. 只读核对：重新读取各项资料，与 listing.md 逐字段比对，截图集合中每种语言 6 张且状态都是 COMPLETE。
5. 字段长度：名称和副标题 ≤ 30，推广文本 ≤ 170，关键词 ≤ 100，描述 ≤ 4000。

## 5. PR 报告模板

```
## 已写入
- App 信息：名称 / 副标题 / 隐私网址 / 类别（逐项旧值 → 新值）
- 年龄分级：…
- 价格与销售范围：免费；地区 N 个，不含 CHN
- 版本：1.4.9（新建 / 已有），构建：…
- 本地化：zh-Hans、en-US 各字段
- 截图：zh-Hans 6 张、en-US 6 张，状态
- 审核信息：联系人、备注（Key 占位）

## 失败或跳过
- …（Apple 原始错误）

## 需用户在网页完成
- App 隐私问卷：选「不收集数据」
- 审核备注中粘贴审核 Key
- 演示视频附件
- 核对后点击「提交审核」

## 验证
- 命令、耗时、结果
```
