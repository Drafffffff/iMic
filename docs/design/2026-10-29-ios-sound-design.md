# iOS 界面音效方案（2026-10-29）

实现：`ios/iMic/SoundDesign.swift`（合成与播放）、`ios/iMic/Haptics.swift`（语义事件入口）、`ios/iMic/SoundPreferencesView.swift`（设置开关与 Debug 试听）。

## 1. 旧问题：多数时候听不到

### 现象

旧版只有一个音效：下拉弦松手回车的弦响（`BowReleaseSound`）。偶尔能听到，多数时候听不到，触感正常。

### 根因

`BowReleaseSound` 用 `CHHapticEngine(audioSession: AVAudioSession.sharedInstance())` 播放「触感 + 音频」组合 pattern，并刻意「不管理音频会话」。所以声音能不能出来，取决于采集链路（`AudioCapture`）当时把共享会话留在什么状态：

| 时机 | 共享会话状态 | 结果 |
| --- | --- | --- |
| 本次启动后还没录过音 | 默认 `.soloAmbient`，未激活 | 静音开关打开时被静音 |
| 录音结束 5 秒保温期内 | `.playAndRecord` + `.measurement`，已激活 | **能听到**（measurement 模式下扬声器偏小） |
| 保温期结束后（最常见的回车时机） | `setActive(false)` 已停用；触感引擎随之被停掉 | 引擎重建后触感照常，音频没有可用会话。`start()` 不报错，也没有任何日志 |

真机日志证据（2026-10-29 从 iPhone 16 Pro 拉取，`scripts/pull-ios-log.sh`）：每一次 `sink engine stop` 之后 10–30 ms，都紧跟一条

```
[iphone.audio] sink engine stop; draining worker
[iphone.bow] coordinated engine stopped reason=1      ← CHHapticEngine.StoppedReason.audioSessionInterrupt
```

当天共 36 次，与停用次数一一对应。也就是说，每次录音结束都会杀掉音效引擎；之后只能靠下一次拉弦时异步重建，而重建出来的引擎挂在一个已停用的会话上。整个过程只有「触感成功、声音丢失」这一种失败形态，而且不会留下日志，所以表现为「偶尔能听到」：只有恰好在保温期内回车才有声音。

复现步骤（旧版本）：静音开关关闭 → 录一句话 → 等 6 秒以上 → 下拉弦回车：有触感，没有声音。改成在 5 秒内回车：能听到。

### 修复

UI 音效不再借用 App 的 `AVAudioSession`。全部音色在启动后离线合成为 WAV，注册成 `SystemSoundID`，再用 `AudioServicesPlaySystemSoundWithCompletion` 播放：

- 与采集会话完全解耦：录音的 category、mode、激活与停用都不会影响音效，音效也不会反过来打断录音。
- 遵守静音开关：系统声音在静音时不出声。这是有意为之。
- 录音期间可混音：`AudioCapture` 已设置 `setAllowHapticsAndSystemSoundsDuringRecording(true)`。
- 中断、路由变化、AirPods 切换都由系统处理；媒体服务重置时重新注册。
- 每次播放都写日志，包括跳过的原因、路由和完成耗时：

```
[iphone.sound] ready sounds=20 ms=293
[iphone.sound] play cue=snapReturn v=2 id=4103 via=event route=Speaker
[iphone.sound] done cue=snapReturn ms=101
[iphone.sound] skip cue=result reason=disabled
```

### 为什么不用 `.ambient` + `AVAudioEngine`

- App 只有一个共享会话。录音需要 `.playAndRecord`；空闲时切到 `.ambient` 再激活，就要和 `AudioCapture` 的后台生命周期队列争抢 category。保温期内（`.playAndRecord`）还会绕过静音开关，行为前后不一致。
- 音效引擎在每次录音开始和结束时都会收到配置变化或中断，必须停下重启。这正是旧 bug 那类问题。
- 实时振荡器给不了我们需要的东西：所有音都是固定的短音，参数化离线合成同样满足「代码生成、无版权素材」，而且没有运行时开销。

代价：系统声音的音量跟随「设置 › 声音与触感 › 铃声和提醒」，而不是媒体音量；也不能逐次调音量（电平已经烘焙进 PCM）。这和系统键盘的按键音行为一致，对 UI 提示音来说是合理的。

