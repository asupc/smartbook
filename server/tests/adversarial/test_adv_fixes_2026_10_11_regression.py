"""对抗缺陷修复回归 —— 2026-10-11 跨域复核确认的 4 个缺陷。

本文件是**回归护栏**:每个用例都对应一个经公开 API 复现确认、已修复的缺陷。
它们必须在修复前失败、修复后通过(每条 docstring 记录了「修复前的红」)。

- **D1 (BLOCKER, 数据丢失)**:`GET /profile/me` 的畸形行自愈把**合法但体积大**
  的 `ai_config_json` 当畸形归零 —— 20 个满配自建 provider(≈93 KB)合法,
  但读一次 profile 就把它们连同全部真 key 一起清掉(不可恢复)。
  根因:读侧判据复用了**写侧**上限 `MAX_FREE_DICT_BYTES = 64 KB`。
- **D2 (BLOCKER)**:`AiHostNotAllowedError`(SSRF 策略拒绝)不是
  `ChatProviderError` 子类 → 只捕获后者的解析入口
  (`/ai/parse-tx-image`、`/ai/parse-tx-text`、`/ai/ask`)把它漏成
  500 INTERNAL_ERROR;而 relay / test-provider 已是 400(口径不一致)。
- **D3 (HIGH)**:`/admin/users/{id}/password` 与 `/admin/users` 的 passlib
  调用点没有长度守卫 → 超长密码(>4096)抛 `PasswordSizeError` → 500。
  S1 只修了 `auth.py`。
- **D4 (HIGH, 跨租户泄密)**:`rclone.conf` 以**裸 remote name** 作 section 名,
  而 DB 唯一约束是 `(user_id, name)` → 两个 admin 同名 remote 互相覆盖,
  A 的下载端点会把 B 的 secret 返给 A。

红绿纪律同其它对抗文件:断言的是**修复后的正确行为**,修复前这些用例必须红。
"""
from __future__ import annotations

import json

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import User, UserProfile

_PW = "Pa$$word1!"


def _make_client() -> tuple[TestClient, sessionmaker]:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override_get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app, raise_server_exceptions=False), Session


