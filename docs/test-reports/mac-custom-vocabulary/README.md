# Mac 自定义词库测试报告

日期：2026-11-23。基线：`main` 的 `d35299a`（PR #51 合并后）。
环境：Apple Silicon，macOS 26.6.2，Xcode 27.1。识别模型 `qwen-audio-3.1-asr-flash-message`（北京），润色使用本机已配置的百炼默认模型。
测试中没有读取、打印或保存任何 API Key：真实识别由无界面 Mac 进程按用户现有配置自行读取 Key。

## 改了什么

- `shared/Vocabulary.swift`：词条模型、规则校验（含非 ASCII 字符时不超过 15 个字符，纯 ASCII 时空格分段不超过 7 段，启用不超过 2000 个，权重 1–5、默认 4，去重时忽略大小写和全半角）、按润色模式筛选、超过 2000 个时按列表顺序确定性截断、纯文本导入导出，以及 `vocabulary.json` 存储（目录 0700、文件 0600、原子写入）。
- `mac/ASR.swift`：run-task 的 `parameters.vocabulary` 携带即时热词；词库为空时不写这个字段，run-task 和改动前逐字段一致。如果在 `task-started` 之前收到 `task-failed`，就换一个任务、不带词库重试一次；音频仍在本地队列里，不会丢。
- `shared/PolishOptions.swift` 和 `mac/DeepSeek.swift`：新增 `systemPrompt(glossary:)`，在系统提示词末尾追加 `<glossary>` 专有名词表，词条里的 `& < >` 会转义。词库为空时，提示词和请求体都与改动前逐字节一致。`DeepSeekPolicy` 没有改动。
- `mac/VocabularySettings.swift` 和 `mac/SettingsWindow.swift`：设置窗口新增第 6 个分页「词库」（⌘6），排在最后，原来 ⌘1…⌘5 的含义不变。支持添加、行内改名、启用/停用、权重、按模式启用、多选删除、纯文本导入导出，以及识别/润色两个开关。
- `mac/main.swift`：识别和润色接入词库。`--headless --vocabulary-file=` 只读取指定文件，不读写用户词库。无界面运行时额外打印 `VOCABULARY recognition=<条数>` 和 `ASR_RAW <原始识别>`，用来区分识别和润色各自的作用。
- `scripts/test-link.sh`：新增 `IMIC_TEST_VOCAB=<文件>`，会转交给 `--vocabulary-file=`。
- 中英文案共 28 条，写在 `ios/iMic/Localizable.xcstrings` 中，`.strings` 由 `tools/generate-l10n.py` 生成。润色规则中的中文字面量已登记到 `tools/l10n-exclusions.json`。
- 不改 iPhone 协议，`shared/iMicLink.swift` 未改动。

导入导出格式选的是**纯文本**：每行 `词条[<Tab>权重[<Tab>模式,模式]]`，模式写 `all` 或 `agent,terminal,classical,waffle,dubbed`，`#` 开头的行是注释。只认 Tab 分隔，因为英文词条本身可能含空格和逗号。

「按模式启用」以当前选择的润色模式为准；关闭润色时，按设置里仍然选中的模式判断。

## 自动化测试

| 命令 | 结果 |
|---|---|
| `DEVELOPER_DIR=… swift test` | 96 项通过；新增 `VocabularyTests` 17 项：长度和段数规则、空白与控制字符、空白归一、去重、2000 上限、权重夹取、按模式筛选、确定性截断、导入导出往返、导入跳过重复和非法行、存储往返与 0600 权限、损坏文件回退为空、内存存储不写盘、空词库提示词不变（全部模式 × 全部输出语言，含终端）、词条转义、守门不受影响 |
| `./scripts/test-asr.sh` | 19 项通过；新增 6 项：空词库时 run-task 参数不变；带词库时发送 `vocabulary`；词库被拒后不带词库重试，期间音频完整上传、旧任务迟到的事件被忽略、提示回调只触发一次；只重试一次；无词库不重试；`task-started` 之后失败不重试 |
| `./scripts/test-polish.sh` | 33 项通过；新增：空词库与旧调用的请求体逐字段一致；带词库时只有 system 消息变化，`<transcript>`、温度等不变 |
| `./scripts/test-mac-settings.sh` | 中英文均通过；工具栏分页数 5 → 6；词库页的两个开关默认开启；添加时去空白、默认权重 4；重复和超长词条有提示；导入时合并并跳过；按模式筛选；删除；预览模式下词库不落盘 |
| `./scripts/test-l10n.sh` | 通过 |
| `./scripts/test-text-history.sh` | 通过 |
| `./scripts/build-mac.sh` | 通过，0 警告 |
| `./scripts/build-ios.sh` | 通过（`shared/Vocabulary.swift` 也会编译进 iOS，iOS 不使用它） |

截图：[中文](zh-Hans/settings-vocabulary.png)、[英文](en/settings-vocabulary.png)，由 `test-mac-settings.sh --capture-ui=` 生成，使用预览示例词条。

## 真实识别对比

### 关于 `test-link.sh` 的说明

在 Claude Code 会话里直接运行 `scripts/test-link.sh`，无界面 Mac 进程启动后会因为蓝牙访问被 TCC 以 `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__` 终止。原因是隐私检查的责任进程是宿主 `claude`，它没有 `NSBluetoothAlwaysUsageDescription`。这个问题和本改动无关，同一天其他会话的崩溃报告里也出现过。