另外，系统声音服务首次播放有约 0.4 s 的冷启动（模拟器实测 456 ms）。注册完成后会先播一段 8 ms 的静音预热，之后首个真实提示音的完成耗时降到 103 ms（其中音频本身长 84 ms）。

## 2. 交互清单

优先级：P0 = 核心手势反馈，P1 = 状态变化，P2 = 点缀。「触感」一栏是 `Haptics.Event`。

| 交互 / 状态 | 音效 | 触感 | 优先级 | 说明 |
| --- | --- | --- | --- | --- |
| 按住（press） | 无 | `press` | — | 麦克风正在打开且保温期内带 150 ms 预录，measurement 模式无回声消除，声音会被录进识别音频 |
| 开始录音 | 无 | `recordingStarted` | — | 同上 |
| 松开提交 | SEND | `release` | P0 | 此时已退出 listening，新音频只进入滚动预录 |
| 上滑取消 | CANCEL | `cancelled` | P0 | |
| 录音太短 | SHORT | `tooShort` | P1 | |
| 上滑进入/离开取消区 | 无 | `cancelArmed` / `cancelDisarmed` | — | 录音中，避免录入 |
| 弦拨动刻度 | 无 | `stringNotchLow/High` | — | 频率太高，只用触感 |
| 弦拉满（下拉过阈值） | ARMED | `bowArmed` | P2 | 极轻的高频“上膛”声 |
| 下拉发射（弦回弹回车） | RETURN ×3 档 | `playBowRelease(strength:)` | P0 | 签名音；按拉弦力度选上扫顶点与音量 |
| 上拉删除一字 / 连续删除 | DEL | `deleteChar`（单次） | P1 | 连续删除每次都发声，受 45 ms 节流 |
| 上拉清空 | CLEAR | `cancelArmed` → 0.22 s 后 `stringSnap` | P1 | 声音与断弦触感同时出现 |
| 识别结果到达 | TEXT | `result` | P1 | |
| 润色完成 | POLISH | `polishReady` | P1 | |
| 复制 | COPY | `copy` | P2 | |
| 连接成功 | LINK | `connected` | P1 | 0.4 s 节流 |
| 连接断开 | LOST | `connectionLost` | P1 | |
| 需要配对 | PAIR? | `pairingRequired` | P1 | |
| 配对成功 | PAIRED | `pairingSuccess` | P1 | |
| 配对失败 | DENIED | `pairingFailed` | P1 | |
| 提示（麦克风被拒等） | WARN | `warning` | P2 | |
| 出错 | ERROR | `error` | P1 | |
| 普通点按、选择、浮层开合、配对码逐位输入 | 无 | `tap` 等 | — | 高频操作，只用触感 |

映射集中在 `SoundCue.forHaptic(_:)`：触感事件就是音效的唯一入口（回车与连续删除除外，它们带力度或不走触感）。`Haptics` 的节流同时作用于声音。

## 3. 声音语言

第二版（同日真机试听后调整）针对三条反馈：

1. 「松手和识别完成一模一样」：第一版两者都从 E6 起、都是短促方波，只差余辉。现在把音区、节奏、尾巴三个维度全部拉开：
   - SEND 是 A3（220 Hz）单下低音闷击，没有余辉；
   - TEXT 是 A5 → A6 八度「叮叮」，带余辉，中心频率高一倍以上。
2. 「发射没有发射感」：RETURN 改成 8-bit 发射音。噪声起音之后，音高从 A3 急速上扫到 2–2.8 kHz，每 1/120 s 跳一级，模拟芯片扫频寄存器的阶梯；再叠一层低八度方波增加厚度，时长 150–180 ms。上扫表示「送出去」，与 CANCEL 的下滑方向相反。
3. 「低音再低一点」：
   - TRANSPORT 与 ALERT 整体下移约一个八度，到 A3–G4；LINK 下移到 A4–E5。
   - 低音一律用方波/脉冲波，并叠加高八度声部：手机外放还原不了 200 Hz 的基频，但能听到它的谐波，耳朵会自动补出低音（缺失基频）。
   - 高通从 150 Hz 降到 90 Hz。

