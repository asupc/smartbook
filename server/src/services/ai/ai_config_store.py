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
import re
from typing import Any

from ...models import UserProfile  # noqa: F401  (类型提示用;保持导入面稳定)
from ...schemas import MAX_AI_CONFIG_BYTES, MAX_AI_CONFIG_DEPTH, json_depth_ok

logger = logging.getLogger(__name__)

# 掩码前缀:对外返回的 apiKey 永远以它开头;写入口见到它 = 「key 未修改」。
MASK_PREFIX = "****"

# 「形如掩码」的判据:一串星号 + 最多 6 个「key 尾字符」(掩码格式 `****` + 末 4 位)。
# 尾字符集必须含 `-` / `_`:真实 API key 常见 `sk-real-key-99` → `****e-99`、
# `****-123` 这类掩码,不含它们会把正常回传的掩码误判成新 key(正是本修复要
# 消灭的行为)。
#
# 历史上的实现是 `key.startswith("****")`,于是**任何变形**都被当成真 key:
#   - `***abcd`(少一个星,UI 截断 / 网关折叠)
#   - ` ****abcd`(剪贴板 / 表单带空白)
#   - `*`(整体被压成一个星)
# 这些串视觉上就是掩码,但会被静默写成新 key —— 真 key 被冲成垃圾串,之后所有
# AI 调用 401,而掩码显示几乎不变(`****abcd` → `****abcd` 只差一个星),用户
# 无从发现。因此判据必须比「前缀相等」宽:星号开头 + 短尾一律视为「未修改」。
#
# 误伤面:真实 API key 不以 `*` 开头,故该判据对真 key 无副作用。
_MASK_LIKE_RE = re.compile(r"^\*+[0-9A-Za-z_-]{0,6}$")


def looks_like_mask(key: str | None) -> bool:
    """串本身是否「形如掩码」(strip 后星号开头 + 短尾)。"""
    if not key:
        return False
    return bool(_MASK_LIKE_RE.match(key.strip()))


def is_mask_of(key: str | None, real_key: str | None) -> bool:
    """`key` 是否**恰好等于** `real_key` 的当前掩码。

    正则兜不住未来掩码格式变化(如改成 `sk-…abcd`);这里再做一次「与当前掩码
    逐字相同」判定 —— 客户端把服务端刚下发的掩码原样回传是最常见的形态,
    必须无条件保留原 key。
    """
    if not key or not real_key:
        return False
    return key.strip() == mask_api_key(real_key)

# 内置智谱服务商 id(与 mobile AIServiceProviderConfig.zhipuDefault 对齐)。
BUILTIN_PROVIDER_ID = "zhipu_glm"


def load_ai_config(profile: UserProfile | None) -> dict:
    """把 DB 里的 ai_config_json TEXT 解析成 dict;无值 / 非法 JSON → {}。"""
    if profile is None or not profile.ai_config_json:
        return {}
    try:
        cfg = json.loads(profile.ai_config_json)
    except (ValueError, TypeError):
        # 不打印内容片段:`ai_config_json` 按 sort_keys 序列化后 `apiKey` 是
        # 首个字段,前 80 字足以泄露真 key 的一截。只记长度。
        logger.warning("ai_config_json parse failed (len=%d)", len(profile.ai_config_json))
        return {}
    return cfg if isinstance(cfg, dict) else {}


def serialize_ai_config(cfg: dict) -> str:
    """ai_config 的**存储序列化**（写侧唯一口径）。

    必须是 `dump_ai_config` 实际落库的那个串（`sort_keys=True` + 默认分隔符），
    否则「判定用的字节数」与「真正存下去的字节数」会错位（差 ~0.2%，足以让
    「刚好压线」的配置过判据却写出更大的行）。
    """
    return json.dumps(cfg, ensure_ascii=False, sort_keys=True)


def ai_config_json_bytes(cfg: dict | None) -> int:
    """`cfg` 按存储序列化后的 **UTF-8 字节**数（与 `MAX_AI_CONFIG_BYTES` 同口径）。

    缺陷 3：schema 的 `max_length` 数的是**字符**，上限数的是**字节** ——
    CJK 下 1 字符 = 3 字节，同一份配置在两种口径下差 ~3 倍。任何做大小判断的
    代码都必须走本函数（而不是 `len(json.dumps(...))`，那是字符数）。
    """
    if cfg is None:
        return 0
    return len(serialize_ai_config(cfg).encode("utf-8"))


