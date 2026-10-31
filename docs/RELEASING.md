# Mac 自动更新与发布

Mac 构建仍使用 `swiftc` 和命令行工具，不引入 Xcode 工程。更新框架固定为 Sparkle 2.10.1，来源与 SHA-256 在 `scripts/fetch-sparkle.sh` 开头；官方包校验后解压到被忽略的 `build/vendor/Sparkle/`。升级框架时同时更新版本、哈希和许可，并重新做本地更新测试。[Sparkle 官方集成文档](https://sparkle-project.org/documentation/)、[签名与可选 XPC 文档](https://sparkle-project.org/documentation/sandboxing/)。

## 发布者一次性操作清单

- [ ] 执行 `./scripts/fetch-sparkle.sh`。
- [ ] **由发布者本人**在自己的 Mac 上执行 `build/vendor/Sparkle/bin/generate_keys`。默认行为将更新签名私钥保存在登录钥匙串。开发和测试不执行此命令，不读取、导入、删除或替换发布者的更新密钥。
- [ ] 把输出的 base64 公钥写入 `mac/sparkle-public-key.txt`，替换占位值，提交这个**公钥**。`build-mac.sh` 将它写入 `SUPublicEDKey`。占位值会关闭开发构建中的自动检查与设置开关，手动检查会说明尚未配置，并让 `package-release.sh` 立即失败。
- [ ] 由发布者执行 `build/vendor/Sparkle/bin/generate_keys -x /安全的仓库外位置/imic-sparkle-private-key`，将备份保存在加密且有访问控制的位置；不要存进仓库、`site/`、公开云盘目录、PR、终端日志或聊天。恢复到另一台发布机器可由发布者使用 `generate_keys -f /安全位置/imic-sparkle-private-key`。遗失密钥时依照 Sparkle 官方密钥轮换说明操作，不同时更换 Developer ID 和 EdDSA 密钥。
- [ ] 确认发布身份是 `Developer ID Application: KE CHENG (5H39F98ND4)`，且具有私钥。设置 `IMIC_RELEASE_IDENTITY` 和已经由发布者配置的 `IMIC_NOTARY_PROFILE`。自动更新发布要求 Developer ID 和公证，不能用 Apple Development 或 ad-hoc 代替。
- [ ] 首次签名发行前，在独立测试目录完成一次 Developer ID 更新，并验证辅助功能权限。私钥不进入仓库；本 PR 仅提交占位公钥与空 appcast。

## 每次发布

1. 更新 `VERSION`（若发行新版本）并保持 Mac/iOS 营销版本一致。将根目录 **`MAC_BUILD` 加 1**，包括原地覆盖同一个 `VERSION`。`CFBundleVersion` 读取它。任务书原定名称 `BUILD` 在 macOS 默认不区分大小写的文件系统上与 `build/` 冲突，因此使用 `MAC_BUILD`；iOS `CURRENT_PROJECT_VERSION` 不受影响。
2. 同步最新的 `site/appcast.xml`。`./scripts/package-release.sh --check-only` 只检查公钥与构建号，不构建、不签名、不发布。构建号必须严格大于 appcast 所有条目的最大值。不要以旧分支的 appcast 绕过检查。
3. 准备 `docs/releases/v<VERSION>.md`，将 `docs/releases/NEXT.md` 的有关改动并入。发布脚本将说明文字作为安全的内嵌 HTML 放进 appcast，Sparkle 不需要访问 GitHub Markdown 页面。
4. 执行：

   ```bash
   IMIC_RELEASE_IDENTITY='Developer ID Application: KE CHENG (5H39F98ND4)' \
   IMIC_NOTARY_PROFILE='发布者的公证配置名称' ./scripts/package-release.sh
   ```

   脚本显式从内向外签 `Autoupdate`、`Updater.app`、`Sparkle.framework` 和主 App，不使用 `--deep` 签名。iMic 未启用 App Sandbox，不启用 Installer/Downloader XPC，嵌入时删除这两个可选服务。验证签名后生成并签名 DMG、提交公证、staple，再用 `sign_update` 对**最终 DMG**签 EdDSA；另用仓库公钥独立校验签名。`codesign --verify --deep --strict`、`spctl -a -vv` 不通过就停止。签名身份还会核验团队为 `5H39F98ND4`。
5. 脚本只在本地生成文件和修改 appcast，**不上传、不创建 Release、不提交或推送**。检查输出 DMG、SHA256SUMS 和 `site/appcast.xml`。同一营销版本只保留新条目，原签名、长度、BUILD 一并替换。未指定发布身份时仅产生本地 ad-hoc 包，不签更新、不生成 appcast；占位公钥仍会阻止打包。
6. **先把最终 DMG 上传到 GitHub Release** 的 `v<VERSION>`，地址必须为 `https://github.com/Drafffffff/iMic/releases/download/v<VERSION>/iMic-<VERSION>-macOS-universal.dmg`。确认可下载、长度和 SHA-256 一致后，再提交并推送 `site/appcast.xml`，让 Pages 部署。禁止先部署 appcast。原地覆盖同样遵守这个顺序，避免用户收到指向不存在文件或旧签名的条目。
7. 执行 `python3 tools/check-site.py`，确认线上 feed 为 `https://drafffffff.github.io/iMic/appcast.xml`。每条须有 EdDSA 签名、长度、递增构建号、营销版本和 macOS 13.0 最低版本。不要修改 DMG 后复用旧签名。

## App 行为与权限

默认每天检查一次，不自动下载安装；菜单可手动检查。「设置 → 通用」提供两个开关与营销版本（构建号）。首次设置未完成、录音/识别/润色/扫光/输入/清除期间推迟提示和重启；异步返回的发现通知也等待空闲。安装重启前先断开 iPhone 链路。Sparkle 系统信息上报在 plist 和运行时都关闭，发布构建总是使用固定 HTTPS feed，不接受 defaults 或 `--debug-*` 改写地址。

发布版必须保持 Bundle ID `com.drafffffff.imic`，并使用同一 Developer ID（团队 `5H39F98ND4`）签名，以保持代码签名的 designated requirement 和 TCC 辅助功能授权身份。不要修改 TCC 或自动批准权限。ad-hoc 开发构建（`IMIC_SIGNING_IDENTITY=-`）更新后可能失去授权，这是预期行为。若权限失效，沿用 README 与 `docs/DEVELOPMENT.md` 中的「移除后重新添加」流程。

## 本地验证（不发布）

临时 Ed25519 密钥使用 CryptoKit 生成文件形式的 32 字节 seed，base64 后写入 `build/` 下的 `0600` 文件，公钥也放在同一临时目录；**不要运行会使用登录钥匙串的 `generate_keys`**。`sign_update --ed-key-file build/临时目录/temporary.key -p 最终测试.dmg` 可以直接签名，不读取发布者钥匙串。

```bash
IMIC_CONFIGURATION=debug IMIC_UPDATE_TEST=1 IMIC_TEST_BUILD=100 \
IMIC_TEST_PUBLIC_KEY_FILE="$PWD/build/临时目录/public.txt" \
IMIC_BUILD_DIR="$PWD/build/临时目录/A" IMIC_SIGNING_IDENTITY=- ./scripts/build-mac.sh
# 同样构建 B，IMIC_TEST_BUILD=101；制作 DMG 后再签名并生成本地 appcast。
python3 -m http.server 8765 --bind 127.0.0.1 --directory build/临时目录/server
build/临时目录/A/iMic.app/Contents/MacOS/iMic \
  --debug-update-feed=http://127.0.0.1:8765/appcast.xml
```

`IMIC_UPDATE_TEST=1` 仅在 DEBUG 构建写入测试标志，让重启后的 B 回到预览设置页，不开启真实录音/联网识别或修改凭据。`--debug-update-check` 请求一次检查；`--debug-update-busy-file=/绝对路径/marker` 在文件存在时模拟忙碌，删除后恢复空闲。发布构建不编译这些调试入口，也忽略测试公钥、构建号与测试标志环境变量。测试 App 不放 `/Applications`。Developer ID 一轮可对 A/B 使用 `scripts/sign-mac.sh <app> '<Developer ID>' release`，只签自己的临时 App；不改证书或钥匙串中的密钥。

检查发现窗口 → 下载/校验/替换/重启 → 设置显示 101；修改 DMG 一个字节，确认被拒绝且仍为 100；测试检查前与安装后的忙碌状态，空闲后才提示/重启。另运行 `python3 -m unittest discover -s tests/Updater -v` 验证占位公钥、构建号预检、XML 和同版本替换。测试后退出测试 App、关闭本地服务、删除整个临时目录（包括私钥和本地 feed），清除测试创建的 Sparkle defaults 项，保留原有应用偏好。不运行 `install-mac.sh`。