顺带拉开的相似音：
- CLEAR 原先是下扫加噪声，与 RETURN、CANCEL 撞型，现在改为 CRT 关机式的静电噪声加 60 ms 低音「嗵」。
- PAIR? 原先与 SHORT 一样是「同音两下」，现在改为三下三角波短点（光标闪烁）。
- PAIRED 原先与 POLISH 都是上行琶音，现在改为 A5/E6 交替颤音（握手）后落在 A6。
- WARN 原先与 SEND 同为单下低音，现在改为三下急促的 D4。

区分规则：同一家族共用音色，不同状态主要靠「次数 × 方向」区分。
- 单下：SEND
- 两下：SHORT、TEXT、COPY
- 三下：WARN、PAIR?
- 上行：RETURN、LINK、POLISH、PAIRED
- 下行：CANCEL、LOST、DENIED
- 无音高：CLEAR

整体参数：
- 音色：方波 / 脉冲波 / 三角波 + 白噪声瞬态，即 8-bit 终端与 CRT 的声音。PolyBLEP 抗混叠，经两级一阶低通去刺耳高频，再用 90 Hz 高通去直流。
- 荧光余辉：SIGNAL / LINK 家族叠加 32 ms 与 64 ms 两次衰减回声（增益 g 与 g²）。
- 时长：手势音 ≤ 190 ms；状态音 ≤ 190 ms 再加最多 70 ms 极轻余辉；最长的配对成功为 283 ms。
- 音量：峰值 −8 至 −22 dBFS。发射音最响，最常出现的 ARMED、DEL、COPY 最轻。

### 家族

| 家族 | 波形 | 音区 | 低通 | 余辉 | 成员 |
| --- | --- | --- | --- | --- | --- |
| TRANSPORT 录音 | 方波 / 25% 脉冲 + 高八度 | A3–A4 | 2.4–2.6 kHz | 无 | SEND / CANCEL / SHORT |
| STRING 弦手势 | 脉冲 + 噪声瞬态 | 全音域扫频 | 3–5 kHz | 无 | ARMED / RETURN / DEL / CLEAR |
| SIGNAL 文字 | 50% 方波（COPY 为三角） | A5–A6 | 4.2 kHz | 0.22–0.25 | TEXT / POLISH / COPY |
| LINK 连接 | 三角 + 12.5% 细脉冲 | A4–A6 | 4–5 kHz | 0.12–0.20 | LINK / LOST / PAIR? / PAIRED |
| ALERT 提醒 | 50% 方波 + 高八度 | B♭3–F4 | 2.2–2.4 kHz | 无 | DENIED / WARN / ERROR |

## 4. 每个音的参数

记号：`起始 ms + 长度 ms，频率（→ 滑音目标，滑音时间常数），衰减时间常数 τ`；「+8va」表示同时叠加 0.4–0.5 增益的高八度声部。所有音的起音都是 1.5 ms 线性上升，结尾有 4 ms 线性释放；整段末尾再加 8 ms 余量并做 3 ms 淡出。峰值按 dBFS 归一化，「总长」含余辉与余量。

