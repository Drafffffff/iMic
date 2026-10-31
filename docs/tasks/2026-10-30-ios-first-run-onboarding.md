# 任务书：iOS 首次引导（引导下载 Mac 版 + 交互式功能教学）

日期：2026-10-30
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 在分支 `codex/ios-first-run-onboarding` 上工作，这个分支从 `codex/ui-phosphor-wireframe` 的最新提交创建。如果启动时你已经处在为此准备好的 worktree 和分支里，直接使用。**不要在 `codex/ui-phosphor-wireframe` 上直接提交。**
2. 提交说明用简体中文，可以分多次提交。
3. 推送：`git push -u origin codex/ios-first-run-onboarding`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**，不要选 `main`（`main` 停在 1.4.0）。
5. PR 描述必须附第 10 节规定的**全量测试报告**。没有报告的 PR 不予审核。
6. 由 Claude 审核。**不要自行合并**，不要开启自动合并。
7. 不改 `VERSION` 和版本号，不发 Release，不覆盖 `/Applications/iMic.app`。
8. 在 `docs/releases/NEXT.md` 的 iPhone 小节（没有就新建）记录本次改动。

### 并行任务与冲突

- `codex/ios-quick-mac-switch`（iOS 快速切换 Mac）正在进行，它会改 `HomeView.swift` 顶部的连接状态按钮和 `DeviceSelectionView.swift`。本任务尽量**不要改这两处**。引导界面写成独立的新文件，`HomeView` 里只加一个最小的入口（例如一个 `.fullScreenCover` 加门控）。
- 落地页任务 `codex/landing-page` 也在同时进行，它只改 `site/`、`.github/` 和 Mac 菜单，和本任务没有重叠。
- 提 PR 前先 `git fetch` 并 rebase 到最新的 `codex/ui-phosphor-wireframe`。有冲突时以对方已合并的代码为准，再把本任务的改动接上去，并在 PR 里说明解决冲突的方式。
- **模拟器**：另一个 Codex 任务可能同时在使用模拟器。请创建你自己的专用模拟器，例如 `xcrun simctl create "iMic Onboarding QA" "iPhone 17 Pro"`（机型名以 `xcrun simctl list devicetypes` 为准），所有测试和截图都只用它，结束后删除。**不要使用、关闭或擦除其他已启动的模拟器。**

---

## 1. 背景与目标

iMic 是"iPhone 当麦克风、松手把文字打进 Mac"的组合产品，必须**同时**装 Mac 端和 iPhone 端。用户往往先在 iPhone 上装好 App（TestFlight，将来是 App Store），这时：

1. App 一启动就搜索 Mac（`HomeView.swift` `.onAppear` 里调用 `link.start()`，约第 169 行），系统的"本地网络"权限弹窗会立刻出现。用户还不知道 iMic 是做什么的就要授权，很容易拒绝；拒绝后就再也找不到 Mac。
2. 没有任何地方告诉用户"还需要在 Mac 上装 iMic"，也没有下载方式。
3. 核心交互（按住说话、上滑取消、弦手势等）全靠用户自己摸索。

目标：
- 首次打开时，有一个**清晰、可中断、可恢复**的引导：解释产品 → 把 Mac 版下载链接送到用户的 Mac 上 → 在合适的时机请求权限 → 配对 → **交互式**练习核心手势。
- 不连 Mac 也能体验完整的交互（练习模式）。这也方便 App 审核：审核员通常没有 Mac。
- 已经在用的用户（已配对过 Mac）不受打扰。

## 2. 名词与常量

- 落地页地址（另一任务正在建设，先写死这个地址，上线前不影响开发）：
  - 主页：`https://drafffffff.github.io/iMic/`
  - 引导下载用：`https://drafffffff.github.io/iMic/?from=ios#download`
  - 放在一个常量里，例如 `ios/iMic/Onboarding/OnboardingLinks.swift` 中的 `enum OnboardingLinks`。
- 偏好键（`UserDefaults.standard`）：
  - `imic.onboarding.completedVersion`（Int，当前版本为 1）
  - `imic.onboarding.step`（Int，进行中的步骤；完成后删除）
  - `imic.tutorial.completedVersion`（Int，练习完成的版本）

## 3. 流程总览

