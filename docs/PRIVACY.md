# iMic 隐私说明

更新日期：2026-11-01。联系邮箱：i0.0ia@qq.com。

iMic 将 iPhone 麦克风音频发送到你配对的 Mac，由 Mac 完成识别并向当前应用输入文字。使用前需要在 Mac 配置自己的识别服务 API Key。iMic 没有用于接收录音、识别文字或服务 Key 的开发者自建服务器，没有广告或跨应用跟踪 SDK。

## 录音、识别与外部服务

- 录音在用户按住录音区域后开始；前台待机不持续采集麦克风。松开后输入引擎可保留约 5 秒的热启动窗口，随后释放音频会话。发送和重传所需的音频块在会话期间暂存在内存中。
- iPhone 与配对 Mac 之间使用加密链路。Mac 将音频发送至用户配置的阿里云百炼识别服务；该服务需要联网，可能产生服务商费用。服务商的数据处理和保留规则以用户所选地域、服务条款及账号设置为准。
- 在用户授予语音识别权限后，iPhone 使用 Apple Speech 生成临时文字预览。应用未强制要求纯离线识别，Apple Speech 可能使用 Apple 的在线服务；不能将这一功能描述为保证完全离线。拒绝此权限不影响 Mac 端最终识别链路。
- 启用文字润色时，Mac 将识别出的文字发送至用户选择的百炼、DeepSeek 官方或自定义兼容服务。关闭润色即可停止此项处理；润色服务不接收 iMic 的原始录音。
- API Key 和服务地址保留在 Mac，不通过 iPhone 的偏好同步消息传输。应用不会将 API Key 写入发布安装包。

## 本地存储

- iPhone 将配对令牌存入本机钥匙串，将设备标识、已知 Mac 名称和偏好选择保存在应用本地。Mac 的配对状态保存在 `~/Library/Application Support/iMic/paired.json`。
- Mac 上在应用内填写的服务 Key 保存于 `~/Library/Application Support/iMic/credentials.json`，目录权限为 `0700`，文件权限为 `0600`。用户也可以自行通过环境变量提供凭据。
- 最近识别结果会显示在应用内，用户可以复制；文字被输入或复制到其他应用后，其保留和同步由该目标应用控制。
- 波形复看只保存频段、响度和相对时间等可视化数据，不包含 PCM 录音或识别正文。缓存最多保留最近 3 条、每条最长 60 秒；下次整理缓存时会清除超过 24 小时的记录。用户可在波形复看页清除缓存，或主动导出 JSON。
- 两端会保存可轮换的本地诊断日志，内容包括连接状态、设备/应用名称或标识、序号、帧数、字节数和错误信息。应用不主动将日志上传至开发者服务器；用户可自行导出排障。日志达到约 2 MB 后轮换，保留当前和上一份文件。
- 常规识别流程不把原始音频持久化为录音文件。

## 权限用途

| 权限 | 用途 |
|---|---|
| iPhone 麦克风 | 获取用户主动录制的语音 |
| iPhone 本地网络、蓝牙 | 发现并连接自己的 Mac |
| iPhone 语音识别 | 提供 Apple Speech 临时文字预览 |
| Mac 辅助功能 | 向用户选定的前台应用投递文字和编辑按键 |
| Mac 屏幕录制（可选） | 本机定位文字以呈现润色扫光效果；该功能不保存或上传截图 |

用户可以在系统设置中撤销权限，也可以关闭润色、更改服务商、解除配对或清除波形缓存。解除配对后不再接受该设备的既有信任关系。删除目标应用中的文字、系统剪贴板内容或服务商已处理的数据，需要分别使用相应应用或服务商提供的方式。

如需反馈问题，请联系 i0.0ia@qq.com。请勿通过公开 issue 发送 API Key、配对令牌或包含私人内容的录音。

## 首次引导与系统连续互通

- 接力由系统通过浏览网页活动传递公开的 Mac 下载页地址，离开下载页即失效；共享由系统共享表单处理。接力是否可用取决于设备、Apple ID 和系统设置。
- 仅在你点击「复制链接」后，iMic 将公开下载地址写入系统剪贴板。通用剪贴板的跨设备传送由 Apple 系统完成；iMic 不读取其他剪贴板内容，也不收集接力或剪贴板数据。下载链接的 `?from=ios` 用于官网展示；官网启用匿名统计后，只计一次来源事件（见下文），App 不发送此统计事件。
- 引导进度和教程完成版本只保存在设备本地。练习使用合成波形与模拟输入框，不访问麦克风或语音识别，不发送练习内容到 Mac。

