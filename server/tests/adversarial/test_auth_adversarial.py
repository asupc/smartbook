"""认证域对抗测试 —— 注册 / 登录 / JWT / 会话边界。

范围:注册邮箱规范化与并发、密码长度边界、JWT 伪造与篡改、刷新令牌分流、
用户 / 设备禁用与吊销后的令牌残留权限。全部用 sqlite in-memory + StaticPool
+ dependency_overrides(照抄 tests/test_p2_s7_s8_write_race.py 的模式)。

标注约定:
  ADVERSE FINDING  —— 真实缺陷(测试保持失败)
  HARDENING        —— 行为可辩护但脆弱(断言当前行为并通过)
"""

from __future__ import annotations

import base64
import json
from datetime import datetime, timezone

import jwt as pyjwt
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import User

PASSWORD = "Pa$$word1!"


def _make_client() -> tuple[TestClient, sessionmaker]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    TS = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override():
        db = TS()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override
    # raise_server_exceptions=False:5xx 断言需要拿到响应体而不是重抛异常。
    return TestClient(app, raise_server_exceptions=False), TS


@pytest.fixture()
def client():
    c, TS = _make_client()
    yield c, TS
    app.dependency_overrides.clear()


def _register(
    client: TestClient,
    email: str,
    *,
    password: str = PASSWORD,
    client_type: str = "web",
    device_id: str | None = None,
    **extra,
):
    body = {
        "email": email,
        "password": password,
        "client_type": client_type,
        "device_name": "pytest",
        "platform": "test",
    }
    if device_id:
        body["device_id"] = device_id
    body.update(extra)
    return client.post("/api/v1/auth/register", json=body)


def _login(client: TestClient, email: str, *, password: str = PASSWORD, client_type: str = "web", device_id: str | None = None):
    body = {"email": email, "password": password, "client_type": client_type}
    if device_id:
        body["device_id"] = device_id
    return client.post("/api/v1/auth/login", json=body)


def _auth(token: str, device: str = "d-web") -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": device}


# --------------------------------------------------------------------------
# 注册:邮箱规范化 / 校验边界
# --------------------------------------------------------------------------


def test_duplicate_email_case_variant_rejected(client):
    """`A@x.com` 与 `a@x.com` 必须视为同一账号(规范化后唯一)。"""
    c, _ = client
    assert _register(c, "Case@Example.com").status_code == 200
    dup = _register(c, "case@example.com")
    assert dup.status_code == 409
    assert dup.json()["error"]["code"] == "AUTH_EMAIL_EXISTS"


def test_unicode_confusable_email_creates_separate_account(client):
    """同形字(西里尔 а vs 拉丁 a)在规范化后不同 → 允许建两个账号。

    HARDENING: 这是 IDN 同形字攻击的一般性缺口(账号冒充),但注册入口本身
    无法靠 lower() 解决,需要域名/字符集策略。当前行为记录在案。
    """
    c, _ = client
    assert _register(c, "\u0430dmin@example.com").status_code == 200  # 西里尔 а
    assert _register(c, "admin@example.com").status_code == 200
    # 两者可分别登录,互不影响
    assert _login(c, "\u0430dmin@example.com").status_code == 200
    assert _login(c, "admin@example.com").status_code == 200


def test_empty_and_short_password_rejected(client):
    c, _ = client
    assert _register(c, "sp@example.com", password="").status_code == 422
    assert _register(c, "sp2@example.com", password="12345").status_code == 422


def test_missing_fields_and_bad_client_type_rejected(client):
    c, _ = client
    assert c.post("/api/v1/auth/register", json={"password": PASSWORD}).status_code == 422
    assert _register(c, "badct@example.com", client_type="boom").status_code == 422
    assert _register(c, "badct2@example.com", client_type="WEB").status_code == 422


def test_register_accepts_5000_char_email(client):
    """超长邮箱(远超 users.email `String(255)`)被接受并落库。

    ADVERSE FINDING: src/schemas.py:24-32 的 email validator 只查 "@" 与域名点,
    没有长度上限;SQLite 不强制 VARCHAR 长度,于是脏数据入库。生产 Postgres 上
    `String(255)` 会抛 DataError → 500(环境相关)。期望:422。
    """
    c, TS = client
    huge = "b" * 5000 + "@example.com"
    res = _register(c, huge)
    assert res.status_code == 422, (
        f"超长邮箱应被校验拒绝,实际 {res.status_code};落地后 users.email 超列宽"
    )
    db = TS()
    assert db.scalar(select(User).where(User.email == huge.lower())) is None
    db.close()