```
冷启动
  └─ OnboardingPolicy.decide(...)
       ├─ skip                 → 正常主页（现有行为，link.start() 照常调用）
       ├─ skipAndMarkComplete  → 已有配对的老用户：标记完成，正常主页
       └─ show(step)           → 引导（全屏）；link.start() 推迟到第 ③ 步
             ① WELCOME
             ② MAC   ── 已安装 ─────────────┐
                    └─ 还没有 → 下载引导 → 继续 ┤
                    └─ 先看看怎么用 → ⑤（练习，结束后回到 ②）
             ③ LINK  本地网络说明 → 开始搜索（此时才触发系统弹窗）
             ④ PAIR  发现 Mac → 输入配对码（复用 PairingSheet）
             ⑤ PRACTICE 交互式练习 5 张（可跳过）
             ⑥ READY 第一次真实使用提示 → 完成
```

### 3.1 门控策略（纯函数，必须单测）

新建 `shared/OnboardingPolicy.swift`。纯逻辑放在 `shared/` 下才能被 `swift test` 覆盖；Mac 构建按显式文件列表编译，不会包含它，所以不必改 `build-mac.sh`。

```swift
public enum OnboardingStep: Int, CaseIterable { case welcome, mac, link, pair, practice, ready }

public enum OnboardingPolicy {
    public static let version = 1
    public enum Decision: Equatable { case skip, skipAndMarkComplete, show(OnboardingStep) }
    public static func decide(completedVersion: Int, savedStep: OnboardingStep?,
                              hasPairedMac: Bool) -> Decision
}
```

规则：
1. `completedVersion >= version` → `.skip`。
2. `savedStep != nil` → `.show(savedStep!)`。**进行中的引导一律恢复，哪怕此时已有配对**。这是吸取 Mac 设置向导的教训：Mac 向导曾因为重启后"看起来已完成"而被静默跳过。
3. `hasPairedMac` → `.skipAndMarkComplete`（老用户）。
4. 其余 → `.show(.welcome)`。

`hasPairedMac` 的判断：`LinkClient.pairedMacIDs` 非空，或者任意已记住的 Mac 在 `TokenStore` 里有令牌（`LinkClient` 初始化时已经算好了 `hasPairedMac` / `pairedMacIDs`）。

### 3.2 推迟搜索

- 引导显示期间，第 ③ 步之前**不得**调用 `link.start()`，也不得以任何方式触发本地网络或蓝牙权限弹窗。
- 实现方式：`HomeView` 的 `.onAppear` 先问门控；需要引导时，由引导在第 ③ 步调用 `link.start()`。注意 `SessionModel` 里有 `link.activate()`（约第 1204 行，回到前台时调用），`activate()` 在 `!running` 时会调用 `start()`。必须保证引导期间回到前台**不会**提前开始搜索：可以在 `LinkClient` 加一个 `startDeferred` 标志，或让 `SessionModel` 判断门控。请选最小改动，在 PR 中说明。
- **蓝牙**：`BLELinkClient` 只在有已配对 Mac 时才会启动（`startBLELocked` 要求候选列表非空），首次引导中不会弹出蓝牙权限。请验证并在报告中写明。
- 麦克风和语音识别权限：保持现状，在**第一次真实按住录音**时请求（`AudioCapture.swift:33`、`SpeechPreview.swift:47`）。⑥ 会提前说明。练习模式**不得**请求这两项权限。

## 4. 各步骤详细规格

界面风格遵循 AGENTS.md：标题和技术标签用英文像素字（复用 `PixelText`、`PixelFont`），说明文字用简体中文；墨黑底，橙色只用于状态、交互和强调，不铺大面积背景。复用 `DesignSystem.swift` 和 `Theme` 里的颜色、字体，不另起一套。每一页顶部用细的分段进度条表示 6 步，当前步骤为橙色。

### ① WELCOME

- 像素标题 `iMic`，副标题："iPhone 当麦克风，说完松手，文字直接打进 Mac。"
- 动效：用主页真实的荧光波形组件做一段安静的循环（复用 `PhosphorDisplay` / `ReceiverFlow` 的 preview 能力，不要录视频放进包里）。开启"减弱动态效果"时显示静帧。
- 三个卖点短句（每句一行，带小图标）："按住说话，松手即输入" / "弦手势：回车、删除、移动光标" / "局域网加密直连，Key 只存在你的 Mac"。
- 主按钮「开始」→ ②。

### ② MAC：Mac 上装好 iMic 了吗？

