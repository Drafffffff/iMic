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
- `ios/iMic/LinkClient.swift`：统一推迟 start / activate、发布 PolicyDenied 状态、练习期间在七个公开用户内容入口丢弃发送请求；握手、心跳和能力协商继续放行。
- `ios/iMic/SessionModel.swift`：前台激活不请求录音权限，READY 依次等待麦克风、语音识别授权，拒绝麦克风保留 micDenied；老用户按住只兜底麦克风，真实录音松手后再兜底语音识别。
- `ios/iMic/SpeechPreview.swift`：可等待的语音识别授权入口，合并并发请求。
- `ios/iMic/PairingSheet.swift`：新增 GUIDE，并避免教程显示时因连接成功关闭整个设置页。
- `tests/LinkResume/main.swift`：新增 `--practice` 回归模式，生产链路连续保活 45 秒、七类内容拦截、前台探测、重新认证及退出练习后恢复内容发送。
- `tests/iOSUI/OnboardingUITests.swift`：八个 UI 用例、真实五步手势、日志 / 权限 / 剪贴板断言以及 keepAlways 截图。
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
- 偏离之处及原因：按本次审核要求覆盖原任务书的权限时机：READY 串行请求两项权限；跳过引导的老用户真实按住仅兜底麦克风，语音识别延后到松手。引导内容可滚动，但练习触摸期间暂停滚动，弦手势优先，避免滚动容器抢走真实动作。引导直接作为根视图显示，避免初始化主页控件；HomeView 保留最小的继续设置入口。没有修改 Mac、协议、密钥派生、配对码规则、版本或仓库设置。
- 冲突：提交前 fetch / rebase 到基线 `61565d8`，无冲突；未改 DeviceSelectionView 或 HomeView 顶部连接按钮。

## 权限弹窗时机

| 权限 | 触发时机 | 验证方式 |
|---|---|---|
| 本地网络 | ③ 点「开始寻找 Mac」；恢复 LINK / PAIR 重新搜索 | start / activate 统一门控；全新安装 → 离线五卡 → 后台再返回，日志连接 0；实际系统允许 / 拒绝恢复仍需真机 |
| 蓝牙 | 全新未配对引导不触发 | 检查 startBLELocked：候选令牌列表为空时在创建 BLELinkClient 前返回；离线练习没有连接日志；已有配对恢复后的兜底仍沿用原逻辑 |
| 麦克风 / 语音识别 | READY「开始使用」先等待麦克风，再请求语音识别；老用户按住只兜底麦克风，录音结束后才请求未决定的语音识别 | 真实系统弹窗 UI 用例验证顺序与全部拒绝后进入主页；离线练习审计保持两项 undetermined |

