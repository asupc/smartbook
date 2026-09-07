"""AI 服务商配置 CRUD(`/api/v1/ai/providers`)— 密钥只存服务端。

App 的「AI 服务商管理」页改为直接调这里;数据仍落在
`UserProfile.ai_config_json` 的 providers[]/binding 段(结构不变),
`provider_client` 解析、/ai/parse-tx-*、/ai/ask、MCP、Web 全部无感。

密钥策略:**只存不吐** —— 列表 / 详情返回的 apiKey 一律是 `****+末4位`
掩码,另带 `hasApiKey` 供 UI 显示;写入口(PATCH)收到空 / 掩码值 = 保留
原值。字段命名沿用 mobile 端 camelCase(与 ai_config_json 内部结构一致)。

- `GET    /providers`            列表 + binding(掩码)
- `POST   /providers`            新建(apiKey 必填;isBuiltIn 仅限内置 id)
- `PATCH  /providers/{id}`       部分更新(apiKey 缺省 / 掩码 = 保留)
- `DELETE /providers/{id}`       删除(内置不可删;相关能力重绑到内置智谱)
- `PUT    /providers/binding`    text / vision / speech 三能力绑定
- `POST   /providers/test`       按 provider_id 用**存储的**配置测试
                                 (复用 test-provider 的探测与错误分类)
"""
from __future__ import annotations

import logging
import time
from typing import Any, Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from ...database import get_db
from ...deps import get_current_user, require_any_scopes
from ...models import User, UserProfile
from ...security import SCOPE_APP_WRITE, SCOPE_WEB_WRITE
from ...services.ai.ai_config_store import (
    BUILTIN_PROVIDER_ID,
    dump_ai_config,
    find_provider,
    get_binding,
    get_providers,
    is_unset_key,
    load_ai_config,
    mask_api_key,
)
from ...services.ai.builtin_providers import (
    BUILTIN_PROVIDER_IDS,
    BUILTIN_PROVIDER_TEMPLATES,
    KNOWN_PROTOCOLS,
    PROTOCOL_OPENAI,
    ensure_builtin_providers,
)

import httpx

logger = logging.getLogger(__name__)
router = APIRouter()

_PROVIDERS_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_WRITE)


# ──────────────── 请求 / 响应 schema(字段名与 ai_config_json 对齐,camelCase)


class ProviderUpsertIn(BaseModel):
    id: str | None = Field(default=None, max_length=64)
    name: str = Field(min_length=1, max_length=64)
    isBuiltIn: bool = False
    apiKey: str = Field(default="", max_length=4096)
    baseUrl: str = Field(default="", max_length=512)
    textModel: str = Field(default="", max_length=128)
    visionModel: str = Field(default="", max_length=128)
    audioModel: str = Field(default="", max_length=128)
    protocol: str | None = Field(default=None, max_length=32)
    # 一次多图批量识别(/relay/vision-batch)时,该服务商最多并行处理的图片数。
    visionConcurrency: int | None = Field(default=None, ge=1, le=32)
    createdAt: str | None = Field(default=None, max_length=40)


class ProviderPatchIn(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=64)
    apiKey: str | None = Field(default=None, max_length=4096)
    baseUrl: str | None = Field(default=None, max_length=512)
    textModel: str | None = Field(default=None, max_length=128)
    visionModel: str | None = Field(default=None, max_length=128)
    audioModel: str | None = Field(default=None, max_length=128)
    protocol: str | None = Field(default=None, max_length=32)
    visionConcurrency: int | None = Field(default=None, ge=1, le=32)


class BindingIn(BaseModel):
    textProviderId: str | None = Field(default=None, max_length=64)
    visionProviderId: str | None = Field(default=None, max_length=64)
    speechProviderId: str | None = Field(default=None, max_length=64)


class ProviderTestIn(BaseModel):
    providerId: str = Field(min_length=1, max_length=64)
    capability: Literal["text", "vision", "speech"]


class ProviderOut(BaseModel):
    id: str
    name: str
    isBuiltIn: bool
    apiKey: str  # 永远是掩码
    hasApiKey: bool
    baseUrl: str
    textModel: str
    visionModel: str
    audioModel: str
    protocol: str = PROTOCOL_OPENAI
    visionConcurrency: int = 3
    createdAt: str | None = None