- 标题 `MAC`，说明："iMic 需要电脑端配合。Mac 端负责识别和把文字输入到当前应用。"
- 两个大按钮：
  - 「已经装好了」→ ③。
  - 「还没有，发送到我的 Mac」→ 展开下载引导（同一页内展开，不跳页）。
- 次要文字按钮：「先看看怎么用」→ ⑤ 练习。练习完成或跳过后回到 ②，此时 `imic.tutorial.completedVersion` 已记录，⑤ 不会再重复出现。

**下载引导**（手机上无法安装 Mac 软件，重点是把链接送到 Mac 上）：

1. **接力（Handoff），自动**：本页可见期间，通过 `NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)` 把 `webpageURL` 设为落地页下载地址，并 `becomeCurrent()`；离开本页时 `invalidate()`。SwiftUI 可以用 `.userActivity(NSUserActivityTypeBrowsingWeb) { $0.webpageURL = … }`。界面上写："如果 Mac 和 iPhone 登录同一 Apple ID，Mac 程序坞左侧会出现一个 Safari 图标，点它即可打开下载页。"这种 activity 类型不需要额外的 entitlement；请确认 Info.plist 不需要新增 `NSUserActivityTypes`（BrowsingWeb 不需要）。
2. **共享**：按钮「共享链接」→ `ShareLink(item: url)`，可以隔空投送给 Mac，也可以发到微信或邮件。
3. **复制链接**：按钮「复制链接」→ `UIPasteboard.general.url = url`，提示"已复制，可在 Mac 上直接粘贴（需开启通用剪贴板）"。
4. 下面列出三步简要说明（不可点）："在 Mac 上下载并打开 iMic（macOS 13 及以上）" → "按 Mac 上的设置向导填入百炼 API Key" → "回到这里继续"。再附一行小字："百炼 API Key 由你自己在阿里云申请，识别会产生少量费用。"
5. 主按钮「Mac 上装好了，继续」→ ③。

不要在 App 里放 DMG 直链或二维码（手机屏幕上的二维码 Mac 无法方便地扫描）。

### ③ LINK：本地网络

- 标题 `LINK`，说明："接下来 iMic 会在同一 Wi-Fi 中寻找你的 Mac，系统会询问是否允许访问本地网络，请选择「允许」。"配一张示意图：用像素风画出系统弹窗的样子，不要截图系统 UI。
- 主按钮「开始寻找 Mac」→ 调用 `link.start()`，进入搜索状态（同一页切换为"正在寻找…"，配动效）。
- **权限被拒绝**的检测：iOS 没有直接读取本地网络权限状态的 API。用 `NWBrowser` 的状态判断：`.waiting(error)` 或 `.failed(error)`，并且 error 是 `NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))`（-65570）时，视为被拒绝。在 `LinkClient` 里把这个状态发布出来，例如新增 `@Published var localNetworkDenied: Bool`；只加观察，不改连接逻辑。
  - 被拒绝时显示：`LOCAL NETWORK OFF`，说明："本地网络权限已关闭，iMic 无法找到 Mac。请在「设置 → iMic」中打开「本地网络」。"按钮「打开设置」→ `UIApplication.openSettingsURLString`。从设置返回后自动重试搜索。
- 发现第一台 Mac 后自动进入 ④。

### ④ PAIR：配对

- 发现 Mac 后，复用现有配对流程：`PairingSheet(embedded: true)` 和 `LinkClient` 的现有配对逻辑。不修改协议、配对码规则和加密（AGENTS.md）。
- 只发现一台：直接显示"配对到 <名称>"和配对码输入。
- 发现多台：先列出供选择（复用 `link.connect(to:)`），选中后显示配对码输入。
- **8 秒仍未发现任何 Mac**：在搜索动效下方展开排查清单，并保持继续搜索：
  1. Mac 上的 iMic 是否已打开？（菜单栏能看到麦克风图标）
  2. iPhone 和 Mac 是否在同一个 Wi-Fi？
  3. 是否连着访客网络、公司网络或酒店网络？这类网络常禁止设备互相访问，可以改用手机热点试试。
  4. 是否开着 VPN 或代理？
  5. Mac 的防火墙是否阻止了 iMic 的传入连接？
  6. 「本地网络」权限是否已允许？附「打开设置」按钮。
