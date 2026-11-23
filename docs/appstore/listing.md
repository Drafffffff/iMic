# App Store 商店文案

App：VoxChord（iOS，Bundle ID `art.malette.imic.app`，App Store Connect App ID 6829771739）
主语言建议：简体中文；另加英文（美国）本地化。括号内为字符数，均在 Apple 上限内。

## 基本信息

| 字段 | 简体中文 | English (U.S.) |
|---|---|---|
| 名称（≤30） | VoxChord 语音输入（13） | VoxChord: Voice Typing（22） |
| 副标题（≤30） | 按住说话，字落进 Mac 输入框（16） | Hold to speak. Type on Mac.（27） |
| 主类别 | 效率 Productivity | Productivity |
| 次类别 | 工具 Utilities | Utilities |
| 价格 | 2.99 美元（基准地区美国，其他地区按 Apple 自动换算），无内购 | USD 2.99, no IAP |
| 支持网址 | https://drafffffff.github.io/iMic/ | https://drafffffff.github.io/iMic/en/ |
| 营销网址 | https://drafffffff.github.io/iMic/ | https://drafffffff.github.io/iMic/en/ |
| 隐私政策网址 | https://github.com/Drafffffff/iMic/blob/main/docs/PRIVACY.md | 同左（见 review.md「待补」） |
| 版权 | 2026 KE CHENG | 2026 KE CHENG |

名称避免使用 Mac / iPhone 等 Apple 商标（审核指南 5.2.5）；副标题中描述性提到 Mac 可以接受。名称若被占用，备选：`VoxChord 语音键` / `VoxChord: Hold to Dictate`。

## 关键词（≤100，逗号分隔、不加空格）

- 中文：`听写,语音转文字,mini,麦克风,外接麦克风,迷你主机,键盘,远程输入,AI润色,Agent,终端,口述,写作,效率,输入法,语音打字`（68）
- English：`dictation,speech to text,mini,studio,microphone,dictate,keyboard,remote,ai,agent,terminal,transcribe`（100）

1.5.0 起（SEO 方案 `docs/seo/2026-11-23-seo-plan.md`）：名称和副标题里已有的词（语音输入、Mac、voice、typing）不再重复放进关键词，腾出位置给 Mac mini / Mac Studio 无麦克风场景。Apple 会把关键词与名称、副标题中的词组合匹配，`mini` 可与副标题里的 `Mac` 组成「mac mini」。

不放其他公司的商标（如 Claude Code、Cursor），以免触犯审核指南 2.3.7。

## 推广文本（≤170，可随时修改，无需审核）

- 中文：Mac mini、Mac Studio 没有麦克风？拿起 iPhone 按住说话，松手文字就出现在 Mac 光标处。给 Agent 下指令、写文档、回消息都不用敲键盘；下拉琴弦，直接发送。
- English: No microphone on your Mac mini or Mac Studio? Hold your iPhone to speak and the words land at your Mac's cursor. Prompt agents, draft docs and reply without typing.

## 描述（中文）

一只手机，接管所有输入。

VoxChord 把 iPhone 变成 Mac 的语音输入键。按住底部横条说话，松手，文字就出现在 Mac 当前光标处：终端、编辑器、浏览器、聊天窗口都可以。

Mac mini、Mac Studio、Mac Pro 没有内置麦克风？不用另买：VoxChord 用 iPhone 收音，Mac 不需要任何麦克风。

【按住就说，松手落字】
说话时 iPhone 上实时显示文字预览，松开后由 Mac 完成识别并输入到前台应用。录音中途上滑即可取消。

【琴弦手势】
识别完成后，下拉琴弦发送回车；上拨删字，左右滑动移动光标，拉到顶清空本次输入。和 AI Agent 一来一回，手不用回到键盘。

【AI 润色】
自动去掉口头禅、理顺语序，口语直接变书面。也可以一键切换成 Agent 指令、终端命令、文言文等多种写法。润色可随时关闭。

【多台 Mac，随时切换】
iPhone 记住你配对过的每一台 Mac，点一下就切换输入目标。

【直连，不经中转】
iPhone 与 Mac 用 6 位配对码配对，在局域网内加密传输。VoxChord 没有开发者自建的服务器，不收集录音、文字或使用数据，没有广告和跟踪。

使用前需要：
• 运行 macOS 13 或更高版本的 Mac，并安装免费的 VoxChord Mac 客户端（官网下载）
• 在 Mac 客户端中填入你自己的阿里云百炼 API Key（识别服务由百炼提供，可能产生服务商费用）
• iPhone 与 Mac 连接同一 Wi-Fi

VoxChord 是开源软件（GPL-3.0）。问题反馈：i0.0ia@qq.com

## Description (English)

One phone. Every text field.

VoxChord turns your iPhone into a voice key for your Mac. Hold the bar, speak, and release: the words appear at your Mac's cursor in terminals, editors, browsers or chat windows.

No built-in microphone on your Mac mini, Mac Studio or Mac Pro? No need to buy one. VoxChord listens through your iPhone, so your Mac needs no microphone at all.

HOLD TO SPEAK, RELEASE TO TYPE
See a live text preview on your iPhone while you talk. When you let go, your Mac finishes recognition and types into the front app. Slide up mid-recording to cancel.

STRING GESTURES
After the text lands, pull the string down to press Return. Flick up to delete, swipe sideways to move the cursor, or pull to the top to clear the input. Go back and forth with your AI agents without reaching for the keyboard.

AI POLISH
Filler words disappear and word order gets cleaned up, so casual speech reads like writing. You can also switch styles, such as agent prompts or terminal commands, with one tap, or turn polishing off.

ALL YOUR MACS
Your iPhone remembers every Mac you pair. Tap to switch where your words go.

DIRECT AND PRIVATE
Pair with a 6-digit code. Audio travels encrypted over your local network straight to your own Mac. VoxChord runs no developer servers and collects no recordings, text or usage data. No ads, no tracking.

What you need:
• A Mac running macOS 13 or later with the free VoxChord Mac app (download from the website)
• Your own Alibaba Cloud Model Studio (Bailian) API key, entered in the Mac app. Recognition is provided by that service and may incur charges from the provider
• iPhone and Mac on the same Wi-Fi network

VoxChord is open source (GPL-3.0). Feedback: i0.0ia@qq.com

## 此版本新增（What's New，首发可用）

- 中文：VoxChord 首次上架 App Store。按住说话、琴弦手势、AI 润色、多台 Mac 切换。
- English: VoxChord is now on the App Store, with hold to speak, string gestures, AI polish and multi-Mac switching.

## 截图

`screenshots/zh-Hans/` 与 `screenshots/en/` 各 6 张，1320×2868（6.9 英寸，App Store Connect 会自动缩放到其他尺寸）。上传顺序即文件编号：

1. ANYWHERE：一只手机，接管所有输入（录音中 LISTEN）
2. STRING：下拉琴弦，弹射发送（识别完成后下拉弦）
3. POLISH：随口说，落笔即成文（润色扫光）
4. MODES：一句话，多种写法（设置页转换模式）
5. LINK：多台 Mac，随时切换（设备列表）
6. PRIVATE：直连你的 Mac，没有中转（配对码输入）

全部画面来自真实 App（Release 同源代码的 Debug 构建、模拟器 iPhone 17 Pro Max），不是设计稿。重新生成：在 `ios` 工程中按 `docs/appstore/screenshots/README.md` 采集帧后运行 `compose.py`。
