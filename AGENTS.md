# iMic 开发约定

## 修改协议

`shared/iMicLink.swift` 是 Mac 与 iPhone 的唯一协议源。改动必须同时更新：

1. `shared/iMicLink.swift`
2. `tests/iMicLinkTests/LinkTests.swift`
3. `docs/PROTOCOL.md`
4. Mac `LinkServer.swift` 与 iPhone `LinkClient.swift`

帧格式、密钥派生、配对码规则不可为了调试放宽。加密帧必须继续使用 AES-GCM combined 格式并逐帧随机 nonce。

## 验证

```bash
# 协议
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Mac
./scripts/build-mac.sh
./scripts/install-mac.sh

# iOS
./scripts/build-ios.sh
./scripts/build-ios.sh --run

# Mac + 百炼 + 联调客户端（真实识别）
./scripts/test-link.sh
```

iOS 界面状态可直接预览，不需要真实链路：

```bash
xcrun simctl launch booted com.drafffffff.imic --ui-preview=idle
xcrun simctl launch booted com.drafffffff.imic --ui-preview=result
xcrun simctl launch booted com.drafffffff.imic --ui-preview=pairing
```

模拟器没有可用输入设备时，`--debug-tts=` 会用系统语音合成走同一条分帧/加密/识别路径：

```bash
xcrun simctl launch booted com.drafffffff.imic \
  --debug-host=127.0.0.1 --debug-port=47832 \
  --debug-pair-code=123456 \
  --debug-tts=把今天讨论的交互细节整理成一页说明
```

`--debug-*` 参数只在 `DEBUG` 构建生效。发布构建不得依赖它们。

## 权限与输入

- 自动输入只使用辅助功能授权，不修改 TCC，不自动批准权限。
- 录音开始时记录前台应用；识别结束时若前台变化，不输入，保留文字。
- 普通模式不要求可读取的 AX 输入框；直接投递 Unicode 键盘事件。
- 实时预览开启时允许将临时文字输入目标应用，不全选、不设置整框 AXValue。范围接口可靠的目标只修订已验证的本轮范围；用户已明确授权对 Otty、缺少范围接口或范围持续不同步的目标使用键盘兼容模式，按本轮已投递文字计算变化尾部，不依赖 AX 光标确认。兼容模式必须有手动按键/点击及应用切换监视，用户接管后冻结本轮，不能在最终回写时绕过。兼容模式无法独立验证目标程序自行改稿或丢弃按键，存在重复或误删风险，文档须说明。没有可用接管监视且无法核验范围的目标只投递最终结果。

## 品牌与版本

- `VERSION`、Mac `Info.plist`、iOS `MARKETING_VERSION` 使用同一版本号。
- 图标由 `tools/icon.swift` 生成，Mac 与 iOS 共用同一套像素麦克风。
- 界面语言：技术标签用英文像素字，操作说明用简体中文。
- 橙色只用于状态、交互与强调，不铺大面积背景。