- 配对成功：`Haptics.shared.play(.pairingSuccess)`（已有事件），显示 "已连接 <名称>"，1 秒后进入 ⑤；如果之前已练习过，直接进入 ⑥。
- 输错配对码、配对被锁定（Mac 端有防暴力破解的锁定）：沿用 `PairingSheet` 现有的错误提示，不另做。

### ⑤ PRACTICE：交互式练习

**核心要求：练习模式里所有手势都被真实识别，但绝不发送任何内容到 Mac，不请求麦克风、语音识别权限，也不录音。**

- 实现建议：新增 `PracticeSession`（或给 `SessionModel` 加一个隔离的练习模式），驱动与主页相同的 `HoldControl`、弦手势组件和 `Spectrum` 显示：
  - 波形用合成数据（参考 DEBUG 下的 `--ui-preview=` 和 `--debug-flight-*` 现有的模拟数据生成方式），不访问 `AudioCapture`。
  - 所有会调用 `link.send…`、`link.sendGesture…`、开始录音的入口，在练习模式下都要被拦截。拦截点要集中，不要在各处分散 `if`。
  - 加一条防线：练习模式下 `LinkClient` 收到任何发送请求时，写一行日志 `iphone.practice blocked send kind=…` 并丢弃。UI 测试会检查日志里没有任何发送。
- 触感和音效与真实使用完全一致（`Haptics.shared` 的语义事件，以及 `SoundDesign`），这样练习的手感就是真实的手感。
- 5 张卡片，每张有：像素标题、一句说明、一个**会动的手势示意**（像素风手指加轨迹，循环播放；减弱动态效果时显示静态箭头）、完成判定，以及一个「跳过」按钮：

| # | 像素标题 | 说明 | 完成判定 |
|---|---|---|---|
| 1 | `HOLD` | 按住下方横条开始说话，松手发送 | 按住 ≥0.6 秒后松手 |
| 2 | `CANCEL` | 按住时向上滑，松手即取消，不会发送 | 按住后上滑超过取消阈值再松手 |
| 3 | `RETURN` | 向下拉弦再松手，弹射时发送回车 | 触发一次 snap return |
| 4 | `EDIT` | 向上拉弦连续删除；左右滑动移动光标 | 触发至少一次删除和一次左右移动（两项可分别打勾） |
| 5 | `CLEAR` | 把弦一直拉到顶部，清空当前输入 | 触发一次清空 |

- 手势的具体阈值、方向和名称**以现有代码为准**（`HoldControl.swift`、`Spectrum.swift`、`ClearDropZone.swift`、`GestureControl.swift`）。上表的描述如与代码不一致，以代码为准，并修正文案，在 PR 中列出。
- 如果用户在设置里关闭了某个手势（`snapReturn`、`pullDelete`、`swipeCursor`，这些设置由 Mac 同步过来），对应的卡片仍然展示，但注明"已在设置中关闭"，允许直接跳过。
- 每张完成时给一个小的成功反馈：一个像素对勾，加 `Haptics.shared.play(.selection)`。全部完成显示 `PRACTICE COMPLETE`，记录 `imic.tutorial.completedVersion = 1`。
- 练习中把"假结果"显示在一个模拟的 Mac 输入框里（一行像素风的假文本框），让用户看到"松手 → 文字出现 → 回车 → 删除"的效果。预设文字，例如"今天下午三点开会"。

### ⑥ READY：第一次真实使用

- 标题 `READY`，说明："在 Mac 上点一下任意输入框（比如备忘录），然后按住下面的横条说一句话。"
- 小字说明权限："第一次按住时，系统会请求麦克风权限（必需）和语音识别权限（用于手机上的实时预览，可以拒绝）。"
- 主按钮「开始使用」→ 写入 `imic.onboarding.completedVersion = 1`，删除 `imic.onboarding.step`，关闭引导，回到主页。
- 次要链接：「在 Mac 上使用时遇到问题？」→ 打开落地页（`OnboardingLinks.home`，用 `openURL`）。

### 通用行为

- **可恢复**：每进入一步，就写入 `imic.onboarding.step`。杀掉 App 后重新打开，回到同一步。③ 和 ④ 恢复时会重新开始搜索。
- **返回**：每一步左上角有返回（① 除外）。
- **不能完全跳过引导**：本产品必须连 Mac 才能用。但 ② 的「先看看怎么用」让用户不连 Mac 也能体验。允许在 ③ 或 ④ 通过次要按钮"稍后再连接"离开引导回到主页；主页的空状态要提示"还没有连接 Mac"，并提供"继续设置"入口回到引导（不清除进度）。
- **横竖屏**：只支持竖屏（与现状一致）。
- **深色**：App 本身是深色，跟现状一致。

