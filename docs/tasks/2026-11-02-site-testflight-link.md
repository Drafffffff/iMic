# 任务书：官网与 README 接入 TestFlight 公开链接

日期：2026-11-02
执行者：omp（DeepSeek）
动手前请阅读本文件和 `AGENTS.md`。

## 0. 交付方式

1. 在已创建的 worktree（分支 `codex/site-testflight-link`）中工作。
2. 提交说明用简体中文，结尾加一行 `Co-Authored-By: omp (DeepSeek) <noreply@example.com>`。
3. 推送后用 `gh pr create` 向 `codex/ui-phosphor-wireframe` 提 PR，附第 3 节测试结果。不要合并。
4. 只改下面列出的文件。

## 1. 链接

TestFlight 公开链接（用户在 App Store Connect 创建）：`https://testflight.apple.com/join/BZmRwkZC`

## 2. 要改的地方

1. `site/assets/js/site.js` 第 2 行：`const IOS_TESTFLIGHT_URL = "";` 改为上述链接。现有代码会把「TestFlight 测试即将开放」按钮换成「通过 TestFlight 安装」链接，不要改这段逻辑。
2. 无 JavaScript 回退：`site/index.html` 与 `site/en/index.html` 的 iPhone 下载卡中，`#testflight-link` 目前带 `hidden`、没有 `href`，`#testflight-pending` 是禁用按钮。改为：`#testflight-link` 直接带 `href="https://testflight.apple.com/join/BZmRwkZC"`、不隐藏；`#testflight-pending` 加上 `hidden`。两个元素的 id 都保留（脚本和测试依赖它们）。
3. 两个页面中仍然说"等待 TestFlight 公开测试开放""即将开放""coming soon"之类的文字，改为指向 TestFlight 的说法。例如 FAQ「iPhone 可以自行签名安装吗？」的结尾"常规安装请等待 TestFlight 公开测试开放"改为"常规安装请使用 TestFlight"（英文页对应修改）。用 `grep -n -i "即将开放\|等待 TestFlight\|coming soon\|wait for the public TestFlight" site/index.html site/en/index.html` 找全。
4. `README.md` 第 28 行改为：`2. **iPhone**：通过 [TestFlight](https://testflight.apple.com/join/BZmRwkZC) 安装。`
5. `README.en.md` 第 28 行改为：`2. **iPhone**: install via [TestFlight](https://testflight.apple.com/join/BZmRwkZC).`
6. `tools/test-site-browser.mjs` 中「No JavaScript: download remains usable; TestFlight disabled」这项检查：按新行为更新为无 JS 时 TestFlight 链接可用、指向上述地址。其他依赖 `IOS_TESTFLIGHT_URL` 为空的测试（如果有）同样更新。
7. `tools/check-site.py` 会检查外部链接，确认 `testflight.apple.com` 不被拒绝；如被拒绝，把它加入允许列表。
8. `docs/releases/NEXT.md` 记一行：官网与 README 接入 TestFlight 公开测试链接。

## 3. 测试

```bash
python3 tools/check-site.py
python3 -m http.server -d site 8781 --bind 127.0.0.1 &   # 用你自己的端口，不要用 8000
IMIC_SITE_URL=http://127.0.0.1:8781/ node tools/test-site-browser.mjs
```

全部通过后再提 PR。测试结束后停止你启动的 HTTP 服务。测试可能会改动 `docs/reviews/` 下的截图，提交前用 `git checkout -- docs/reviews` 还原，不要提交这些截图变化。
