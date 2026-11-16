# 任务书：润色扫光跟随会变高变矮的输入框

日期：2026-10-30
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 的最新提交新建分支 `codex/sweep-follow-resizing-field`。**不要直接在 `codex/ui-phosphor-wireframe` 上提交。**
2. 在新分支上开发、提交，提交说明用简体中文。
3. 推送到 GitHub：`git push -u origin codex/sweep-follow-resizing-field`。
4. 用 `gh pr create` 创建 PR，**base 选 `codex/ui-phosphor-wireframe`**，不要选 `main`。`main` 停在 1.4.0，不是工作分支。
5. PR 描述必须包含第 7 节规定的**全量测试报告**。没有测试报告的 PR 不予审核。
6. PR 创建后由 Claude 审核，**不要自行合并**，也不要开启自动合并。
7. 不改 `VERSION` 和版本号；不发 Release；不覆盖 `/Applications/iMic.app`，也就是不要运行 `install-mac.sh`。
8. 本次改动写进 `docs/releases/NEXT.md`（"下一版待同步的改动"），加在 Mac 小节下。

---

## 1. 问题

用户反馈：输入框静止时，润色扫光是好的；但很多输入框会上下跳动。典型情况是，口述输入后输入框是 3 行，润色结果写入后变成 2 行（或者反过来变多），这时扫光的过渡会出错。具体表现是：骨架线悬在空中、和文字错位，接着下划线瞬移一整行到新位置。

常见的触发场景：
- 聊天类输入框（Chrome 里各种网页聊天、Slack、微信等）：底部固定、向上长高，行数变少时整个框的上边缘下移一行。
- 普通 textarea、编辑器：顶部固定，行数变化时下边缘移动；文字超出可见区域时还会内部滚动。
- 很多网页输入框的高度变化带 CSS 过渡（约 100–200 ms），尺寸是逐帧变化的。

## 2. 根因（已在代码中确认）

本节的文件都在 `mac/` 下。

扫光的时间线：扫光（sweeping）→ 等待（holding）→ 写入（writing，下划线变成骨架线）→ 收尾（releasing）。

1. **写入阶段的骨架钉在旧的屏幕坐标上**。`TextPolishEffect.swift` 的 `SweepView.beginLoading()` 把 rails 原地转成骨架；`reshapeSkeleton(to:)` 明确禁止骨架上下移动：
   ```swift
   // Keep the bar on its own line; only a near-identical row may shift.
   let y = abs(rect.minY-1-thickness(rect)/2-line.position.y) < rect.height*0.6
       ? rect.minY-1-thickness(rect)/2 : line.position.y
   ```
   输入框整体移动一行（行距约 1.25 倍行高，大于 0.6 倍）时，骨架不跟着走，文字和线就分开了。

2. **最终排版是瞬移过去的**。`align(regions:…confirmed: true)` 让旧骨架原地退场（`retireSkeleton`），新 rails 在新位置重画。前后差一整行，看起来就是"跳"了一下。

3. **在固定时间点读取最终几何**。`finishDelivery` 在 0 / 0.12 / 0.28 / 0.44 秒触发 `refreshFinalLayout`。第 2 次起读 AX 排版，OCR 在第 1 或第 3 次。输入框还在做高度过渡时，可能读到中间状态。估算（`PolishEndpointEstimate`，`PolishPresentation.swift:164`）按读取那一刻的 `visibleField` 和原始的 `target.field` 之差平移旧行；读早了，框还没变，估算就是错的，之后再被确认结果覆盖，于是跳两次。

4. **等待阶段输入框一动，扫光就被取消**。`watchHeldGeometry` 每 0.3 秒检查一次 `valid(target)`；`valid` 要求输入框 frame 和可见区域与开始时**完全一致**（误差小于 1pt），否则 `skipVisual(reason: "held_geometry_changed")`。

5. 日志佐证：`~/Library/Logs/iMic/iMic.1.log` 中，`release source=display_deadline_estimated`（600 ms 超时后按估算收尾）有 89 次，说明不少情况下没等到可靠的最终排版。

## 3. 目标行为（规格）

核心原则：**把输入框当作移动的参照物，扫光跟着框走，而不是钉在屏幕上。**

### 3.1 跟随

