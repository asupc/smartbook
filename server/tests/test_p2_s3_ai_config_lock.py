"""S3:ai_config_json 乐观锁(ai_config_version)回归测试。

- 正常流:POST /ai/providers 建服务商 → 版本 +1;
- 并发冲突:用读时版本(过期)再写 → 409 AI_CONFIG_CONFLICT,原值不被覆盖;
- 首建竞态:两路同时 INSERT 撞 user_id 唯一约束 → 409;
- PATCH /profile/me 带 ai_config 同样走 guarded UPDATE。
"""
from __future__ import annotations

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from src.database import Base, get_db
from src.main import app
from src.models import User, UserProfile
from src.routers.ai.providers import save_ai_config_guarded
from tests.test_tx_batch_delete import _make_client, _register_and_login


def _session():
    return next(app.dependency_overrides[get_db]())


def test_s3_provider_create_bumps_version():
    client = _make_client()
    try:
        token = _register_and_login(client, "s3a@test.com")
        r = client.post(
            "/api/v1/ai/providers",
            json={"name": "P1", "apiKey": "sk-1", "baseUrl": "https://x.example"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 201, r.text

        db = _session()
        user = db.scalar(select(User).where(User.email == "s3a@test.com"))
        profile = db.scalar(select(UserProfile).where(UserProfile.user_id == user.id))
        assert profile.ai_config_version == 1
        assert "P1" in (profile.ai_config_json or "")
    finally:
        app.dependency_overrides.clear()


def test_s3_stale_version_write_conflicts():
    """模拟并发:profile 按版本 N 读出,DB 已被别人推进到 N+1 → 写 409,不覆盖。"""
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autoflush=False)
    db = Session()
    db_concurrent = Session()  # 并发者用的独立 session(真实并发即如此)
    try:
        db.add(User(id="u3", email="s3b@t.com", password_hash="x"))
        db.commit()
        profile = save_ai_config_guarded(
            db, user_id="u3", new_json='{"providers":[{"id":"p1"}]}', profile=None,
        )
        assert profile.ai_config_version == 1

        # 并发者(独立 session)推进版本;本 session 的 profile 对象保持读时值 1
        db_concurrent.execute(
            UserProfile.__table__.update()
            .where(UserProfile.user_id == "u3")
            .values(ai_config_version=2, ai_config_json='{"providers":[{"id":"p2"}]}')
        )
        db_concurrent.commit()

        # 旧对象(版本 1)再写 → 409
        from fastapi import HTTPException
        with pytest.raises(HTTPException) as exc:
            save_ai_config_guarded(
                db, user_id="u3",
                new_json='{"providers":[{"id":"p1","name":"mine"}]}',
                profile=profile,
            )
        assert exc.value.status_code == 409
        assert exc.value.detail["error_code"] == "AI_CONFIG_CONFLICT"

        # DB 值未被覆盖
        row = db.execute(
            select(UserProfile.ai_config_json, UserProfile.ai_config_version)
            .where(UserProfile.user_id == "u3")
        ).one()
        assert "p2" in row[0] and row[1] == 2
    finally:
        db.close()
        db_concurrent.close()
        engine.dispose()


def test_s3_concurrent_first_insert_conflicts():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autoflush=False)
    db = Session()
    try:
        db.add(User(id="u4", email="s3c@t.com", password_hash="x"))
        db.commit()
        # 第一个创建成功
        save_ai_config_guarded(
            db, user_id="u4", new_json='{"providers":[]}', profile=None,
        )
        # 并发者手里没有 profile(读到 None)再创建 → 撞唯一约束 → 409
        from fastapi import HTTPException
        with pytest.raises(HTTPException) as exc:
            save_ai_config_guarded(
                db, user_id="u4", new_json='{"providers":[]}', profile=None,
            )
        assert exc.value.status_code == 409
        assert exc.value.detail["error_code"] == "AI_CONFIG_CONFLICT"
    finally:
        db.close()
        engine.dispose()


def test_s3_profile_patch_ai_config_conflict():
    """PATCH /profile/me 带 ai_config:外部推进版本后,端点 guard 失败 → 409。

    直接调 endpoint 无法在 load 与 save 之间插桩;此处验证「带 ai_config 的
    PATCH 正常成功且版本递增」+ guarded helper 的 409 已由上面单测覆盖。"""
    client = _make_client()
    try:
        token = _register_and_login(client, "s3d@test.com")
        r = client.patch(
            "/api/v1/profile/me",
            json={"ai_config": {"strategy": "cloud_first"}},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200, r.text

        db = _session()
        user = db.scalar(select(User).where(User.email == "s3d@test.com"))
        profile = db.scalar(select(UserProfile).where(UserProfile.user_id == user.id))
        assert profile.ai_config_version == 1
        assert "cloud_first" in (profile.ai_config_json or "")

        # 非 ai_config 字段 PATCH 不动版本
        r = client.patch(
            "/api/v1/profile/me",
            json={"display_name": "n1"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200
        db.refresh(profile)
        assert profile.ai_config_version == 1
        assert profile.display_name == "n1"
    finally:
        app.dependency_overrides.clear()