def _login(client: TestClient, email: str, client_type: str = "app") -> str:
    reg = client.post(
        "/api/v1/auth/register",
        json={"email": email, "password": _PW, "device_id": f"dev-{email}",
              "client_type": client_type, "device_name": "pytest-adv", "platform": "test"},
    )
    assert reg.status_code in (200, 201), reg.text
    res = client.post(
        "/api/v1/auth/login",
        json={"email": email, "password": _PW, "device_id": f"dev-{email}",
              "client_type": client_type, "device_name": "pytest-adv", "platform": "test"},
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _stored_ai_config(Session, email: str) -> str | None:
    with Session() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
        profile = db.scalar(select(UserProfile).where(UserProfile.user_id == uid))
        return None if profile is None else profile.ai_config_json


# ══════════════════════════════════════════════════════════════════════
# D1 —— profile 读侧自愈不得清空「合法但体积大」的 ai_config_json
# ══════════════════════════════════════════════════════════════════════


def test_profile_read_preserves_legit_large_ai_config() -> None:
    """D1 (BLOCKER):20 个满配 provider(≈93 KB,全部经公开 API 合法写入)
    在 `GET /profile/me` 之后必须**逐字保留**,响应里 providers 数不变。

    修复前:读侧把体积 > 64 KB(写侧上限)的行当畸形 → 归零 → 真 key 全丢
    (`profile_json_selfheal applied ... fields=['ai_config']`),且不可恢复。
    """
    client, Session = _make_client()
    try:
        email = "d1-large@example.com"
        token = _login(client, email)
        headers = _auth(token)
        client.get("/api/v1/ai/providers", headers=headers)  # 种内置目录

        for i in range(20):
            res = client.post(
                "/api/v1/ai/providers", headers=headers,
                json={
                    "id": f"mine{i}", "name": f"Mine {i}",
                    "apiKey": "sk-" + "A" * 4092,
                    "baseUrl": "https://api.example.com/v1",
                    "textModel": "m", "visionModel": "m", "audioModel": "m",
                },
            )
            assert res.status_code == 201, res.text

        before = _stored_ai_config(Session, email)
        assert before is not None
        # 前提:这份配置**确实超过**写侧 appearance 口径的 64 KB(缺陷触发条件)
        assert len(before) > 65536, f"fixture too small to trigger the defect: {len(before)}"
        providers_before = json.loads(before)["providers"]
        assert len(providers_before) == 25  # 5 内置 + 20 自建

        res = client.get("/api/v1/profile/me", headers=headers)
        assert res.status_code == 200, res.text
        body = res.json()
        assert len((body.get("ai_config") or {}).get("providers") or []) == 25, (
            "profile 读返回的 providers 数不对(应 25)"
        )

        after = _stored_ai_config(Session, email)
        assert after == before, (
            "GET /profile/me 把合法的大 ai_config 改写了(读路径不得写库):"
            f"before={len(before)}B after={None if after is None else len(after)}B"
        )
        assert any(p.get("id") == "mine19" for p in json.loads(after)["providers"]), (
            "真 key 配置被清空 —— 对抗缺陷 1 复现"
        )
    finally:
        app.dependency_overrides.clear()


def test_profile_read_selfheals_only_unservable_rows() -> None:
    """D1 反向护栏:真正**不可服务**的行(超深 → pydantic 序列化 500)仍自愈。

    判据只收窄到「不可服务」,不能因为修 D1 就把 F-04 的自锁修复一起丢掉:
    超深行必须被归零,而不是让 `GET /profile/me` 永久 500。
    """
    client, Session = _make_client()
    try:
        email = "d1-selfheal@example.com"
        token = _login(client, email)
        headers = _auth(token)

        deep: dict = {}
        cur = deep
        for _ in range(130):
            cur["n"] = {}
            cur = cur["n"]
        with Session() as db:
            uid = db.scalar(select(User.id).where(User.email == email))
            profile = db.scalar(select(UserProfile).where(UserProfile.user_id == uid))
            if profile is None:
                # 注册不会自动建 profile 行;直接落一行模拟存量脏数据
                profile = UserProfile(user_id=uid)
                db.add(profile)
            profile.appearance_json = json.dumps({"deep": deep})
            db.commit()

        res = client.get("/api/v1/profile/me", headers=headers)
        assert res.status_code == 200, res.text
        with Session() as db:
            uid = db.scalar(select(User.id).where(User.email == email))
            profile = db.scalar(select(UserProfile).where(UserProfile.user_id == uid))
            assert profile.appearance_json is None, "超深(不可服务)行应被自愈归零"
    finally:
        app.dependency_overrides.clear()


def test_ai_config_write_bound_rejects_oversized_but_not_max_legit() -> None:
    """D1 写侧边界:最大合法配置(满配自建 ≈ 142 KB)必须被接受;
    真正超界(> 256 KB)的写入 → 4xx,**不落库**。

    读侧不再按体积判畸形,前提就是写侧必须有硬上界
    (`MAX_AI_CONFIG_BYTES = 256 KB`)。

    数量口径:内置目录由 `GET /ai/providers` 种入且**没有** `isBuiltIn=True`
    标记(它们因此也算进 `_MAX_PROVIDERS = 32` 的自建计数),所以满配容量
    是「5 内置 + 27 自建」—— 本用例建到上限为止,不写死 32。
    """
    client, Session = _make_client()
    try:
        email = "d1-bounds@example.com"
        token = _login(client, email)
        headers = _auth(token)
        client.get("/api/v1/ai/providers", headers=headers)

        # 上限内的满配:全部 201,直到底层数量上限回 400(即已满配)
        created = 0
        for i in range(32):
            res = client.post(
                "/api/v1/ai/providers", headers=headers,
                json={
                    "id": f"m{i}", "name": "N" * 64, "apiKey": "sk-" + "A" * 4092,
                    "baseUrl": "https://" + "b" * 490 + ".com/v1",
                    "textModel": "m" * 128, "visionModel": "m" * 128, "audioModel": "m" * 128,
                },
            )
            if res.status_code == 400 and "at most" in res.text:
                break  # 已到数量上限(满配)
            assert res.status_code == 201, f"i={i}: {res.status_code} {res.text[:200]}"
            created += 1
        assert created >= 25, f"满配容量异常少:{created}"
        stored = _stored_ai_config(Session, email)
        assert stored is not None and len(stored) > 100_000, (
            f"满配合法配置应 ~142 KB,实际 {len(stored or '')}B"
        )

        # 读一次仍完好(与 D1 同源)
        assert client.get("/api/v1/profile/me", headers=headers).status_code == 200
        assert _stored_ai_config(Session, email) == stored

        # 超界写入 → 4xx 且不落库
        oversized = {"providers": [{"id": f"x{i}", "apiKey": "k" * 4096} for i in range(80)]}
        res = client.patch("/api/v1/profile/me", headers=headers, json={"ai_config": oversized})
        assert res.status_code in (400, 422), (
            f"超界 ai_config 应 4xx,实际 {res.status_code} {res.text[:200]}"
        )
        assert _stored_ai_config(Session, email) == stored, "被拒的写入不得改变库内配置"
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# D2 —— SSRF host 拒绝在**每个** AI 入口都是 4xx,绝不 500
# ══════════════════════════════════════════════════════════════════════


def _bind_blocked_provider(client: TestClient, headers: dict[str, str]) -> None:
    """建一个 baseUrl 指向链路本地(云元数据)的 provider 并绑到全部能力。

    用 `169.254.169.254` 而不是 `127.0.0.1`:策略对二者都拒,但前者不依赖
    本地环回可用性,也不受 `AI_ALLOWED_PRIVATE_HOSTS` 的测试夹具影响。
    """
    client.get("/api/v1/ai/providers", headers=headers)
    res = client.post(
        "/api/v1/ai/providers", headers=headers,
        json={
            "id": "blocked", "name": "Blocked", "apiKey": "sk-x",
            "baseUrl": "http://169.254.169.254/v1",
            "textModel": "m", "visionModel": "m", "audioModel": "m",
        },
    )
    assert res.status_code == 201, res.text
    res = client.put(
        "/api/v1/ai/providers/binding", headers=headers,
        json={"textProviderId": "blocked", "visionProviderId": "blocked",
              "speechProviderId": "blocked"},
    )
    assert res.status_code == 200, res.text


_PNG_1PX = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d4944415478da63f8cf00000301010018dd8db00000000049454e44ae426082"
)


