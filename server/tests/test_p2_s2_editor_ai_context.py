"""S2:AI 记账账本上下文对共享账本 Editor 可见(parse-tx-image/text 共用 helper)。

旧行为:按 `Ledger.user_id == caller` 判定 → Editor 传共享账本 id 拿不到
上下文(空分类/账户 + CNY 兜底),识别质量下降。
新行为:`get_accessible_ledger_by_external_id`(任意可读角色)→ Editor 也
拿到 owner 账本的币种;分类/账户按 user-global 投影给全。
"""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from src.database import Base
from src.models import (
    Ledger,
    LedgerMember,
    User,
    UserAccountProjection,
    UserCategoryProjection,
)
from src.routers.ai.parse_tx_image import _load_ledger_context


def _make_db():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autoflush=False)
    return Session(), engine


def test_s2_editor_gets_shared_ledger_context():
    db, engine = _make_db()
    try:
        owner = User(id="u1", email="o@t.com", password_hash="x")
        editor = User(id="u2", email="e@t.com", password_hash="x")
        db.add_all([owner, editor])
        ledger = Ledger(
            id="L1", external_id="fam", name="Fam",
            currency="USD", user_id="u1",
            created_at=datetime.now(timezone.utc),
        )
        db.add(ledger)
        db.add(LedgerMember(ledger_id="L1", user_id="u1", role="owner"))
        db.add(LedgerMember(ledger_id="L1", user_id="u2", role="editor"))
        # 分类/账户是 user-global:Editor 自己的投影也有(按 caller user_id 拉)
        db.add(UserCategoryProjection(user_id="u2", sync_id="c1", name="餐饮"))
        db.add(UserAccountProjection(user_id="u2", sync_id="a1", name="Cash"))
        db.commit()

        cats, accts, currency = _load_ledger_context(db, "fam", "u2")
        assert currency == "USD"  # Editor 读到共享账本本位币,不再 CNY 兜底
        assert cats == ["餐饮"]
        assert [a[0] for a in accts] == ["Cash"]

        # owner 视角不变
        cats_o, accts_o, currency_o = _load_ledger_context(db, "fam", "u1")
        assert currency_o == "USD"

        # 非成员拿不到 → 空上下文 + CNY
        db.add(User(id="u3", email="x@t.com", password_hash="x"))
        db.commit()
        cats_x, accts_x, currency_x = _load_ledger_context(db, "fam", "u3")
        assert (cats_x, accts_x, currency_x) == ([], [], "CNY")
    finally:
        db.close()
        engine.dispose()


def test_s2_no_ledger_id_aggregates_accessible_ledgers():
    """未传 ledger_id:聚合「用户可见」账本 —— Editor 含共享账本(币种单账本取它)。"""
    db, engine = _make_db()
    try:
        editor = User(id="u2", email="e@t.com", password_hash="x")
        db.add(editor)
        # Editor 自有账本一个(JPY)+ 被共享一个(USD)→ 两个可见,多账本回退 CNY
        db.add(Ledger(
            id="L0", external_id="mine", name="Mine",
            currency="JPY", user_id="u2", created_at=datetime.now(timezone.utc),
        ))
        db.add(Ledger(
            id="L1", external_id="fam", name="Fam",
            currency="USD", user_id="u1", created_at=datetime.now(timezone.utc),
        ))
        db.add(LedgerMember(ledger_id="L0", user_id="u2", role="owner"))
        db.add(LedgerMember(ledger_id="L1", user_id="u2", role="editor"))
        db.commit()

        _cats, _accts, currency = _load_ledger_context(db, None, "u2")
        assert currency == "CNY"  # 两个可见账本 → 兜底

        # 只有被共享的一个账本时取其币种
        db.execute(LedgerMember.__table__.delete().where(
            LedgerMember.ledger_id == "L0"))
        db.commit()
        _cats, _accts, currency = _load_ledger_context(db, None, "u2")
        assert currency == "USD"
    finally:
        db.close()
        engine.dispose()
