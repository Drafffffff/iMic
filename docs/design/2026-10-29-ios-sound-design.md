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
- 实时振荡器给不了我们需要的东西：所有音都是固定的短音，参数化离线合成同样满足「代码生成、无版权素材」，没有运行时开销，还能在合成链里做降采样和降位深。

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
| 下拉发射（弦回弹回车） | RETURN ×3 档 | `playBowRelease(strength:)` | P0 | 签名音；力度越大，踢鼓越重、呼啸越快越长 |
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

## 3. 声音语言：8-bit lo-fi

第三版（同日真机试听后调整）。用户反馈与对应做法：

| 反馈 | 做法 |
| --- | --- |
| 「整体都偏 8-bit lo-fi 一点」 | 全部 19 个音改用芯片声道合成，并整体降采样、降位深（见下） |
| 「松手和识别完成一模一样」 | SEND = 8-bit 踢鼓 + 一下短「咔」，单下、干、低频为主；TEXT = A5 → A6 空心方波八度「叮叮」，带两次颗粒回声，几乎没有低频。音区、节奏、尾巴三处全部相反 |
| 「发射没有发射感」，第三版的「冰」一声太轻巧、太灵动 | 第四版 RETURN 去掉所有清亮音头和上行旋律，改成「厚、短、狠」。力量：硬起音踢鼓 + 30 ms 低时钟噪声爆破（推力）；速度：噪声时钟从 1.5 kHz 急冲到 8–12 kHz 的「呼—」，底下一层 50% 方波从 A3 坠到约 70 Hz 加重量；远去：整段低通从 5 kHz 收到 700 Hz，与音量同步衰减，不留余音 |
| 「低音再低一点」「要带感、有打击感的低音」 | 动作音（SEND、RETURN）加 8-bit 踢鼓：硬起音的 25% 脉冲 + 4-bit 三角，从约 190 Hz 半音阶梯下坠到 45–50 Hz（60–75 ms），起音叠 3 ms 噪声咔嗒。手机外放靠脉冲波的 2/3 次谐波听出「咚」，耳机上有完整低频。信息提示（TEXT、LINK 等）不加踢鼓，避免又变得相似 |

### 芯片合成链

1. **声道**，模仿 NES / Game Boy 的几种声道：
   - 方波 / 脉冲：占空比 12.5%、25%、50%，PolyBLEP 抗混叠，并去掉直流分量。
   - 4-bit 阶梯三角：16 级。
   - 15-bit LFSR 噪声：噪声时钟可设，也可以滑动。
2. **音高**：所有音高量化到十二平均律半音。滑音按 `step` 节拍阶梯推进，默认 1/120 s，取消音用 1/60 s，踢鼓用 1/480 s。和弦用琶音表达：每个 step 轮换一个半音偏移，例如润色完成的 0/4/7/12。
3. **音量包络**：0.8 ms 硬起音 + 指数衰减，量化为 16 级，即 4-bit 音量寄存器的台阶感。不加混响。
4. **低保真回声**：SIGNAL / LINK 家族保留 36 ms 与 72 ms 两次回声（增益 g 与 g²）。回声在降采样之前叠加，所以回声本身也是颗粒的。
5. **降采样 + 降位深**：
   - 先把信号归一化到满幅，再用采样保持降到 11–22 kHz，量化到 6–8 bit。
   - 不同家族的颗粒度不同：SIGNAL 22 kHz / 8 bit 最干净；TRANSPORT、STRING、LINK 16 kHz / 8 bit；ALERT 11 kHz / 6 bit 最粗。SHORT、CLEAR 用 11 kHz / 7 bit，RETURN 用 16 kHz / 7 bit。
6. **滤波**：
   - 两级一阶低通（2.2–6 kHz）压掉降采样的混叠镜像，iPhone 外放不扎耳。RETURN 的截止频率随时间从 5 kHz 指数收到 700 Hz（`cutoffEnd`），营造远去感。实测各音 6 kHz 以上能量比总能量低 20–41 dB。
   - 30 Hz 高通只去直流，保留踢鼓低频。
   - 最后峰值归一化，末尾 3 ms 淡出。

### 区分规则

同一家族共用声道与颗粒度，不同状态靠「低频冲击 × 次数 × 方向」区分：

- 有踢鼓：SEND（单下 + 短「咔」）、RETURN（踢鼓 + 爆破 + 暗呼啸）
- 单下：SEND
- 两下：SHORT、TEXT、COPY
- 三下：WARN、PAIR?
- 上行：LINK
- 高音塌缩：CLEAR（CRT 关机的「滋—」）
- 琶音：POLISH（四音和弦）、PAIRED（两音颤音）
- 下行：CANCEL（1/60 s 半音阶梯）、LOST、DENIED
- 不协和：ERROR

时长：手势音 ≤ 190 ms；状态音 ≤ 210 ms，再加最多 80 ms 回声；最长的配对成功为 293 ms。峰值 −5.5 至 −22 dBFS：发射最响，提交次之，最常出现的 ARMED、DEL、COPY 最轻。

### 家族

