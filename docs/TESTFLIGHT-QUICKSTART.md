# iMic 测试版上手

你需要 iOS 17+ 的 iPhone、macOS 13+ 的 Mac，以及自己的阿里云百炼 API Key。识别需要联网并可能产生服务商费用。反馈邮箱：i0.0ia@qq.com。

## 安装与配对

1. 在 iPhone 安装 Apple 的 TestFlight，打开收到的 iMic 测试邀请链接，接受邀请并安装。邀请链接由发布者在 Beta 审核通过后提供。
2. 在 Mac 从 [iMic 官网下载区](https://drafffffff.github.io/iMic/?from=ios#download)（备用：[GitHub Releases](https://github.com/Drafffffff/iMic/releases/latest)） 下载 macOS universal DMG，把 iMic 拖到 Applications 并启动。
3. 按 Mac 设置向导开启辅助功能权限，填写并校验百炼 API Key。屏幕录制权限只用于润色扫光，可以跳过。
4. 将两台设备连到同一 Wi-Fi。iPhone 打开 iMic，允许麦克风和本地网络权限，选择自己的 Mac，输入 Mac 显示的六位配对码。语音识别权限用于 Apple Speech 临时预览，可选择拒绝。
5. 在 Mac 打开一份新的文本编辑文档，点击空白输入处。按住 iPhone 底部录音区域说一句话，松手等待结果。首次测试建议关闭文字润色，确认基础输入正常后再尝试。

## 使用注意

- 录音时保持目标应用在 Mac 前台。中途切换应用时，iMic 会保留文字，避免自动输入到新应用。
- 上滑取消正在进行的录音。编辑手势会操作 Mac 中的文字，请先在临时测试文档中尝试。
- 使用实时预览时，手动按键、点击或切换应用会使本轮自动修订停止。部分应用使用键盘兼容模式，应用自行改稿或丢弃按键时可能出现重复或误删。
- Apple Speech 预览可能使用 Apple 的在线服务。最终音频由 Mac 发到百炼；开启润色还会把识别文字发到选定服务。详见 [隐私说明](PRIVACY.md)。
- 找不到 Mac 时，先检查两端应用都在运行、本地网络权限已开启、Wi-Fi 允许设备互相访问，以及 VPN/防火墙设置；不要为了测试关闭整个系统安全保护。
- TestFlight 新 App（`art.malette.imic`）会与旧开发包并存。请在新 App 中重新配对 Mac；先复制旧 App 中需要保留的结果，再按需手动删除旧 App。
- 单个 TestFlight 构建有效期为 90 天，发布者会通过 TestFlight 提供后续更新。

## 反馈

请发送设备型号、iOS/macOS 版本、iMic 版本与构建号、复现步骤、发生时间和截图至 **i0.0ia@qq.com**。只有在排障需要且你检查过内容后，才分享诊断日志；不要发送 API Key、配对令牌或私人录音。
