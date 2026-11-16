# iOS 返回前台重连恢复：调查与验证

日期：2026-11-03。分支 `codex/ios-foreground-reconnect-recovery`，基线 `86a7fbd`（`codex/ui-phosphor-wireframe`）。独立于“上次 Mac 与删除配对”PR。

## 结论与边界

这次复现并修复的是 **冷启动会新建的连接/发现状态，在返回前台时却被保留或旧回调覆盖** 的生命周期缺陷。新回归在未修 `LinkClient.swift` 上 6/6 失败，在修复版上 6/6 通过。

现有手机日志不足以把用户每次失败都对应到这六种时序；这些是通过生产代码和隔离故障注入证明的缺陷，不宣称已经解释所有网络环境。百炼/润色服务的 `cloud_network` 错误不能据此归为手机与 Mac 的 TCP/BLE 断线。

## 已确认的缺陷

1. **退役发现器的延迟重试**：`NWBrowser.failed` 安排的 2 秒任务只看 `running / ready`，不核对发起该任务的浏览器是否仍是当前实例。旧任务可能取消并替换新发现器。现在弱引用捕获并核对当前实例身份，退役时解除其回调。
2. **主线程恢复交接窗口**：`restartForegroundLocked` 要先在主线程交付丢失通知，再启动新链路；原先旧浏览器在此窗口仍存活，其结果回调可能先行连接、推进 epoch，使恢复发布及新浏览器启动失效。现在先取消并清空旧发现器和发现缓存，再交接给主线程。
3. **配对码等待状态跳过恢复**：返回前台的 `!needsCode` 条件使静默失效的配对 socket 留在原状态。现在重建传输，再从 Mac 取得新的 hello / 配对提示，不等旧握手超时。
4. **手动目标在第一条 hello 前丢失意图**：手动选择尚未配对的 B 后立即后台，`needsCode` 还没置位，返回时会被当作自动选择；有已配对 A 时可能转向 A，或被严格自动配对保护挡住。现在无本机令牌、正在手动连接/配对的目标（第一条 hello 前，以及 needsCode 阶段）都会保留，只为该目标重建传输。已配对或纯离线目标的自动候选策略仍由单独的选机 PR 负责。依旧需要输入正确配对码。
5. **健康 socket 不代表发现器可继续使用**：原先健康 TCP/BLE 的返回路径只做 ping，始终保留同一发现器实例。现在独立重建 Bonjour 发现，同时仍用既有加密 ping/pong 判定是否需要更换传输；健康语音连接保持原 socket。
6. **发现失败覆盖健康 UI**：浏览器失败会无条件把 phase 写成 failed，即使语音传输已认证或正在连接。现在仅在没有可用/连接中传输时发布发现错误，避免把健康传输显示为失败。

没有修改 Mac 选择纯函数、配对码规则、帧格式、AES-GCM、TokenStore、自动输入或用户接管保护，也不改 App 版本或签名配置。测试入口只追加到临时源文件，不进入 App。

## 新回归方法

`tests/LinkResumeLifecycle/ClientHarness.swift` 由脚本追加到临时 `LinkClient.swift`，直接驱动私有串行队列及真实浏览器回调，模拟 UIKit 主线程尚未处理恢复发布的间隙。涉及配对和健康连接的场景使用真实 `LinkServer`、真实六位码和加密握手，经字节代理制造旧连接黑洞，不伪造 ready 或认证结果。

- 旧浏览器失败后换成新实例，等旧任务到点，验证新实例不被替换。
- 主线程暂不消费发布时，确认恢复开始已退役旧浏览器。
- 另有一台已配对 Mac，当前手动目标尚未配对且等配对码；旧传输黑洞后由生产 activate 自行建立第二条连接，仍向同一目标请求正确代码。
- 另有一台已配对 Mac，手动目标在第一条 hello 前即被黑洞；后台返回仍只为原目标重建，正确代码通过才 ready。
- 已有健康语音连接，后台返回重新建发现器但不换 socket、不丢失语音会话。
- 健康认证连接上注入发现器失败，不得覆盖 ready。

