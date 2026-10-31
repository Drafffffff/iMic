# 百炼国际站公开文档核对

查阅日期：2026-10-31（北京时间）；仅访问公开文档，没有注册或登录阿里云账号，没有调用付费模型。

| 核对项 | 结论与依据 |
| --- | --- |
| 国际站控制台 | [Model Studio](https://modelstudio.console.alibabacloud.com/)；[新加坡 API Key 页](https://modelstudio.console.alibabacloud.com/ap-southeast-1/model/settings/api-key)。地址直接取自[官方地域表](https://www.alibabacloud.com/help/en/model-studio/regions)。英文 App / 官网 / README 使用此地址；中文保持中国站入口。 |
| 账号与地域 | 国际站文档列出北京、新加坡、弗吉尼亚、法兰克福、东京、香港；每个地域的 Key、模型清单、endpoint 独立。具体账号资格、受限国家/模型审批取决于服务开通，文档没有承诺所有账号无条件可用。[地域文档](https://www.alibabacloud.com/help/en/model-studio/regions) |
| 免费额度 | 国际站首次开通后，符合条件的新加坡、International 范围模型有免费额度，有效期 90 天；需完善账号信息。用完/到期后自动按量计费，Free Quota Only 默认关闭，应自行开启以免超额扣费。不能把中国站“仅北京有免费额度”的说明套用于国际站，也不能保证这两个具体模型都有额度。[国际站免费额度说明](https://www.alibabacloud.com/help/en/model-studio/new-free-quota) |
| 语音模型 | 官方实时识别文档的 Singapore 列表明确含 `qwen-audio-3.1-asr-flash-message`。[Supported models and regions](https://www.alibabacloud.com/help/en/model-studio/real-time-speech-recognition-user-guide) |
| 润色模型 | 官方[模型总览](https://www.alibabacloud.com/help/en/model-studio/models)将 `deepseek-v4.1-flash` 链接到新加坡模型页；[DeepSeek API](https://www.alibabacloud.com/help/en/model-studio/deepseek-api)也列出新加坡 endpoint 和此模型的北京/新加坡支持。可用性有公开依据；本任务保持默认模型，不保证某个账号已获模型权限。 |
| 国际站 Key 的识别 | 现有 `BailianDiscovery` 已探测 `dashscope-intl.aliyuncs.com`，支持手填 `{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`。官方均使用 Bearer API Key；无需本任务更改探测逻辑。`test-polish.sh` 的模拟 HTTP 测试验证唯一新加坡成功、同步识别与润色地址、workspace/trial、401、歧义和权限不足。没有国际站真实 Key，因此未做真实账号验证。 |
| 后续改动建议 | 本次不需要更换默认模型/域名/验证方式。官方建议生产使用 workspace 专属域名，现有“高级选项”已支持。若特定国际账号在 DashScope 域名被拒、但专属域名可用，应手填 Base URL；后续若需自动发现 workspace，应另立任务并评估 API 与权限，不能从通用 Key 推测 workspace。 |

[获取 Key 文档](https://www.alibabacloud.com/help/en/model-studio/get-api-key)建议权限 All；创建后立即保存完整 Key。套餐 Key 与按量付费 Key 不能混用。英文引导保留这些说明和计费提示，中文原文保持不变并增加海外账号小字。
