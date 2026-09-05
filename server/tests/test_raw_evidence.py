from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, func
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import RawBookkeepingEvidence, SyncChange
from src.security import create_access_token, decode_token
from src.services.raw_evidence_retention import purge_expired_raw_evidence


def _bootstrap(monkeypatch):
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autocommit=False, autoflush=False)
    def override():
        db = Session()
        try:
            yield db
        finally:
            db.close()
    app.dependency_overrides[get_db] = override
    return Session


def _register(client: TestClient, email: str) -> str:
    password = "Pa$$word1!"
    r = client.post("/api/v1/auth/register", json={"email": email, "password": password, "device_id": email, "client_type": "app"})
    assert r.status_code in (200, 201), r.text
    r = client.post("/api/v1/auth/login", json={"email": email, "password": password, "device_id": email, "client_type": "app"})
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _payload(key: str, body: str = "支付成功 30 元") -> dict:
    return {
        "event_key": key, "source": "sms", "source_channel": "bank",
        "actor": "95555", "title": "交易提醒", "body": body,
        "metadata": {"length": len(body)},
        "captured_at": datetime.now(timezone.utc).isoformat(),
    }

def test_raw_evidence_isolated_upsert_list_detail_delete(monkeypatch):
    _bootstrap(monkeypatch)
    try:
        c = TestClient(app)
        token = _register(c, "evidence-a@example.com")
        h = {"Authorization": f"Bearer {token}"}
        r = c.post("/api/v1/evidence/raw", headers=h, json=_payload("sms:event-1"))
        assert r.status_code == 200, r.text
        first = r.json()
        assert first["body"] == "支付成功 30 元"
        r2 = c.post("/api/v1/evidence/raw", headers=h, json=_payload("sms:event-1", "支付成功 31 元"))
        assert r2.status_code == 200
        assert r2.json()["id"] == first["id"]
        assert r2.json()["body"] == "支付成功 31 元"
        listed = c.get("/api/v1/evidence/raw?source=sms", headers=h)
        assert listed.status_code == 200
        assert listed.json()["total"] == 1
        detail = c.get(f"/api/v1/evidence/raw/{first['id']}", headers=h)
        assert detail.status_code == 200
        assert c.delete(f"/api/v1/evidence/raw/{first['id']}", headers=h).json() == {"ok": True}
        assert c.get(f"/api/v1/evidence/raw/{first['id']}", headers=h).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_raw_evidence_user_isolation_and_cleanup(monkeypatch):
    Session = _bootstrap(monkeypatch)
    try:
        c = TestClient(app)
        ta = _register(c, "evidence-b@example.com")
        tb = _register(c, "evidence-c@example.com")
        ha = {"Authorization": f"Bearer {ta}"}; hb = {"Authorization": f"Bearer {tb}"}
        row = c.post("/api/v1/evidence/raw", headers=ha, json=_payload("sms:private")).json()
        assert c.get(f"/api/v1/evidence/raw/{row['id']}", headers=hb).status_code == 404
        assert c.delete(f"/api/v1/evidence/raw/{row['id']}", headers=hb).status_code == 404
        with Session() as db:
            item = db.scalar(select(RawBookkeepingEvidence).where(RawBookkeepingEvidence.id == row["id"]))
            item.captured_at = datetime.now(timezone.utc) - timedelta(days=10)
            db.commit()
        clean = c.post("/api/v1/evidence/raw/cleanup", headers=ha, json={"before": datetime.now(timezone.utc).isoformat()})
        assert clean.status_code == 200 and clean.json()["deleted"] == 1
    finally:
        app.dependency_overrides.clear()


def test_raw_evidence_limits_body_and_metadata(monkeypatch):
    _bootstrap(monkeypatch)
    try:
        c = TestClient(app); t = _register(c, "evidence-d@example.com"); h={"Authorization":f"Bearer {t}"}
        bad = _payload("sms:too-long", "x" * 65537)
        assert c.post("/api/v1/evidence/raw", headers=h, json=bad).status_code == 422
        bad = _payload("sms:metadata"); bad["metadata"] = {"x": "x" * 17000}
        assert c.post("/api/v1/evidence/raw", headers=h, json=bad).status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_raw_evidence_scopes_keep_web_read_only_and_allow_explicit_cleanup(monkeypatch):
    _bootstrap(monkeypatch)
    try:
        c = TestClient(app)
        token = _register(c, "evidence-scopes@example.com")
        h = {"Authorization": f"Bearer {token}"}
        user_id = decode_token(token)["sub"]
        read, _ = create_access_token(user_id, scopes=["web_read"], client_type="web")
        write, _ = create_access_token(user_id, scopes=["web_read", "web_write"], client_type="web")
        hr = {"Authorization": f"Bearer {read}"}
        hw = {"Authorization": f"Bearer {write}"}
        payload = _payload("sms:scope")
        row = c.post("/api/v1/evidence/raw", headers=h, json=payload).json()
        url = f"/api/v1/evidence/raw/{row['id']}"
        assert c.get("/api/v1/evidence/raw", headers=hr).status_code == 200
        assert c.get(url, headers=hr).status_code == 200
        assert c.post("/api/v1/evidence/raw", headers=hr, json=payload).status_code == 403
        assert c.post("/api/v1/evidence/raw", headers=hw, json=payload).status_code == 403
        assert c.patch(url, headers=hw, json=payload).status_code == 403
        assert c.delete(url, headers=hr).status_code == 403
        assert c.post("/api/v1/evidence/raw/cleanup", headers=hr, json={}).status_code == 403
        assert c.delete(url, headers=hw).status_code == 200
    finally:
        app.dependency_overrides.clear()


