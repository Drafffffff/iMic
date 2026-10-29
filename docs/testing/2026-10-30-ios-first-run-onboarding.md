# iOS 首次引导全量验证报告

iPhone 首次打开先解释双端用法，再引导把 Mac 下载页送到电脑；搜索延后到用户确认，并提供不录音、不发送的真实手势练习。

## 改动

- `shared/OnboardingPolicy.swift`：纯函数按完成版本、进行中步骤、已有配对依次决策，进行中的引导始终恢复。
- `tests/iMicLinkTests/OnboardingPolicyTests.swift`：覆盖新装、已完成、老用户、旧版本以及全部步骤恢复。
- `ios/iMic/Onboarding/OnboardingCoordinator.swift`：初始化门控、步骤持久化、练习返回路径和 DEBUG 重置 / 预览路由。额外的本地布尔键 `imic.onboarding.practiceReturnsToMac` 只保存练习入口来源，离开练习 / 完成时清理，DEBUG 重置一并清除，避免已配对时恢复练习后错误进入 READY。
- `ios/iMic/Onboarding/OnboardingLinks.swift`：集中保存主页和 Mac 下载页地址。
- `ios/iMic/Onboarding/OnboardingView.swift`：六步引导、接力 / 共享 / 复制、拒绝权限和超时排查、配对复用、READY 及设置教程入口。
- `ios/iMic/Onboarding/PracticeSession.swift`：独立的本地练习命令接收端，复用真实横条、弦弹簧、频谱、触感和音效，合成波形与模拟输入框支持五张卡片。
- `ios/iMic/Onboarding/OnboardingAudit.swift`：仅 DEBUG 的 UI 测试探针，核对本次日志、系统授权状态、教程版本及复制结果。
- `ios/iMic/iMicApp.swift`：在 HomeView 出现之前同步创建门控对象，引导与主页分开构建，初次引导不初始化主页图形 / 录音控件。
- `ios/iMic/HomeView.swift`：稍后连接后的继续设置入口，以及避免引导期间重复弹配对 sheet；顶部连接按钮保持不动。
- `ios/iMic/LinkClient.swift`：统一推迟 start / activate、发布 PolicyDenied 状态、练习期间在公开发送入口和最终帧边界丢弃发送请求。
- `ios/iMic/SessionModel.swift`：前台激活不请求录音权限，首次真实按住才请求麦克风与语音识别。
- `ios/iMic/SpeechPreview.swift`：更新授权入口注释。
- `ios/iMic/PairingSheet.swift`：新增 GUIDE，并避免教程显示时因连接成功关闭整个设置页。
- `tests/iOSUI/OnboardingUITests.swift`：七个 UI 用例、真实五步手势、日志 / 权限 / 剪贴板断言以及 keepAlways 截图。
- `README.md`：说明 iPhone 首次使用、双端要求、下载方式与权限时机。
- `docs/TESTFLIGHT-QUICKSTART.md`：安装与配对流程对齐六步引导。
- `docs/PRIVACY.md`：说明接力、系统剪贴板、公开下载地址及本地练习的数据边界。
- `docs/releases/NEXT.md`：记录 iPhone 改动。
- `docs/testing/2026-10-30-ios-first-run-onboarding.md`：保存本次全量测试报告。

## 规格对照

