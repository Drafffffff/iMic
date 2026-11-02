# 下一版待同步的改动

- 官网修复 Retina / 页面缩放下 CRT 首屏标题放大裁切，统一特效尺寸，并在绘制尺寸异常时自动退回 CSS 辉光。

- 官网预留 Umami Cloud 无 Cookie 匿名访问统计（默认关闭），增加下载等事件、DNT/GPC 开关与中英文隐私说明；App 不做任何统计。

- iOS 发布 Bundle ID 改为 `art.malette.imic.app`；本地真机签名强制隔离到 `art.malette.imic.dev`，非发布团队请求发布 ID 时提前报错。更新 TestFlight 交接与未签名打包，Mac ID、协议及版本号不变。

- iPhone 新手引导改为真实主页上的轻提示：先离线练习按住、松手和下拉发送，再进入共用设备列表配对；可选练习删字、移光标、清空与取消。练习在 Release 中可用，不开麦、不请求录音权限、不连网。设置可重播，支持步骤恢复、中英文、动态字体、减少动态效果和 VoiceOver 跳过。
