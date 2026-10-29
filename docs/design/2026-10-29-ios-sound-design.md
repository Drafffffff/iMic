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
| 下拉回车（弦回弹发射） | RETURN ×3 档 | `playBowRelease(strength:)` | P0 | 签名音；按拉弦力度选音高与音量 |
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

- 音色：方波 / 脉冲波 / 三角波 + 白噪声瞬态，即 8-bit 终端与 CRT 的声音，与像素字、荧光屏同一来源。PolyBLEP 抗混叠，再过两级一阶低通去掉方波的刺耳高频，最后用 150 Hz 高通去直流、保护扬声器。
- 荧光余辉：SIGNAL / LINK 家族叠加 32 ms 与 64 ms 两次衰减回声（增益 g 与 g²），模拟荧光粉的拖尾。
- 时长：核心手势音 ≤ 100 ms；状态音 ≤ 160 ms 再加最多 70 ms 极轻余辉；最长的配对成功为 258 ms（三音琶音）。
- 音量：峰值 −11 至 −22 dBFS，RMS 约 −20 至 −33 dBFS；最常出现的音（ARMED、DEL、COPY）最轻。
- 音高：主体在 A 大调五声音阶（A5 880 / C♯6 1109 / E6 1319 / A6 1760 Hz），手机扬声器在 600 Hz 以上才清晰。
  - 成功：上行（大三度、纯四度、琶音）
  - 取消 / 断开：下行或下滑
  - 太短 / 等待：同音两下
  - 错误：低音区小二度（B♭4 + B4 不协和双音，或 F5 → E5）

### 家族

| 家族 | 波形 | 低通 | 余辉 | 成员 |
| --- | --- | --- | --- | --- |
| TRANSPORT 录音 | 25% 脉冲 | 3.2 kHz | 无 | SEND / CANCEL / SHORT |
| STRING 弦手势 | 12.5% 细脉冲 + 噪声瞬态 | 4.2 kHz（CLEAR 2.6 kHz） | 无 | ARMED / RETURN / DEL / CLEAR |
| SIGNAL 文字 | 50% 方波（COPY 为三角波） | 3.6 kHz | 0.22 | TEXT / POLISH / COPY |
| LINK 连接 | 三角波 | 5 kHz | 0.12–0.20 | LINK / LOST / PAIR? / PAIRED |
| ALERT 提醒 | 50% 方波，低音区 | 2.0–2.2 kHz | 无 | DENIED / WARN / ERROR |

## 4. 每个音的参数

记号：`起始 ms + 长度 ms，频率（→ 滑音目标，滑音时间常数），衰减时间常数 τ`。所有音的起音都是 1.5 ms 线性上升，结尾有 4 ms 线性释放；整段末尾再加 8 ms 余量并做 3 ms 淡出。峰值按 dBFS 归一化，「总长」含余辉与余量。

| 音 | 声部 | 峰值 | 总长 |
| --- | --- | --- | --- |
| SEND 松开提交 | 脉冲25% 0+26 E6 τ30；30+46 A6 τ28 | −13 | 84 ms |
| CANCEL 上滑取消 | 脉冲25% 0+95 A5→B4（τ35）τ60 | −14 | 103 ms |
| SHORT 录音太短 | 脉冲25% 0+32 D5 τ30；60+32 D5 τ30 | −14 | 100 ms |
| ARMED 弦拉满 | 三角 0+14 E7 τ6 | −22 | 22 ms |
| RETURN 1/2/3 下拉回车 | 脉冲12.5% 0+85 F♯6/A6/C7 → 半频（τ18）τ40；噪声 0+10 增益0.35 τ3 | −14 / −12.5 / −11 | 93 ms |
| DEL 删除一字 | 脉冲12.5% 0+22 D6 τ9；噪声 0+6 增益0.25 τ2 | −17 | 30 ms |
| CLEAR 清空 | 脉冲25% 0+140 E6→330 Hz（τ50）τ70；噪声 0+140 增益0.5 τ50；低通 2.6 kHz | −14 | 148 ms |
| TEXT 结果到达 | 方波 0+60 E6 τ35；余辉 0.22 | −14 | 138 ms |
| POLISH 润色完成 | 方波 0+35 E6 τ30；40+80 A6 τ45；余辉 0.22 | −12 | 198 ms |
| COPY 复制 | 三角 0+15 C7 τ8；40+15 C7 τ8 | −18 | 63 ms |
| LINK 连接成功 | 三角 0+40 C♯6 τ40；45+70 E6 τ45；余辉 0.18 | −13 | 193 ms |
| LOST 连接断开 | 三角 0+45 E6 τ40；50+90 A5 τ55；余辉 0.12 | −14 | 218 ms |
| PAIR? 需要配对 | 三角 0+35 E6 τ30；75+35 E6 τ30 | −15 | 118 ms |
| PAIRED 配对成功 | 三角 0+40 A5；45+40 C♯6（τ40）；90+90 E6 τ60；余辉 0.20 | −12 | 258 ms |
| DENIED 配对失败 | 方波 0+50 F5 τ40；60+60 E5 τ45；低通 2.2 kHz | −13 | 128 ms |
| WARN 提示 | 方波 0+70 D5 τ40；低通 2.2 kHz | −14 | 78 ms |
| ERROR 出错 | 方波双音 B♭4+B4：0+60 τ50；80+70 τ50；低通 2.0 kHz | −11 | 158 ms |

生成方式：`SoundSynth.render` 是一个确定性合成器，使用固定噪声种子，44.1 kHz 采样，输出单声道 16-bit PCM WAV，文件写入 `Library/Caches/iMicSounds-v<renderVersion>/`。修改任何参数时必须递增 `SoundSynth.renderVersion`。仓库里不存放任何音频文件。

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
