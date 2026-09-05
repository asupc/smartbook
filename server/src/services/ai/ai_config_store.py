"""ai_config_json 的读 / 掩码 / 合并工具 — profile 掩码与 /ai/providers CRUD 共用。

`UserProfile.ai_config_json` 的 providers[]/binding 段是「AI 服务商 + 能力绑定」
的唯一存储(provider_client 解析、/ai/parse-tx-*、/ai/ask、MCP 都从这读)。
密钥策略:**只存不吐** —— 所有对外返回都必须先过 `mask_ai_config()`;写入口
见空 / 掩码 key 一律保留原值(`merge_ai_config_on_patch` / providers CRUD),
保证客户端拿到掩码后原样回传不会把真 key 冲掉。
"""
from __future__ import annotations

import json
import logging
from typing import Any

from ...models import UserProfile  # noqa: F401  (类型提示用;保持导入面稳定)

logger = logging.getLogger(__name__)

# 掩码前缀:对外返回的 apiKey 永远以它开头;写入口见到它 = 「key 未修改」。
MASK_PREFIX = "****"

# 内置智谱服务商 id(与 mobile AIServiceProviderConfig.zhipuDefault 对齐)。
BUILTIN_PROVIDER_ID = "zhipu_glm"


def load_ai_config(profile: UserProfile | None) -> dict:
    """把 DB 里的 ai_config_json TEXT 解析成 dict;无值 / 非法 JSON → {}。"""
    if profile is None or not profile.ai_config_json:
        return {}
    try:
        cfg = json.loads(profile.ai_config_json)
    except (ValueError, TypeError):
        logger.warning("ai_config_json parse failed: %s", profile.ai_config_json[:80])
        return {}
    return cfg if isinstance(cfg, dict) else {}


def dump_ai_config(cfg: dict) -> str:
    return json.dumps(cfg, ensure_ascii=False, sort_keys=True)


def get_providers(cfg: dict) -> list[dict[str, Any]]:
    providers = cfg.get("providers")
    if not isinstance(providers, list):
        return []
    return [p for p in providers if isinstance(p, dict)]


def get_binding(cfg: dict) -> dict[str, Any]:
    binding = cfg.get("binding")
    return dict(binding) if isinstance(binding, dict) else {}


def find_provider(cfg: dict, provider_id: str) -> dict[str, Any] | None:
    for p in get_providers(cfg):
        if p.get("id") == provider_id:
            return p
    return None


def mask_api_key(key: str | None) -> str:
    """`sk-abcd1234` → `****1234`;空 key → ""。"""
    if not key:
        return ""
    if len(key) <= 4:
        return MASK_PREFIX
    return f"{MASK_PREFIX}{key[-4:]}"


def is_unset_key(key: str | None) -> bool:
    """写入口语义:apiKey 缺省 / 空 / 掩码值都表示「没有提供新 key」。"""
    if not key:
        return True
    return key.startswith(MASK_PREFIX)


def mask_ai_config(cfg: dict | None) -> dict | None:
    """返回对外安全副本:providers[].apiKey 全部掩码,其余字段原样透传
    (customPromptTemplate / strategy 等非敏感字段照常返回)。"""
    if cfg is None:
        return None
    out = dict(cfg)
    providers = get_providers(cfg)
    if providers:
        out["providers"] = [
            {**p, "apiKey": mask_api_key(p.get("apiKey"))} for p in providers
        ]
    return out


def merge_ai_config_on_patch(existing: dict | None, incoming: dict) -> dict | None:
    """PATCH /profile/me 的 ai_config 合并规则。

    主体仍是「整体替换」,但两个密钥相关段特殊:
    - incoming **不带** `providers` 键 → 保留 existing 的 providers(新客户端
      不再经 profile 同步服务商,只同步 prompt/strategy 等非敏感段);
    - incoming 带 `providers` → 逐 provider 按 id 合并 apiKey:传入空 / 掩码
      = 保留原值,传真实 key = 替换。binding 段同理,不带则保留。

    返回 None 表示合并结果为空(等价于清空,保持旧的 `{}` 清空语义)。
    """
    base = dict(existing or {})
    merged = dict(incoming)

    old_by_id = {
        p.get("id"): p for p in get_providers(base) if isinstance(p.get("id"), str)
    }
    if "providers" in merged and isinstance(merged.get("providers"), list):
        new_list: list[dict[str, Any]] = []
        for p in merged["providers"]:
            if not isinstance(p, dict):
                continue
            old = old_by_id.get(p.get("id"))
            if old and is_unset_key(p.get("apiKey")):
                p = {**p, "apiKey": old.get("apiKey") or ""}
            new_list.append(p)
        merged["providers"] = new_list
    if "providers" not in merged and "providers" in base:
        merged["providers"] = base["providers"]
    if "binding" not in merged and "binding" in base:
        merged["binding"] = base["binding"]

    if not merged:
        return None
    return merged
