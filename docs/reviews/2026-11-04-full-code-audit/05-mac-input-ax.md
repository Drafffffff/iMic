# Mac 文本输入与辅助功能 审计

## 范围与方法

只读检查了 `AGENTS.md`、指定的五个源文件，以及输入范围、Unicode 修订、清空输入和润色效果相关测试；对照 `docs/ARCHITECTURE.md`、`docs/DEVELOPMENT.md`、协议与发布说明排除了已知限制。另查阅本机 macOS SDK 中全局事件监视与 Secure Input 的说明。

尝试运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --scratch-path /tmp/imic-audit-mac-input --filter TextRevisionTests
```

只读沙箱禁止创建 `/tmp` 缓存，测试在编译器初始化阶段失败。以下发现基于静态调用链核查，未进行实机投递。未修改仓库、访问网络或调用真实 API。

## 发现

### [P1] AX 信息缺失时，内嵌终端漏过换行过滤

- 位置：`mac/InputTarget.swift:145`、`shared/TextRevision.swift:66`、`mac/main.swift:670`、`mac/main.swift:1096`
- 证据：终端判断仅依赖终端应用 Bundle ID 或焦点元素标签；`element == nil` 时标签为空。VS Code、Cursor 等宿主不在终端 Bundle 集合中，因此返回 `false`。`targetIsTerminal` 仅在会话开始时赋值，随后 `sanitize` 按该值决定是否保留换行。
- 触发条件：新启动、尚未暴露 AX 树的 Electron 编辑器中，焦点位于内嵌终端；识别或润色结果包含换行。`mac/TextPolishEffect.swift:937` 已明确说明这类应用可能需要请求 `AXManualAccessibility` 才暴露文本控件。
- 后果：多行结果按普通文本原样投递到终端，换行可能提交并执行前一行。这与 `docs/releases/v1.4.3.md:10` 声明的“含编辑器内置终端”换行防护不符。
- 建议修复：将目标类型区分为普通文本、终端和未知；对可承载终端且类型未知的宿主，禁止原样投递换行及 Tab。可靠识别焦点类型后再确定本轮过滤策略。
- 置信度：高。

### [P1] Secure Input 使按键监视失效后，仍允许键盘兼容修订

- 位置：`mac/InputTarget.swift:268`、`mac/InputTarget.swift:283`、`mac/InputTarget.swift:429`、`mac/main.swift:1139`
- 证据：是否具备接管监视仅通过 `inputMonitor != nil` 判断；兼容模式只检查接管标志和前台 PID。输入链路没有查询 Secure Input，也没有针对密码字段禁用实时修订。本机 SDK `CarbonEventsCore.h:2977` 明确说明，Secure Input 开启后，其他应用的事件监视器收不到键盘输入。
- 触发条件：目标开启 Secure Keyboard Entry，或焦点处于启用 Secure Input 的密码控件；本轮进入兼容模式后，用户在同一应用内手动输入或移动光标。范围模式也可能在失配 1.5 秒后通过现有非空监视器检查转入兼容模式。
- 后果：手动按键不会设置 `userIntervened`，本轮没有冻结；后续预览和最终结果仍可进入退格、追加通路，在用户调整后的输入位置继续投递。这超出了文档仅承认的“目标自行改稿或吞键”边界。
- 建议修复：在捕获、每次投递及兼容模式切换前检查 Secure Input。监视失效且已有投递内容时冻结本轮；密码或受保护字段禁止自动修订，保留完整结果。
- 置信度：高。

### [P2] 长文本同步投递期间，接管信号无法及时中止剩余事件

- 位置：`mac/main.swift:1106`、`mac/main.swift:1228`、`mac/main.swift:1252`
- 证据：前台及接管检查发生在 `insert` 入口；`typeText` 随后同步发送全部退格和文本分块，循环内没有再次检查。接管状态由异步事件监视和主队列应用切换通知更新。
- 触发条件：兼容模式需要重写较长尾部，用户在退格或分块投递尚未结束时点击其他位置、按键或切换应用。
- 后果：本次调用继续向原 PID 排入剩余事件；应用已经切走后仍可能收到输入，用户移动光标后剩余退格也可能落到其他正文位置。冻结只能阻止下一次调用。
- 建议修复：将投递改为有界异步批次，批次间让主队列处理接管通知，并重新检查会话代际、前台 PID 和冻结状态；记录部分投递进度，取消后禁止最终结果重放。
- 置信度：中；事件循环缺少中止点可直接确认，实机影响窗口未测量。

### [P2] 扫光提前返回目标，绕过同窗口受保护内容检查

- 位置：`mac/TextPolishEffect.swift:935`、`mac/TextPolishEffect.swift:959`、`mac/TextPolishEffect.swift:979`、`mac/TextPolishEffect.swift:1015`
- 证据：候选队列优先放入捕获的输入框；找到该框后立即返回 `allowsCapture: !protectedSeen`，尚未遍历窗口中的其他节点。`capture` 实际先截取整个窗口，再裁剪输入框。即使 AX 几何定位成功，`mac/TextPolishEffect.swift:203` 的亮度采样也会调用截图。
- 触发条件：同一窗口同时含普通输入框及其他密码框或 `AXProtectedContent` 区域；普通输入框先被找到，且已授予屏幕录制权限。
- 后果：`protectedSeen` 仍为 `false`，整个窗口进入临时截图，受保护兄弟区域未经过预期检查。可确认的后果是本机内存截图范围越过保护策略。
- 建议修复：将输入框定位与窗口保护检查分开；保护检查未完成或超时则禁用截图、保留 AX 几何效果。字段采样应在捕获阶段限定区域，避免整窗截图后再裁剪。
- 置信度：高。

## 已检查且未发现问题的方面

- **权限路径**：自动输入检查辅助功能及事件投递权限；未发现修改 TCC 或自动批准权限的代码。
- **常规前台变化与接管冻结**：会话开始保存目标 PID；每次 `insert` 检查前台，接管标志会阻止最终回写。上述 Secure Input 和单次长批次是例外。
- **范围修订**：替换前核验本轮正文、选区与焦点；AX 正文写入一经尝试，结果不明时先回读确认，不能再走键盘重放。
- **原稿保护**：预览修订不全选、不设置整框 `AXValue`。整框清空限于用户明确请求，并核验完整选区及清空结果。
- **Unicode 常规路径**：修订按字素簇计算删除数，AX 范围使用 UTF-16；普通分块按完整 `Character` 追加，避免在常规代理对、组合字符内部切分。
- **视觉与输入分离**：OCR 和排版估算不授权文本修改；扫光使用非激活、鼠标穿透面板，并以代际和取消令牌阻止迟到回调。