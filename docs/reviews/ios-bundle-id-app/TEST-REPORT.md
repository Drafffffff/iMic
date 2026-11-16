# iOS Bundle ID 迁移测试报告

日期：2026-11-02。分支：`codex/ios-bundle-id-app`，基线：`3b67810`。

## 第 6 节命令

| 命令 | 结果 |
|---|---|
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | 74 tests，0 failures |
| `./scripts/build-ios.sh` | Debug / iOS Simulator，BUILD SUCCEEDED，签名禁用 |
| `./scripts/test-ios-mac-selection.sh` | 全部自动 Mac 选择检查通过 |
| `./scripts/test-ios-reconnect.sh` | 全部前台重连检查通过 |
| `./scripts/test-polish-link.sh` | 4 项加密链路润色设置检查通过 |
| `python3 tools/check-l10n.py` | 675 个应用 key、9 个 InfoPlist key 中英一致，0 个未审核中文硬编码 |
| `python3 tools/validate-testflight.py --help` | 成功退出 |
| `./scripts/testflight.sh archive-unsigned` / `check` | 未签名 Release 归档和内容校验通过 |
| `bash -n scripts/*.sh` | 通过 |
| `./scripts/test-ios-signing-guard.sh` | 两个真机入口保护测试通过，构建/设备命令调用数为 0 |
| Python 工具编译与 `git diff --check` | 通过 |

构建仍显示现有 LinkClient Swift 并发/捕获警告、AudioInputBridge 枚举运算警告和 AppIntents 元数据跳过提示；本次未修改这些文件，没有构建错误。

## 身份与保护证据

工程实际 `-showBuildSettings`（仅使用模拟器 SDK、`CODE_SIGNING_ALLOWED=NO`，没有构建到真机）：

| 覆盖 | App | iMicUITests |
|---|---|---|
| 默认 | `art.malette.imic.app` | `art.malette.imic.app.uitests` |
| `IMIC_BUNDLE_ID=art.malette.imic.dev` | `art.malette.imic.dev` | `art.malette.imic.dev.uitests` |

两个入口分别执行以下命令，均退出 1，只到保护报错为止：

```bash
IMIC_DEV_TEAM=S889TFV5A4 IMIC_BUNDLE_ID=art.malette.imic.app ./scripts/install-ios-device.sh --dry-run
IMIC_DEV_TEAM=S889TFV5A4 IMIC_BUNDLE_ID=art.malette.imic.app ./scripts/site-demo.sh --dry-run
```

```text
拒绝签名：团队 S889TFV5A4 不能使用发布 Bundle ID art.malette.imic.app（包括 .uitests 运行器）；自动签名会在个人/其他团队占用发布 ID。请使用 art.malette.imic.dev。 / Refusing signing: automatic signing would reserve the release ID in the wrong team; use art.malette.imic.dev.
```

保护测试另覆盖 `.app.uitests`、另一个非正式团队、有/无 `--dry-run`，所有构建/设备工具均替换成失败桩，验证保护早于任何工具调用。TestFlight 的 archive、archive-unsigned、export、upload、handoff 对错误团队全部提前退出。正式团队仅做 dry-run，未实际签名。

真实读取本机已有 Xcode 团队设置后，`./scripts/install-ios-device.sh --dry-run` 与 `./scripts/site-demo.sh --dry-run` 均输出：

```text
Team: S889TFV5A4
IMIC_BUNDLE_ID: art.malette.imic.dev
UI tests: art.malette.imic.dev.uitests
Dry run: no build, signing, device discovery or installation.
```

使用临时 Info.plist 检查归档验证器会拒绝 `.dev` 和任意其他 ID；分发配置工具拒绝非正式团队。均未读取描述文件或调用签名。

`git grep -n "art.malette.imic"` 完整结果附 PR。除 tasks/releases v*/reviews/research 历史记录外，引用属于正式、开发或保留的 Mac 演示采集 ID；脚本变量与工程派生值通过上述 build settings 验证。Mac 的 `com.drafffffff.imic`、共享日志子系统、Keychain service 标签没有变化；iOS 无共享 Keychain access group、App Group 或依赖 ID 的 URL scheme。

## 未签名归档

路径：`build/testflight.noindex/1.4.5-4/iMic.xcarchive`。

```json
{
  "version": "1.4.5",
  "build": "4",
  "bundleID": "art.malette.imic.app",
  "team": "5H39F98ND4",
  "signed": false,
  "distributionVerified": false,
  "privacyManifest": "passed",
  "releaseDebugEntrypoints": "absent",
  "platform": "IOS"
}
```

归档内 Info.plist 的 `CFBundleIdentifier` 为 `art.malette.imic.app`。交接 ZIP 通过 `testflight.sh handoff` 从已提交源码生成；路径、大小、SHA-256、内容清单与逐项清单校验结果附 PR。未签名校验不能替代正式签名导出和 TestFlight 真机验收。

## 模拟器启动证据与边界

只使用本次创建的 iPhone 17 Pro / iOS 27.0 专用模拟器，以 `--ui-preview=idle` 启动新 ID。首轮截图落在启动动画，重建第二台专用模拟器后取得稳定 READY 界面：[截图](ui-preview-idle.png)。两台均已关闭并删除：

- `C1C85106-E522-4602-AFDD-293F6E9C102E`
- `FA13BB14-2E65-46FB-8D19-9AF0BE4632DA`

没有使用其他模拟器，没有登录/注册 Apple 账号、App ID、描述文件或 App 记录，没有以物理设备为目标构建、安装或签名，没有上传 TestFlight。没有覆盖 `/Applications/iMic.app`，也没有改 Mac、协议、VERSION 或 MAC_BUILD。图标构建生成的无关本地变化已恢复。