## 5. 设置页入口

- 在 iOS 设置页（`PairingSheet` / 设置 sheet 里现有的分区，请找准位置）新增一项：`GUIDE · 使用教程` →
  - 「重新练习手势」：打开 ⑤，独立运行，完成后回到设置，不改 `completedVersion`。
  - 「获取 Mac 版」：打开 ② 的下载引导部分（含接力、共享、复制）。
- 不要在这里重新触发完整引导。

## 6. 文案原则

- 简体中文，句子短，用"你"。不夸大，不说"零延迟""100% 准确"之类无法保证的话。
- 明确告知：需要 Mac（macOS 13+）、需要自己的百炼 API Key，并且会产生费用。
- 技术标签用英文像素字：`WELCOME`、`MAC`、`LINK`、`PAIR`、`PRACTICE`、`READY`、`LOCAL NETWORK OFF`。
- 不要写死落地页上还不存在的承诺，比如 App Store 链接。

## 7. 无障碍与动效

- 旁白（VoiceOver）：每一步的标题、说明、按钮都有清晰的标签；手势示意动画加 `accessibilityLabel` 描述动作。
- **每张练习卡都必须有不靠手势也能完成的路径**：开启旁白时显示「标记为已了解」按钮，否则使用旁白的用户无法完成练习。
- 动态字体：说明文字支持动态字体，像素标题可以固定大小。
- 减弱动态效果：关闭波形和手势示意的循环动画，改为静帧或箭头。

## 8. DEBUG 预览与重置

仅在 `#if DEBUG` 下（`tools/validate-testflight.py` 会检查 Release 二进制中没有 `--ui-preview=` 和 `--debug-`）：

- `--ui-preview=onboarding-welcome`、`onboarding-mac`、`onboarding-mac-download`、`onboarding-link`、`onboarding-link-denied`、`onboarding-search-timeout`、`onboarding-pair`、`onboarding-practice-1` 到 `onboarding-practice-5`、`onboarding-practice-complete`、`onboarding-ready`
- `--debug-reset-onboarding`：清除三个偏好键，用于测试。
- 预览中的 `LinkClient` 使用 preview 数据，不发起真实网络请求。

## 9. 硬性约束

- 不修改协议（`shared/iMicLink.swift`、`docs/PROTOCOL.md`、`tests/iMicLinkTests/LinkTests.swift`、`mac/LinkServer.swift`）。
- 不修改 Mac 端代码。
- 不放宽配对和安全规则：不自动配对，不跳过配对码。
- 练习模式绝不发送、绝不录音、绝不请求麦克风和语音识别权限。
- 不加任何统计、追踪或第三方 SDK；`?from=ios` 只是让落地页决定显示什么，不是统计参数。
- 已配对的老用户首次升级后不出现引导（3.1 规则 3）。
- `--ui-preview=*`、`--debug-*` 只在 DEBUG 下生效。
- 只用系统框架（SwiftUI、UIKit、Network），不引入第三方依赖。
- 不提交 `.claude/`、`build/` 下的产物。
- 同步更新文档：`docs/TESTFLIGHT-QUICKSTART.md`（安装与配对步骤改为与引导一致）、`README.md` 中 iPhone 首次使用的描述、`docs/PRIVACY.md`（说明接力和剪贴板由系统完成，iMic 不收集）。

## 10. 测试

### 10.1 单元测试（`tests/iMicLinkTests/OnboardingPolicyTests.swift`）

至少覆盖：
1. 全新安装 → `.show(.welcome)`
2. 已完成 → `.skip`
3. 进行中（任意步骤）且已配对 → `.show(该步骤)`（关键用例）
4. 未开始、已配对 → `.skipAndMarkComplete`
5. `completedVersion` 小于当前版本、未开始、未配对 → `.show(.welcome)`
6. 每个 `OnboardingStep` 都能恢复（遍历）

### 10.2 UI 测试（`tests/iOSUI/OnboardingUITests.swift`，在你的专用模拟器上运行）