def test_register_accepts_oversized_device_fields(client):
    """device_name/platform/device_model/app_version/os_version 无长度校验。

    ADVERSE FINDING: src/schemas.py:22-27 全为裸 `str | None`;
    src/routers/auth.py:_upsert_device 原样写库。devices.name 声明 String(128)、
    platform String(32),SQLite 不截断 → 5000 字符入库。期望:422 或被截断。
    """
    c, TS = client
    res = _register(
        c,
        "longdev@example.com",
        device_name="D" * 5000,
        platform="P" * 5000,
        device_model="M" * 5000,
        app_version="V" * 5000,
        os_version="O" * 5000,
    )
    assert res.status_code == 422, f"超长设备字段应被拒绝,实际 {res.status_code}"
    # 修复:422 响应体不含 user 字段(请求整体被拒),原 `res.json()["user"]["id"]`
    # 在断言通过的绿色分支上必然 KeyError(可证伪测试自身笔误)。改用注册邮箱定位:
    # 注册被拒 → user / device 两表都不应留下超长行。
    db = TS()
    from src.models import Device, User

    assert db.scalar(select(User).where(User.email == "longdev@example.com")) is None, (
        "注册应整体被拒,users 不应留行"
    )
    for dev in db.scalars(select(Device)).all():
        assert len(dev.name or "") <= 128, f"devices.name 超列宽:{len(dev.name or '')}"
        assert len(dev.platform or "") <= 32, f"devices.platform 超列宽:{len(dev.platform or '')}"
        assert len(dev.device_model or "") <= 128, (
            f"devices.device_model 超列宽:{len(dev.device_model or '')}"
        )
    db.close()


# --------------------------------------------------------------------------
# 注册 / 登录:密码长度上限(哈希库直接抛异常 → 500)
# --------------------------------------------------------------------------


def test_register_huge_password_returns_422_not_500(client):
    """超过 passlib 上限(4096)的密码注册 → 500。

    ADVERSE FINDING: src/routers/auth.py:195 `hash_password(req.password)` 直接调
    passlib;密码 >4096 字节时 passlib 抛 PasswordSizeError,未被捕获 →
    全局异常处理器返回 500。期望:422(校验阶段拒绝)。
    """
    c, _ = client
    res = _register(c, "hugepw@example.com", password="x" * 5000)
    assert res.status_code != 500, f"超长密码导致 500:{res.text[:200]}"
    assert res.status_code == 422


def test_login_huge_password_returns_401_not_500(client):
    """登录时超长密码 → 500(passlib PasswordSizeError 未捕获)。

    ADVERSE FINDING: src/routers/auth.py:... `verify_password(req.password, ...)`
    同样不设上限。期望:401(凭据错误),不得泄漏"服务端崩了"。
    """
    c, _ = client
    assert _register(c, "hugepw2@example.com").status_code == 200
    res = _login(c, "hugepw2@example.com", password="x" * 4097)
    assert res.status_code != 500, f"超长密码登录导致 500:{res.text[:200]}"
    assert res.status_code == 401


