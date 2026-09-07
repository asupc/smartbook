"""内置 AI 服务商目录 — 服务端权威,GET /ai/providers 时 ensure 落库。

与 mobile `AIServiceProviderConfig` 内置项对齐(id 一致才能被能力绑定引用)。
内置服务商 `isBuiltIn=True`:不可删除;用户只需要填 apiKey —— baseUrl / 默认
模型 / 协议都由这里给默认值。

`protocol` 字段(2026-09):`openai`(OpenAI-compatible /chat/completions)或
`anthropic`(Anthropic /v1/messages)。存量用户的 providers 段没有该字段,
provider_client 读到缺省一律按 `openai` 处理(行为与升级前完全一致);
GET /ai/providers 的 ensure 会顺手给内置行补上 protocol。
"""
from __future__ import annotations

from typing import Any

# 协议取值(provider_client / test_provider 按 It 分派调用实现)
PROTOCOL_OPENAI = "openai"
PROTOCOL_ANTHROPIC = "anthropic"
KNOWN_PROTOCOLS = {PROTOCOL_OPENAI, PROTOCOL_ANTHROPIC}

# 内置目录。audioModel 留空 = 该家没有 /audio/transcriptions 语音转写,
# App 端 UI 不显示语音能力 chip。
# - DeepSeek:OpenAI 兼容 https://api.deepseek.com/v1;另有 Anthropic 兼容
#   入口 /anthropic(用户想走 Anthropic 协议可自行改 baseUrl + protocol)。
# - Kimi:https://api.moonshot.cn/v1;kimi-k2.6 支持 thinking.type 开关,
#   视觉走同款 chat 模型的多模态 content。
# - MiniMax:国内站 https://api.minimaxi.com/v1(国际站 api.minimax.io),
#   无 /audio/transcriptions,语音留空。
# - 小米 MiMo:开放平台 OpenAI 兼容入口;仅文本。
#
# `visionConcurrency`:一次多图批量识别(/relay/vision-batch)时,服务端同一
# 时刻最多并行发给该模型的图片数(有上限并发队列,超出排队)。只对 vision 相关
# 调用生效;各家能安全并行请求的量不同,由此字段按服务商控制。
BUILTIN_PROVIDER_TEMPLATES: list[dict[str, Any]] = [
    {
        "id": "zhipu_glm",
        "name": "智谱GLM",
        "protocol": PROTOCOL_OPENAI,
        "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
        "textModel": "glm-4-flash",
        "visionModel": "glm-4v-flash",
        "audioModel": "glm-4-voice",
        "visionConcurrency": 3,
    },
    {
        "id": "deepseek_builtin",
        "name": "DeepSeek",
        "protocol": PROTOCOL_OPENAI,
        "baseUrl": "https://api.deepseek.com/v1",
        "textModel": "deepseek-v4-flash",
        "visionModel": "deepseek-v4-flash-vision-exp",
        "audioModel": "",
        "visionConcurrency": 3,
    },
    {
        "id": "kimi_builtin",
        "name": "Kimi",
        "protocol": PROTOCOL_OPENAI,
        "baseUrl": "https://api.moonshot.cn/v1",
        "textModel": "kimi-k2.6",
        "visionModel": "kimi-k2.6",
        "audioModel": "",
        "visionConcurrency": 3,
    },
    {
        "id": "minimax_builtin",
        "name": "MiniMax",
        "protocol": PROTOCOL_OPENAI,
        "baseUrl": "https://api.minimaxi.com/v1",
        "textModel": "MiniMax-M2",
        "visionModel": "MiniMax-M2",
        "audioModel": "",
        "visionConcurrency": 3,
    },
    {
        "id": "xiaomi_mimo_builtin",
        "name": "小米 MiMo",
        "protocol": PROTOCOL_OPENAI,
        "baseUrl": "https://api.xiaomimimo.com/v1",
        "textModel": "MiMo",
        "visionModel": "",
        "audioModel": "",
        "visionConcurrency": 3,
    },
]

# 未单独配置 visionConcurrency 的存量服务商 / 自定义 provider 用该默认值。
DEFAULT_VISION_CONCURRENCY = 3

BUILTIN_PROVIDER_IDS = {t["id"] for t in BUILTIN_PROVIDER_TEMPLATES}


def ensure_builtin_providers(cfg: dict) -> tuple[dict, bool]:
    """把缺失的内置服务商补进 cfg["providers"],并给内置行补 protocol 缺省。

    返回 (cfg, changed)。不落库 —— 调用方决定是否持久化(GET /providers 时
    changed=True 才写 DB)。已有同 id 行用户改过的字段一律不动。
    """
    providers = [p for p in cfg.get("providers", []) if isinstance(p, dict)]
    changed = False

    existing = {p.get("id") for p in providers}
    for tpl in BUILTIN_PROVIDER_TEMPLATES:
        if tpl["id"] not in existing:
            providers.append(dict(tpl))
            changed = True

    for p in providers:
        if p.get("id") in BUILTIN_PROVIDER_IDS and not p.get("protocol"):
            p["protocol"] = PROTOCOL_OPENAI
            changed = True

    if changed:
        cfg["providers"] = providers
    return cfg, changed
