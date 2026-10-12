import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import jwt
from fastapi import HTTPException, status
from passlib.context import CryptContext
from passlib.exc import PasswordSizeError
from passlib.utils import MAX_PASSWORD_SIZE

from .config import get_settings

pwd_context = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")
settings = get_settings()

SCOPE_APP_WRITE = "app_write"
SCOPE_WEB_READ = "web_read"
SCOPE_WEB_WRITE = "web_write"
SCOPE_OPS_WRITE = "ops_write"
# MCP 专用 scope。PAT 创建时用户选这两个之一或两个都选。MCP server 的
# read tools 要求 `mcp:read`,write tools 要求 `mcp:write`。详见 .docs/mcp-
# server-design.md。
SCOPE_MCP_READ = "mcp:read"
SCOPE_MCP_WRITE = "mcp:write"

# PAT token 明文前缀,识别"这是 SmartBook MCP token"。跟 GitHub PAT `ghp_` /
# OpenAI `sk-` 同惯例,方便用户和 secret scanner 识别。
PAT_PREFIX = "bcmcp_"
# Token 主体随机字节数。32 字节 base64url 后约 43 字符,加 PAT_PREFIX 共 ~49,
# 熵 256 bit 远超暴力破解。
PAT_RANDOM_BYTES = 32
# 列表展示用前缀长度(明文,含 PAT_PREFIX),如 `bcmcp_a1b2c3d4`,共 14 字符。
# 既能识别 PAT 类型,又能区分用户的多个 token,但还不够撞库。
PAT_DISPLAY_PREFIX_LEN = 14


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return pwd_context.verify(password, password_hash)


# ──────────────────────────────────────────────────────────────────────────
# 密码长度守卫(所有 passlib 调用点的唯一入口)
#
# passlib 对超过 `MAX_PASSWORD_SIZE`(默认 4096 字符)的密码抛
# `PasswordSizeError`;任何**未守卫**的调用点都会让它穿透到全局兜底 handler
# → 500 INTERNAL_ERROR(对抗 F-05 + 2026-10-11 缺陷 3:auth.py 修过了,但
# admin.py 的三处 passlib 调用漏网 —— admin 改密 / 建用户照样 500)。
#
# 放在 security.py 而不是 auth.py,是因为守卫必须覆盖**所有**调用点,而
# security.py 是 passlib 的唯一封装层;任何新代码要哈希/校验密码都从这个
# 模块 import,`grep hash_password` 就能查出是否绕过了守卫。
#
# 上限用 passlib 自己的常量而非写死 4096 —— 该值可由环境变量
# `PASSLIB_MAX_PASSWORD_SIZE` 覆盖。
# ──────────────────────────────────────────────────────────────────────────


def password_size_exceeded(password: str | None) -> bool:
    """密码是否超过 passlib 的处理上限(True = 必须拒绝,不能进 passlib)。"""
    if password is None:
        return False
    return len(password) > MAX_PASSWORD_SIZE


def require_password_size(password: str, *, status_code: int, detail: str) -> None:
    """超长密码前置拦截(不进入 passlib),超限抛 `HTTPException`。

    调用方按语义给 status_code:注册 / 建用户 / 改密 → 422(校验失败),
    登录 / 二次验证 → 401(凭据错误,不泄漏内部状态)。
    """
    if password_size_exceeded(password):
        raise HTTPException(status_code=status_code, detail=detail)


def hash_password_or_422(password: str, *, detail: str = "Password too long") -> str:
    """哈希密码;超长(前置判定 + 兜住 passlib 的 ``PasswordSizeError``)→ 422。

    两层防护:
    1. `password_size_exceeded` 前置判 —— 与 `require_password_size` 同一常量;
    2. `except PasswordSizeError` —— 兜住库内策略变化(如换 handler 后上限
       不同)导致的意外,避免退化成 500。
    """
    if password_size_exceeded(password):
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=detail)
    try:
        return hash_password(password)
    except PasswordSizeError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=detail,
        ) from exc