def test_register_integrity_error_on_flush_returns_409(client):
    """并发同邮箱注册:flush 撞 UNIQUE → 500(无 IntegrityError 兜底)。

    ADVERSE FINDING: src/routers/auth.py:187-205 `register()` 的
    「SELECT 查重 → INSERT」是 TOCTOU,flush 处没有 try/except IntegrityError。
    对照:src/routers/write/ledgers.py:74-100 的 create_ledger 有同款兜底返回 409。
    用自定义 Session 让 User 插入的 flush 抛 IntegrityError 确定性复现。
    """
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)

    class _RacingSession(sessionmaker(bind=engine, autoflush=False).class_):
        def flush(self, *a, **k):
            if any(isinstance(o, User) for o in self.new):
                raise IntegrityError("dup", None, Exception("unique"))
            return super().flush(*a, **k)

    Session = sessionmaker(bind=engine, autoflush=False, class_=_RacingSession)

    def override():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override
    c = TestClient(app, raise_server_exceptions=False)
    try:
        res = _register(c, "race@example.com")
        assert res.status_code == 409, (
            f"并发同邮箱注册应返回 409,实际 {res.status_code}:{res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()


# --------------------------------------------------------------------------
# 登录:枚举与敏感字段
# --------------------------------------------------------------------------


def test_login_response_has_no_secret_fields(client):
    """登录响应不得包含 password_hash / 内部字段。"""
    c, _ = client
    _register(c, "leak@example.com")
    res = _login(c, "leak@example.com")
    assert res.status_code == 200
    body = res.json()
    assert "password_hash" not in json.dumps(body)
    assert set(body.keys()) == {
        "user", "access_token", "refresh_token", "expires_in", "device_id", "scopes",
    }
    assert set(body["user"].keys()) == {"id", "email", "is_admin"}


def test_login_nonexistent_and_wrong_password_are_indistinguishable(client):
    """不存在用户 vs 密码错误:状态码与 error.code 必须一致(防枚举)。"""
    c, _ = client
    _register(c, "enum@example.com")
    missing = _login(c, "nobody@example.com")
    wrong = _login(c, "enum@example.com", password="WrongPass123")
    assert missing.status_code == wrong.status_code == 401
    assert missing.json()["error"]["code"] == wrong.json()["error"]["code"]


# --------------------------------------------------------------------------
# JWT 攻击面
# --------------------------------------------------------------------------


def _tamper_payload(token: str, **updates) -> str:
    header_b64, payload_b64, sig = token.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)  # noqa: E731
    payload = json.loads(base64.urlsafe_b64decode(pad(payload_b64)))
    payload.update(updates)
    new_b64 = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"{header_b64}.{new_b64}.{sig}"


def test_forged_jwt_with_wrong_key_rejected(client):
    c, _ = client
    forged = pyjwt.encode(
        {"sub": "attacker", "type": "access", "scopes": ["web_read"], "exp": 9999999999},
        "wrong-secret", algorithm="HS256",
    )
    assert c.get("/api/v1/read/ledgers", headers=_auth(forged)).status_code == 401


def test_alg_none_token_rejected(client):
    c, _ = client
    token = pyjwt.encode(
        {"sub": "attacker", "type": "access", "scopes": ["web_read"], "exp": 9999999999},
        "", algorithm="none",
    )
    assert c.get("/api/v1/read/ledgers", headers=_auth(token)).status_code == 401


def test_tampered_sub_payload_rejected(client):
    """把 sub 换成另一个 user_id 但保留原签名 → 401(签名校验生效)。"""
    c, _ = client
    victim = _register(c, "victim@example.com").json()
    attacker = _register(c, "attacker@example.com").json()
    tampered = _tamper_payload(attacker["access_token"], sub=victim["user"]["id"])
    assert c.get("/api/v1/read/ledgers", headers=_auth(tampered)).status_code == 401


