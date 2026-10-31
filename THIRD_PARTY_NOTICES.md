# 第三方与来源说明

## Brick Mic

iMic 的 Mac 端在 Brick Mic（GPL-3.0）基础上改造，复用了百炼 ASR、凭据读取、辅助功能权限引导与 Unicode 键盘输入实现。Brick Mic 原作者与项目地址：

- https://github.com/Drafffffff/brick-mic

原项目的完整许可证见 `LICENSE`。

## Apple 框架

Mac 端使用 AppKit、Network、CryptoKit、ApplicationServices；iOS 端使用 SwiftUI、Network、CryptoKit、AVFoundation、Security。这些框架随操作系统提供，不单独再分发。

## Phosphor Icons

应用图标使用 Phosphor Icons 的 `microphone-fill`，经 Iconify 取得：

- https://phosphoricons.com
- MIT License，完整文本见 `licenses/PHOSPHOR-LICENSE.txt`

## 字体

没有内置第三方字体。像素标题由 `shared` 之外的 `ios/iMic/PixelFont.swift` 以 5×7 字模绘制；正文使用系统字体。

## Sparkle 2.10.1

Mac 自动更新使用 [Sparkle](https://sparkle-project.org/)，MIT 许可。
完整版权与许可声明见 `licenses/SPARKLE-LICENSE.txt`，随 App 的 Legal 目录分发。
官方二进制仅在构建时下载并校验 SHA-256，不入仓库。