NWBrowser 拒绝检测参照 [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。接力使用系统 [NSUserActivityTypeBrowsingWeb](https://developer.apple.com/documentation/foundation/nsuseractivitytypebrowsingweb)；真机跨设备接力未在模拟器中声称通过。

## 审核意见处理

1. **练习拦截范围（已修复）**：移除 `sendFrame` 的 `permitsSend`；七个用户内容/意图入口保留统一带锁拦截，日志保持 `iphone.practice blocked send kind=…`。hello/auth/pair、ping/pong、能力协商继续使用原来的明文握手或 AES-GCM 加密控制链路。新增 `iphone.content send kind=…` 元数据，UI 审计仅统计内容发送，不把协议控制帧计入 `send=0`。
   - 验证：`./scripts/test-ios-reconnect.sh --practice` 使用生产 LinkClient + 未修改的 headless LinkServer、真实本地 TCP、原协议/加密/配对规则；初始配对时练习已开启，已连接后重新进入练习；保持 45 秒跨过 40 秒门槛，收到至少 4 次加密 pong，连接保持原条，ready 未重复、loss=0、Mac 收到内容=0。之后在练习中前台 ping/pong，黑洞旧连接并完成新 hello/auth；无 timeout，七类 blocked-send 日志齐全、内容审计=0；退出练习后真实 audio.start 可送达。
2. **首次权限顺序（已修复）**：READY「开始使用」先 await 麦克风授权，再 await Speech 授权，完成后才写完成版本并进入主页；按钮在请求中禁用，避免重复请求。拒绝麦克风保存 `micDenied`，继续沿用主页 `ENABLE MIC`。按下路径移除 Speech 请求，只保留麦克风兜底；真实录音结束后才对 notDetermined 的 Speech 发起兜底，预览/练习不会触发该路径。README、快速开始、NEXT 和 READY 文案同步更新。
   - 验证：新增 `testReadyRequestsPermissionsInOrderAndCompletesWhenDenied` 通过，观察并截图真实系统麦克风弹窗，拒绝后才出现真实 Speech 弹窗；再次拒绝后主页出现，`ENABLE MIC` 可见且无残留弹窗。离线真实五卡手势用例通过，审计精确保持 `link=0 send=0 mic=undetermined speech=undetermined tutorial=1`。允许/拒绝结果均不阻断完成逻辑；真机识别与老用户真实录音兜底仍列入手测范围。
3. **截图与范围（已处理）**：14 个状态重新截图，均使用 `simctl status_bar <专用 UDID> override --time 9:41 ...`；原始 PNG 状态栏为 09:41。没有修改协议文件、Mac 代码、心跳参数、版本、GitHub 设置或既有显示测试；没有合并或开启自动合并。

## 全量测试报告

2026-10-30 审核修复后重新执行任务书 10.4 全部 15 条命令，以下均为本轮结果，顺序执行。源码提交 `f3f1063`，base `61565d8`；fetch/rebase 无冲突。DEVELOPER_DIR=`/Applications/Xcode.app/Contents/Developer`。

只使用本轮新建的 `iMic Onboarding Review QA` / iPhone 17 Pro / iOS 27.0，UDID `7245BC9F-4DF0-47D2-9C59-101F1715CCDC`；未进入或修改主仓库。首轮定向权限测试后仅擦除这台专用设备以恢复首次授权，再执行完整 UI。Xcode 关闭并行测试，避免克隆模拟器；`-collect-test-diagnostics never` 只关闭失败后的冗长诊断收集。结束后已删除该模拟器，证据 `build/onboarding-review-report/simulator-cleanup.json`。

| 命令 | 结果 | 耗时 | 关键输出 / 日志 |
|---|---|---:|---|
| `swift test` | 通过 | 5.4s | 69 项通过，含 5 个门控测试（遍历步骤/配对状态）；`build/onboarding-review-report/01.log` |
| `./scripts/test-ios-mac-selection.sh` | 通过 | 44.8s | 自动 Mac 选择全部集成检查通过；`build/onboarding-review-report/02.log` |
| `./scripts/test-ios-reconnect.sh` | 通过 | 24.9s | 健康探测、失效连接替换、录音缓存与退避绕过通过；`build/onboarding-review-report/03.log` |
| `./scripts/test-polish-link.sh` | 通过 | 16.2s | 真实加密链路模式/语气/语言保存、广播非 ACK、旧 Mac 兼容通过；`build/onboarding-review-report/04.log` |
| `./scripts/test-screen-idle.sh` | 通过 | 4.6s | App 内休眠、首次触摸唤醒、忙碌保护与生命周期通过；`build/onboarding-review-report/05.log` |
| `./scripts/test-polish-effect.sh` | 通过 | 12.8s | 56 项通过；`build/onboarding-review-report/06.log` |
| `./scripts/test-polish.sh` | 通过 | 2.7s | 17 项通过；`build/onboarding-review-report/07.log` |
| `./scripts/test-mac-settings.sh` | 通过 | 20.8s | 五个设置分区、Key 校验、关闭草稿、手机/菜单同步通过；`build/onboarding-review-report/08.log` |
| `./scripts/test-input.sh` | 通过 | 2.4s | 21 项通过；`build/onboarding-review-report/09.log` |
| `./scripts/test-clear-input.sh` | 通过 | 2.9s | direct / ignored-value / readonly 三种清空集成通过；`build/onboarding-review-report/10.log` |
| `./scripts/build-mac.sh` | 通过 | 62.9s | 仅 build/mac.noindex/iMic.app，未安装到 /Applications；`build/onboarding-review-report/11.log` |
| `IMIC_SIM_NAME=7245BC9F-4DF0-47D2-9C59-101F1715CCDC IMIC_SIM_DESTINATION='platform=iOS Simulator,id=7245BC9F-4DF0-47D2-9C59-101F1715CCDC' ./scripts/build-ios.sh` | 通过 | 26.1s | BUILD SUCCEEDED，仅指定的专用模拟器；`build/onboarding-review-report/12.log` |
| `xcodebuild test -project ios/iMic.xcodeproj -scheme iMic -destination 'platform=iOS Simulator,id=7245BC9F-4DF0-47D2-9C59-101F1715CCDC' -parallel-testing-enabled NO -collect-test-diagnostics never -derivedDataPath build/ios-uitest.noindex -resultBundlePath build/ios-uitest.noindex/onboarding-review.xcresult` | 失败（退出 65，既有显示设置失败） | 402.9s | 见下方逐项 UI 结果；仅显示设置既有失败；`build/onboarding-review-report/13.log` |
| `IMIC_TESTFLIGHT_DIR=build/testflight-onboarding.noindex ./scripts/testflight.sh archive-unsigned` | 通过 | 28.3s | ARCHIVE SUCCEEDED；未签名、不上传；版本 1.4.4 / build 3；`build/onboarding-review-report/14.log` |
| `IMIC_TESTFLIGHT_DIR=build/testflight-onboarding.noindex ./scripts/testflight.sh check` | 通过 | 0.1s | privacyManifest=passed；releaseDebugEntrypoints=absent；platform=IOS；`build/onboarding-review-report/15.log` |
| `./scripts/test-ios-reconnect.sh --practice` | 通过 | 58.9s | 生产 10s/40s 心跳参数不变；45s 保活、加密 pong、练习中配对/重认证、七类内容拦截及退出后恢复发送通过；`build/onboarding-review-report/16.log` |

### UI 与既有失败

- 全套 14/15 通过；唯一失败为下述既有显示设置问题。全套 xcresult：`build/ios-uitest.noindex/onboarding-review.xcresult`；新增引导八项全部通过，包含实际系统权限顺序和 micDenied 主页提示。
- `DisplayUITests/testNativeSettingsAndDisplayModes` 的 CRT isHittable 断言保持原状，按审核要求继续标注为既有失败。上轮已用 `git archive 61565d8` 的未改动源码在专用模拟器复现；证据仍在 `build/baseline-onboarding.noindex/settings-comparison.xcresult` 与 `build/onboarding-report/baseline-comparison.log`。本轮不修复、不放宽断言。
- 任务书列出的录音触摸历史失败，本轮实际结果见下表，不将通过项写成失败。润色 UI 的两项断言保持原样。

```text
Test Case '-[iMicUITests.DisplayUITests testDeviceNavigationReturnsToLiveDisplay]' passed (27.199 seconds).
Test Case '-[iMicUITests.DisplayUITests testIdleScreenRestoresOnFirstRecordingHold]' passed (85.978 seconds).
Test Case '-[iMicUITests.DisplayUITests testNativeSettingsAndDisplayModes]' failed (20.712 seconds).
Test Case '-[iMicUITests.DisplayUITests testRecordingTouchPassesThroughMetalAndResultRemainsUsable]' passed (23.792 seconds).
Test Case '-[iMicUITests.DisplayUITests testUpwardDragToTopClearsCurrentInput]' passed (13.316 seconds).
Test Case '-[iMicUITests.OnboardingUITests testDeniedNetworkExplainsSettings]' passed (7.083 seconds).
Test Case '-[iMicUITests.OnboardingUITests testDownloadSharingAndClipboard]' passed (20.646 seconds).
Test Case '-[iMicUITests.OnboardingUITests testExistingPairedPreviewSkipsOnboarding]' passed (8.123 seconds).
Test Case '-[iMicUITests.OnboardingUITests testOfflinePracticeRecognizesAllGesturesWithoutPermissionsOrTransport]' passed (41.072 seconds).
Test Case '-[iMicUITests.OnboardingUITests testPracticeFromMacRestoresItsReturnDestination]' passed (28.264 seconds).
Test Case '-[iMicUITests.OnboardingUITests testReadyRequestsPermissionsInOrderAndCompletesWhenDenied]' passed (15.205 seconds).
Test Case '-[iMicUITests.OnboardingUITests testRestoresMacStepAfterRelaunch]' passed (19.623 seconds).
Test Case '-[iMicUITests.OnboardingUITests testTimeoutKeepsTroubleshootingVisible]' passed (9.671 seconds).
Test Case '-[iMicUITests.PolishUITests testModeToneLanguagePersistAndTerminalKeepsInactiveChoices]' passed (25.742 seconds).
Test Case '-[iMicUITests.PolishUITests testUnconfirmedSaveRestoresMacSelection]' passed (9.716 seconds).
```

失败命令 `xcodebuild test -project ios/iMic.xcodeproj -scheme iMic -destination 'platform=iOS Simulator,id=7245BC9F-4DF0-47D2-9C59-101F1715CCDC' -parallel-testing-enabled NO -collect-test-diagnostics never -derivedDataPath build/ios-uitest.noindex -resultBundlePath build/ios-uitest.noindex/onboarding-review.xcresult` 最后 20 行：

```text
	 Executed 15 tests, with 1 failure (0 unexpected) in 356.142 (356.229) seconds
2026-10-30 10:27:02.823 xcodebuild[60469:60381494] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 10:27:02.823 xcodebuild[60469:60381494] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 10:27:02.824 xcodebuild[60469:60381494] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 10:27:02.842 xcodebuild[60469:60381494] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 10:27:02.842 xcodebuild[60469:60381494] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 10:27:02.846 xcodebuild[60469:60381494] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
2026-10-30 10:27:03.328 xcodebuild[60469:60381494] [MT] IDETestOperationsObserverDebug: 384.853 elapsed -- Testing started completed.
2026-10-30 10:27:03.328 xcodebuild[60469:60381494] [MT] IDETestOperationsObserverDebug: 0.002 sec, +0.002 sec -- start
2026-10-30 10:27:03.328 xcodebuild[60469:60381494] [MT] IDETestOperationsObserverDebug: 384.853 sec, +384.851 sec -- end

Test session results, code coverage, and logs:
	/Users/drafff/.codex/worktrees/ios-first-run-onboarding/iMic/build/ios-uitest.noindex/onboarding-review.xcresult

Failing tests:
	DisplayUITests.testNativeSettingsAndDisplayModes()

** TEST FAILED **

Testing started
```

练习链路回归关键输出：

```text
PASS practice 47s; 4 encrypted pongs; same connection; content=0
PASS practice initial pair; foreground ping/pong; reconnect hello/auth; timeout=0; seven content guards; content resumes after exit
```

## UI 测试与截图

- 每个引导 UI 用例及两次系统权限弹窗均有 `XCTAttachment`，`lifetime = .keepAlways`；完整 xcresult 路径如上。
- 14 张截图位于 `build/ux-shots/onboarding/`，均为专用模拟器原始 PNG，状态栏统一 9:41；逐张 OCR 核对，记录在 `build/onboarding-review-report/screenshots-ocr.log`。
- build 产物、完整日志、xcresult 和截图按任务要求保留本地，不提交 Git。

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

- 同 Apple ID 的 Mac 接力图标、通用剪贴板与隔空投送。
- 本地网络拒绝 → 设置打开 → 返回自动发现，以及访客 Wi-Fi 下排查清单。
- 真实麦克风和 Mac 最终识别；拒绝 Speech 后仍走百炼最终识别；跳过引导的老用户首次按住仅请求麦克风，松手后才请求 Speech。
- VoiceOver「标记为已了解」、大号动态字体、减弱动态效果、真实触感与蓝牙兜底。

执行：Codex。提交供审核，不合并、不启用自动合并、不修改仓库设置、不发 Release、不覆盖 /Applications/iMic.app。