- 从扫光开始到收尾结束，跟踪目标输入框的位置和尺寸（`frame(element)` 与 `visibleField`），只读几何，**不读文字**。有 AX 元素时，采样间隔约 30 ms。
- 输入框发生平移（窗口内容滚动、聊天框整体上移或下移）时，骨架线、paragraph caps、端点核心以及整个扫光层平移同样的距离，跟手完成，最多做一帧的平滑，不要比框慢。
- 计算跟随偏移量时，要判断文字以哪条边为基准：
  - 多数 textarea、富文本、聊天框的文字从输入框**内部顶边**开始排版，文字的屏幕 y 坐标跟着 `visibleField.minY` 走。
  - 底部固定的聊天框缩短时，上边缘下移，文字也随之下移，这同样是"跟顶边"。
  - 内部滚动（框尺寸不变，内容滚动）不会改变 frame。这种情况仍然依靠最终的确认排版，跟随不需要处理。
  - 建议实现：偏移量 = 当前 `visibleField.minY` − 写入前的 `visibleField.minY`。x 方向同理，对 `minX` 做相同处理。请用测试页验证"跟顶边"假设在各类输入框里成立；如果发现反例，在 PR 里说明。
- 没有 AX 元素的目标（例如只能整窗 OCR）无法跟随，维持现有行为。

### 3.2 稳定后再确认

- 最终排版（`textLayout` 或 OCR）只在输入框几何**连续 2 次采样不变**（约 60 ms）之后才去读，不再依赖固定的 0.12、0.28、0.44 秒。
- 估算（`PolishEndpointEstimate`）始终用**当前跟踪到的**输入框几何，不用某个固定时刻的读数。
- 收尾超时：从现在的 0.6 秒改成"输入框稳定后再给 0.3 秒，总上限 0.9 秒"，把它们做成常量。到上限仍不稳定，就按最新的估算收尾，并记录日志 `release source=display_deadline_estimated moving=1`。

### 3.3 行数变化原地收放

- 跟随平移之后，第 i 行骨架应当仍然贴着第 i 行文字。
- 行数**变少**：多出来的骨架行在原地向右端收回，与现有 `retire` 的视觉一致，不上下移动。
- 行数**变多**：新增的行原地淡入，带 shimmer。现有的"只有 ≥2 行才加行"的规则保留。
- 端点：旧端点原地淡出，在新的最后一行行尾淡入（沿用现有的 `reanchor` 透明度关键帧）。**不要让端点在文字上方穿行**，这是之前与用户确认过的规则：过渡不穿过文字。
- 确认排版到达时，因为骨架已经跟着框走了，新 rails 的位置应当和骨架基本重合，只剩宽度变化，看不出跳动。

### 3.4 等待阶段的几何变化

- `valid(target)` 拆成两部分：
  - **致命变化**，仍然取消：窗口换了、窗口不可见、窗口 frame 变了、元素消失、文字签名变了（用户改了字）。
  - **可跟随变化**：同一个元素、同一个窗口，只是 frame 或 visibleField 平移、改变尺寸。这时不取消，按 3.1 跟随。
- 用户手动接管（按键、点击、切换应用）仍然立即冻结并取消，这一点不能放宽，见 AGENTS.md 中"用户接管后冻结本轮"。

### 3.5 面板

- 扫光面板（`SweepPanel`）的尺寸要覆盖跟随过程中可能到达的范围。建议在进入写入阶段时，把面板预先扩到"原面板 ∪ 输入框所在窗口内容区与屏幕的交集"，避免在动画中反复调用 `setFrame`/`reframe` 造成闪烁。面板始终 `ignoresMouseEvents = true`，不得遮挡用户操作。

## 4. 实现建议

- 新增一个跟踪器，例如 `FieldGeometryTracker`：在后台 `queue` 上按约 30 ms 采样，在主线程回调 `(delta: CGVector, field: CGRect, stable: Bool)`。生命周期和 `generation`、`EffectCancellation` 绑定：取消、收尾或用户接管时立即停止，**收尾后不能留下迟到的回调**。
- `SweepView` 新增 `follow(by delta: CGVector)`：平移 `loadingRoot`（或使用 `sublayerTransform`），同时平移 `rowRegions`、`endpoint`。不要逐个重建图层。
- `reshapeSkeleton` 的"不允许上下移动"规则保留，但它比较的是**跟随平移之后**的位置。
- 把纯计算抽成可测的函数，放进 `PolishPresentation.swift`，例如：
  - `FieldFollow.delta(from:to:) -> CGVector`
  - `FieldFollow.isStable(samples:) -> Bool`
  - `FieldFollow.classify(old:new:) -> .fatal / .followable / .none`
- 日志（`IMicLog.write("mac.effect", …)`）新增：`follow dx=… dy=… samples=…`、`stable after=…ms`。**只记坐标，不记文字。**
- 所有 Core Animation 改动遵守 Reduce Motion：开启"减弱动态效果"时直接跳到最终位置，不做平滑。

## 5. 测试输入框（新增到 `tests/PolishApps`）

在 `tests/PolishApps/fields.html` 增加几种会变高变矮的输入框（通过 `kind=` 选择），并在 `run.py` 中注册目标和用例：