两个重连脚本使用随机可执行文件名，以隔离 `UserDefaults` 域（仅临时目录不同不足以隔离同名进程），并保存/清除/还原选择 PR 引入的持久化键，支持两 PR 组合和并行验证。

## 测试结果

下表耗时包含编译，受并行构建负载影响；日志保留在本 worktree 的 `build/foreground-reconnect/`，不提交构建产物。

| 命令 | 结果 | 耗时 | 关键输出 |
|---|---|---:|---|
| `swift test` | PASS | 49.91s | 74 项共享/协议单测，0 failures |
| `./scripts/test-ios-mac-selection.sh` | PASS | 26.49s | 原有自动选择、宽限、手动等待及令牌拒绝等集成回归全部通过（本 PR 不改变其选择策略） |
| `./scripts/test-polish-link.sh` | PASS | 19.27s | 真实加密链路上润色配置、模式、语言及回显通过 |
| `./scripts/test-screen-idle.sh` | PASS | 4.71s | 待机遮罩、首次触摸唤醒、忙碌保护与生命周期取消通过 |
| `./scripts/test-ios-foreground-lifecycle.sh（旧源对照）` | 预期 FAIL | 17.76s | 未修改的 86a7fbd LinkClient + 最新 fixture：0/6；6 个失败均按预期复现 |
| `./scripts/test-ios-foreground-lifecycle.sh` | PASS | 13.25s | 6/6 新生命周期回归通过 |
| `./scripts/test-ios-reconnect.sh` | PASS | 19.91s | 健康存活、静默黑洞替换、单次丢失通知、缓冲录音保护、取消退避通过 |
| `./scripts/test-ios-reconnect.sh --long-background` | PASS | 77.02s | 55 秒黑洞，跨越 Mac 的 40 秒心跳窗口；重连后重新认证通过 |
| `./scripts/build-ios.sh` | PASS | 后台构建未单独计时 | `BUILD SUCCEEDED`，模拟器构建，`CODE_SIGNING_ALLOWED=NO` |
| `git diff --check` | PASS | — | 无空白错误 |

新旧源对照可以复现：

```bash
git show 86a7fbd:ios/iMic/LinkClient.swift > build/foreground-reconnect/baseline-LinkClient.swift
IMIC_LINK_CLIENT_SOURCE="$PWD/build/foreground-reconnect/baseline-LinkClient.swift" ./scripts/test-ios-foreground-lifecycle.sh
./scripts/test-ios-foreground-lifecycle.sh
```

完整命令及退出码：`build/foreground-reconnect/results.json`、`final-results.json`、`scope-results.json`。最终新源码为全部 PASS；旧源码故障注入是有意保留的 FAIL。首轮旧重连脚本编译时测试源被本轮隔离键更新触发 `input file ... was modified during the build`，随后固定源独立重跑通过；未放宽产品断言。开发过程也修正了 fixture 的配对码旋转：`PairingStore.forgetAll()` 后重新设置测试码，真实配对校验没有放宽。

原有 Swift 5 并发/捕获警告仍存在；没有顺手改动这些无关代码。构建重新生成的 9 个 AppIcon PNG 已恢复，不纳入 PR。

## 实机复验建议

无需重新配对即可先测已配对的同一台 Mac：

1. 两端在线，后台 5 秒后返回：应通过加密存活检查继续使用原连接，不打断在途会话。
2. 后台 45–60 秒，期间暂时断开并恢复 Wi-Fi：返回应刷新发现并重新认证；目标选择由另一 PR 固定为上次/明确选择的 Mac。
3. 手动选一台新 Mac，在首次连接中或看到配对码后后台再返回：仍指向同一台，需正确配对码才能连上。
4. 从 Wi-Fi 切到 BLE 后备再返回前台：检查存活与重新发现，不自动把录音换到另一台 Mac。

这里验证了真实生产链路与可重复的逻辑生命周期，没有声称模拟了 iOS 的进程冻结、真实多 Wi-Fi 路由或真实 CoreBluetooth 无线环境；这些仍需真机验证。未接管用户前台、安装覆盖用户 App 或手机，未修改 TCC。