1. 全新状态（`--debug-reset-onboarding`），走 ① → ② → 「先看看怎么用」→ 逐张完成 5 张练习 → 回到 ②。断言：全程日志里**没有** `iphone.link` 的连接或发送记录，也没有 `practice blocked send` 以外的发送；麦克风权限从未被请求。可以用 `XCUIApplication` 的 `resetAuthorizationStatus(for: .microphone)` 配合断言系统弹窗没有出现。
2. ② →「还没有」→ 下载引导可见，「共享链接」和「复制链接」可点；复制后 `UIPasteboard` 里是落地页地址。
3. 在 ② 杀掉 App 后重新启动 → 回到 ②。
4. `--ui-preview=onboarding-link-denied` → 显示 `LOCAL NETWORK OFF` 和「打开设置」。
5. `--ui-preview=onboarding-search-timeout` → 排查清单可见。
6. 已配对的预览状态（现有 `--ui-preview=idle`）→ 不出现引导，直接是主页。
7. 每个用例截图，用 `XCTAttachment`，`lifetime = .keepAlways`。

### 10.3 截图

每个 `--ui-preview=onboarding-*` 状态各截一张，放在 `build/ux-shots/onboarding/`，PR 里附路径并逐张说明。

### 10.4 全量测试（PR 必须附报告）

依次执行以下全部命令，每条记录：通过或失败、耗时、关键输出（失败时附最后 20 行）。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
./scripts/test-ios-mac-selection.sh
./scripts/test-ios-reconnect.sh
./scripts/test-polish-link.sh
./scripts/test-screen-idle.sh
./scripts/test-polish-effect.sh
./scripts/test-polish.sh
./scripts/test-mac-settings.sh
./scripts/test-input.sh
./scripts/test-clear-input.sh
./scripts/build-mac.sh
IMIC_SIM_NAME=<你的专用模拟器 UDID> ./scripts/build-ios.sh
xcodebuild test -project ios/iMic.xcodeproj -scheme iMic \
  -destination 'platform=iOS Simulator,id=<你的专用模拟器 UDID>' \
  -derivedDataPath build/ios-uitest.noindex \
  -resultBundlePath build/ios-uitest.noindex/onboarding.xcresult
IMIC_TESTFLIGHT_DIR=build/testflight-onboarding.noindex ./scripts/testflight.sh archive-unsigned
IMIC_TESTFLIGHT_DIR=build/testflight-onboarding.noindex ./scripts/testflight.sh check
```

- `DisplayUITests/testRecordingTouchPassesThroughMetalAndResultRemainsUsable` 是**既有失败**（改动前就失败：按住 0.8 秒后没有出现"录音太短"）。不要放宽它的断言，在报告中标注即可。
- 环境原因无法执行的命令，如实写明原因，不要写成"通过"。其他在干净分支上也失败的测试，标注为"既有失败"。

### PR 描述模板

```markdown
## 改动
- …（每个文件一句话）

## 规格对照
- 3.1 门控 / 3.2 推迟搜索：…
- ① WELCOME … ⑥ READY：…
- 5 设置入口 / 7 无障碍 / 8 预览：…
- 手势文案与代码核对结果：…
- 偏离之处及原因：…

## 权限弹窗时机
| 权限 | 触发时机 | 验证方式 |
|---|---|---|
| 本地网络 | ③ 点「开始寻找 Mac」 | … |
| 蓝牙 | 引导中不触发 | … |
| 麦克风 / 语音识别 | 第一次真实按住 | … |

## 全量测试报告
| 命令 | 结果 | 耗时 | 备注 |
|---|---|---|---|
| … | | | |

## UI 测试与截图
- xcresult：…
- build/ux-shots/onboarding/…

## 需要用户真机手测
- 接力：同一 Apple ID 的 Mac 程序坞是否出现 Safari 图标
- 本地网络拒绝 → 去设置打开 → 返回后自动找到 Mac
- 访客 Wi-Fi 下的排查清单是否出现

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## 11. 遇到以下情况时停下来，在 PR 中说明

- 推迟 `link.start()` 需要大改 `LinkClient` 或 `SessionModel` 的生命周期。
- 练习模式无法在不复制大量 `HoldControl` / `Spectrum` 代码的前提下实现。给出替代方案，例如抽出共用的手势识别层。
- 与 `codex/ios-quick-mac-switch` 的冲突无法简单解决。
- 测试中出现与本任务无关的失败：标注为"既有失败"即可，不要顺手修。
