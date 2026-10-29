# 任务书：iOS Bundle ID 迁移到 `art.malette.imic`

日期：2026-10-29
仓库：`/Users/drafff/Desktop/iMic`，分支 `codex/ui-phosphor-wireframe`
执行者：Codex
请先完整阅读本文件和仓库根目录的 `AGENTS.md`，再动手。

---

## 1. 背景

- iPhone 端要通过 TestFlight 分发，发布团队是 **KE CHENG / `5H39F98ND4`**。
- Apple 拒绝在该团队注册 `com.drafffffff.imic`（提示 "An App ID with identifier 'com.drafffffff.imic' is not available"），这个 ID 被旧的 Personal Team（`S889TFV5A4`）占用了。
- iMic 还没在 App Store 上架，所以决定 **只把 iOS 端的 Bundle ID 改为 `art.malette.imic`**。
- 在 Apple 后台注册 App ID、生成 App Store 描述文件、创建 App Store Connect 记录，由另一个助手和用户完成。**这些不属于本任务。** 本任务只改仓库。

## 2. 目标

1. iOS 主 App 的 Bundle ID 改为 `art.malette.imic`，UI 测试改为 `art.malette.imic.uitests`。
2. 所有 iOS 相关的脚本、工具、文档都同步改用新 ID，可以直接用于 TestFlight 归档和校验。
3. **Mac 端完全不变**，仍然是 `com.drafffffff.imic`。
4. 构建、测试、模拟器启动都要验证通过，最后单独提交一次。

## 3. 硬性约束（不得违反）

- **不得修改 Mac 端的 Bundle ID 或签名标识。** Mac 用 Developer ID 签名并公证后分发，不需要在 Apple 后台注册 App ID。改动 Mac 端会让用户已授予的辅助功能和屏幕录制授权失效，已发布的公证包也会对不上。
- **不得修改协议。** `shared/iMicLink.swift`、`docs/PROTOCOL.md`、`tests/iMicLinkTests/LinkTests.swift`、`mac/LinkServer.swift` 里的帧格式、密钥派生、配对码规则都不要动。Bundle ID 不属于协议内容。
- **不要修改内部标识字符串**，它们只是命名空间，和签名、上架无关，改了反而会引入兼容问题（详见第 5 节）：
  - `ios/iMic/LinkClient.swift:1472` 的 `Keychain.service = "com.drafffffff.imic.link"`
  - `shared/IMicLog.swift:11` 的日志 subsystem `"com.drafffffff.imic"`（Mac 和 iOS 共用）
  - `ios/iMic/IMicAudioInputBridge.m:86` 的错误 domain `"com.drafffffff.imic.audio-input"`
  - `mac/main.swift:1805` 的通知名 `com.drafffffff.imic.reopen.*`
- 不登录、不访问 Apple Developer 或 App Store Connect 后台，不创建证书或描述文件，不输入任何密码。
- 不修改 `VERSION`、`MARKETING_VERSION`（`1.4.3`）和 `CURRENT_PROJECT_VERSION`（`2`）。这是一个新的 App 记录，Build 2 可以直接使用。
- 不修改已发布的历史发布说明 `docs/releases/v1.4.3.md`。
- 不提交 `.claude/` 目录；不提交 `build/`、`.build/`、`__pycache__` 里的产物。
- `--debug-*` 参数只在 DEBUG 构建里生效，不要改变这一点。

## 4. 需要修改的文件

完成后，在仓库里搜 `com.drafffffff.imic`，结果应该**只剩**第 5 节列出的保留项。

### 4.1 Xcode 工程（核心）

| 文件 | 行 | 改为 |
|---|---|---|
| `ios/project.yml` | 34 | `PRODUCT_BUNDLE_IDENTIFIER: art.malette.imic` |
| `ios/project.yml` | 61 | `PRODUCT_BUNDLE_IDENTIFIER: art.malette.imic.uitests` |
| `ios/iMic.xcodeproj/project.pbxproj` | 429、600 | `art.malette.imic` |
| `ios/iMic.xcodeproj/project.pbxproj` | 450、621 | `art.malette.imic.uitests` |

`project.pbxproj` 是 XcodeGen 生成的。改完 `project.yml` 后，在 `ios/` 目录里运行 `xcodegen generate` 重新生成，**不要手改 pbxproj**。生成后检查 diff：除了 Bundle ID 这 4 行，不应该有其他无关变化。如果 XcodeGen 版本不同导致大量重排，要在汇报里说明。

### 4.2 TestFlight 工具

| 文件 | 位置 | 改法 |
|---|---|---|
| `tools/validate-testflight.py` | 32 行 | `CFBundleIdentifier` 期望值改为 `art.malette.imic` |
| `tools/testflight-export-options.py` | 29 行 | `bundle_id = "art.malette.imic"` |

