from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..config import get_settings
from ..database import get_db
from ..deps import get_current_user, require_any_scopes
from ..models import User, UserProfile
from ..schemas import (
    MAX_SERVABLE_JSON_DEPTH,
    UserProfileAvatarUploadOut,
    UserProfileOut,
    UserProfilePatchRequest,
    json_depth_ok,
)
from ..security import SCOPE_APP_WRITE, SCOPE_OPS_WRITE, SCOPE_WEB_READ, SCOPE_WEB_WRITE
from ..services.ai.ai_config_store import (
    AIConfigBoundsError,
    dump_ai_config,
    mask_ai_config,
    merge_ai_config_on_patch,
)
from .ai.providers import save_ai_config_guarded

router = APIRouter()
settings = get_settings()
logger = logging.getLogger(__name__)


async def _broadcast_profile_change(
    request: Request, *, user_id: str, payload: dict[str, Any]
) -> None:
    """Profile 是 user-scoped 小状态：上传头像 / 改昵称后，把变更推给该用户所
    有连着的 WS（mobile、多标签 web）。对齐 sync.py:393-409 的 sync_change
    广播模式，但 type 用 `profile_change` 区分，客户端只做 profile refetch
    不去重拉交易等其它 section。失败不 break 请求。"""
    try:
        ws_manager = getattr(request.app.state, "ws_manager", None)
        if ws_manager is None:
            logger.info("avatar_sync: ws_manager unavailable, skip broadcast user=%s", user_id)
            return
        message = {"type": "profile_change", **payload}
        logger.info("avatar_sync: broadcast profile_change user=%s payload=%s", user_id, payload)
        await ws_manager.broadcast_to_user(user_id, message)
        logger.info("avatar_sync: broadcast done user=%s", user_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("avatar_sync: broadcast failed user=%s err=%s", user_id, exc)
_READ_SCOPE_DEP = require_any_scopes(
    SCOPE_APP_WRITE,
    SCOPE_WEB_READ,
    SCOPE_WEB_WRITE,
    SCOPE_OPS_WRITE,
)
_AVATAR_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_WRITE, SCOPE_OPS_WRITE)
# PATCH /profile/me 需要让 mobile（app.write）也能调：mobile 要推收支颜色 /
# 主题色到 server。如果只开 web/ops，mobile 的推送全部返回 Insufficient scope。
# 跟 avatar upload 的 scope 集合保持一致。
_PATCH_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_WRITE, SCOPE_OPS_WRITE)

_AVATAR_MAX_UPLOAD_BYTES = 1 * 1024 * 1024
_ALLOWED_IMAGE_MIME_TYPES = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
}


def _avatar_root() -> Path:
    root = Path(settings.attachment_storage_dir).expanduser() / "profile-avatars"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _avatar_url(*, user_id: str, avatar_version: int | None = None) -> str:
    base = f"{settings.api_prefix}/profile/avatar/{user_id}"
    if avatar_version is None:
        return base
    return f"{base}?v={avatar_version}"


def _guess_mime_type(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if ext == ".png":
        return "image/png"
    if ext == ".webp":
        return "image/webp"
    return "application/octet-stream"


def _resolve_avatar_extension(file: UploadFile) -> str:
    content_type = (file.content_type or "").strip().lower()
    if content_type in _ALLOWED_IMAGE_MIME_TYPES:
        return _ALLOWED_IMAGE_MIME_TYPES[content_type]

    file_name = (file.filename or "").strip().lower()
    if file_name.endswith(".jpg") or file_name.endswith(".jpeg"):
        return "jpg"
    if file_name.endswith(".png"):
        return "png"
    if file_name.endswith(".webp"):
        return "webp"

    raise HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail="Profile avatar format invalid",
    )