- 3.1 门控：纯函数优先恢复进行中步骤，`hasPairedMac || !pairedMacIDs.isEmpty` 覆盖任意已记住且有令牌的 Mac；已配对且未开始的老用户标记完成并直接进主页。
- 3.2 推迟搜索：`startDeferred` 在构造主页前设置，`LinkClient.start()` 和 `activate()` 共用同一个门控；根视图仅构建引导或主页之一；引导直接复用 activate / enterBackground 恢复搜索，无需重构连接生命周期。LINK 点击开始后放行，恢复 LINK / PAIR 时重新搜索。离线练习后切到后台再返回仍没有连接记录。
- ① WELCOME：复用 TorusView / SpectrumStore 的安静波形与减弱动态效果支持；三条卖点和开始按钮。
- ② MAC：说明 macOS 13+、自己的百炼 Key 与费用；内置 BrowsingWeb 活动仅在本页可见时 current，离页 invalidate；系统共享和主动复制均已 UI 验证。Info.plist 未新增 NSUserActivityTypes 或 entitlement，没有 DMG 直链或二维码。
- ③ LINK：明确授权说明和像素示意；仅按钮启动搜索；观察 NWBrowser waiting / failed 的 DNS -65570，拒绝时提示并打开设置；返回后 retry。8 秒无发现展开六条排查，仍保持搜索。
- ④ PAIR：单台发起现有连接；多台使用 PairingSheet 内既有选择列表与 connect(to:)；六位码、错误和锁定提示全部复用。ready 后 pairingSuccess，等待一秒，再按教程完成状态进入练习或 READY。
- ⑤ PRACTICE：独立 PracticeSession 不持有 AudioCapture / SpeechPreview / 发送能力；动作只作用于假输入框。LinkClient 另有带锁发送防线，日志格式为 `iphone.practice blocked send kind=…`。五张卡片可完成、可跳过，EDIT 分别显示删除与移动勾选；Mac 关闭的手势仍显示并可跳过。完成即记录教程版本；另有 UI 用例验证 MAC → 练习 → 杀进程 → 恢复 → 完成后回 MAC。
- ⑥ READY：提示 Mac 输入框、麦克风必需 / 语音识别可拒绝；完成时写版本、删步骤并关闭引导；提供主页帮助链接。
- 5 设置入口：GUIDE 可独立重新练习或获取 Mac 版，不重开完整引导、不更改首次引导完成版本。
- 7 无障碍：像素标题外补语义标题（PixelText 默认隐藏于无障碍树）；说明采用动态字体；每张卡有旁白下的「标记为已了解」；示意动画有动作标签，减弱动态效果时为静帧箭头。
- 8 预览：14 个 onboarding 状态全部截图；所有 CLI 预览、重置及审计探针均在 DEBUG 下。Release 扫描确认无 `--ui-preview=` / `--debug-` 入口。
- 手势文案与代码核对：横条上滑取消 `< -64pt`；练习 HOLD 判定 `>=0.6s`；弦沿用 StringMotionStore 的弹簧 / 回车 / 重复删除识别，向下松手后回到中线才回车；水平每 30pt 一步，方向判别横向超过纵向的 1.35 倍；清空为上滑超过 80pt 且触点进入屏幕顶部 84pt。文案改为「向上拉弦删除」，兼容松手单删和停留连续删。未复制 HoldControl / Spectrum 渲染代码。
- 偏离之处及原因：现有 activateAudio 实际会在主页出现时请求权限，与任务书的现状描述不一致；本次将授权收敛到真实按住。引导内容可滚动，但练习触摸期间暂停滚动，弦手势优先，避免滚动容器抢走真实动作。引导直接作为根视图显示，避免初始化主页控件；HomeView 保留最小的继续设置入口。没有修改 Mac、协议、密钥派生、配对码规则、版本或仓库设置。
- 冲突：提交前 fetch / rebase 到基线 `61565d8`，无冲突；未改 DeviceSelectionView 或 HomeView 顶部连接按钮。

## 权限弹窗时机

| 权限 | 触发时机 | 验证方式 |
|---|---|---|
| 本地网络 | ③ 点「开始寻找 Mac」；恢复 LINK / PAIR 重新搜索 | start / activate 统一门控；全新安装 → 离线五卡 → 后台再返回，日志连接 0；实际系统允许 / 拒绝恢复仍需真机 |
| 蓝牙 | 全新未配对引导不触发 | 检查 startBLELocked：候选令牌列表为空时在创建 BLELinkClient 前返回；离线练习没有连接日志；已有配对恢复后的兜底仍沿用原逻辑 |
| 麦克风 / 语音识别 | 第一次真实按住 | activateAudio 不发起授权；练习 UI 测试读取系统状态均为 undetermined，并断言没有系统弹窗 |

