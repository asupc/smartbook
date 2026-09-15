"""S1:附件下载越权修复 + S9:附件并发重复(部分唯一索引)回归测试。

S1:
- 被移除成员曾上传的交易附件 → 下载 403(旧实现「本人上传」分支放行);
- 在册 editor(非上传者)→ 200;
- 本人上传的 category_icon(ledger_id NULL)→ 仍 200(分支保留);
- 陌生人上传的 category_icon → 403。

S9:
- SQLite/模型层:(ledger_id, sha256, kind=transaction) 部分唯一索引生效,
  重复插入 IntegrityError;category_icon(ledger_id NULL)不受约束;
- 上传同图两次 → 复用同一行(同 file_id);
- check-then-insert 竞态兜底:monkeypatch 预检 miss → IntegrityError 分支
  复用既有行(以 transactions_batch 的 _create_attachment_from_bytes 为例)。
"""
from __future__ import annotations

import io

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker

from src.database import Base, get_db
from src.main import app
from src.models import AttachmentFile, Ledger, LedgerMember, User
from tests.test_tx_batch_delete import (
    _create_ledger,
    _make_client,
    _register_and_login,
)


def _png_bytes(b: bytes = b"\x89PNG-fake") -> bytes:
    return b


def _upload(client: TestClient, token: str, ledger_ext: str, content: bytes, name: str = "a.png"):
    return client.post(
        "/api/v1/attachments/upload",
        data={"ledger_id": ledger_ext},
        files={"file": (name, io.BytesIO(content), "image/png")},
        headers={"Authorization": f"Bearer {token}"},
    )


def _session():
    gen = app.dependency_overrides[get_db]()
    return next(gen)


