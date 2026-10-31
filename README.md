# iMic

[官网](https://drafffffff.github.io/iMic/) · [下载 Mac 版](https://drafffffff.github.io/iMic/#download) · [隐私说明](docs/PRIVACY.md) · [反馈](https://github.com/Drafffffff/iMic/issues)

按住说话，松手即输入。iPhone 当 Mac 的麦克风，说完松手，文字直接打进你正在用的任何应用。

## 亮点

- 按住说话，松手发射：文字落到 Mac 当前输入处。
- 弦手势：下拉发射回车、上拨删字、左右移光标，继续拉到顶部可请求清空；部分编辑器或终端无法确认清空，会提示失败。
- AI 润色：口语整理成书面文字，还支持 Agent 指令、终端命令、文言文、废话文学、翻译腔；完成时可用扫光提示（可关闭的测试功能，需要 macOS 14+，部分应用需屏幕录制权限）。
- 8-bit 音效，每个动作都有回应，也可以在声音设置中关闭。
- 任何能打字的 Mac 应用都可以试试，已测试 TextEdit、Safari、Chrome、Terminal、Cursor、Zed、iTerm、Otty；输入与扫光能力因应用而异。
- 直连自己的 Mac，Key 留在 Mac，iMic 没有自建服务器。

## 你需要准备

- 一台 Mac：macOS 13 或更高，Apple Silicon 和 Intel 都可以。
- 一部 iPhone：iOS 17 或更高。
- 一个[阿里云百炼 API Key](https://bailian.console.aliyun.com/?tab=model#/api-key)，识别和润色按量计费。
- Mac 和 iPhone 连接同一个 Wi-Fi。

## 安装教程

### 第一步：安装 Mac 版

1. 从[官网下载区](https://drafffffff.github.io/iMic/#download)或 [GitHub Releases](https://github.com/Drafffffff/iMic/releases/latest) 下载最新版本的 `iMic-<版本号>-macOS-universal.dmg`。
2. 打开 DMG，把 iMic 拖进「应用程序」。
3. 从「应用程序」打开 iMic。安装包已通过 Apple 公证，可以直接打开。
4. 按设置向导先填入百炼 API Key，再开启「辅助功能」权限：点「去开启」，在系统设置中打开 iMic 的开关，然后回到向导点「完成」。
5. 完成后，iMic 会常驻在菜单栏；点击菜单栏图标可打开 Mac 窗口。

### 第二步：安装 iPhone 版

TestFlight 公开测试即将开放，开放后请从[官网下载区](https://drafffffff.github.io/iMic/#download)获取链接。

高级用户也可下载 Releases 中未签名的 IPA，用 AltStore、Sideloadly 等工具自行签名安装。

### 第三步：配对

1. 打开 iPhone 上的 iMic，按引导操作，也可以先练习手势。
2. 在 iPhone 上选择你的 Mac，输入 Mac 窗口显示的 6 位配对码。
3. 配对完成后，以后打开就会自动连接；按引导允许麦克风权限，语音识别权限可按需选择。

### 第四步：开始输入

1. 在 Mac 上点进任意输入框。
2. 按住 iPhone 底部的橙色横条说话，松开后文字就会输入进去。上滑后松开可以取消。
3. 等待本次输入完成，下拉中间的弦再松开，相当于按回车；往上拨删除一个字；左右滑动移动光标。

## 常见问题

**iPhone 找不到 Mac？**
确认两端在同一 Wi-Fi，并在 Mac「系统设置 → 隐私与安全性 → 本地网络」允许 iMic。访客或公司网络可能禁止设备互访，可以在 Mac 设置里开启蓝牙兜底，速度会慢一些。

**辅助功能开关已打开，为什么没有效果？**
在系统设置的列表中选中 iMic，点「−」删除，再回到 iMic 点「去开启」，重新打开权限。

**文字为什么没有输入进去？**
识别完成时如果你已经切换到别的应用，iMic 不会自动输入，文字会保留供你复制；未开启辅助功能权限时，也可以先复制结果。

**实时预览会不会改错字？**
实时预览在新安装中默认开启，可在 Mac 设置中关闭「实时预览与逐字输入」；部分应用无法核实输入结果，可能出现重复或误删。你自己动了键盘或鼠标后，本轮就不再自动修改。

**要花多少钱？**
识别和润色按百炼的用量计费，具体价格与额度以阿里云官网及账号设置为准。

**语音会被上传吗？**
音频由你自己的 Mac 发给百炼识别，开启润色时文字会发给你选择的服务；iPhone 的实时文字预览也可能使用 Apple 在线服务。iMic 没有自己的服务器，详见[隐私说明](docs/PRIVACY.md)。

**如何卸载？**
退出 iMic，删除「应用程序」中的 iMic，以及 `~/Library/Application Support/iMic` 文件夹。

## 反馈与许可

发邮件至 [i0.0ia@qq.com](mailto:i0.0ia@qq.com)，或提交 [GitHub Issue](https://github.com/Drafffffff/iMic/issues)。请附版本和复现步骤，不要在公开反馈中贴 API Key。

开发者请看[开发文档](docs/DEVELOPMENT.md)。

许可：GPL-3.0。