def verify_password_or_401(password: str, password_hash: str) -> bool:
    """校验密码;超长 → False(= 凭据错误),不泄漏内部状态、不 500。"""
    if password_size_exceeded(password):
        return False
    try:
        return verify_password(password, password_hash)
    except PasswordSizeError:
        return False


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def hash_invite_code(code: str) -> str:
    return hash_token(f"invite:{code}")


def _normalize_scopes(scopes: list[str] | None) -> list[str]:
    if not scopes:
        return []
    seen: set[str] = set()
    ordered: list[str] = []
    for scope in scopes:
        if not scope or scope in seen:
            continue
        seen.add(scope)
        ordered.append(scope)
    return ordered


def _create_token(
    sub: str,
    token_type: str,
    expires_delta: timedelta,
    scopes: list[str] | None = None,
    client_type: str = "app",
) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": sub,
        "type": token_type,
        "client_type": client_type,
        "scopes": _normalize_scopes(scopes),
        "jti": uuid4().hex,
        "iat": int(now.timestamp()),
        "exp": int((now + expires_delta).timestamp()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def create_access_token(
    user_id: str,
    *,
    scopes: list[str] | None = None,
    client_type: str = "app",
) -> tuple[str, int]:
    minutes = settings.access_token_expire_minutes
    token = _create_token(
        user_id,
        "access",
        timedelta(minutes=minutes),
        scopes=scopes,
        client_type=client_type,
    )
    return token, minutes * 60


def create_refresh_token(
    user_id: str,
    *,
    scopes: list[str] | None = None,
    client_type: str = "app",
) -> tuple[str, datetime]:
    days = settings.refresh_token_expire_days
    expires_at = datetime.now(timezone.utc) + timedelta(days=days)
    token = _create_token(
        user_id,
        "refresh",
        timedelta(days=days),
        scopes=scopes,
        client_type=client_type,
    )
    return token, expires_at


def decode_token(token: str) -> dict:
    return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])


# --------------------------------------------------------------------------- #
# PAT (Personal Access Token) — 长期 token 给 MCP / 外部 LLM 客户端用。
# 详见 .docs/mcp-server-design.md。
# --------------------------------------------------------------------------- #


def generate_pat() -> tuple[str, str, str]:
    """生成新 PAT。

    返回 `(plaintext, token_hash, display_prefix)`:
      - plaintext:`bcmcp_<base64url 32 字节>`,**仅返回一次**给用户,不存表
      - token_hash:sha256 hex,存表用
      - display_prefix:前 14 字符(如 `bcmcp_a1b2c3d4`),列表展示用

    不用 PBKDF2 / bcrypt 是因为校验路径需要常数时间且很快(MCP 每次 tool
    call 都跑一次),sha256 + timing-safe compare 足够安全 — token 本身已是
    256 bit 熵的随机串,不像密码需要抗暴力破解。
    """
    raw = secrets.token_urlsafe(PAT_RANDOM_BYTES)
    plaintext = f"{PAT_PREFIX}{raw}"
    token_hash = hash_token(plaintext)
    display_prefix = plaintext[:PAT_DISPLAY_PREFIX_LEN]
    return plaintext, token_hash, display_prefix


def looks_like_pat(token: str) -> bool:
    """快速判断一个 token 字符串看着像不像 PAT。

    用在 Auth header 路由分流上 — `Authorization: Bearer <token>` 同时接受
    JWT access token 和 PAT,看前缀决定走哪条校验路径,避免给每个请求都做
    两遍解码。
    """
    return token.startswith(PAT_PREFIX)


def verify_pat_hash(provided_token: str, stored_hash: str) -> bool:
    """常数时间比较 PAT hash,防 timing attack 推测正确 hash。"""
    return hmac.compare_digest(hash_token(provided_token), stored_hash)