def test_expired_detail_is_hidden_without_listing_and_gc_needs_no_viewer(monkeypatch):
    Session = _bootstrap(monkeypatch)
    try:
        c = TestClient(app)
        token = _register(c, "evidence-expiry@example.com")
        h = {"Authorization": f"Bearer {token}"}
        now = datetime.now(timezone.utc)
        past = (now - timedelta(days=1)).isoformat()
        assert c.post("/api/v1/evidence/raw", headers=h, json={**_payload("expired:upload"), "expires_at": past}).status_code == 410
        rows = [c.post("/api/v1/evidence/raw", headers=h, json=_payload(f"sms:expired:{i}")).json() for i in range(3)]
        with Session() as db:
            for row in rows[:2]:
                item = db.get(RawBookkeepingEvidence, row["id"])
                item.expires_at = now - timedelta(seconds=1)
            db.commit()
        assert c.get(f"/api/v1/evidence/raw/{rows[0]['id']}", headers=h).status_code == 404
        with Session() as db:
            assert db.get(RawBookkeepingEvidence, rows[0]["id"]) is None
            assert purge_expired_raw_evidence(db, now=now) == 1
        listed = c.get("/api/v1/evidence/raw", headers=h)
        assert listed.json()["total"] == 1
        assert listed.headers["cache-control"] == "no-store"
    finally:
        app.dependency_overrides.clear()


def test_filters_preview_cleanup_and_sync_channel_are_independent(monkeypatch, caplog):
    Session = _bootstrap(monkeypatch)
    try:
        c = TestClient(app)
        token = _register(c, "evidence-filters@example.com")
        other = _register(c, "evidence-other@example.com")
        h = {"Authorization": f"Bearer {token}"}; ho = {"Authorization": f"Bearer {other}"}
        now = datetime.now(timezone.utc)
        old = (now - timedelta(days=3)).isoformat()
        cutoff = (now - timedelta(days=1)).isoformat()
        text = "RAW_SECRET_SENTINEL" + "z" * 1000
        with Session() as db:
            changes_before = db.scalar(select(func.count()).select_from(SyncChange))
        row = c.post("/api/v1/evidence/raw", headers=h, json={**_payload("sms:old", text), "captured_at": old}).json()
        c.post("/api/v1/evidence/raw", headers=h, json=_payload("sms:new"))
        c.post("/api/v1/evidence/raw", headers=h, json={**_payload("notification:old"), "source": "notification", "captured_at": old})
        c.post("/api/v1/evidence/raw", headers=ho, json={**_payload("sms:old"), "captured_at": old})
        assert c.get("/api/v1/evidence/raw", headers=h, params={"source": "sms", "to": cutoff}).json()["total"] == 1
        preview = c.get("/api/v1/evidence/raw", headers=h, params={"to": cutoff, "source": "sms"}).json()["items"][0]
        assert len(preview["body"]) == 500
        assert c.get(f"/api/v1/evidence/raw/{row['id']}", headers=h).json()["body"] == text
        assert c.get("/api/v1/evidence/raw", headers=h, params={"from": cutoff}).json()["total"] == 1
        assert c.get("/api/v1/evidence/raw", headers=h, params={"limit": 1, "offset": 1}).json()["total"] == 3
        assert c.post("/api/v1/evidence/raw", headers=h, json={**_payload("bad-ledger"), "ledger_id": "not-accessible"}).status_code == 404
        clean = c.post("/api/v1/evidence/raw/cleanup", headers=h, json={"source": "sms", "before": cutoff})
        assert clean.json()["deleted"] == 1
        assert c.get("/api/v1/evidence/raw", headers=h).json()["total"] == 2
        assert c.get("/api/v1/evidence/raw", headers=ho).json()["total"] == 1
        with Session() as db:
            assert db.scalar(select(func.count()).select_from(SyncChange)) == changes_before
        assert "RAW_SECRET_SENTINEL" not in caplog.text
    finally:
        app.dependency_overrides.clear()
