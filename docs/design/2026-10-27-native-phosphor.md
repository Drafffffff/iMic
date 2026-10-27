# 原版 iOS 主界面：荧光与轻 CRT

> 此文保留第一版的实施记录。主界面显示现已由 [Metal 荧光显示管线](metal-display-pipeline.md) 替代；下文局部阴影方案只用于兼容路径，不能代表当前主界面实现。

本轮按已确认的原 UI 材质方向接入原生界面。保留像素字标、状态字、黑橙配色、刻度弦、切角录音条及现有录音与输入逻辑。

## 界面调整

- 删除波形下方的两行常驻手势说明。
- 删除录音条下方的「松开输入 · 上滑取消」。保留右侧 PCM 信息与识别结果入口，避免结果功能丢失。
- 网页原型同时移除手势区及其张力数值。原生页面原本没有这个数值。
- 弦的操作说明保留在辅助功能提示中；按住录音的辅助功能提示及取消确认继续有效。

## 显示实现

`Phosphor.metal` 提供 iOS 17 起可用的 stitchable color shader，按物理像素加入低强度扫描纹、RGB mask 和静态颗粒。输入与输出保持预乘 alpha，不对透明背景加不透明噪声。没有时间参数、反馈纹理或新增计时器。

`PhosphorDisplay.swift` 只修饰 SwiftUI 绘制的表面：背景网格、像素状态、波形 Canvas 与录音条视觉层。系统状态栏、中文正文、UIKit 触摸覆盖层与文字的独立 CAMetalLayer 不被捕获进 SwiftUI shader。

波形主体先合并为一个 Canvas layer，再叠加 1.5pt 与 5pt 两层弱光晕，避免为 44 个圆环分别创建滤镜。刻度与技术标签保留清晰描边；像素状态单独使用两层小范围阴影保留字模线芯。开启「降低透明度」时关闭新增材质及辉光；「减少动态效果」继续沿用原来的动画降级逻辑。

原频谱、解析弹簧、首次过中线触发、文字落点、接触亮弧、弹射轨迹、字形快门采样及真实输入时序未改动。继续由原有显示时钟驱动，40 秒保持、4 秒渐停、隐藏/后台暂停逻辑不增加新的保活源。

新 Metal 代码为本项目实现，未导入 RetroArch shader。API 参考：[Apple SwiftUI Shader](https://developer.apple.com/documentation/swiftui/shader)、[GraphicsContext shadow](https://developer.apple.com/documentation/swiftui/graphicscontext/filter/shadow(color:radius:x:y:blendmode:options:))。

## 验证记录

- Debug 模拟器及签名 Release 真机构建通过。
- 原生截图中两处说明已消失，系统时间、电量、网络标识正常显示。
- 原生 shader 成功编译运行，未出现 SwiftUI/Metal 不支持的层捕获警告。
- `scripts/test-receiver-flight.sh` 通过：密度预算、弹射物理、居中快门、GPU 曝光积分。
- `scripts/test-ios-standby.sh` 通过：40 秒保持、4 秒渐停、零待机回调、唤醒、减少动态效果、手势、文字与飞行、前后台可见性。
- 已安装到现有 iPhone 16 Pro（zhou）。命令行首次自动启动被 iOS 的安全校验拦截；已核验签名与描述文件有效，且与之前构建使用同一证书与描述文件。用户随后在手机手动打开，并确认可以正常运行。

模拟器截图：`build/phosphor-review/native-idle.png`。构建及测试日志位于 `/tmp/imic-native-phosphor-*`。