def _parse_profile_json(
    raw: str | None, *, label: str, max_depth: int = MAX_SERVABLE_JSON_DEPTH
) -> dict | None:
    """把 DB 里的 profile JSON TEXT 列（appearance_json / ai_config_json）
    解析成 dict。无值 / 非法 JSON / 非 dict 顶层 都返 None,让客户端按
    "未设置"处理,不至于请求失败。

    **读侧容错只挡「真的无法服务」的行**:

    - 解析失败（`json.loads` 抛错 / 递归超限）→ 反序列化本身就不可用；
    - 顶层不是 dict → `UserProfileOut.appearance/ai_config: dict | None`
      校验会失败 → 响应 500；
    - 嵌套深度 > `MAX_SERVABLE_JSON_DEPTH`（64）→ pydantic 序列化实测
      90 层仍可、100 层抛 `PydanticSerializationError: Circular reference
      detected`，超深行会把 GET /profile/me 打成永久 500（对抗 F-04）。

    **刻意不做序列化体积检查**（2026-10-11 对抗缺陷 1，BLOCKER）：

    历史实现把**写侧**上限 `MAX_FREE_DICT_BYTES`（64 KB）当读侧畸形判据，
    于是「合法但体积大」的配置（`/ai/providers` 允许 32 个自建服务商 ×
    ~5.6 KB 满配 ≈ 180 KB，正常经官方 API 写入）在用户读一次
    `GET /profile/me` 时被当成畸形行**归零**，真 key 不可恢复地丢失。
    写侧的上限是「输入收窄」，读侧判据必须是「能不能服务」—— 两者不同源。
    现在的大小约束统一放在写侧（`schemas.MAX_AI_CONFIG_BYTES` 256 KB +
    `ai_config_store.enforce_ai_config_bounds`），因此读侧看到的内容天然
    有界，不需要、也不允许在这里做体积判定。

    同时这个判据不做 `json.dumps`（深度判定只遍历容器、超限立即短路），
    避免每次读 profile 都为整块配置分配一份等长输出串。
    """
    if raw is None:
        return None
    stripped = raw.strip()
    if not stripped:
        return None
    try:
        parsed = json.loads(stripped)
    except (ValueError, TypeError, RecursionError):
        # **不打印内容片段**:ai_config_json 按 sort_keys 序列化后 `apiKey` 是
        # 首个字段,前 80 字就足以泄露真 key 的一截。只记长度与列名 ——
        # 排查够用,不落密。
        logger.warning("profile %s_json parse failed (len=%d)", label, len(stripped))
        return None
    if not isinstance(parsed, dict):
        logger.warning(
            "profile %s_json top-level is not an object (%s), treated as unset",
            label,
            type(parsed).__name__,
        )
        return None
    if not json_depth_ok(parsed, max_depth=max_depth):
        logger.warning(
            "profile %s_json nesting deeper than %d (len=%d), treated as unset",
            label,
            max_depth,
            len(stripped),
        )
        return None
    return parsed


def _dump_appearance_json(value: dict | None) -> str | None:
    """把客户端传来的 appearance dict 序列化成 TEXT 存库。None / 空 dict
    存 NULL 清掉。

    写侧 schema(`BoundedFreeDictOptional`)已保证深度 ≤ 8 / 体积 ≤ 64 KB,
    这里只做序列化;若 JSON 层仍有异常(理论上不会)也转 400 而不是 500。
    """
    if value is None or not isinstance(value, dict) or not value:
        return None
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    except (ValueError, TypeError, RecursionError) as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Profile JSON value is not serializable",
        ) from exc


def _dump_ai_config_json(
    value: dict | None,
    *,
    profile: UserProfile | None = None,
) -> str | None:
    """把 ai_config dict 序列化成 TEXT 存库(None / 空 dict 存 NULL 清掉)。

    落库前走写侧唯一边界 `dump_ai_config`(深度 ≤ 8 / 体积 ≤ 256 KB,
    见 `ai_config_store.MAX_AI_CONFIG_BYTES`)。body schema 的
    `BoundedAIConfigOptional` 已在入参处判过一次,但
    `merge_ai_config_on_patch` 的合并结果(保留服务端原 key + 新增 provider)
    可能比入参更大,因此合并后必须再判 —— 超限 → 422,不落库。

    **缩容豁免(round-3 缺陷 2)**:传入当前 profile(`profile` 参数)时,
    库内 `ai_config_json` 的字节数作为 `stored_bytes` 透传给 `dump_ai_config`
    —— 与 `/ai/providers` 的 `_save_config` 同一语义:合并结果 ≤ 存量字节数
    一律放行。否则存量超限(CJK 撑过 256 KB)用户的 app 端 AI 偏好同步
    (`snapshotForSync()` 发 prefs 不带 providers 段,合并结果不变)会被
    422 永久拒掉 —— 这正是移动端的真实调用形态。真增长的写入仍 422。
    """
    if value is None or not isinstance(value, dict) or not value:
        return None
    stored_bytes: int | None = None
    if profile is not None and profile.ai_config_json:
        raw = profile.ai_config_json
        stored_bytes = (
            len(raw.encode("utf-8")) if isinstance(raw, str)
            else len(str(raw).encode("utf-8"))
        )
    try:
        return dump_ai_config(value, stored_bytes=stored_bytes)
    except AIConfigBoundsError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"error_code": "AI_CONFIG_TOO_LARGE", "message": str(exc)},
        ) from exc
    except (ValueError, TypeError, RecursionError) as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Profile JSON value is not serializable",
        ) from exc