建议：在这两个脚本里各定义一个常量 `BUNDLE_ID = "art.malette.imic"`，放在 import 之后，然后引用它，不要在逻辑里写死字符串。`testflight-export-options.py` 会用这个值去核对描述文件里的 `application-identifier` 后缀，并写入 `provisioningProfiles` 的键，所以必须和 Apple 后台注册的 ID 完全一致。

`ios/TestFlightExportOptions.plist` 里没有 Bundle ID，不用改。`scripts/testflight.sh` 本身没有写死 Bundle ID，不用改。

### 4.3 iOS 脚本

| 文件 | 行 | 改法 |
|---|---|---|
| `scripts/build-ios.sh` | 39 | `xcrun simctl launch "$DEVICE" art.malette.imic` |
| `scripts/install-ios-device.sh` | 6 | `BUNDLE_ID=${IMIC_BUNDLE_ID:-art.malette.imic}` |
| `scripts/pull-ios-log.sh` | 6 | `BUNDLE_ID=${IMIC_BUNDLE_ID:-art.malette.imic}` |
| `scripts/test-ios-standby.sh` | 12、17 | `get_app_container` 和 `launch` 中的 ID 改为 `art.malette.imic` |
| `scripts/test-link.sh` | 48 | `xcrun simctl terminate booted art.malette.imic`（这一行终止的是模拟器里的 iOS App） |

`install-ios-device.sh` 和 `pull-ios-log.sh` 已经支持用 `IMIC_BUNDLE_ID` 覆盖，保留这个机制，只改默认值。

### 4.4 文档

| 文件 | 位置 | 改法 |
|---|---|---|
| `AGENTS.md` | 35–37、43 行 | 4 处 `simctl launch booted com.drafffffff.imic` 改为 `art.malette.imic` |
| `README.md` | 156、159 行 | iOS 模拟器的 `simctl launch` 命令改为新 ID |
| `README.md` | 59 行 | **不改**。`defaults delete com.drafffffff.imic` 清的是 Mac 端偏好 |
| `docs/TESTFLIGHT.md` | 11 行表格 | Bundle ID 改为 `art.malette.imic` |
| `docs/TESTFLIGHT.md` | 表格下方那段"旧真机开发包属于 `S889TFV5A4`……" | 改写为：iOS 端 Bundle ID 已从 `com.drafffffff.imic` 改为 `art.malette.imic`（原因：旧 ID 被 Personal Team `S889TFV5A4` 占用，无法在 `5H39F98ND4` 注册）；Mac 端仍为 `com.drafffffff.imic`；新 App 会和旧开发包并存，需要在新 App 中重新配对 Mac，旧 App 可手动删除 |
| `docs/TESTFLIGHT-TEAM-REQUEST.md` | 18、47、63 行 | 都改为 `art.malette.imic` |
| `docs/TESTFLIGHT-HANDOFF.md` | 17、23、48 行 | 改为新 ID。23 行"如果系统提示被占用，先确认归属，不要直接改成随机 ID"改写为：已确认 `com.drafffffff.imic` 被旧 Personal Team 占用，改用 `art.malette.imic`；如果新 ID 也被占用，停下来报告，不要自行换 ID |
| `docs/TESTFLIGHT-QUICKSTART.md` | 全文 | 搜一遍，如果有旧 ID 就改；如果测试者需要知道"要删旧 App、重新配对"，补一句 |

文档语言规则沿用 AGENTS.md：操作说明用简体中文。

## 5. 保留不改的项（以及原因）

全部改完后搜索 `com.drafffffff.imic`，**只应剩下这些**：

| 位置 | 原因 |
|---|---|
| `mac/main.swift:1805, 1816` | Mac 端通知名和 Mac 自身 Bundle ID 检查 |
| `scripts/build-mac.sh:83, 114` | Mac 的 Info.plist 和签名标识 |
| `scripts/install-mac.sh:37` | 安装前校验 Mac 的 Bundle ID |
| `scripts/package-release.sh:48` | Mac 发布签名标识 |
| `scripts/test-polish-apps.sh:29, 40` | Mac 自测 App，必须和正式 Mac App 同 ID 才能共用辅助功能授权 |
| `shared/IMicLog.swift:11` | 日志 subsystem，Mac 和 iOS 共用，用来按名过滤日志 |
| `ios/iMic/LinkClient.swift:1472` | 钥匙串服务名。钥匙串条目本来就按团队前缀加 Bundle ID 隔离，新 App 读不到旧 App 的条目，和这个字符串无关；保持不变，避免以后再次迁移时多一个变量 |
| `ios/iMic/IMicAudioInputBridge.m:86` | NSError domain，只用于日志 |
| `README.md:59` | Mac 偏好清理命令 |
| `docs/releases/v1.4.3.md:25` | 已发布的历史说明 |

## 6. 已知影响（写进文档，不需要写代码处理）