def test_s1_removed_member_cannot_download_own_tx_attachment():
    """Editor 上传附件 → 被移除后下载 403;在册时 200。"""
    import uuid

    client = _make_client()
    try:
        owner_token = _register_and_login(client, "s1-owner@test.com")
        editor_token = _register_and_login(client, "s1-editor@test.com")
        ledger_ext = _create_ledger(client, owner_token)

        db = _session()
        owner = db.scalar(select(User).where(User.email == "s1-owner@test.com"))
        editor = db.scalar(select(User).where(User.email == "s1-editor@test.com"))
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        db.add(LedgerMember(
            ledger_id=ledger.id, user_id=editor.id, role="editor", invited_by=owner.id,
        ))
        db.commit()

        content = b"s1-tx-attachment-" + uuid.uuid4().hex.encode()
        r = _upload(client, editor_token, ledger_ext, content)
        assert r.status_code == 200, r.text
        file_id = r.json()["file_id"]

        # 在册 editor(上传者)可下载
        r = client.get(
            f"/api/v1/attachments/{file_id}",
            headers={"Authorization": f"Bearer {editor_token}"},
        )
        assert r.status_code == 200

        # owner(非上传者,但 owner 角色)也可下载
        r = client.get(
            f"/api/v1/attachments/{file_id}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
        assert r.status_code == 200

        # 移除 editor → 上传者本人下载被拒(S1 核心)
        db.execute(
            LedgerMember.__table__.delete().where(
                LedgerMember.ledger_id == ledger.id,
                LedgerMember.user_id == editor.id,
            )
        )
        db.commit()
        r = client.get(
            f"/api/v1/attachments/{file_id}",
            headers={"Authorization": f"Bearer {editor_token}"},
        )
        assert r.status_code == 403, r.text
    finally:
        app.dependency_overrides.clear()


def test_s1_category_icon_own_upload_still_allowed():
    """ledger_id IS NULL(category_icon):本人上传分支保留;陌生人 icon 403。"""
    client = _make_client()
    try:
        token_a = _register_and_login(client, "s1-icon-a@test.com")
        token_b = _register_and_login(client, "s1-icon-b@test.com")

        r = client.post(
            "/api/v1/attachments/category-icons/upload",
            files={"file": ("icon.png", io.BytesIO(b"icon-by-a"), "image/png")},
            headers={"Authorization": f"Bearer {token_a}"},
        )
        assert r.status_code == 200, r.text
        file_id = r.json()["file_id"]

        # 本人可下载
        r = client.get(
            f"/api/v1/attachments/{file_id}",
            headers={"Authorization": f"Bearer {token_a}"},
        )
        assert r.status_code == 200

        # 无共享账本关系的陌生人 → 403
        r = client.get(
            f"/api/v1/attachments/{file_id}",
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert r.status_code == 403
    finally:
        app.dependency_overrides.clear()


# ───────────────────────── S9 ─────────────────────────


def test_s9_partial_unique_index_blocks_duplicate_tx_rows():
    """模型层:transaction kind 撞 (ledger_id, sha256) 唯一索引;NULL ledger 不受限。"""
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine)
    db = Session()
    try:
        db.add(User(id="u9", email="u9@t.com", password_hash="x"))
        ledger = Ledger(id="L9", external_id="lg9", name="T", currency="CNY", user_id="u9")
        db.add(ledger)
        db.commit()

        db.add(AttachmentFile(
            id="f1", ledger_id="L9", user_id="u9", sha256="x" * 64,
            size_bytes=1, storage_path="/tmp/f1",
        ))
        db.commit()

        # 同 (ledger, sha) 第二行 → 唯一索引拒绝
        db.add(AttachmentFile(
            id="f2", ledger_id="L9", user_id="u9", sha256="x" * 64,
            size_bytes=1, storage_path="/tmp/f2",
        ))
        with pytest.raises(IntegrityError):
            db.commit()
        db.rollback()

        # category_icon(ledger NULL)同 sha 不受限
        db.add(AttachmentFile(
            id="f3", ledger_id=None, user_id="u9", sha256="x" * 64,
            size_bytes=1, storage_path="/tmp/f3", attachment_kind="category_icon",
        ))
        db.commit()
        assert db.get(AttachmentFile, "f3") is not None
    finally:
        db.close()
        engine.dispose()


def test_s9_upload_same_content_reuses_row():
    client = _make_client()
    try:
        token = _register_and_login(client, "s9-up@test.com")
        ledger_ext = _create_ledger(client, token)
        content = b"same-bytes-" + b"9" * 8

        r1 = _upload(client, token, ledger_ext, content)
        assert r1.status_code == 200, r1.text
        r2 = _upload(client, token, ledger_ext, content)
        assert r2.status_code == 200, r2.text
        assert r1.json()["file_id"] == r2.json()["file_id"]

        db = _session()
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        rows = db.scalars(
            select(AttachmentFile).where(AttachmentFile.ledger_id == ledger.id)
        ).all()
        assert len(rows) == 1
    finally:
        app.dependency_overrides.clear()


def test_s9_race_fallback_reuses_existing_row(monkeypatch):
    """模拟 check-then-insert 竞态:让预检 miss,插入撞唯一索引 → 复用既有行。"""
    import hashlib
    import tempfile
    from pathlib import Path

    from src.routers.write import transactions_batch as tb

    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autoflush=False)
    db = Session()
    tmpdir = tempfile.mkdtemp()
    try:
        db.add(User(id="u9b", email="u9b@t.com", password_hash="x"))
        ledger = Ledger(id="L9b", external_id="lg9b", name="T", currency="CNY", user_id="u9b")
        db.add(ledger)
        db.commit()

        sha = hashlib.sha256(b"abc").hexdigest()
        existing = AttachmentFile(
            id="win", ledger_id="L9b", user_id="u9b", sha256=sha,
            size_bytes=3, storage_path=str(Path(tmpdir) / "win.png"),
        )
        db.add(existing)
        db.commit()

        # 预检 miss:第一次 attachment_files 点查返回 None(伪造竞态窗口),
        # 之后恢复真实行为(except 分支的复用查询必须能看到赢家行)。
        real_scalar = db.scalar
        missed = {"done": False}

        def fake_scalar(stmt, *a, **k):
            if not missed["done"] and "attachment_files" in str(stmt):
                missed["done"] = True
                return None
            return real_scalar(stmt, *a, **k)

        monkeypatch.setattr(db, "scalar", fake_scalar)

        from src.config import get_settings
        monkeypatch.setattr(
            tb, "get_settings",
            lambda: get_settings().model_copy(update={"attachment_storage_dir": tmpdir}),
        )

        row = tb._create_attachment_from_bytes(
            db=db, ledger=ledger, user_id="u9b",
            image_bytes=b"abc", mime_type="image/png",
        )
        # 撞唯一索引 → SAVEPOINT 回滚 → 复用赢家行
        assert row.id == "win"
        # 外层事务仍可用(保存点隔离未被破坏)
        db.commit()
    finally:
        db.close()
        engine.dispose()