| 音 | 声部 | 峰值 | 总长 |
| --- | --- | --- | --- |
| SEND 松开提交 | 方波 0+70 330→A3 220（τ6）τ32；25%脉冲 A4 声部同步下坠，增益0.5；噪声 0+5 增益0.3 | −12 | 78 ms |
| CANCEL 上滑取消 | 25%脉冲 0+130 A4→E3（τ45）τ75 +8va | −13 | 138 ms |
| SHORT 录音太短 | 25%脉冲 G4 392 +8va：0+22、36+22，τ20 | −13 | 66 ms |
| ARMED 弦拉满 | 三角 0+14 E7 τ6 | −22 | 22 ms |
| RETURN 1/2/3 下拉发射 | 25%脉冲 A3 → 2000/2400/2800 Hz（τ22，1/120 s 阶梯），长 150/165/180，τ=0.6×长；50%方波低八度同步扫频，增益0.45；噪声 0+16 增益0.3 τ6 | −11 / −9.5 / −8 | 158 / 173 / 188 ms |
| DEL 删除一字 | 12.5%脉冲 0+22 D6 τ9；噪声 0+6 增益0.25 τ2 | −17 | 30 ms |
| CLEAR 清空 | 噪声 0+130 增益0.7 τ45；方波 0+60 A3→110 Hz（τ12）增益0.8 τ30；低通 3 kHz | −13 | 138 ms |
| TEXT 识别结果到达 | 方波 0+30 A5 τ25；45+60 A6 τ40；余辉 0.25 | −14 | 183 ms |
| POLISH 润色完成 | 方波 E5 / G♯5 / B5 各 28 ms（间隔 32）+ 96+80 E6 τ45；余辉 0.22 | −12 | 254 ms |
| COPY 复制 | 三角 0+15 C7 τ8；40+15 C7 τ8 | −18 | 63 ms |
| LINK 连接成功 | 三角+12.5%脉冲(0.35)：0+50 A4 τ45；55+80 E5 τ50；余辉 0.18 | −13 | 213 ms |
| LOST 连接断开 | 三角+12.5%脉冲(0.35)：0+50 E5 τ45；55+100 A4 τ60；余辉 0.12 | −14 | 233 ms |
| PAIR? 需要配对 | 三角 E6 0+20、60+20、120+20，τ15 | −15 | 148 ms |
| PAIRED 配对成功 | 三角 A5/E6/A5/E6 各 24 ms（间隔 28）+ 115+90 A6 τ60；余辉 0.20 | −13 | 283 ms |
| DENIED 配对失败 | 方波 +8va：0+50 F4 τ40；60+70 E4 τ50 | −12 | 138 ms |
| WARN 提示 | 方波 D4 +8va：0、30、60 各 20 ms，τ18 | −13 | 88 ms |
| ERROR 出错 | 方波双音 B♭3+B3 +8va：0+70、90+90，τ55 | −11 | 188 ms |

## 5. 开关与试听

- 设置 › SOUND（界面音效）：ON / OFF，存于 `UserDefaults` 键 `imic.sound.enabled`，默认开启。关闭后只剩触感，日志记为 `skip … reason=disabled`。
- Debug 试听：
  - `xcrun simctl launch --terminate-running-process booted art.malette.imic --ui-preview=sounds` 打开独立试听页，不连 Mac、不开麦克风。点单个音逐个试听，`PLAY ALL` 依次播放全部 19 个音。
  - Debug 构建的设置页底部也有同一个试听列表，方便在真机上直接试听。
  - 两个入口都在 `#if DEBUG` 内，Release 不含（`tools/validate-testflight.py` 会检查 `--ui-preview=` 字符串）。

## 6. 真机验收清单

先装 Debug 包，测完后用 `scripts/pull-ios-log.sh` 拉日志，`grep iphone.sound` 核对每一项。

1. 静音开关关闭（有声）、铃声音量调到一半：设置页试听全部音，每个都能听到，`play` 与 `done` 一一对应。
2. 静音开关打开：再次试听，应完全无声，触感照常；日志仍有 `play`（若某些系统版本静音时不回调 `done`，属系统行为，不算失败）。
3. 录音前回车：冷启动 App，连上 Mac，不录音，直接下拉弦回车。应听到 RETURN，日志有 `play cue=snapReturn`。
4. 录音后马上回车：录一句话，结果到达后 5 秒内下拉回车。应依次听到 SEND、TEXT、RETURN。
5. 录音后等一会再回车（旧 bug 场景）：录一句话，等 10 秒以上再下拉回车。应能听到 RETURN。
6. 录音期间：按住说话时不应有任何提示音；在 Mac 上核对识别文字里没有被录入的提示音。上滑取消时听到 CANCEL。
7. AirPods：连接 AirPods 后重复第 3、4 项。声音跟随当前系统路由，日志的 `route=` 显示 `BluetoothA2DPOutput` 或 `BluetoothHFP`。若提示音没有跟随 AirPods 而是从手机扬声器发出，记录 `route=` 一并反馈。
8. 前后台切换：App 切到后台 30 秒再回来，下拉回车与连接提示音照常；切后台期间不应出现 `play` 日志（后台记为 `skip … reason=inactive`）。
9. 来电或闹钟中断后回到 App：提示音照常。
10. 设置 › SOUND 选 OFF：所有提示音消失，触感保留；选回 ON 时会播放一次 LINK 作为确认。