def _heal_malformed_profile_json(db: Session, *, profile: UserProfile) -> None:
    """一次性自愈:把**真的不可服务**(解析失败 / 顶层非对象 / 超深)的
    appearance_json / ai_config_json 归零为 NULL,让自锁的账号恢复正常。

    - **幂等**:正常行不做任何写操作;两次调用结果一致;
    - **best-effort**:写失败只告警,不影响本次读请求(宁可返回空,不 500);
    - 只清畸形的那一列(另一列若正常则保留),不做整行归零;
    - **只对不可服务的行生效**:合法但体积大的配置不在此列 —— 体积上限
      由写侧负责(`MAX_AI_CONFIG_BYTES`),读侧判「畸形」绝不含体积
      (见 `_parse_profile_json` 的注释与对抗缺陷 1)。
    """
    repairs: list[str] = []
    for attr, label in (
        ("appearance_json", "appearance"),
        ("ai_config_json", "ai_config"),
    ):
        raw = getattr(profile, attr, None)
        if raw is None:
            continue
        stripped = raw.strip() if isinstance(raw, str) else ""
        if not stripped:
            continue
        if _parse_profile_json(raw, label=label) is None:
            repairs.append(label)
            setattr(profile, attr, None)
    if not repairs:
        return
    try:
        db.commit()
    except Exception as exc:  # noqa: BLE001 — 自愈失败不能拖垮读请求
        db.rollback()
        logger.warning(
            "profile_json_selfheal failed user=%s fields=%s err=%s",
            profile.user_id,
            repairs,
            exc,
        )
        return
    # ERROR 级:admin 日志面板默认筛 ERROR,运维能直接看到哪些账号被自愈过。
    logger.error(
        "profile_json_selfheal applied user=%s fields=%s (unservable rows zeroed)",
        profile.user_id,
        repairs,
    )