class AIConfigBoundsError(ValueError):
    """ai_config 超出写侧上限（深度 / 体积）—— 调用方应归一成 4xx。

    读侧**不**用这两个上限判「畸形」：那是 2026-10-11 的 BLOCKER（合法但
    体积大的配置在 GET /profile/me 时被归零）。上限是**输入收窄**，目的是
    让读侧看到的内容天然有界。
    """


def enforce_ai_config_bounds(
    cfg: dict | None,
    *,
    stored_bytes: int | None = None,
    serialized: str | None = None,
) -> None:
    """写侧边界：深度 ≤ 8 + 序列化体积 ≤ 256 KB，超限抛 `AIConfigBoundsError`。

    **缩容豁免（2026-10-11 缺陷 2）**：传入 `stored_bytes`（当前库内
    `ai_config_json` 的字节数）时，任何**不超过**该值的写入一律放行 ——
    配置只会变小，永远不会把用户锁死在「存了的行读不出、想删却写不进」的
    状态。可达路径：CJK 字段把已存配置撑到上限之上（满配 32 个 CJK provider
    ≈ 488 KiB，见 `MAX_AI_CONFIG_BYTES` 注释），此时
    `DELETE /ai/providers/{id}` 与 `POST` 都因落库边界 400
    `AI_CONFIG_TOO_LARGE`，用户唯一的自助出口只剩 `PATCH /profile/me`
    （非显然）。豁免让「逐个删 provider」这条最自然的路恢复可用。

    绝对上限对**真增长**的写入仍然生效（`stored_bytes` 为 None 或新配置更大）
    —— 防的是无界增长，不是存量行。

    体积按 [ai_config_json_bytes][src.services.ai.ai_config_store.ai_config_json_bytes]
    的字节口径算（`serialized` 可传入已算好的存储串，避免重复 dumps）。

    这是同一个上限的**唯一实现**：`/profile/me` 的 PATCH 走
    `schemas.BoundedAIConfigOptional`（同值），`/ai/providers` CRUD 与
    自愈脚本走这里 —— 两个入口互相兜底，任何路径写入的 ai_config 都有界。
    """
    if cfg is None:
        return
    if not isinstance(cfg, dict):
        raise AIConfigBoundsError("ai_config must be a JSON object")
    if not json_depth_ok(cfg, max_depth=MAX_AI_CONFIG_DEPTH):
        raise AIConfigBoundsError(f"ai_config nesting too deep (max {MAX_AI_CONFIG_DEPTH})")
    if serialized is None:
        serialized = serialize_ai_config(cfg)
    size = len(serialized.encode("utf-8"))
    if stored_bytes is not None and size <= stored_bytes:
        # 缩容（或不变）：只可能让存量行更小，永不放行增长。
        return
    if size > MAX_AI_CONFIG_BYTES:
        raise AIConfigBoundsError(
            f"ai_config too large (max {MAX_AI_CONFIG_BYTES} bytes, got {size})"
        )


def dump_ai_config(cfg: dict, *, stored_bytes: int | None = None) -> str:
    """序列化 ai_config 为存储文本（**写侧唯一的落库出口**）。

    带边界校验：`/ai/providers` CRUD 的历史路径不经过 profile 的入参
    schema（`BoundedFreeDict`），因此边界必须在这里兜住 —— 否则无限增长
    （更多内置 / 未来字段）会再次把读侧拖进「合法但超大」的两难。
    校验失败抛 `AIConfigBoundsError`。

    `stored_bytes` 透传给 `enforce_ai_config_bounds` 的缩容豁免（见其
    docstring）—— 调用方若能拿到库内当前大小就该传，让「只变小」的写入
    在存量超限时仍然可用。
    """
    dumped = serialize_ai_config(cfg)
    enforce_ai_config_bounds(cfg, stored_bytes=stored_bytes, serialized=dumped)
    return dumped



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
    """写入口语义:apiKey 缺省 / 空 / **形如掩码** 都表示「没有提供新 key」。

    掩码判据覆盖变形输入(少一个星 / 带空白 / 只有一个 `*`)—— 见
    `_MASK_LIKE_RE` 的注释:把变形掩码当真 key 会静默冲掉真 key。
    """
    if not key:
        return True
    return looks_like_mask(key)


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
            incoming_key = p.get("apiKey")
            if old and (
                is_unset_key(incoming_key)
                # 二次判定:回传的串恰好等于该 provider 的当前掩码(未来掩码
                # 格式变化也兜住),同样保留原 key。
                or is_mask_of(incoming_key, old.get("apiKey"))
            ):
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