NWBrowser 拒绝检测参照 [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。接力使用系统 [NSUserActivityTypeBrowsingWeb](https://developer.apple.com/documentation/foundation/nsuseractivitytypebrowsingweb)；真机跨设备接力未在模拟器中声称通过。

## 全量测试报告

环境：Xcode / DEVELOPER_DIR=`/Applications/Xcode.app/Contents/Developer`；iPhone 17 Pro / iOS 27.0；本次专用模拟器 `iMic Onboarding QA` / `D83438C2-11EF-45D9-81AE-FCAC35AC93C2`。所有运行与截图均仅用该 UDID，并关闭 Xcode 并行测试以免克隆设备。结束后已删除该模拟器，记录见 `build/onboarding-report/simulator-cleanup.json`。

源码实现提交：`33fd248`，测试隔离修正：`8305d38`，练习返回路径持久化：`ed27461`，基线 `61565d8`。最终整套 UI 与归档均覆盖返回路径修正及根视图隔离（`8af19a0`）。以下耗时为完整命令墙钟时间（含编译）。

| 命令 | 结果 | 耗时 | 关键输出 / 备注 |
|---|---|---:|---|
| `swift test` | 通过 | 174.9s | 69 项通过，含 5 个门控测试（遍历全部步骤与配对状态）；日志 `build/onboarding-report/01.log` |
| `./scripts/test-ios-mac-selection.sh` | 通过 | 230.3s | 全部自动选择集成检查通过；日志 `build/onboarding-report/02.log` |
| `./scripts/test-ios-reconnect.sh` | 通过 | 40.3s | 前台恢复、失效连接、缓存录音与退避绕过通过；首次编译因保存文件失效，稳定代码重跑通过；日志 `build/onboarding-report/03-retry.log` |
| `./scripts/test-polish-link.sh` | 通过 | 34.4s | 真实加密链路验证模式 / 语气 / 语言与旧 Mac 兼容性；日志 `build/onboarding-report/04.log` |
| `./scripts/test-screen-idle.sh` | 通过 | 5.6s | App 内休眠、首次触摸唤醒及生命周期检查通过；日志 `build/onboarding-report/05.log` |
| `./scripts/test-polish-effect.sh` | 通过 | 33.6s | 56 项通过；日志 `build/onboarding-report/06.log` |
| `./scripts/test-polish.sh` | 通过 | 6.4s | 17 项通过；日志 `build/onboarding-report/07.log` |
| `./scripts/test-mac-settings.sh` | 通过 | 58.9s | 五个设置分区、Key 校验、关闭草稿与同步通过；日志 `build/onboarding-report/08.log` |
| `./scripts/test-input.sh` | 通过 | 6.6s | 21 项通过；日志 `build/onboarding-report/09.log` |
| `./scripts/test-clear-input.sh` | 通过 | 8.3s | direct / ignored-value / readonly 三种清空集成通过；日志 `build/onboarding-report/10.log` |
| `./scripts/build-mac.sh` | 通过 | 105.0s | 仅构建 build/mac.noindex/iMic.app，未安装到 /Applications；日志 `build/onboarding-report/11.log` |
| `IMIC_SIM_NAME=D83438C2-11EF-45D9-81AE-FCAC35AC93C2 IMIC_SIM_DESTINATION='platform=iOS Simulator,id=D83438C2-11EF-45D9-81AE-FCAC35AC93C2' ./scripts/build-ios.sh` | 通过 | 11.9s | BUILD SUCCEEDED；日志 `build/onboarding-report/12.log` |
| `xcodebuild test -project ios/iMic.xcodeproj -scheme iMic -destination 'platform=iOS Simulator,id=D83438C2-11EF-45D9-81AE-FCAC35AC93C2' -parallel-testing-enabled NO -derivedDataPath build/ios-uitest.noindex -resultBundlePath build/ios-uitest.noindex/onboarding.xcresult` | 失败（如实保留） | 336.8s | 首轮 11/13：新增引导 6/6；显示设置基线失败；润色设置一次不稳定失败，单独重跑通过；日志 `build/onboarding-report/13.log` |
| `IMIC_TESTFLIGHT_DIR=build/testflight-onboarding.noindex ./scripts/testflight.sh archive-unsigned` | 通过 | 27.9s | ARCHIVE SUCCEEDED；未签名、不上传；版本 1.4.4 / build 3；日志 `build/onboarding-report/root-archive-unsigned.log` |
| `IMIC_TESTFLIGHT_DIR=build/testflight-onboarding.noindex ./scripts/testflight.sh check` | 通过 | 0.1s | privacyManifest=passed；releaseDebugEntrypoints=absent；platform=IOS；日志 `build/onboarding-report/root-check.log` |
| `xcodebuild test -project ios/iMic.xcodeproj -scheme iMic -destination 'platform=iOS Simulator,id=D83438C2-11EF-45D9-81AE-FCAC35AC93C2' -parallel-testing-enabled NO -collect-test-diagnostics never -derivedDataPath build/ios-uitest.noindex -resultBundlePath build/ios-uitest.noindex/onboarding-root.xcresult` | 最终 13/14，仅既有失败 | 310.1s | 新增 7/7；`DisplayUITests/testNativeSettingsAndDisplayModes` 基线复现；日志 `build/onboarding-report/ui-root.log` |

### UI 复核与既有失败

- 完整 UI 最终运行：13/14 通过、1 失败，310.1s，退出码 65；`build/ios-uitest.noindex/onboarding-root.xcresult`。附加 `-collect-test-diagnostics never` 只关闭失败后的冗长诊断收集，不改变测试或断言。
- 新增 OnboardingUITests 七项在完整套件中通过，包括 0.8 秒按住、上滑取消、snap return、删除加光标移动、顶部清空；返回 MAC 后切后台再返回，审计断言精确为 `link=0 send=0 mic=undetermined speech=undetermined tutorial=1`。
- `DisplayUITests/testNativeSettingsAndDisplayModes`：荧光 CRT 按钮 isHittable 断言失败。用 `git archive 61565d8` 导出的未改动源码，在同一专用模拟器复现相同文件 / 行 / 断言，标为既有失败。没有修改其测试或顺手修复。
- `PolishUITests/testModeToneLanguagePersistAndTerminalKeepsInactiveChoices`：前两轮完整套件找不到「日文」。基线通过，当前同一源码单独重跑也通过（37.3s），不将它冒称为已确认的既有失败。移除新增超时用例在断言后的非必要系统设置跳转，避免污染后续用例，原断言不变；此后完整 13 项与最终 14 项运行的两项润色测试均通过。保留原始失败记录。
- 任务书列出的 `DisplayUITests/testRecordingTouchPassesThroughMetalAndResultRemainsUsable` 历史失败：本次各轮均通过，断言未修改；最终结果见下列测试清单。
- 基线复核：`build/baseline-onboarding.noindex/settings-comparison.xcresult`，两个用例一个失败一个通过；命令与耗时在 `build/onboarding-report/baseline-comparison.json`，原始日志 `baseline-comparison.log`。基线构建 22.5s；早先一次 Xcode 在测试结束后卡住诊断收集，停止后用 `-collect-test-diagnostics never` 得到完整结果。
- 开发中首次重连编译因 LinkClient 保存而失效（117.3s），稳定代码重跑通过（40.3s）；初期 UI 编译与标题无障碍问题、滚动抢走取消手势的问题均已修正，最新完整结果使用最终实现。未放宽已有录音触摸断言。

最终全套逐项结果：

- Test Case '-[iMicUITests.DisplayUITests testDeviceNavigationReturnsToLiveDisplay]' passed (13.370 seconds).
- Test Case '-[iMicUITests.DisplayUITests testIdleScreenRestoresOnFirstRecordingHold]' passed (78.934 seconds).
- Test Case '-[iMicUITests.DisplayUITests testNativeSettingsAndDisplayModes]' failed (16.666 seconds).
- Test Case '-[iMicUITests.DisplayUITests testRecordingTouchPassesThroughMetalAndResultRemainsUsable]' passed (21.104 seconds).
- Test Case '-[iMicUITests.DisplayUITests testUpwardDragToTopClearsCurrentInput]' passed (12.400 seconds).
- Test Case '-[iMicUITests.OnboardingUITests testDeniedNetworkExplainsSettings]' passed (6.687 seconds).
- Test Case '-[iMicUITests.OnboardingUITests testDownloadSharingAndClipboard]' passed (18.589 seconds).
- Test Case '-[iMicUITests.OnboardingUITests testExistingPairedPreviewSkipsOnboarding]' passed (6.946 seconds).
- Test Case '-[iMicUITests.OnboardingUITests testOfflinePracticeRecognizesAllGesturesWithoutPermissionsOrTransport]' passed (38.406 seconds).
- Test Case '-[iMicUITests.OnboardingUITests testPracticeFromMacRestoresItsReturnDestination]' passed (25.916 seconds).
- Test Case '-[iMicUITests.OnboardingUITests testRestoresMacStepAfterRelaunch]' passed (14.558 seconds).
- Test Case '-[iMicUITests.OnboardingUITests testTimeoutKeepsTroubleshootingVisible]' passed (6.684 seconds).
- Test Case '-[iMicUITests.PolishUITests testModeToneLanguagePersistAndTerminalKeepsInactiveChoices]' passed (23.959 seconds).
- Test Case '-[iMicUITests.PolishUITests testUnconfirmedSaveRestoresMacSelection]' passed (8.697 seconds).

首次重连编译失效的最后 20 行（已重跑通过）：

```text

/Users/drafff/.codex/worktrees/ios-first-run-onboarding/iMic/ios/iMic/LinkClient.swift:1452:28: warning: capture of 'self' with non-Sendable type 'LinkClient' in a '@Sendable' closure [#SendableClosureCaptures]
  41 | /// iPhone 侧链路：Bonjour 发现 → Curve25519 握手 → 六位配对码 → 令牌会话。
  42 | /// 所有网络状态在私有串行队列，`@Published` 只在主线程更新。
  43 | final class LinkClient: ObservableObject {
     |             `- note: class 'LinkClient' does not conform to the 'Sendable' protocol
  44 |     enum Phase: Equatable {
  45 |         case idle
     :
1450 |         #endif
1451 |         queue.async {
1452 |             guard epoch == self.currentEpoch(), self.ready, self.supportsPolishPreferences else {
     |                            `- warning: capture of 'self' with non-Sendable type 'LinkClient' in a '@Sendable' closure [#SendableClosureCaptures]
1453 |                 self.publish {
1454 |                     self.polishPreferencesSaving = false

[#ImplicitStrongCapture]: <https://docs.swift.org/compiler/documentation/diagnostics/implicit-strong-capture>
[#SendableClosureCaptures]: <https://docs.swift.org/compiler/documentation/diagnostics/sendable-closure-captures>
error: input file '/Users/drafff/.codex/worktrees/ios-first-run-onboarding/iMic/ios/iMic/LinkClient.swift' was modified during the build
error: input file '/Users/drafff/.codex/worktrees/ios-first-run-onboarding/iMic/ios/iMic/LinkClient.swift' was modified during the build
```

失败命令最后 20 行（首轮全套）：

```text
2026-10-30 03:31:22.809 xcodebuild[74765:59555525] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 03:31:22.810 xcodebuild[74765:59555525] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 03:31:22.811 xcodebuild[74765:59555525] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 03:31:22.830 xcodebuild[74765:59555525] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 03:31:22.831 xcodebuild[74765:59555525] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 03:31:22.834 xcodebuild[74765:59555525] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 03:31:35.684 xcodebuild[74765:59555525] [MT] IDETestOperationsObserverDebug: 331.248 elapsed -- Testing started completed.
2026-10-30 03:31:35.685 xcodebuild[74765:59555525] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start
2026-10-30 03:31:35.685 xcodebuild[74765:59555525] [MT] IDETestOperationsObserverDebug: 331.248 sec, +331.248 sec -- end

Test session results, code coverage, and logs:
	/Users/drafff/.codex/worktrees/ios-first-run-onboarding/iMic/build/ios-uitest.noindex/onboarding.xcresult

Failing tests:
	DisplayUITests.testNativeSettingsAndDisplayModes()
	PolishUITests.testModeToneLanguagePersistAndTerminalKeepsInactiveChoices()

** TEST FAILED **

Testing started
```

最终全套最后 20 行：

```text
	 Executed 14 tests, with 1 failure (0 unexpected) in 292.915 (292.953) seconds
2026-10-30 04:02:23.079 xcodebuild[85279:59645964] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 04:02:23.079 xcodebuild[85279:59645964] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 04:02:23.080 xcodebuild[85279:59645964] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 04:02:23.099 xcodebuild[85279:59645964] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 04:02:23.100 xcodebuild[85279:59645964] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 04:02:23.103 xcodebuild[85279:59645964] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 04:02:23.421 xcodebuild[85279:59645964] [MT] IDETestOperationsObserverDebug: 302.891 elapsed -- Testing started completed.
2026-10-30 04:02:23.421 xcodebuild[85279:59645964] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start
2026-10-30 04:02:23.421 xcodebuild[85279:59645964] [MT] IDETestOperationsObserverDebug: 302.891 sec, +302.891 sec -- end

Test session results, code coverage, and logs:
	/Users/drafff/.codex/worktrees/ios-first-run-onboarding/iMic/build/ios-uitest.noindex/onboarding-root.xcresult

Failing tests:
	DisplayUITests.testNativeSettingsAndDisplayModes()

** TEST FAILED **

Testing started
```

## UI 测试与截图

- 首轮全套 xcresult：`build/ios-uitest.noindex/onboarding.xcresult`。
- 最终全套 xcresult：`build/ios-uitest.noindex/onboarding-root.xcresult`。
- 首次真实五卡独立验证：`build/ios-uitest.noindex/onboarding-focus-4.xcresult`。
- 每个新增 UI 用例均添加截图附件，`lifetime = .keepAlways`。本地构建、xcresult 和截图保留在工作区 build 下，按要求不提交到 Git。
- 截图由 simctl 原样生成，未修改像素；使用原始 PNG 的 OCR 再核对标题和说明。预览通道会省略重复区域，早期曾误判为缺字，原始文件经核对完整，没有将此误判当成 App 缺陷。
- 以下 14 张截图位于 `build/ux-shots/onboarding/`；均由本次专用模拟器取得并逐张检查。

| 截图 | 说明 |
|---|---|
| `onboarding-welcome.png` | 产品说明、真实安静波形、三条卖点与开始 |
| `onboarding-mac.png` | 双端说明、已安装 / 下载展开 / 先练习入口 |
| `onboarding-mac-download.png` | 接力说明、共享 / 复制、Mac 安装三步与费用提示 |
| `onboarding-link.png` | 本地网络解释、像素权限示意与开始寻找 |
| `onboarding-link-denied.png` | LOCAL NETWORK OFF、去设置恢复权限 |
| `onboarding-search-timeout.png` | 仍在寻找及六条网络排查清单 |
| `onboarding-pair.png` | 复用六位配对码输入与键盘 |
| `onboarding-practice-1.png` | HOLD、假输入框、真实横条 |
| `onboarding-practice-2.png` | CANCEL、上滑示意与取消练习 |
| `onboarding-practice-3.png` | RETURN、向下拉弦与回车反馈 |
| `onboarding-practice-4.png` | EDIT、删除与光标两项勾选 |
| `onboarding-practice-5.png` | CLEAR、向顶部清空 |
| `onboarding-practice-complete.png` | 完成页和本地练习隔离说明 |
| `onboarding-ready.png` | 第一次真实使用和权限说明 |

## 需要用户真机手测

- 接力：同一 Apple ID 的 Mac 程序坞是否出现 Safari 图标；通用剪贴板是否把复制链接送到 Mac。
- 本地网络拒绝 → 去设置打开 → 返回后自动找到 Mac；访客 Wi-Fi 下 8 秒排查清单。
- 真正输入六位码、错误码和锁定提示、配对后进入 READY，再在 Mac 输入框真实录音。
- 真实麦克风与语音识别授权提示次序，以及拒绝语音识别仍能走 Mac 最终识别。
- VoiceOver 的「标记为已了解」、大号动态字体和减弱动态效果；模拟器不代表真实触感 / 蓝牙 / 跨设备接力。

执行：Codex。提交供 Claude 审核，不合并、不启用自动合并、不修改仓库设置、不发 Release、不覆盖 /Applications/iMic.app。