@router.get("/me", response_model=UserProfileOut)
def get_my_profile(
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UserProfileOut:
    profile = db.scalar(select(UserProfile).where(UserProfile.user_id == current_user.id))
    # S1 一次性修复路径:加固前写入的深嵌套 JSON 会让反序列化/序列化递归爆栈,
    # 用户此后所有 profile 请求全 500 且无法自救(对抗 F-04)。读路径顺手做
    # **幂等**自愈:发现畸形列就归零(NULL)+ 告警;成功后正常返回 200。
    # 只在真的畸形时写库,正常读不产生任何 UPDATE。
    if profile is not None:
        _heal_malformed_profile_json(db, profile=profile)
    display_name = profile.display_name if profile is not None else None
    avatar_file_id = profile.avatar_file_id if profile is not None else None
    avatar_version = profile.avatar_version if profile is not None else 0
    income_is_red = profile.income_is_red if profile is not None else None
    theme_primary_color = profile.theme_primary_color if profile is not None else None
    appearance = _parse_profile_json(profile.appearance_json, label="appearance") if profile is not None else None
    # ai_config 对外一律掩码:providers[].apiKey 只回 `****+末4位`,真 key
    # 永不出服务端(与 /ai/providers 列表同口径)。
    ai_config = mask_ai_config(
        _parse_profile_json(profile.ai_config_json, label="ai_config") if profile is not None else None
    )
    primary_currency = profile.primary_currency if profile is not None else None
    return UserProfileOut(
        user_id=current_user.id,
        email=current_user.email,
        display_name=display_name,
        avatar_url=_avatar_url(user_id=current_user.id, avatar_version=avatar_version)
        if avatar_file_id
        else None,
        avatar_version=avatar_version,
        income_is_red=income_is_red,
        theme_primary_color=theme_primary_color,
        appearance=appearance,
        ai_config=ai_config,
        primary_currency=primary_currency,
    )


@router.patch("/me", response_model=UserProfileOut)
async def patch_my_profile(
    req: UserProfilePatchRequest,
    request: Request,
    _scopes: set[str] = Depends(_PATCH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UserProfileOut:
    profile = db.scalar(select(UserProfile).where(UserProfile.user_id == current_user.id))
    now = datetime.now(timezone.utc)
    if profile is None:
        profile = UserProfile(
            user_id=current_user.id,
            display_name=req.display_name,
            income_is_red=req.income_is_red,
            theme_primary_color=req.theme_primary_color,
            appearance_json=_dump_appearance_json(req.appearance),
            ai_config_json=_dump_ai_config_json(merge_ai_config_on_patch(None, req.ai_config))
            if req.ai_config is not None
            else None,
            primary_currency=(req.primary_currency.upper() if req.primary_currency is not None else None),
            updated_at=now,
        )
        # S3:首建即带 ai_config → 版本从 1 起;否则 0(与迁移 default 一致)。
        profile.ai_config_version = 1 if req.ai_config is not None else 0
        db.add(profile)
        try:
            db.commit()
        except IntegrityError:
            # 并发首建撞 user_id 唯一约束 → 409 让客户端重读重试(S3)。
            db.rollback()
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "error_code": "AI_CONFIG_CONFLICT",
                    "message": "Profile was created concurrently; please refresh and retry",
                },
            ) from None
    else:
        # 只更新显式提供的字段，None 表示不改。这样 mobile 切单项配色时
        # 不会把其它字段清掉；反之亦然。appearance 例外:客户端传 {} 时视为
        # 清空（_dump_appearance_json 返回 None），传 dict 时整体替换。
        # ai_config:整体替换 + 密钥合并 —— 传入 providers[].apiKey 为空 /
        # 掩码 = 保留服务端原值,不带 providers 段 = 原段整体保留(密钥
        # 只存不吐后,客户端回传的 ai_config 不再含真 key)。
        if req.display_name is not None:
            profile.display_name = req.display_name
        if req.income_is_red is not None:
            profile.income_is_red = req.income_is_red
        if req.theme_primary_color is not None:
            profile.theme_primary_color = req.theme_primary_color
        if req.appearance is not None:
            profile.appearance_json = _dump_appearance_json(req.appearance)
        if req.primary_currency is not None:
            profile.primary_currency = req.primary_currency.upper()
        profile.updated_at = now
        if req.ai_config is not None:
            # S3:ai_config_json 走乐观锁 guarded UPDATE(版本不匹配 → 409,
            # 同时回滚本次请求的其它字段改动,整体重试);helper 内部 commit,
            # 其 autoflush 会把上面已设的 ORM 字段一并发出去。
            # 写侧边界:合并结果再判一次(超限 → 422,不落库)。
            merged_json = _dump_ai_config_json(
                merge_ai_config_on_patch(
                    _parse_profile_json(profile.ai_config_json, label="ai_config"), req.ai_config,
                ),
                profile=profile,
            )
            save_ai_config_guarded(
                db,
                user_id=current_user.id,
                new_json=merged_json,
                profile=profile,
            )
        else:
            db.commit()
    db.refresh(profile)
    logger.info(
        "profile_patch: user=%s display_name=%s income_is_red=%s theme=%s appearance=%s ai_config_len=%s avatar_version=%s primary_currency=%s",
        current_user.id,
        profile.display_name,
        profile.income_is_red,
        profile.theme_primary_color,
        profile.appearance_json,
        len(profile.ai_config_json or ""),
        profile.avatar_version,
        profile.primary_currency,
    )
    appearance = _parse_profile_json(profile.appearance_json, label="appearance")
    ai_config = mask_ai_config(_parse_profile_json(profile.ai_config_json, label="ai_config"))
    await _broadcast_profile_change(
        request,
        user_id=current_user.id,
        payload={
            "avatar_version": profile.avatar_version,
            "display_name": profile.display_name,
            "income_is_red": profile.income_is_red,
            "theme_primary_color": profile.theme_primary_color,
            "appearance": appearance,
            "primary_currency": profile.primary_currency,
            # ai_config 可能很大(providers 数组里若干对象),WS payload 不塞,
            # 客户端收到 profile_change 自己拉 /profile/me 即可。
        },
    )
    return UserProfileOut(
        user_id=current_user.id,
        email=current_user.email,
        display_name=profile.display_name,
        avatar_url=_avatar_url(
            user_id=current_user.id,
            avatar_version=profile.avatar_version,
        )
        if profile.avatar_file_id
        else None,
        avatar_version=profile.avatar_version,
        income_is_red=profile.income_is_red,
        theme_primary_color=profile.theme_primary_color,
        appearance=appearance,
        ai_config=ai_config,
        primary_currency=profile.primary_currency,
    )


@router.post("/avatar", response_model=UserProfileAvatarUploadOut)
async def upload_my_avatar(
    request: Request,
    file: UploadFile = File(...),
    _scopes: set[str] = Depends(_AVATAR_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UserProfileAvatarUploadOut:
    ext = _resolve_avatar_extension(file)
    payload = await file.read()
    if not payload:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Profile avatar file is empty",
        )
    if len(payload) > _AVATAR_MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="Profile avatar upload too large",
        )
    logger.info(
        "avatar_sync: upload start user=%s size=%d content_type=%s",
        current_user.id,
        len(payload),
        file.content_type,
    )

    profile = db.scalar(select(UserProfile).where(UserProfile.user_id == current_user.id))
    if profile is None:
        profile = UserProfile(
            user_id=current_user.id,
            avatar_version=0,
        )
        db.add(profile)
        db.flush()

    now = datetime.now(timezone.utc)
    avatar_file_id = f"avatar_{uuid4().hex}.{ext}"
    storage_dir = _avatar_root() / current_user.id
    storage_dir.mkdir(parents=True, exist_ok=True)
    storage_path = storage_dir / avatar_file_id
    storage_path.write_bytes(payload)

    # Best-effort cleanup of the previous avatar file.
    previous_avatar = (profile.avatar_file_id or "").strip()
    if previous_avatar:
        old_path = storage_dir / previous_avatar
        if old_path.exists() and old_path.is_file():
            old_path.unlink(missing_ok=True)

    profile.avatar_file_id = avatar_file_id
    profile.avatar_version = int(profile.avatar_version or 0) + 1
    profile.updated_at = now
    db.commit()
    db.refresh(profile)
    logger.info(
        "avatar_sync: saved user=%s file_id=%s new_version=%d",
        current_user.id,
        avatar_file_id,
        profile.avatar_version,
    )
    await _broadcast_profile_change(
        request,
        user_id=current_user.id,
        payload={
            "avatar_version": profile.avatar_version,
            "display_name": profile.display_name,
            "income_is_red": profile.income_is_red,
            "theme_primary_color": profile.theme_primary_color,
        },
    )
    return UserProfileAvatarUploadOut(
        avatar_url=_avatar_url(
            user_id=current_user.id,
            avatar_version=profile.avatar_version,
        ),
        avatar_version=profile.avatar_version,
    )


@router.get("/avatar/{user_id}")
def download_avatar(
    user_id: str,
    request: Request,
    _user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> FileResponse:
    """用户头像下载(S5:补鉴权 —— 原先完全无认证,任何匿名请求都能拉头像)。

    只认证、不查关系:任何登录用户可看任意用户头像(共享账本成员列表 /
    交易行的创建者头像需要跨用户展示)。注意 web 端 `<img>` 无法携带
    Authorization 头,需走「fetch + blob URL」(同 AI 日志图片的模式)。
    带缓存版本号 `v` 时可长缓存,但改为 `private`(响应已需认证,公共
    CDN/代理缓存不合适)。
    """
    profile = db.scalar(select(UserProfile).where(UserProfile.user_id == user_id))
    if profile is None or not (profile.avatar_file_id or "").strip():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile avatar not found")

    path = _avatar_root() / user_id / profile.avatar_file_id
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile avatar not found")

    cache_control = (
        "private, max-age=31536000, immutable"
        if (request.query_params.get("v") or "").strip()
        else "no-cache"
    )
    return FileResponse(
        path=path,
        media_type=_guess_mime_type(path),
        filename=path.name,
        headers={"Cache-Control": cache_control},
    )
