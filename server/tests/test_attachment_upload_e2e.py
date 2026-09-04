"""附件上传 HTTP 端到端测试 —— 复现 2026-09 反馈"App/Web 导入附件失败"。

完整走一遍:注册/登录 → 建账本 → POST /attachments/upload(multipart,模拟
Web 端 FormData 与 App 端 http.MultipartRequest 的字段形态)→ 断言 200。
"""

from __future__ import annotations

import io

from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
import src.routers.attachments as attachments_module


def _make_client():
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
    return TestClient(app), TS


def _login(client, email):
    client.post("/api/v1/auth/register", json={"email": email, "password": "Pa$$word1!"})
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "d1",
            "client_type": "web",
            "device_name": "pytest",
            "platform": "test",
        },
    )
    return r.json()["access_token"]


def test_upload_csv_attachment_e2e(tmp_path, monkeypatch):
    """Multipart 上传 CSV 附件应 200 且落库(不依赖 `ledger_id` 之外的东西)。"""
    monkeypatch.setattr(attachments_module, "_attachment_root", lambda: tmp_path)

    client, TS = _make_client()
    try:
        tok = _login(client, "att@t.com")
        hdr = {"Authorization": f"Bearer {tok}"}

        r = client.post(
            "/api/v1/write/ledgers",
            headers=hdr,
            json={"ledger_id": "attlg", "ledger_name": "附件账本", "currency": "CNY"},
        )
        assert r.status_code == 200, r.text

        csv_bytes = (
            "支付宝交易记录明细查询,,,,,,,,,,,,,,,\r\n"
            "2026/9/2 19:18,支出,20,天府通-VIVO NFC充值\r\n" * 100
        ).encode("gbk")
        r = client.post(
            "/api/v1/attachments/upload",
            headers=hdr,
            data={"ledger_id": "attlg"},
            files={
                "file": (
                    "alipay_record_20260903_1346_1.csv",
                    io.BytesIO(csv_bytes),
                    "text/csv",
                )
            },
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert "file_id" in body, body
        assert body["file_name"] == "alipay_record_20260903_1346_1.csv", body

        with TS() as db:
            from src.models import AttachmentFile
            row = db.get(AttachmentFile, body["file_id"])
            assert row is not None
            assert row.size_bytes == len(csv_bytes)
    finally:
        app.dependency_overrides.clear()
