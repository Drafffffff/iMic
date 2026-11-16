# PR #25 合并基础分支后的验证

日期：2026-11-03。将 `origin/codex/ui-phosphor-wireframe` 的 `862436f` 合入 `codex/ios-onboarding-redesign`，包含 PR #23（采集恢复、静音监测、MIC TEST）和 PR #24（官网 TestFlight 链接）。使用普通 merge，保留双方提交历史；不合并 PR #25。

## 冲突处理

- `HomeView.swift`：同时保留引导连接页 fullScreenCover 与 MIC TEST sheet；弦的可用条件同时检查连接引导和自检弹层。保留 #23 自检期间暂停主屏绘制及错误区入口。第一次真实输入失败时让出 coach mark，让原有错误和 MIC TEST 操作可以正常使用。
- `Localizable.xcstrings`：按词条做三方合并，保留双方的中英文翻译与注释；首次合并为 712 个词条。程序逐项核验两个合并父分支的词条和值全部保留，生成资源检查通过。
- `docs/releases/NEXT.md`：同时保留新引导和官网 TestFlight 两条记录。
- `SessionModel.swift` 自动合并后逐项复核：保留 #23 的静音监测调用、五秒热窗口、`startAudioEngine()` 和 `microphoneTestCapture()`。只在共用 `updateAudioStandby()` 入口增加练习早返回，避免练习的 phase 变化开启采集监测；正式录音、自检的实现不变。

相对基础分支，`AudioCapture.swift`、`AudioCaptureController.swift`、`MicrophoneTestView.swift`、`PairingSheet.swift` 字节一致；`startAudioEngine()` 与 `microphoneTestCapture()` 函数也逐字一致。#24 的官网文件和两份 README 与基础分支字节一致。协议未改动。

## 隔离与 UI 回归

练习 begin / end / sendInput 仍在真实采集和链路处理之前转入本地数据源。保留暂停发现/连接、发送锁与前后台隔离，并在审计结果中新增 `captureStarts`，统计 #23 的采集启动请求及静音重试日志。UI 测试要求该值为 0，同时检查网络发送为 0、麦克风/语音权限仍未决定。

新增 `MicrophoneEntryMergeUITests` 验证主页 MIC TEST 弹层、设置入口和第一次真实输入失败时的错误入口，检查拒绝权限后的提示、复制与关闭。测试不自动批准麦克风权限。

首次并行运行两个模拟器时，出现一次下拉未推进、一次点击稍后连接后页面仍未关闭的失败；不能确定具体系统原因。改为串行执行，并给连接页测试增加“页脚位置稳定后再点击”和“连接页已关闭”的断言。没有修改手势阈值或用测试参数替代动作。最终结果及日志见 [merge-test-results.txt](merge-test-results.txt)。

## 专用模拟器

- iPhone 17 Pro / iOS 27.0：`8908A9CF-6553-4663-90E4-4094E12FBF8D`
- iPhone SE 3 / iOS 27.0：`4ADD3176-F849-4ABD-B510-90DA40445F2F`

仅使用本次创建的设备，全部 iOS 构建均为 Simulator，禁用签名；没有真机构建。验证完毕后两台设备均已关闭、删除，并检查设备清单确认两个 UDID 均不存在。

## 最终结果

| 检查 | 结果 |
| --- | --- |
| `swift test` | 74 tests / 0 failures |
| `./scripts/build-ios.sh` | Debug Simulator 通过 |
| `python3 tools/check-l10n.py` | 最终 720 个双语词条、生成资源及文字检查通过 |
| `./scripts/test-ios-mac-selection.sh` | 全部通过 |
| `IMIC_RESUME_TEST_PORT=48625 ./scripts/test-ios-reconnect.sh` | 全部通过，独立测试端口 |
| `./scripts/test-ios-audio.sh` | 48 项采集控制器断言通过 |
| Debug UI（串行） | 4 tests / 0 failures：原 3 项引导测试与新增 MIC TEST 合并回归 |
| Release Simulator 构建及 ShippingPracticeUITests | 构建通过，1 test / 0 failures，未使用调试参数 |
| 练习隔离 | `link=0 send=0 mic=undetermined speech=undetermined captureStarts=0` |
| 专用模拟器 | 两台均已删除 |

验证期间基础分支先增加仅含任务书的 `c817e36`，随后又合入 `c6118cb`（PR #26：Mac Key 输入修复）。本地共享远端引用在同步前已更新，因此第二次合并 `50c44ae` 实际包含 #26；其提交标题“无代码变更”不准确，在此更正，不改写已发布历史。

与已验证的 `1af2f19` 比较，#26 没有改变 iOS / shared 执行代码、UI 测试或项目配置，仅为 iOS 共用 catalog 追加 8 个 Mac 文案；Mac 端改动完整继承基础分支。最终在 `50c44ae` 上重新运行指定检查及 UI 测试，详细输出见 `merge-test-results.txt`。

最终基线复核另新建 iPhone 17 Pro / iOS 27.0：`D85F3E2E-572E-42FA-A3F8-5BE210679337`，只在该专用设备上串行执行最后一轮 UI 测试，已关闭、删除并复核清单无残留。