class ProviderListOut(BaseModel):
    providers: list[ProviderOut]
    binding: dict[str, Any]


class ProviderTestOut(BaseModel):
    success: bool
    error_code: str | None = None
    error_message: str | None = None
    latency_ms: int = 0
    preview: str = ""


def _to_out(p: dict[str, Any]) -> ProviderOut:
    key = p.get("apiKey") or ""
    protocol = p.get("protocol") or PROTOCOL_OPENAI
    return ProviderOut(
        id=p.get("id") or "",
        name=p.get("name") or "",
        isBuiltIn=bool(p.get("isBuiltIn")),
        apiKey=mask_api_key(key),
        hasApiKey=bool(key),
        baseUrl=p.get("baseUrl") or "",
        textModel=p.get("textModel") or "",
        visionModel=p.get("visionModel") or "",
        audioModel=p.get("audioModel") or "",
        protocol=protocol if protocol in KNOWN_PROTOCOLS else PROTOCOL_OPENAI,
        visionConcurrency=int(p.get("visionConcurrency") or 3),
        createdAt=p.get("createdAt"),
    )


def _load_profile(db: Session, user_id: str) -> UserProfile | None:
    return db.scalar(select(UserProfile).where(UserProfile.user_id == user_id))


def _validate_protocol(protocol: str | None) -> str:
    """protocol 写入口校验:None / 空 = openai 缺省;非法值 400。"""
    if not protocol:
        return PROTOCOL_OPENAI
    if protocol not in KNOWN_PROTOCOLS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_PROVIDER_INVALID",
                "message": f"protocol must be one of {sorted(KNOWN_PROTOCOLS)}, got {protocol!r}",
            },
        )
    return protocol