- iPhone 上，`art.malette.imic` 和旧的 `com.drafffffff.imic` 开发包是两个不同的 App，会同时存在。
- 新 App 的钥匙串和 `UserDefaults`（`imic.deviceID`、`imic.preferredMacID`、`imic.macNames`）都是空的，所以会生成新的 deviceID，需要输入配对码和 Mac 重新配对。Mac 端会保留旧设备的配对记录，不影响使用。
- **不要写任何从旧 App 迁移数据的代码**：不同 Bundle ID 之间没有共享容器，也没有 App Group，做不到，也不需要做。

## 7. 验证步骤（全部执行，把输出摘要写进汇报）

```bash
# 0. 残留检查：结果应只剩第 5 节的保留项
grep -rn "com\.drafffffff\.imic" --exclude-dir=build --exclude-dir=.build --exclude-dir=.git --exclude-dir=__pycache__ .

# 1. 协议测试（协议没改，应该全绿）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# 2. iOS 模拟器构建并启动
./scripts/build-ios.sh
./scripts/build-ios.sh --run

# 3. 确认产物里的 Bundle ID
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/ios.noindex/Build/Products/Debug-iphonesimulator/iMic.app/Info.plist
# 期望：art.malette.imic

# 4. 用新 ID 启动 UI 预览，三个状态都能起来、不崩溃
xcrun simctl launch --terminate-running-process booted art.malette.imic --ui-preview=idle
xcrun simctl launch --terminate-running-process booted art.malette.imic --ui-preview=result
xcrun simctl launch --terminate-running-process booted art.malette.imic --ui-preview=pairing

# 5. TestFlight 未签名归档 + 校验（不需要账号）
#    如果 build/testflight.noindex/1.4.3-2/ 已存在，先用 IMIC_TESTFLIGHT_DIR 指定一个新目录，不要删除旧归档
IMIC_TESTFLIGHT_DIR=build/testflight-bundleid.noindex ./scripts/testflight.sh archive-unsigned
IMIC_TESTFLIGHT_DIR=build/testflight-bundleid.noindex ./scripts/testflight.sh check
# 期望：validate-testflight.py 不再报 "Bundle ID 不一致"。未签名归档可能在签名相关检查上失败，这属于预期，需在汇报里如实说明哪些检查通过、哪些失败

# 6. Python 工具语法检查
python3 -m py_compile tools/validate-testflight.py tools/testflight-export-options.py

# 7. Mac 端没有被波及
./scripts/build-mac.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/mac.noindex/iMic.app/Contents/Info.plist
# 期望：com.drafffffff.imic
# 不要运行 install-mac.sh：用户本机装的是公证版，覆盖会换掉签名，导致需要重新授权
```

如果模拟器里同时装着旧 ID 的 App，可以先 `xcrun simctl uninstall booted com.drafffffff.imic`，只在模拟器里执行，不要动真机。

## 8. 提交

- 只提交本任务涉及的文件，用一次提交。提交说明用简体中文，例如：

  ```
  iOS Bundle ID 改为 art.malette.imic

  旧 ID com.drafffffff.imic 被旧 Personal Team 占用，无法在 KE CHENG
  (5H39F98ND4) 注册。Mac 端保持 com.drafffffff.imic；钥匙串服务名、
  日志 subsystem 等内部标识不变。新 App 需重新配对 Mac。
  ```

- 本任务书 `docs/tasks/2026-10-29-ios-bundle-id-migration.md` 一起提交。
- **不要 push**，等用户确认后再推。
- 提交前用 `git status` 确认工作区里没有夹带无关改动。如果有用户自己的未提交改动，不要碰，也不要提交。

## 9. 遇到以下情况时停下来报告，不要自行处理

- XcodeGen 重新生成的 pbxproj 出现大量无关差异。
- 发现第 4、5 节都没列到的 `com.drafffffff.imic` 用法，而且不确定它属于 Mac 还是 iOS。
- 有 entitlements 文件或能力配置（App Groups、iCloud、Push、Associated Domains）引用了 Bundle ID。目前仓库里 iOS 端没有 entitlements 文件，如果发现了，要报告。
- 任何一步验证失败，而原因和 Bundle ID 无关（例如原本就存在的编译错误）。

## 10. 交付汇报格式

1. 修改的文件清单，每个文件一句话说明。
2. 第 0 步残留检查的完整输出。
3. 第 1–7 步每步的结果（通过、失败加原因）。
4. 提交哈希。
5. 需要用户或负责 Apple 后台的助手后续处理的事项，至少包括：在 `5H39F98ND4` 注册 `art.malette.imic` 显式 App ID；生成 App Store 描述文件；创建 App Store Connect 记录（SKU `imic-ios`）；然后运行 `./scripts/testflight.sh archive` 或用 `IMIC_PROFILE_PATH=… ./scripts/testflight.sh export` 做真实签名导出。
