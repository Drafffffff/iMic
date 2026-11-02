# 下一版待同步的改动

- Mac 百炼手动服务地址支持控制台「API 快捷接入」的 API Host、OpenAI 兼容地址和 DashScope 地址，兼容末尾斜杠与前后空白；沿用域名白名单、HTTPS/WSS、443 端口及套餐地址拦截。

- Mac 接受带 `. + / =` 的新格式百炼 Key（保持注入字符防护与 512 字节上限），修正格式提示与 `sk-ws-` 套餐误判；补齐标准编辑快捷键，向导和设置页的 Key 输入保持单行。

- 官网修复 Retina / 页面缩放下 CRT 首屏标题放大裁切，统一特效尺寸，并在绘制尺寸异常时自动退回 CSS 辉光。

- 官网预留 Umami Cloud 无 Cookie 匿名访问统计（默认关闭），增加下载等事件、DNT/GPC 开关与中英文隐私说明；App 不做任何统计。

- iOS 发布 Bundle ID 改为 `art.malette.imic.app`；本地真机签名强制隔离到 `art.malette.imic.dev`，非发布团队请求发布 ID 时提前报错。更新 TestFlight 交接与未签名打包，Mac ID、协议及版本号不变。

- 官网与 README 接入 TestFlight 公开测试链接。