async def _broadcast_providers_changed(request: Request, *, user_id: str) -> None:
    """providers/binding 变更后广播 profile_change,让其它登录设备实时拉
    /ai/providers 刷新掩码缓存(修复「App 改了配置,另一台设备不生效」)。
    广播不带 ai_config 本体;客户端收到后各自走 refreshFromServer。失败不 break 请求。"""
    try:
        ws_manager = getattr(request.app.state, "ws_manager", None)
        if ws_manager is None:
            logger.info("ai.providers.broadcast: ws_manager unavailable, skip user=%s", user_id)
            return
        await ws_manager.broadcast_to_user(user_id, {"type": "profile_change", "ai_providers_changed": True})
        logger.info("ai.providers.broadcast: done user=%s", user_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("ai.providers.broadcast: failed user=%s err=%s", user_id, exc)


def _save_config(db: Session, profile: UserProfile | None, user_id: str, cfg: dict) -> UserProfile:
    if profile is None:
        profile = UserProfile(user_id=user_id)
        db.add(profile)
    profile.ai_config_json = dump_ai_config(cfg)
    db.commit()
    return profile


# ──────────────── 查询


@router.get("/providers", response_model=ProviderListOut)
def list_providers(
    response: Response,
    _scopes: set[str] = Depends(_PROVIDERS_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProviderListOut:
    profile = _load_profile(db, current_user.id)
    cfg = load_ai_config(profile)
    # 内置服务商目录(智谱 / DeepSeek / Kimi / MiniMax / 小米 MiMo)缺哪个补
    # 哪个,并给内置行补 protocol 缺省。有补齐动作时落库,下次不再写;
    # X-AI-Providers-Seeded 头给客户端/排查用。
    cfg, changed = ensure_builtin_providers(cfg)
    if changed:
        _save_config(db, profile, current_user.id, cfg)
        response.headers["X-AI-Providers-Seeded"] = "1"
    return ProviderListOut(
        providers=[_to_out(p) for p in get_providers(cfg)],
        binding=get_binding(cfg),
    )


# ──────────────── 新建


@router.post("/providers", response_model=ProviderOut, status_code=status.HTTP_201_CREATED)
async def create_provider(
    payload: ProviderUpsertIn,
    request: Request,
    _scopes: set[str] = Depends(_PROVIDERS_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProviderOut:
    profile = _load_profile(db, current_user.id)
    cfg = load_ai_config(profile)
    providers = get_providers(cfg)

    provider_id = (payload.id or "").strip() or f"prov_{uuid4().hex}"
    if any(p.get("id") == provider_id for p in providers):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_PROVIDER_EXISTS", "message": f"provider id {provider_id!r} already exists"},
        )
    if payload.isBuiltIn and provider_id not in BUILTIN_PROVIDER_IDS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_PROVIDER_INVALID", "message": "isBuiltIn is reserved for built-in providers"},
        )

    provider: dict[str, Any] = {
        "id": provider_id,
        "name": payload.name,
        "isBuiltIn": payload.isBuiltIn,
        "apiKey": payload.apiKey,
        "baseUrl": payload.baseUrl,
        "textModel": payload.textModel,
        "visionModel": payload.visionModel,
        "audioModel": payload.audioModel,
        "protocol": _validate_protocol(payload.protocol),
        "visionConcurrency": payload.visionConcurrency or 3,
    }
    if payload.createdAt:
        provider["createdAt"] = payload.createdAt
    providers.append(provider)
    cfg["providers"] = providers
    _save_config(db, profile, current_user.id, cfg)
    await _broadcast_providers_changed(request, user_id=current_user.id)
    return _to_out(provider)


# ──────────────── 更新


@router.patch("/providers/{provider_id}", response_model=ProviderOut)
async def update_provider(
    provider_id: str,
    payload: ProviderPatchIn,
    request: Request,
    _scopes: set[str] = Depends(_PROVIDERS_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProviderOut:
    cfg = load_ai_config(_load_profile(db, current_user.id))
    provider = find_provider(cfg, provider_id)
    if provider is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "AI_PROVIDER_NOT_FOUND", "message": f"provider {provider_id!r} not found"},
        )

    if payload.name is not None:
        provider["name"] = payload.name
    if payload.baseUrl is not None:
        provider["baseUrl"] = payload.baseUrl
    if payload.textModel is not None:
        provider["textModel"] = payload.textModel
    if payload.visionModel is not None:
        provider["visionModel"] = payload.visionModel
    if payload.audioModel is not None:
        provider["audioModel"] = payload.audioModel
    if payload.protocol is not None:
        provider["protocol"] = _validate_protocol(payload.protocol)
    if payload.visionConcurrency is not None:
        provider["visionConcurrency"] = payload.visionConcurrency
    if payload.apiKey is not None and not is_unset_key(payload.apiKey):
        provider["apiKey"] = payload.apiKey

    cfg["providers"] = get_providers(cfg)
    _save_config(db, _load_profile(db, current_user.id), current_user.id, cfg)
    await _broadcast_providers_changed(request, user_id=current_user.id)
    return _to_out(provider)


# ──────────────── 删除


@router.delete("/providers/{provider_id}")
async def delete_provider(
    provider_id: str,
    request: Request,
    _scopes: set[str] = Depends(_PROVIDERS_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, bool]:
    cfg = load_ai_config(_load_profile(db, current_user.id))
    # 内置 id 保护优先于存在性检查:目录还没被 GET 种进 DB 时也拒绝(不是 404)
    if provider_id in BUILTIN_PROVIDER_IDS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_PROVIDER_BUILTIN", "message": "built-in provider cannot be deleted"},
        )
    provider = find_provider(cfg, provider_id)
    if provider is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "AI_PROVIDER_NOT_FOUND", "message": f"provider {provider_id!r} not found"},
        )
    if provider.get("isBuiltIn"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_PROVIDER_BUILTIN", "message": "built-in provider cannot be deleted"},
        )

    cfg["providers"] = [p for p in get_providers(cfg) if p.get("id") != provider_id]
    # 相关能力重绑到内置智谱(与 mobile 删除服务商后的语义一致)
    binding = get_binding(cfg)
    for key in ("textProviderId", "visionProviderId", "speechProviderId"):
        if binding.get(key) == provider_id:
            binding[key] = BUILTIN_PROVIDER_ID
    if binding:
        cfg["binding"] = binding
    _save_config(db, _load_profile(db, current_user.id), current_user.id, cfg)
    await _broadcast_providers_changed(request, user_id=current_user.id)
    return {"ok": True}


# ──────────────── 能力绑定


@router.put("/providers/binding")
async def update_binding(
    payload: BindingIn,
    request: Request,
    _scopes: set[str] = Depends(_PROVIDERS_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    cfg = load_ai_config(_load_profile(db, current_user.id))
    binding = {
        "textProviderId": payload.textProviderId,
        "visionProviderId": payload.visionProviderId,
        "speechProviderId": payload.speechProviderId,
    }
    cfg["binding"] = binding
    _save_config(db, _load_profile(db, current_user.id), current_user.id, cfg)
    await _broadcast_providers_changed(request, user_id=current_user.id)
    return {"binding": binding}


# ──────────────── 用存储配置测试(复用 test-provider 的探测 helper)


@router.post("/providers/test", response_model=ProviderTestOut)
async def test_stored_provider(
    payload: ProviderTestIn,
    _scopes: set[str] = Depends(_PROVIDERS_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProviderTestOut:
    cfg = load_ai_config(_load_profile(db, current_user.id))
    provider = find_provider(cfg, payload.providerId)
    if provider is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "AI_PROVIDER_NOT_FOUND", "message": f"provider {payload.providerId!r} not found"},
        )

    cap = payload.capability
    model_key = {"text": "textModel", "vision": "visionModel", "speech": "audioModel"}[cap]
    api_key = provider.get("apiKey") or ""
    base_url = (provider.get("baseUrl") or "").rstrip("/")
    model = provider.get(model_key) or ""
    protocol = provider.get("protocol") or PROTOCOL_OPENAI
    if not api_key or not base_url or not model:
        return ProviderTestOut(
            success=False,
            error_code="AI_TEST_MISSING_FIELDS",
            error_message=f"apiKey / baseUrl / {model_key} missing",
        )

    started = time.monotonic()
    try:
        if cap == "text":
            preview = await _test_text(base_url, api_key, model, protocol=protocol)
        elif cap == "vision":
            preview = await _test_vision(base_url, api_key, model, protocol=protocol)
        else:
            if protocol == "anthropic":
                return ProviderTestOut(
                    success=False,
                    error_code="AI_TEST_MISSING_FIELDS",
                    error_message="Anthropic protocol has no speech-to-text API",
                )
            preview = await _test_speech(base_url, api_key, model)
        latency = int((time.monotonic() - started) * 1000)
        logger.info(
            "ai.providers.test success user=%s provider=%s capability=%s model=%s latency=%dms",
            current_user.id, payload.providerId, cap, model, latency,
        )
        return ProviderTestOut(success=True, latency_ms=latency, preview=preview[:200] if preview else "")
    except _UpstreamHTTPError as exc:
        latency = int((time.monotonic() - started) * 1000)
        code = _classify_error(exc.status_code, exc.body)
        logger.warning(
            "ai.providers.test upstream error user=%s provider=%s status=%d code=%s",
            current_user.id, payload.providerId, exc.status_code, code,
        )
        return ProviderTestOut(
            success=False,
            error_code=code,
            error_message=f"{exc.status_code}: {exc.body[:200]}",
            latency_ms=latency,
        )
    except httpx.TimeoutException as exc:
        latency = int((time.monotonic() - started) * 1000)
        return ProviderTestOut(success=False, error_code="AI_TEST_TIMEOUT", error_message=str(exc), latency_ms=latency)
    except httpx.HTTPError as exc:
        latency = int((time.monotonic() - started) * 1000)
        return ProviderTestOut(success=False, error_code="AI_TEST_NETWORK", error_message=str(exc), latency_ms=latency)
    except Exception as exc:  # noqa: BLE001 — diagnostic last-resort
        latency = int((time.monotonic() - started) * 1000)
        logger.exception("ai.providers.test unknown user=%s err=%s", current_user.id, exc)
        return ProviderTestOut(success=False, error_code="AI_TEST_UNKNOWN", error_message=str(exc), latency_ms=latency)


# 从同包 test_provider.py 复用的探测实现与错误分类(包内共享 helper 的
# 既有惯例,同 _parse_and_log 被 parse_tx_text 复用一样)
from .test_provider import (  # noqa: E402
    _UpstreamHTTPError,
    _classify_error,
    _test_speech,
    _test_text,
    _test_vision,
)
