# iPhone 同端口路由变化误取消录音

基础提交 `6c9f7b5`，分支 `codex/ios-route-false-change`。仅在本任务指定的 `/Users/drafff/.codex/worktrees/ios-route-false-change/iMic` 工作。

## 根因与核实范围

用户报告：已发布的 1.4.6 TestFlight 录音中频繁提示“麦克风输入设备已变化，请重新按住录音”，取消本轮。

**源码已核实**：`AVMicHardware.inputIdentity` 把当前输入端口 UID、portType 与 `session.sampleRate`、`session.inputNumberOfChannels` 拼成同一个字符串；控制器在路由通知及前台检查时比较它和启动时的快照。同一麦克风只要会话从 48 kHz / 1 声道变成 24 kHz / 3 声道，就会命中设备变化取消分支。旧注入测试还明确断言“仅采样率变化应取消”，因此未发现这个回归。另一个已确认的问题是当前引擎的配置变化通知无条件取消本轮，不检查引擎是否仍正常。

**注入测试已复现并验证修复**：VPIO 开/关、八种路由原因、同一端口 48k→24k / 1→3 声道，均继续使用同一引擎、保留回调、不取消、不消耗恢复预算；真正切换到蓝牙输入仍取消。测试直接向生产控制器注入端口与格式数据，身份集合由生产控制器计算，测试后端不再另造身份字符串。

Claude 关于 VPIO/音效触发具体系统重配置时机的判断与代码缺陷相符，但本环境没有使用真机重现具体通知序列，不把 iOS 27 的特定触发规律当作已证实的系统根因。[Apple 路由原因文档](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason)区分 categoryChange、override、routeConfigurationChange 等原因，通知本身不等于换了麦克风；oldDeviceUnavailable 也可能只描述输出路径丢失。[Apple 引擎配置通知文档](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)说明硬件格式变化可能令引擎停止、需要重建连接，因此处理依据改为实际引擎/格式状态。

## 改动

- 删除含格式元数据的硬件身份字符串；控制器保存 **`Set<(uid, portType)>`**。端口顺序、重复描述、显示名称、采样率和声道均不参与设备身份比较。前台检查也采用同一集合。
- 输入集合不变且路由有效时，所有路由原因均只记录日志、更新诊断并继续采集，包含 categoryChange、override、routeConfigurationChange。路由通知不据此重启引擎、不重置静音计时，也不重置已用恢复预算。
- 真正的 UID/type 集合切换仍按原有规则结束本轮。oldDeviceUnavailable 若丢失了本轮正在使用的输入，则在按住/自检期间使用现有单次预算恢复；即使系统已切回一个有效的内置输入，也会重建引擎并更新输入快照。借助 previousRoute.inputs 核对旧端口，避免把无关旧设备归到当前采集；单纯输出断开且输入未变不会恢复或取消。
- 保留 #27 的空路由、悬空端口、availableInputs 无法核验等恢复检查；空闲热窗口遇到失效路由仍释放，不无人值守激活。
- AVAudioEngineConfigurationChange 仅处理来自当前引擎的通知；健康运行、当前图格式可用时继续录音。真正停止或格式不可用时，停止/丢弃旧引擎，沿用既有恢复路径重建、重新配置当前 VPIO 设置、等待新输入电平。只在仍按住或 MIC TEST 中恢复；坏掉的空闲热引擎只释放。
- 新增的格式健康检查读取输入节点当前 `outputFormat` 是否具有正采样率/声道，不使用可变的会话提示字段判断图是否坏掉。电平报告也会发现停止/格式不可用的引擎，避免配置通知延迟时直接取消。
- 配置恢复与无效路由、静音、VPIO 兜底和手动恢复共用原来的 **一次预算**。第二次真实故障或重建失败才终止，不循环。旧引擎配置/失败/电平回调继续受对象与代际过滤；中断/媒体服务重置仍按 #23 结束旧录音，不自动恢复旧请求。
- 日志增加 route reason、previousInputs、会话采样率/输入声道、采集格式及引擎状态。MIC TEST 分别显示 `SESSION FORMAT`、`CAPTURE FORMAT`；复制保留原有字段并增加 `sessionChannels`。技术标签保持英文，原有中英文操作提示不变，不含音频数据。

改动集中于 AudioCapture.swift、AudioCaptureController.swift、MicrophoneTestView.swift、注入测试及发布/交接文档。**SessionModel.swift、协议、Mac、版本号和构建号均未改动。**

## 测试结果

仅运行用户指定的四项检查，没有运行全量 UI、standby、polish 或链路联调。

| 检查 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | PASS，74 tests，0 failures |
| `./scripts/test-ios-audio.sh` | PASS，277 条断言，包含旧生命周期/路由/VPIO 覆盖及本次回归 |
| `IMIC_SIM_DESTINATION='platform=iOS Simulator,id=A9A7C3CF-0679-4C66-857A-5A25DB33C08E' ./scripts/build-ios.sh` | PASS，iphonesimulator，CODE_SIGNING_ALLOWED=NO |
| `python3 tools/check-l10n.py` | PASS，双语键、占位符、生成资源和中文常量检查 |

本次创建的专用模拟器：`iMic Route False Change QA 20261103`，iPhone 16 Pro / iOS 27.0，UDID `A9A7C3CF-0679-4C66-857A-5A25DB33C08E`。只用作构建目标，没有启动或安装 App；验证完成后已删除。没有构建、安装真机，也未使用签名发布 ID。

新增/调整覆盖：八种同端口路由原因 × VPIO 开/关、48k→24k 和 1→3 声道、有效图格式改变、真实 UID/type 切换、端口集合顺序/重名、旧输入丢失/仅输出丢失/迟到断开通知、配置停止与格式不可用、恢复失败、旧代回调、空闲热窗口、前台格式变化、路由通知风暴不延后静音检测/重置预算，以及配置恢复与各类原有恢复的预算互斥。

## 真机交接（Claude 改构建号 6 后验证）

1. VPIO 默认开，连续按住录音多次，触发正常开始/结束音效；即使日志出现同端口 categoryChange/override/routeConfigurationChange，录音和识别应继续，不出现输入设备变化误报。核对 48k→24k、1→3 声道仅在格式诊断中变化。
2. MIC TEST 观察同一麦克风的会话/采集格式、回调和电平；切换 VPIO 对照，同端口正常通知不消耗恢复次数。健康配置通知也不增加次数。
3. 内置麦切到蓝牙/有线输入时，真实输入变化仍按原有规则结束本轮；拔掉正在录音的输入设备时最多自动重建一次，单纯断开输出、输入未变时继续录音。
4. 真正引擎停止/格式不可用时，本轮最多恢复一次，恢复后有电平才能确认成功；再次失败明确结束。来电中断、媒体服务重置、退出前台后不会自动复活旧录音。

限制：本次是源码、注入测试与模拟器编译验证；未验证真实设备的通知频率、重建间隙和音质，仍需上述 TestFlight 真机复核。
