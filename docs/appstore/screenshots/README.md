# App Store 截图

`zh-Hans/`、`en/` 各 6 张，1320×2868（6.9 英寸）。画面来自真实 App，文案与排版由 `compose.py` 合成，配色与像素标签沿用官网（`site/assets/pixel/`）。

## 重新生成

1. 生成工程并构建测试包（模拟器 iPhone 17 Pro Max，深色模式，状态栏 9:41 满电）：
   `xcodegen generate`（在 `ios/` 下），然后对 `iMic` scheme 执行 `build-for-testing`，使用发布 Bundle ID 并禁用签名。
2. 静态画面：`xcrun simctl launch <sim> art.malette.imic.app --ui-preview=<settings|pairing|devices-manage|result>`，然后截图。
3. 动态画面：运行 `iMicUITests/DemoCaptureUITests/testScene`，环境变量 `TEST_RUNNER_IMIC_DEMO_SCENE=hero|string|polish`，同时用 `simctl io screenshot` 连续截图或 `simctl io recordVideo` 录屏，挑出 LISTEN、下拉琴弦、POLISH 三帧。
4. 把帧命名为 `<lang>-<scene>.png`（scene：listen、pull、polish、settings、devices-manage、pairing）放进同一目录，运行：

```bash
python3 docs/appstore/screenshots/compose.py <帧目录> docs/appstore/screenshots
```

切换模拟器语言：`xcrun simctl spawn <sim> defaults write -g AppleLanguages -array en`，然后重启模拟器。