| 家族 | 声道 | 音区 | 颗粒 | 低通 | 回声 | 成员 |
| --- | --- | --- | --- | --- | --- | --- |
| TRANSPORT 录音 | 25% / 12.5% 脉冲；SEND 加踢鼓 | 45 Hz 踢鼓 + A3–A4 | 16k/8（SHORT 11k/7） | 2.6–3.2 kHz | 无 | SEND / CANCEL / SHORT |
| STRING 弦手势 | 脉冲 + LFSR 噪声；RETURN 加踢鼓 | 全音域扫频 | 16k/8（RETURN 16k/7，CLEAR 11k/7，ARMED 22k/8） | 3–6 kHz | 无 | ARMED / RETURN / DEL / CLEAR |
| SIGNAL 文字 | 50% / 25% 方波，4-bit 三角 | A5–A6 | 22k/8 | 4.2–6 kHz | 0.22–0.28 | TEXT / POLISH / COPY |
| LINK 连接 | 4-bit 三角 + 12.5% 细脉冲 | A4–A6 | 16k/8 | 4–5 kHz | 0.12–0.20 | LINK / LOST / PAIR? / PAIRED |
| ALERT 提醒 | 50% 方波 + 高八度 | B♭3–F4 | 11k/6 | 2.2–2.4 kHz | 无 | DENIED / WARN / ERROR |

## 4. 每个音的参数

记号：
- 声部写作「起始 ms + 长度 ms，频率（→ 滑音目标，滑音时间常数），衰减时间常数 τ」。
- 「+8va」表示叠加增益 0.4–0.5 的高八度声部。
- 「踢鼓(a→b, L)」：25% 脉冲 + 4-bit 三角，从 a Hz 以 τ14 ms、1/480 s 半音阶梯下坠到 b Hz，长 L ms；起音叠 3 ms 噪声。
- 「颗粒」写作「降采样率 / 位深」。
- 「总长」含回声与 8 ms 余量。

| 音 | 声部 | 颗粒 | 峰值 | 总长 |
| --- | --- | --- | --- | --- |
| SEND 松开提交 | 踢鼓(190→50, 65)；25% 脉冲 4+30 A4 增益 0.35 τ16 | 16k/8 | −9 | 73 ms |
| CANCEL 上滑取消 | 25% 脉冲 0+140 A4→E3（τ50，1/60 s 阶梯）τ80；12.5% 脉冲高八度同步，增益 0.35 | 16k/8 | −13 | 148 ms |
| SHORT 录音太短 | 25% 脉冲 G4 +8va：0+22、36+22，τ20 | 11k/7 | −13 | 66 ms |
| ARMED 弦拉满 | 4-bit 三角 0+16 E7 τ8 | 22k/8 | −22 | 24 ms |
| RETURN 1/2/3 下拉发射 | 踢鼓(170/190/210→45, 55/65/75)；爆破：噪声(4 kHz 时钟) 0+30 增益 0.8 τ10；呼啸：噪声时钟 1.5 kHz → 8/10/12 kHz（τ28/24/20，1/240 s 阶梯），10+90/130/170，起音 12 ms，增益 0.6，τ = 0.45×长；重量：50% 方波 A3 → 70 Hz（τ = 1.5×呼啸 τ，1/120 s 半音阶梯），同长，增益 0.45；低通 5 kHz → 700 Hz | 16k/7 | −8.5 / −7 / −5.5 | 108 / 148 / 188 ms |
| DEL 删除一字 | 12.5% 脉冲 0+22 D6 τ9；噪声(8 kHz) 0+6 增益 0.3 τ2 | 16k/8 | −17 | 30 ms |
| CLEAR 清空 | 12.5% 脉冲 0+90 E6 → A3（τ18，1/240 s 半音阶梯）增益 0.7 τ45；噪声时钟 12 kHz → 3 kHz（τ40）0+100 增益 0.5 τ35；不带踢鼓 | 11k/7 | −12 | 108 ms |
| TEXT 识别完成 | 50% 方波 0+30 A5 τ25；45+60 A6 τ40；回声 0.28 | 22k/8 | −14 | 193 ms |
| POLISH 润色完成 | 25% 脉冲 0+120 E5 琶音 [0, 4, 7, 12] 每 1/60 s 轮换；50% 方波 125+70 E6 τ40；回声 0.22 | 22k/8 | −12 | 283 ms |
| COPY 复制 | 4-bit 三角 C7：0+15、40+15，τ8 | 22k/8 | −18 | 63 ms |
| LINK 连接成功 | 三角 + 12.5% 脉冲(0.35)：0+50 A4 τ45；55+80 E5 τ50；回声 0.18 | 16k/8 | −13 | 223 ms |
| LOST 连接断开 | 三角 + 12.5% 脉冲(0.35)：0+50 E5 τ45；55+100 A4 τ60；回声 0.12 | 16k/8 | −14 | 243 ms |
| PAIR? 需要配对 | 4-bit 三角 E6：0、60、120 各 20 ms，τ15 | 16k/8 | −15 | 148 ms |
| PAIRED 配对成功 | 4-bit 三角 0+112 A5 琶音 [0, 7] 每 28 ms 轮换；115+90 A6 τ60；回声 0.20 | 16k/8 | −13 | 293 ms |
| DENIED 配对失败 | 50% 方波 +8va：0+50 F4 τ40；60+70 E4 τ50 | 11k/6 | −12 | 138 ms |
| WARN 提示 | 50% 方波 D4 +8va：0、30、60 各 20 ms，τ18 | 11k/6 | −13 | 88 ms |
| ERROR 出错 | 50% 方波双音 B♭3+B3 +8va：0+70、90+90，τ55 | 11k/6 | −11 | 188 ms |

生成方式：`SoundSynth.render` 是一个确定性合成器（LFSR 噪声固定初值），以 44.1 kHz 采样输出单声道 16-bit PCM WAV。降采样与降位深在合成链内部完成，最终容器仍是 44.1 kHz / 16-bit。文件写入 `Library/Caches/iMicSounds-v<renderVersion>/`；修改任何参数时必须递增 `SoundSynth.renderVersion`。仓库里不存放任何音频文件。

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