## Mac 更新检查

Mac 默认每天访问一次 `drafffffff.github.io` 获取更新列表，下载更新时访问 GitHub Releases。你可以在「设置 → 通用」关闭「自动检查更新」，也可以通过菜单手动检查。默认不会自动下载安装。更新检查关闭 Sparkle 系统信息上报，不发送任何个人信息、设备信息或使用数据；网络服务仍会按正常 HTTP 请求看到 IP 地址和应用版本的 User-Agent。不收集或上传录音、识别文字、服务 Key。


## 官网匿名访问统计 / Website analytics

统计仅适用于官网，**Mac 与 iPhone App 不做任何使用统计**，不包含分析 SDK；上文 App 的录音、权限、本地数据与更新检查规则不变。

官网使用 [Umami Cloud](https://umami.is/) 无 Cookie 匿名统计（2026-11-01 启用）。统计页面浏览量、来源网站域名（不发送来源路径）、国家/地区、浏览器/操作系统及设备类型。页面只发送固定的中英文路径，不发送 URL 查询参数、片段、自由文本或用户输入；没有广告标识、跨站追踪、会话回放或额外设备指纹。服务会从正常 HTTP 请求看到 IP 和 User-Agent，用于粗略地域与匿名汇总，不将原始 IP 作为访客个人资料保存。无需为此配置 Cookie 同意横幅；无 Cookie 并不免除站点经营者适用的数据保护义务。

自定义事件仅包含：Mac 下载位置（首屏/卡片/移动端直接下载）、iPhone 获取位置、分享或复制的结果（成功/失败，取消分享计为失败）、来自 iOS 的访问、语言切换、手动视频播放、开启声音、展开的 FAQ 序号，以及 25%/50%/75%/100% 滚动档位。属性仅限页面语言、位置和编号等短枚举，不记录具体文字、剪贴板内容、分享对象或个人信息。

不使用 Cookie，不写入 localStorage 或 sessionStorage。站点 ID 为空、本地开发地址、浏览器开启 Do Not Track（DNT）或 Global Privacy Control（GPC）时不加载分析脚本、不发送统计请求；开启 DNT/GPC 后刷新页面即可关闭统计。脚本被拦截或加载失败不影响下载、播放或其他页面功能。

上线时应在 Umami Cloud 选择 **EU（欧盟）数据地域**，分析数据存放于所选地域；当前尚无账号或数据。Hobby 档分析数据保留 6 个月。CDN、安全、支持及运行日志处理可能发生在所选地域之外，具体以 [Umami Cloud 地域说明](https://docs.umami.is/docs/cloud/faq)、[隐私政策](https://umami.is/privacy)及其数据处理协议为准。

Analytics applies only to the website. **The Mac and iPhone apps do not collect usage analytics** or include analytics SDKs. Their audio, permissions, local data and update-check behavior described above remains unchanged.

The website uses cookieless anonymous analytics through Umami Cloud (enabled 2026-11-01). It counts fixed page paths, referring site origins, country/region, browser/OS and device type, plus downloads, iPhone acquisition, share/copy outcomes (cancellation counts as failure), arrivals from iOS, language switches, manual video plays, sound activation, FAQ numbers and scroll milestones. Only short enumerated properties are sent. URL queries, fragments, referrer paths, user input, clipboard contents, share recipients and personal details are excluded. Normal HTTP requests expose IP/User-Agent to the provider for approximate location and anonymous aggregation; raw IP addresses are not stored as visitor profiles. There is no cross-site tracking, advertising ID, session replay or additional fingerprinting.

No cookies or browser storage are written. An empty website ID, local development URL, DNT or GPC prevents loading and reporting. Enable DNT/GPC and reload to opt out. Analytics failure does not affect site features. No cookie consent banner is needed for this configuration; applicable data protection duties still apply. Before activation, select the EU data region: analytics is stored there (Hobby retention: six months), while CDN, security, support and operational logs may be processed elsewhere under Umami's terms. No account has been created and no analytics data has been collected for this integration.