def test_blocked_host_never_500_on_parse_or_ask_entrypoints() -> None:
    """D2 (BLOCKER):blocked host 在 parse-tx-image / parse-tx-text / ask
    上必须是 400 配置类错误,不得 500。

    修复前实测:parse-tx-image → 500、parse-tx-text → 500(ask 同族,因
    docs index 缺失本地不可达,S1 报告已点名为「需同样修复」)。500 会被
    客户端当 transient 无限重试,而配置类错误重试永不可能成功。
    """
    client, _Session = _make_client()
    try:
        email = "d2-blocked@example.com"
        token = _login(client, email)
        headers = _auth(token)
        _bind_blocked_provider(client, headers)

        res = client.post(
            "/api/v1/ai/parse-tx-image", headers=headers,
            files={"image": ("a.png", _PNG_1PX, "image/png")},
            data={"locale": "zh"},
        )
        assert res.status_code == 400, (
            f"parse-tx-image blocked host 应 400,实际 {res.status_code} {res.text[:200]}"
        )
        assert res.json().get("error_code") == "AI_PROVIDER_HOST_NOT_ALLOWED", res.text

        res = client.post(
            "/api/v1/ai/parse-tx-text", headers=headers,
            json={"text": "coffee 12", "locale": "zh"},
        )
        assert res.status_code == 400, (
            f"parse-tx-text blocked host 应 400,实际 {res.status_code} {res.text[:200]}"
        )
        assert res.json().get("error_code") == "AI_PROVIDER_HOST_NOT_ALLOWED", res.text

        # relay 是既有正确行为(对照组),固定住口径一致
        res = client.post(
            "/api/v1/ai/relay/chat", headers=headers,
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        assert res.status_code == 400, res.text
        assert res.json().get("error_code") == "AI_PROVIDER_HOST_NOT_ALLOWED", res.text

        # ask:docs index 缺失时 503 先于 host 判定 —— 但只要不是 500 就说明
        # host 错误没有穿透成未捕获异常(两种 4xx/503 都是「明确归因」)。
        res = client.post("/api/v1/ai/ask", headers=headers, json={"query": "hi", "locale": "zh"})
        assert res.status_code != 500, f"ask blocked host 不得 500: {res.text[:200]}"
    finally:
        app.dependency_overrides.clear()


def test_host_not_allowed_error_is_chat_provider_error_subclass() -> None:
    """D2 根因护栏:`AiHostNotAllowedError` 必须是 `ChatProviderError` 子类。

    这是「一个改动关闭一族」的根因修复 —— 任何只捕获
    `ChatProviderError` 的既有/未来入口,最坏退化成 502,永不 500。
    同时断言 re-export 是**同一个类对象**(既有 import 路径不变)。
    """
    from src.services.ai import ChatProviderError as ViaPackage
    from src.services.ai.outbound_policy import AiHostNotAllowedError
    from src.services.ai.provider_client import AiHostNotAllowedError as ViaClient
    from src.services.ai.provider_client import ChatProviderError

    assert issubclass(AiHostNotAllowedError, ChatProviderError)
    assert ViaClient is AiHostNotAllowedError
    assert ViaPackage is ChatProviderError


# ══════════════════════════════════════════════════════════════════════
# D3 —— admin 密码端点:超长 → 4xx,不得 500
# ══════════════════════════════════════════════════════════════════════


def _make_admin(Session, email: str) -> None:
    with Session() as db:
        user = db.scalar(select(User).where(User.email == email))
        assert user is not None
        user.is_admin = True
        db.commit()


def test_admin_password_endpoints_reject_oversized_passwords() -> None:
    """D3 (HIGH):admin 改密 / 建用户的超长密码 → 4xx(不是 500)。

    修复前实测:`admin_password="A"*5000` → 500、`new_password="B"*5000` → 500、
    `POST /admin/users password="C"*5000` → 500(4096 恰好仍可用)。
    """
    client, Session = _make_client()
    try:
        admin_email = "d3-admin@example.com"
        admin_token = _login(client, admin_email, client_type="web")
        _make_admin(Session, admin_email)

        victim_token = _login(client, "d3-victim@example.com", client_type="web")
        assert victim_token  # 目标用户存在即可
        with Session() as db:
            victim = db.scalar(select(User).where(User.email == "d3-victim@example.com"))
            victim_id = victim.id

        headers = _auth(admin_token)

        # 1) 超长 admin_password(二次验证)→ 401(凭据错误),不是 500
        res = client.post(
            f"/api/v1/admin/users/{victim_id}/password", headers=headers,
            json={"admin_password": "A" * 5000, "new_password": "newpass123"},
        )
        assert res.status_code in (400, 401, 422), (
            f"超长 admin_password 应 4xx,实际 {res.status_code} {res.text[:200]}"
        )

        # 2) 超长 new_password → 422(校验失败),不是 500
        res = client.post(
            f"/api/v1/admin/users/{victim_id}/password", headers=headers,
            json={"admin_password": _PW, "new_password": "B" * 5000},
        )
        assert res.status_code in (400, 422), (
            f"超长 new_password 应 4xx,实际 {res.status_code} {res.text[:200]}"
        )

        # 3) 建用户超长密码 → 422,不是 500
        res = client.post(
            "/api/v1/admin/users", headers=headers,
            json={"email": "d3-new@example.com", "password": "C" * 5000},
        )
        assert res.status_code in (400, 422), (
            f"建用户超长密码应 4xx,实际 {res.status_code} {res.text[:200]}"
        )

        # 4) 边界:passlib 上限(4096)本身仍应可用(修复不得过度收紧)
        res = client.post(
            "/api/v1/admin/users", headers=headers,
            json={"email": "d3-edge@example.com", "password": "C" * 4096},
        )
        assert res.status_code == 201, (
            f"4096 字符密码(恰好在上限内)应仍可建用户,实际 {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()


def test_admin_password_change_flow_still_works() -> None:
    """D3 正向护栏:修复不得破坏正常改密(短密码 + 正确 admin 密码)。"""
    client, Session = _make_client()
    try:
        admin_email = "d3ok-admin@example.com"
        admin_token = _login(client, admin_email, client_type="web")
        _make_admin(Session, admin_email)
        _login(client, "d3ok-victim@example.com", client_type="web")
        with Session() as db:
            victim = db.scalar(select(User).where(User.email == "d3ok-victim@example.com"))
            victim_id = victim.id

        res = client.post(
            f"/api/v1/admin/users/{victim_id}/password", headers=_auth(admin_token),
            json={"admin_password": _PW, "new_password": "BrandNewPass9"},
        )
        assert res.status_code == 200, res.text

        # 目标用户能用新密码登录
        res = client.post(
            "/api/v1/auth/login",
            json={"email": "d3ok-victim@example.com", "password": "BrandNewPass9",
                  "client_type": "web"},
        )
        assert res.status_code == 200, res.text
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# D4 —— rclone.conf 跨租户隔离:同名 remote 不得串号
# ══════════════════════════════════════════════════════════════════════


def _add_remote(client: TestClient, token: str, *, name: str, secret: str, key_id: str) -> None:
    res = client.post(
        "/api/v1/admin/backup/remotes", headers=_auth(token),
        json={
            "name": name, "backend_type": "s3",
            "config": {
                "provider": "AWS", "access_key_id": key_id,
                "secret_access_key": secret, "region": "us-east-1",
                "bucket": f"bucket-{name}",
            },
        },
    )
    assert res.status_code == 201, res.text


def test_rclone_conf_same_name_across_admins_does_not_leak_secret(tmp_path) -> None:
    """D4 (HIGH, 跨租户泄密):两个 admin 各建同名 remote `shared`,共享
    `rclone.conf` 必须同时容纳两份配置,且 download 端点只返回自己的。

    修复前实测:A 下载到 `AKIA-B / SECRET-B`(B 的凭据),自己的 secret 丢失
    —— A 的定时备份会用 B 的凭据打 B 的 bucket(跨租户读写删)。
    """
    from src.services.backup.rclone_config import RcloneConfigManager

    client, Session = _make_client()
    try:
        token_a = _login(client, "d4-a@example.com", client_type="web")
        token_b = _login(client, "d4-b@example.com", client_type="web")
        _make_admin(Session, "d4-a@example.com")
        _make_admin(Session, "d4-b@example.com")

        _add_remote(client, token_a, name="shared", secret="SECRET-A", key_id="AKIA-A")
        _add_remote(client, token_b, name="shared", secret="SECRET-B", key_id="AKIA-B")

        conf_path = tmp_path / "rclone.conf"
        mgr = RcloneConfigManager(str(conf_path), "rclone")
        with Session() as db:
            user_a = db.scalar(select(User).where(User.email == "d4-a@example.com"))
            user_b = db.scalar(select(User).where(User.email == "d4-b@example.com"))

            mgr.rewrite_from_db(db, user_a.id)
            after_a = conf_path.read_text(encoding="utf-8")
            assert "SECRET-A" in after_a

            mgr.rewrite_from_db(db, user_b.id)
            merged = conf_path.read_text(encoding="utf-8")
            # 共享文件同时含两份(命名空间隔离)
            assert "SECRET-A" in merged, f"A 的配置被 B 的 rewrite 抹掉:\n{merged}"
            assert "SECRET-B" in merged, merged

            dl_a = mgr.read_text_for_user(db, user_a.id)
            dl_b = mgr.read_text_for_user(db, user_b.id)

        assert "SECRET-A" in dl_a and "SECRET-B" not in dl_a, (
            f"A 的下载端点返回了 B 的 secret(跨租户泄密):\n{dl_a}"
        )
        assert "SECRET-B" in dl_b and "SECRET-A" not in dl_b, (
            f"B 的下载端点返回了 A 的 secret:\n{dl_b}"
        )
        # 两份下载产物都只应有 1 个 section(自己的),且用的都是用户可见名
        assert dl_a.count("[") == 1 and "[shared]" in dl_a, dl_a
        assert dl_b.count("[") == 1 and "[shared]" in dl_b, dl_b
    finally:
        app.dependency_overrides.clear()


def test_rclone_paths_use_namespaced_sections(tmp_path) -> None:
    """D4 一致护栏:写进 conf 的 section 名 = 命令路径里的 remote 名。

    `remote_path` / `remote_root` 必须与 `rewrite_from_db` 用**同一个**
    section 派生函数,否则 rclone 会报 "didn't find section in config file"。
    顺带锁住命名空间的确定性(同一 user_id 恒定、不同 user_id 不撞)。
    """
    from src.services.backup.rclone_config import (
        RcloneConfigManager,
        remote_path,
        remote_root,
        scoped_section_name,
        section_name_for,
        user_namespace,
    )

    # 确定性 + 互斥:同一 id 两次相同;两个不同 id 不同
    uid_a = "9d622cb3-e4f8-4497-8f3d-bf074bee93ac"
    uid_b = "2281e0a8-e18c-41d6-bbfa-36b8b933c88b"
    assert user_namespace(uid_a) == user_namespace(uid_a)
    assert user_namespace(uid_a) != user_namespace(uid_b)
    # 同名 remote 在不同 namespace 下 section 不同(修复的核心不变量)
    assert scoped_section_name(uid_a, "same") != scoped_section_name(uid_b, "same")

    client, Session = _make_client()
    try:
        token = _login(client, "d4-single@example.com", client_type="web")
        _make_admin(Session, "d4-single@example.com")
        _add_remote(client, token, name="solo", secret="SECRET-S", key_id="AKIA-S")

        conf_path = tmp_path / "rclone.conf"
        mgr = RcloneConfigManager(str(conf_path), "rclone")
        with Session() as db:
            user = db.scalar(select(User).where(User.email == "d4-single@example.com"))
            mgr.rewrite_from_db(db, user.id)
            from src.models import BackupRemote

            row = db.scalar(select(BackupRemote).where(BackupRemote.user_id == user.id))
            section = section_name_for(row)
            conf = conf_path.read_text(encoding="utf-8")
            assert f"[{section}]" in conf, f"conf 里没有命令路径引用的 section:\n{conf}"
            assert remote_root(row).startswith(f"{section}:"), remote_root(row)
            assert remote_path(row, "x.tar.gz").startswith(f"{section}:"), remote_path(row, "x.tar.gz")
            # 单 admin 往返:自己的 secret 在下载里,且 section 名还原成
            # 用户可见名(UI 的 CLI 步骤按 remote name 打印命令)。
            dl = mgr.read_text_for_user(db, user.id)
            assert "SECRET-S" in dl, dl
            assert "[solo]" in dl, f"下载产物应使用用户可见 remote name:\n{dl}"
            assert f"[{section}]" not in dl, (
                f"下载产物不应暴露内部命名空间 section 名:\n{dl}"
            )
    finally:
        app.dependency_overrides.clear()


def test_rclone_remote_delete_drops_only_own_section(tmp_path) -> None:
    """D4 回归护栏:remote 删除后,自己命名空间的段被清掉,别人的留着。"""
    from src.models import BackupRemote
    from src.services.backup.rclone_config import RcloneConfigManager

    client, Session = _make_client()
    try:
        token_a = _login(client, "d4d-a@example.com", client_type="web")
        token_b = _login(client, "d4d-b@example.com", client_type="web")
        _make_admin(Session, "d4d-a@example.com")
        _make_admin(Session, "d4d-b@example.com")
        _add_remote(client, token_a, name="shared", secret="SECRET-A", key_id="AKIA-A")
        _add_remote(client, token_b, name="shared", secret="SECRET-B", key_id="AKIA-B")

        conf_path = tmp_path / "rclone.conf"
        mgr = RcloneConfigManager(str(conf_path), "rclone")
        with Session() as db:
            user_a = db.scalar(select(User).where(User.email == "d4d-a@example.com"))
            user_b = db.scalar(select(User).where(User.email == "d4d-b@example.com"))
            mgr.rewrite_from_db(db, user_a.id)
            mgr.rewrite_from_db(db, user_b.id)
            assert "SECRET-A" in conf_path.read_text(encoding="utf-8")

            # 删掉 A 的 remote,再 rewrite
            row_a = db.scalar(
                select(BackupRemote).where(BackupRemote.user_id == user_a.id)
            )
            db.delete(row_a)
            db.commit()
            mgr.rewrite_from_db(db, user_a.id)

            conf = conf_path.read_text(encoding="utf-8")
            assert "SECRET-A" not in conf, f"A 的段应被删除:\n{conf}"
            assert "SECRET-B" in conf, f"B 的段被误删:\n{conf}"
    finally:
        app.dependency_overrides.clear()