所以改用 [`run-link-headless.sh`](run-link-headless.sh)：步骤和 `test-link.sh` 相同（用 `say` 合成 zh_CN 语音，转成 16 kHz PCM，用 `imic-client` 配对并发送），只是用 `open` 启动 `VoxChord.app`，让应用自己作为责任进程。在普通终端里可以直接运行：

```bash
IMIC_TEST_TEXT="请祺元和洛柯明天参加璇枢评审。" ./scripts/test-link.sh
```

```bash
IMIC_TEST_TEXT="请祺元和洛柯明天参加璇枢评审。" IMIC_TEST_VOCAB=/path/to/vocab.txt ./scripts/test-link.sh
```

### 测试设计

词库（8 个词条）：`祺元 洛柯 璇枢 VoxChord Otty Kubernetes Helm Argo CD`。另有一份 2000 词的词库：这 8 个词加上 1992 个随机生成的「汉字 + 数字」假词。

| 条件 | 词库 | 润色 |
|---|---|---|
| A | 无 | 关（`-deepseekEnabled <false/>`） |
| B | 8 词，权重 4 | 关 |
| B5 | 8 词，权重 5 | 关 |
| D | 2000 词，权重 4 | 关 |
| C | 8 词，权重 4 | 开（带专有名词表） |

每个句子在每种条件下各跑 3 次，共 60 次。原始数据见 [link-matrix.tsv](link-matrix.tsv)。

### 结果（原始识别，命中数 / 应出现次数）

| 句子 | A | B | B5 | D | C（原始 → 润色后） |
|---|---|---|---|---|---|
| T3 请**祺元**和**洛柯**明天参加**璇枢**评审 | **0/9**（奇缘、洛科、选书） | **9/9** | 9/9 | 9/9 | 9/9 → 9/9 |
| T2 把 **Kubernetes** 的 **Helm** chart 推到 **Argo CD** | K 2/3，H 2/3，Argo CD 0/3（ArgoCD 2 次） | K 3/3，H 3/3，Argo CD 0/3（ArgoCD 1 次） | K 3/3，H 3/3，Argo CD 1/3（ArgoCD 2 次） | K 3/3，H 3/3，Argo CD 0/3（ArgoCD 2 次） | K 2/3，H 2/3（原始）；润色把 1 次 `ArgoCD` 改成 `Argo CD` |
| T1 我在 **VoxChord** 里打开了 **Otty** 终端 | 0/6 | 0/6 | 0/6 | 0/6 | 0/6 → 0/6 |
| T4 今天天气不错，我们去公园走走（反例） | 正常 | 无误召回 | 无误召回 | 无误召回（2000 词） | 无误召回 |

- 词库对**中文生僻人名和自造词**效果非常明显：不带词库时 9 处全错，带词库后 9 处全对。2000 词的词库里同样全对。
- 对 **TTS 合成的英文品牌名**几乎无效：`say` 的中文语音把 `VoxChord` 和 `Otty` 读得接近 `Voice Chat` 和 `VoIP`，权重 5 也没纠正过来。T2 中常见的 Kubernetes 和 Helm 不带词库也大多能识别对；带词库后更稳定（3/3），但 `Argo CD` 多数仍输出成 `ArgoCD`。**这些英文结论需要用真人录音复核**。
- 反例 T4 共 12 次带词库识别（含 2000 个随机假词），都没有误召回。
- 润色阶段的专有名词表没有凭空加词，也没有把错的人名改成别的。它把一次 `ArgoCD` 改成了词库写法 `Argo CD`。`Voice Chat` 没有被改成 `VoxChord`，符合「读音相近且显然指同一事物才改」的保守规则。
- 60 次中，词库被拒、触发重试的次数为 0。

### 延迟

| 条件 | 松手 → 最终结果，中位数（ms） | 均值（ms） |
|---|---|---|
| A 无词库 | 371 | 477 |
| B 8 词 | 311 | 337 |
| B5 8 词，权重 5 | 313 | 430 |
| D 2000 词 | **704** | 712 |
| C 8 词 + 润色 | 328 | 427 |

`task-started` 的等待时间（来自 `~/Library/Logs/iMic/iMic.log`，中位数）：无词库 294 ms，8 词 329 ms，2000 词 297 ms。

结论：几个到几十个词条对延迟没有可测的影响。**2000 词不影响建连，但最终结果大约慢 0.3–0.4 秒**，应在界面中提示，并建议只保留常用词。

## 没有覆盖的部分

- 不合规词条会被百炼怎样拒绝、返回什么错误码：本地校验会先拦截，真实链路上无法构造；自动重试的逻辑由离线测试覆盖。
- 即时热词是否计入输入 token：客户端没有记录 usage，需要看百炼账单或用量页确认。
- 真人录音、iPhone 真机或模拟器整链路（`--debug-tts`）没有测。词库在 Mac 侧生效，和录音来源无关；`--debug-tts` 用的也是系统语音合成，结论会和上面的 TTS 结果相近。
- 设置页「最近一次被拒绝」提示：触发它的回调由离线 ASR 测试覆盖，真实链路上没有触发过，界面提示也没有单独测。
