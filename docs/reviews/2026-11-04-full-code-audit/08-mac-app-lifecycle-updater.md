# Mac App 生命周期、设置与自动更新 审计

## 范围与方法

审阅了指定九个文件的相关实现，并追踪 `SettingsField.swift`、`SettingsValidation.swift`、`SingleInstance.swift`、`PairingStore.swift`、配置读取及发布打包路径。使用 `rg`、`nl`、`cat` 核对调用关系、守卫、测试及文档中的已知限制。

按要求尝试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/imic-audit-mac-lifecycle
```

沙箱禁止编译器写入 `/tmp` 缓存，测试在编译前失败。以下发现基于静态代码证据，未进行运行时复现。未修改仓库、访问网络、调用真实 API 或执行安装及签名操作。

## 发现

### [P1] 自定义服务首次配置存在循环依赖，无法通过界面保存

- 位置：[mac/SettingsWindow.swift:466](../../../mac/SettingsWindow.swift:466)、[mac/DeepSeek.swift:26](../../../mac/DeepSeek.swift:26)、[mac/DeepSeek.swift:126](../../../mac/DeepSeek.swift:126)
- 证据：保存时只有当前字段使用草稿，其余字段使用已保存值；自定义服务的默认模型和地址均为空，而验证要求模型、地址和 Key 同时有效。关闭窗口后的顺序保存仍调用同一逻辑。
- 触发条件：没有保存过自定义服务配置，在高级页填入有效 Key、模型和地址，分别点击“验证并保存”，或关闭窗口后选择保存。
- 后果：保存 Key 时缺模型；保存模型时缺地址；保存地址时缺模型。所有保存顺序均失败，自定义服务无法完成首次配置。
- 建议修复：以服务为单位收集三个字段的草稿，验证同一份配置快照，成功后统一保存；保留异步代际及配置变化检查。
- 置信度：高。

### [P2] 已完成用户重开向导后，启动策略跳过向导，但更新持续被阻塞

- 位置：[mac/Onboarding.swift:81](../../../mac/Onboarding.swift:81)、[mac/Onboarding.swift:266](../../../mac/Onboarding.swift:266)、[mac/Updater.swift:139](../../../mac/Updater.swift:139)
- 证据：重开向导会写入 `setup.inProgressStep`；启动策略先判断 `completedVersion`，已完成用户直接 `.skip`；更新门控则无条件要求未完成标记为空。关闭向导不会清除标记。
- 触发条件：完成过首次设置的用户重新打开向导，未点击完成便退出，随后重启应用。
- 后果：向导不自动恢复，自动及手动更新却一直等待未完成状态；必须再次主动打开向导并完成才能恢复。该行为与开发文档所述“重新打开后向导会回到这一步”不符。
- 建议修复：让有效的 `inProgress` 状态优先于历史完成版本，或在明确跳过重开流程时清除标记；增加“完成→重开→中断→重启→检查更新”的组合回归。
- 置信度：高。

### [P2] 退出应用绕过设置草稿的保存确认

- 位置：[mac/main.swift:1504](../../../mac/main.swift:1504)、[mac/SettingsWindow.swift:680](../../../mac/SettingsWindow.swift:680)
- 证据：草稿检查仅在 `windowShouldClose` 中执行；菜单退出直接调用 `NSApp.terminate(nil)`，未实现 `applicationShouldTerminate` 来协调草稿保存。
- 触发条件：修改模型、服务地址等尚未保存的字段，直接选择“Quit iMic”或按 Command-Q。
- 后果：应用退出，内存中的草稿丢失，绕过关闭设置窗口时提供的“保存／放弃／取消”保护。
- 建议修复：将草稿确认抽成协调方法，由窗口关闭和 `applicationShouldTerminate` 共用；异步验证时使用 `.terminateLater`，确认退出后再停止链路。
- 置信度：高。

### [P2] 第二实例发送的重开通知没有注册接收者

- 位置：[mac/main.swift:150](../../../mac/main.swift:150)、[mac/main.swift:1731](../../../mac/main.swift:1731)
- 证据：第二实例发送分布式通知后退出；仓库中未找到对应 `DistributedNotificationCenter` 观察者注册，`reopenFromAnotherInstance` 也没有其他调用点。
- 触发条件：已有正常实例运行，再直接执行另一个 iMic 可执行文件，并传入 `--show-permissions`。
- 后果：第二实例以成功状态退出，但第一实例不会执行通知处理中的 `show()`、`permissions()`，权限引导请求被丢弃。普通 Launch Services 重开回调不能接收该通知携带的参数。
- 建议修复：持锁实例进入事件循环前注册对应通知，按当前 PID 过滤 `object`，退出时移除观察者。
- 置信度：高。

### [P2] 设置页重新生成配对码后，仍显示旧码

- 位置：[mac/SettingsWindow.swift:284](../../../mac/SettingsWindow.swift:284)、[mac/SettingsWindow.swift:630](../../../mac/SettingsWindow.swift:630)、[mac/main.swift:1284](../../../mac/main.swift:1284)
- 证据：设置页配对码只在创建或点击显示按钮时赋值；虽定义了 `refreshPairCode()`，却没有调用者。“重新生成”更新存储并调用 `refreshUI()`，该方法不刷新设置页配对码。
- 触发条件：在设置的 iPhone 页显示配对码，再点击“重新生成”，产生不同的新码。
- 后果：界面仍展示已失效的旧码。用户照着输入会配对失败，反复尝试还会计入错误次数；“复制配对码”取得的却是新码，两个入口不一致。
- 建议修复：将 `refreshPairCode()` 接入统一 UI 刷新和设置窗口展示路径，覆盖手动换码及其他配对状态变化。
- 置信度：高。

## 已检查且未发现问题的方面

- **更新来源与 DEBUG 隔离**：Release 的 feed 固定为 HTTPS；本地 HTTP feed、忙碌标记和更新测试入口受 `#if DEBUG` 限制，测试公钥及构建号覆盖也仅在 debug 分支读取。
- **更新校验与签名链**：检查了 EdDSA 公钥长度、解压前验证、Sparkle 下载包固定 SHA-256、逐层签名，以及正式打包路径的 hardened runtime、时间戳和团队检查，未发现绕过路径。
- **输入忙碌门控**：录音、识别、润色、输入、清除及特效均进入更新空闲判断；延迟重启会重新检查空闲，停止链路后以串行队列屏障确认。
- **常见异步覆盖风险**：设置验证包含字段代际、当前值及运行配置快照检查；失败不覆盖已保存配置，关闭窗口会取消验证任务。
- **资源所有权**：相关 Timer 和主要回调使用弱引用；更新 Timer 有失效清理，设置观察者在析构时移除，未发现明显的新增窗口强引用环。
- **验证边界**：睡眠唤醒及 Sparkle 实际替换重启未做动态验证；未将缺少专用睡眠观察者本身作为缺陷。