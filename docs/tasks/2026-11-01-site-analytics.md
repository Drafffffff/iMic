# 任务书：官网接入无 Cookie 用户分析

日期：2026-11-01
仓库：`/Users/drafff/Desktop/iMic`（GitHub：`Drafffffff/iMic`）
执行者：Codex
动手前请完整阅读本文件和仓库根目录的 `AGENTS.md`。

---

## 0. 交付方式（必须遵守）

1. 从 `codex/ui-phosphor-wireframe` 最新提交新建分支 `codex/site-analytics`，在专用 worktree 中工作。不要直接提交到 `codex/ui-phosphor-wireframe`。
2. 提交说明用简体中文。推送后用 `gh pr create` 向 `codex/ui-phosphor-wireframe` 提 PR，附第 7 节测试报告。不要自行合并。
3. **不要注册、登录或创建任何分析服务账号。** 账号由用户自己创建，拿到站点 ID 后再填入（见 3.2）。
4. 只改官网相关文件（`site/`、`tools/check-site.py`、`tools/test-site-browser.mjs`）以及 `docs/PRIVACY.md`、`docs/releases/NEXT.md`、`docs/DEVELOPMENT.md`。不改 App 代码。

---

## 1. 背景与目标

用户想了解官网访客：有多少人来、从哪里来、看了什么、有没有下载。用户已决定：**使用无 Cookie 的隐私友好型分析**，不用 Google Analytics（GA 需要 Cookie 同意横幅，且在中国大陆基本无法访问，而官网主要访客是中文用户）。

现状：

- 官网页脚写着「本站无追踪、无 Cookie」（`site/index.html`、`site/en/index.html` 隐私区块）。
- `tools/check-site.py` 禁止 JS 使用 `localStorage`、`sessionStorage`、`document.cookie`，并收集外部域名做检查。
- `docs/PRIVACY.md` 有官网隐私说明。

## 2. 选型（先调研，再决定）

### 2.1 硬性要求

- **不使用 Cookie，不写 localStorage / sessionStorage**，不做跨站追踪，不收集可识别个人身份的信息。按欧盟 GDPR 与中国《个人信息保护法》的一般理解，无需同意横幅即可使用。
- **支持自定义事件**（第 4 节的事件），并能带少量属性（例如 `lang=zh`）。注意：Cloudflare Web Analytics 不支持自定义事件，不满足要求。
- **在中国大陆可以正常加载和上报**。请用公开信息判断各家脚本域名与上报域名在大陆的可达性；能实测就实测（例如从本机直接请求其脚本地址，记录结果），不能实测的写明依据。
- 脚本体积小（建议小于 5 KB gzip），异步加载，不阻塞首屏，加载失败时页面功能完全不受影响。
- 免费或低价，适合个人开源项目。

### 2.2 候选

至少比较以下几家，可以补充：GoatCounter、Umami Cloud、Plausible、Cloudflare Web Analytics（作为对照，说明为什么不选）、自托管 Umami（说明需要服务器，作为备选）。

### 2.3 输出

在 PR 中给出对比表（Cookie/存储、自定义事件、大陆可达性及依据、价格、脚本体积、数据存放地、开源与否），选出一家并说明理由。实现按选定的那家做；如果你认为两家不分伯仲，选更简单的那家，并在 PR 中写明另一家怎么切换。

## 3. 实现

### 3.1 统一的事件接口

- 在 `site/assets/js/site.js` 中新增一个很小的 `track(name, props)` 函数。所有埋点只调用它，不直接调用第三方 API。
- `track` 先派发一个页面内事件 `imic:track`（`detail: { name, props }`），再交给分析服务的适配层。这样测试可以监听 `imic:track`，不依赖第三方。
- 适配层把事件转换为所选服务的 API。服务脚本未加载、加载失败或未配置时，`track` 静默不做任何事。
- 属性只允许短的枚举值（如 `lang`、`placement`、`question` 的编号），**绝不发送用户输入、文字内容、完整 URL 查询参数或任何个人信息**。

### 3.2 配置与开关