| kind | 行为 |
|---|---|
| `grow-bottom` | 聊天框：贴页面底部，`min-height` 1 行，随内容增高（JS 按 `scrollHeight` 设置高度），向上长 |
| `grow-top` | 普通文本框：顶部固定，随内容增高，向下长 |
| `grow-animated` | 同 `grow-bottom`，但 `height` 带 `transition: height 160ms ease` |
| `grow-max` | 增高到 4 行封顶，超过后内部滚动 |

用例（加进 `CASES`，并允许只在这些目标上运行）：
- `shrink`：草稿 3 行，润色结果 2 行（可以复用 `shorten` 的思路，换一段会折成 3 行的长草稿）。
- `grow`：沿用现有的 1 行扩成 4 行。
- `shrink-to-one`：草稿 3 行，结果 1 行。

每个用例除了现有的 `hold` 和 `final` 截图，**再在写入后约 80 ms 和 200 ms 各截一张**（例如 `mid1`、`mid2`），用来检查过渡中途骨架是否贴着文字。`report.py` 要能显示新增的截图列。

## 6. 硬性约束

- 不修改协议（`shared/iMicLink.swift` 等，见 AGENTS.md）。
- 扫光只是视觉提示，**从不**作为写入或修改文字的依据，本任务不得改动 `main.swift` 里的输入投递逻辑。
- 不修改 TCC，不自动批准权限。
- 只读几何，不新增任何读取文字内容的调用（现有的文字签名校验除外）。
- 不提交 `.claude/`、`build/` 下的产物。截图和报告放在 `build/` 下，只在 PR 里附上路径和摘要。
- `--ui-preview=*` 和 `--debug-*` 只在预览或 DEBUG 下生效。

## 7. 全量测试（PR 必须附报告）

依次执行以下全部命令，每条记录：通过或失败、耗时、关键输出（失败时附最后 20 行）。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                                # 协议与共享逻辑
./scripts/test-polish-effect.sh           # 扫光单测（新增的 FieldFollow 测试放这里）
./scripts/test-polish.sh                  # 润色服务
./scripts/test-mac-settings.sh            # Mac 设置与向导
./scripts/test-input.sh                   # 输入投递
./scripts/test-clear-input.sh             # 清空输入
./scripts/test-ios-mac-selection.sh       # iOS 自动选择 Mac
./scripts/test-ios-reconnect.sh           # 重连
./scripts/test-polish-link.sh             # 润色链路
./scripts/test-screen-idle.sh             # iOS 待机遮罩
./scripts/build-mac.sh                    # Mac 构建
./scripts/build-ios.sh                    # iOS 构建
```

真实应用回归（会接管前台约 10 分钟；需要屏幕录制权限）：

```bash
# 新增的会变高变矮的输入框，必须跑
./scripts/test-polish-apps.sh chrome-grow-bottom,chrome-grow-top,chrome-grow-animated,chrome-grow-max
# 原有目标全量回归，确认没有退化
./scripts/test-polish-apps.sh
python3 tests/PolishApps/report.py build/polish-apps/report-sweep-follow <运行目录…>
```

> 目标名以你在 `run.py` 中实际注册的为准。

如果某条命令因环境原因无法执行（例如没有屏幕录制权限、需要真实百炼 Key 的脚本缺少 Key），**如实写明原因**，不要跳过不报，也不要把它写成"通过"。改动前就已失败的测试，先在干净的 `codex/ui-phosphor-wireframe` 上复现一次并在报告中注明"既有失败"。

### PR 描述模板

```markdown
## 改动
- …（每个文件一句话）

## 规格对照
- 3.1 跟随：…
- 3.2 稳定后确认：…
- 3.3 行数变化：…
- 3.4 等待阶段：…
- 3.5 面板：…
- 偏离之处及原因：…

## 全量测试报告
| 命令 | 结果 | 耗时 | 备注 |
|---|---|---|---|
| swift test | ✅ 64/64 | 12s | |
| … | | | |

## 真实应用回归
- 报告路径：build/polish-apps/report-sweep-follow/index.html
- 新增输入框：grow-bottom ✅ / grow-top ✅ / grow-animated ✅ / grow-max ✅（每项附 mid1/mid2 截图结论）
- 原有目标：通过 x / 估算 y / 未显示 z，与上一份报告相比：…

## 需要用户手测
- …

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## 8. 遇到以下情况时停下来，在 PR 或回复中说明

- 发现"跟顶边"的假设在某类常见输入框里不成立，而且需要逐个应用做特判。
- 跟随需要修改输入投递逻辑或协议。
- 30 ms 采样在某些应用里造成明显卡顿（AX 调用阻塞）。请附测得的耗时。
- 全量测试中出现与本任务无关、且在干净分支上也失败的测试：记录为既有失败即可，不要顺手修。