def test_expired_access_token_rejected(client):
    """手工构造已过期 access token(同密钥)→ 401。"""
    c, _ = client
    _register(c, "exp@example.com")
    from src.config import get_settings

    settings = get_settings()
    now = datetime.now(timezone.utc)
    expired = pyjwt.encode(
        {
            "sub": "any",
            "type": "access",
            "client_type": "web",
            "scopes": ["web_read"],
            "jti": "x",
            "iat": int(now.timestamp()) - 7200,
            "exp": int(now.timestamp()) - 3600,
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    assert c.get("/api/v1/read/ledgers", headers=_auth(expired)).status_code == 401


def test_refresh_and_access_tokens_are_not_interchangeable(client):
    c, _ = client
    tokens = _register(c, "swap@example.com").json()
    assert c.get("/api/v1/read/ledgers", headers=_auth(tokens["refresh_token"])).status_code == 401
    assert c.post(
        "/api/v1/auth/refresh", json={"refresh_token": tokens["access_token"]}
    ).status_code == 401


def test_token_of_deleted_user_rejected(client):
    c, TS = client
    tok = _register(c, "gone@example.com").json()
    db = TS()
    user = db.scalar(select(User).where(User.email == "gone@example.com"))
    db.delete(user)
    db.commit()
    db.close()
    assert c.get("/api/v1/read/ledgers", headers=_auth(tok["access_token"])).status_code == 401
    assert c.post(
        "/api/v1/auth/refresh", json={"refresh_token": tok["refresh_token"]}
    ).status_code == 401


def test_disabled_user_tokens_rejected(client):
    c, TS = client
    tok = _register(c, "disabled@example.com").json()
    db = TS()
    user = db.scalar(select(User).where(User.email == "disabled@example.com"))
    user.is_enabled = False
    db.commit()
    db.close()
    assert c.get("/api/v1/read/ledgers", headers=_auth(tok["access_token"])).status_code == 403
    assert c.get("/api/v1/profile/me", headers=_auth(tok["access_token"])).status_code == 403
    assert _login(c, "disabled@example.com").status_code == 403
    assert c.post(
        "/api/v1/auth/refresh", json={"refresh_token": tok["refresh_token"]}
    ).status_code == 403


def test_device_revocation_does_not_kill_access_token_for_rest_reads(client):
    """设备吊销后,JWT access token 对非 device 校验端点仍全权有效。

    HARDENING: 设计上 access token 是无状态 JWT,撤销只杀 refresh token 与
    device 校验端点(/sync/pull 401,/sync/push 403)。但 `GET /read/*`、
    CSV 导出、`/profile/me` 仍 200 —— "登出/吊销设备"在实际语义上不能立即
    停止数据读取。记录当前行为以便后续评估(需要 token 版本号/黑名单)。
    """
    c, TS = client
    # /devices/* 需要 ops_write scope → 用 web 客户端(see src/routers/devices.py:20)。
    reg = _register(c, "devrev@example.com", device_id="dev-1", client_type="web")
    assert reg.status_code == 200
    body = reg.json()
    access, device_id = body["access_token"], body["device_id"]
    assert device_id == "dev-1"

    rv = c.post(f"/api/v1/devices/{device_id}/revoke", headers=_auth(access, device_id))
    assert rv.status_code == 200

    # device 校验路径被正确拒绝
    assert c.get(
        f"/api/v1/sync/pull?since=0&device_id={device_id}", headers=_auth(access, device_id)
    ).status_code == 401
    assert c.post(
        "/api/v1/sync/push", headers=_auth(access, device_id),
        json={"device_id": device_id, "changes": []},
    ).status_code in (401, 403)
    # refresh token 已被连带撤销
    assert c.post(
        "/api/v1/auth/refresh", json={"refresh_token": body["refresh_token"]}
    ).status_code == 401

    # 但普通读路径仍然放行(HARDENING:吊销不彻底)
    assert c.get("/api/v1/read/ledgers", headers=_auth(access, device_id)).status_code == 200


# --------------------------------------------------------------------------
# Authorization header 形态
# --------------------------------------------------------------------------


def test_authorization_header_malformed_variants(client):
    c, _ = client
    tok = _register(c, "hdr@example.com").json()["access_token"]
    cases = {
        "no header": {},
        "empty bearer": {"Authorization": "Bearer"},
        "no scheme": {"Authorization": tok},
        "bogus token": {"Authorization": "Bearer bogus"},
        "huge token": {"Authorization": "Bearer " + "A" * 100000},
        "tab separator": {"Authorization": "Bearer\t" + tok},
        "bcmcp prefix (no such PAT)": {"Authorization": "Bearer bcmcp_deadbeef"},
    }
    for label, headers in cases.items():
        code = c.get("/api/v1/read/ledgers", headers=headers).status_code
        assert code in (401, 403), f"{label} 应被拒绝,实际 {code}"


def test_authorization_header_whitespace_laxity(client):
    """`Bearer  <token>`(双空格)被接受,`bearer <token>`(小写)也被接受。

    HARDENING: OAuth2PasswordBearer 用 str.split() 取最后一段,对空白与大小写
    过于宽容。不构成越权(仍必须持有合法 token),记录现状。
    """
    c, _ = client
    tok = _register(c, "hdr2@example.com").json()["access_token"]
    assert c.get("/api/v1/read/ledgers", headers={"Authorization": "Bearer  " + tok}).status_code == 200
    assert c.get("/api/v1/read/ledgers", headers={"Authorization": "bearer " + tok}).status_code == 200