- 站点 ID 放在一处配置，例如 `site/assets/js/site.js` 顶部的常量 `ANALYTICS_SITE_ID`（与现有 `IOS_TESTFLIGHT_URL` 同样的写法），默认为空字符串。**为空时不加载任何第三方脚本，不发任何请求。**
- 不在本地开发地址上报：`localhost`、`127.0.0.1`、`[::1]`、`*.local`、`file:` 一律不加载。
- 尊重浏览器的 Do Not Track / Global Privacy Control：任一开启时不加载。
- 在 `docs/DEVELOPMENT.md` 写清楚：用户需要去所选服务注册、添加站点 `drafffffff.github.io`、拿到站点 ID 后填入哪里；如何在服务后台查看自定义事件。

### 3.3 页面文案与隐私说明

- 隐私区块的「本站无追踪、无 Cookie」改为准确的说法，例如「本站使用无 Cookie 的匿名访问统计」（英文页同步），并链接到隐私说明。
- `docs/PRIVACY.md` 的官网部分：说明使用了哪家服务、收集哪些匿名数据（页面、来源、国家/地区、设备类型、第 4 节的事件）、不使用 Cookie、不收集个人信息、数据存放在哪里、如何通过 DNT / GPC 关闭。
- **App 的隐私说明不变**：分析只在官网，App 不做任何统计。在 PRIVACY.md 中明确写出这一点。
- `docs/releases/NEXT.md` 记一行。

## 4. 需要的事件

页面浏览量、来源（referrer）、国家/地区、设备类型由服务自动统计。另外埋点：

| 事件 | 触发时机 | 属性 |
|---|---|---|
| `download_mac` | 点击 Mac 下载（首屏按钮、下载卡片按钮、移动端「仍然直接下载」） | `placement`（hero / card / mobile-direct）、`lang` |
| `iphone_get` | 点击「获取 iPhone 版」或 TestFlight 按钮 | `placement`、`lang` |
| `share_to_mac` | 移动端点击「把链接发送到 Mac」，以及分享/复制结果 | `result`（shared / copied / failed）、`lang` |
| `from_ios` | 带 `?from=ios` 进入页面（每次页面加载最多一次） | `lang` |
| `language_switch` | 点击「中文 / EN」切换，或语言提示条中的英文链接 | `to`（zh / en）、`placement`（nav / banner） |
| `video_play` | 用户**手动**点击视频播放（自动播放不算） | `video`（hero / string / polish / sound） |
| `sound_on` | 开启音效视频的声音 | 无 |
| `faq_open` | 展开某一条 FAQ | `question`（第几条，1 起） |
| `scroll_depth` | 页面滚动到 25%、50%、75%、100%（每个档位每次加载最多一次） | `depth` |

`lang` 取页面语言（`zh` 或 `en`）。不要为 glitch、示意动画等装饰效果埋点。

## 5. 检查脚本与测试

- `tools/check-site.py`：
  - 继续禁止 `localStorage`、`sessionStorage`、`document.cookie`。
  - 外部域名只额外允许所选分析服务的脚本域名与上报域名，写成明确的白名单。
  - 检查页面隐私文案已更新（不再出现「无追踪」的表述），并链接隐私说明。
- `tools/test-site-browser.mjs` 新增检查：
  - 站点 ID 为空时不请求任何分析域名。
  - 在本地地址运行时，即使临时注入站点 ID，也不加载分析脚本。
  - DNT / GPC 开启时不加载。
  - 第 4 节每个事件在对应操作后派发 `imic:track`，属性正确；自动播放不触发 `video_play`；滚动档位不重复。
  - 页面仍然没有任何 Cookie 和本地存储（沿用现有断言）。
  - 用你自己在 worktree 中启动的 HTTP 服务（`IMIC_SITE_URL`），不要用 8000 端口上可能属于别人的服务。

## 6. 不要做的事

- 不接 Google Analytics、百度统计等使用 Cookie 的服务。
- 不注册账号，不把任何账号凭据写进仓库。
- 不在 App 中加入任何统计。
- 不收集用户输入或文字内容，不收集 IP 以外服务默认之外的设备指纹。
- 不改变页面外观（文案调整除外）。

## 7. PR 中必须附上

1. 第 2.3 节的选型对比表与结论，包括大陆可达性的实测或依据。
2. 测试报告：

```bash
python3 tools/check-site.py
IMIC_SITE_URL=<本 worktree 的服务> node tools/test-site-browser.mjs
```

3. 事件清单与实际派发的 `imic:track` 样例（截取 `detail`）。
4. 隐私文案改动前后对照（中英文）。
5. 给用户的上线步骤：注册哪家服务、添加站点、站点 ID 填在哪里、填好后如何验证收到数据。
