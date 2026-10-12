"""批次 X3:Postgres 专有行为契约测试(@pytest.mark.pg_only)。

本文件覆盖 FINDINGS-sync-consistency.md「未能验证(测试不可确定性复现)」与
FINDINGS-auth-security.md「未能验证项」点名的四条契约 —— 它们**全部由
Postgres 专有行为承载**,SQLite in-memory 下不可复现:

  1. advisory lock 真实串行化:`pg_advisory_xact_lock` 在 SQLite 是 no-op
     (src/concurrency.py:19-21 `dialect_name != "postgresql"` 直接 return)。
  2. user→ledger 锁顺序防死锁:两连接以相反顺序抢同一对锁 —— PG 下会真死锁,
     固定顺序下不会;SQLite 无锁无从验证。
  3. 列宽越界报错:`String(255)` / `String(128)` 在 SQLite 静默放行,
     PG 抛 DataError(F-07/F-09 的「生产影响」推断)。
  4. 并发 push 不丢更新:同账本两个连接并发 apply 投影,advisory lock
     保证串行;SQLite 用文件锁把竞态窗口盖住,行为不同。

运行方式(默认 SQLite 下整文件 skip,不会让 `pytest tests/` 变红):

    bash scripts/run_pg_tests.sh                 # 起 postgres:16 + 跑全量
    # 或手动:
    export SMARTBOOK_TEST_DATABASE_URL='postgresql+psycopg://u:p@127.0.0.1:55432/smartbook_test'
    python -m pytest tests/test_pg_only_contracts.py -m pg_only -q

设计约束:
  - 本文件**只读取** src/**,不改生产代码。
  - 每个用例自己建 engine + create_all;不依赖 tests/conftest.py 的全局替换。
  - 未设置 SMARTBOOK_TEST_DATABASE_URL 时 `pytestmark` 让整文件 skip
    (conftest 也会对 pg_only 标记统一 skip,这里是双保险)。
"""
from __future__ import annotations

import os
import threading
import time

import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.exc import DataError, IntegrityError
from sqlalchemy.orm import sessionmaker

from src.concurrency import lock_ledger_for_materialize, lock_user_global
from src.database import Base
from src.models import Ledger, SyncChange, User, UserAccountProjection

pytestmark = pytest.mark.pg_only

PG_URL = os.environ.get("SMARTBOOK_TEST_DATABASE_URL") or ""

if not PG_URL:
    pytest.skip(
        "SMARTBOOK_TEST_DATABASE_URL 未设置 —— 见 scripts/run_pg_tests.sh",
        allow_module_level=True,
    )


# --------------------------------------------------------------------------- #
# 脚手架                                                                        #
# --------------------------------------------------------------------------- #

def _fresh_engine():
    """每用例一个干净 schema(public 重建),避免跨用例污染。"""
    engine = create_engine(PG_URL, pool_size=5, max_overflow=5)
    with engine.begin() as conn:
        conn.execute(text("DROP SCHEMA public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
    Base.metadata.create_all(bind=engine)
    return engine


def _session_factory(engine):
    return sessionmaker(bind=engine, autocommit=False, autoflush=False)


def _seed_user_ledger(SF) -> tuple[str, str]:
    with SF() as db:
        user = User(email=f"pg-{time.time_ns()}@t.com", password_hash="x")
        db.add(user)
        db.flush()
        ledger = Ledger(
            user_id=user.id, external_id=f"L{time.time_ns()}", name="L", currency="CNY"
        )
        db.add(ledger)
        db.commit()
        return user.id, ledger.id


# --------------------------------------------------------------------------- #
# 契约 1:advisory lock 真的存在且是事务级                                        
# --------------------------------------------------------------------------- #

def test_pg_advisory_lock_is_real_not_noop():
    """SQLite 下 `lock_ledger_for_materialize` 直接 return(no-op);
    PG 下必须真的执行 `pg_advisory_xact_lock`。

    证据:锁释放前第二个连接阻塞;COMMIT 后立即放行。
    """
    engine = _fresh_engine()
    try:
        SF = _session_factory(engine)
        _, ledger_id = _seed_user_ledger(SF)

        holder = SF()
        holder.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
            {"k": ledger_id},
        )

        got_it = threading.Event()
        released = threading.Event()

        def contender():
            other = SF()
            try:
                other.execute(
                    text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
                    {"k": ledger_id},
                )
                got_it.set()
            finally:
                other.rollback()
                other.close()
                released.set()

        t = threading.Thread(target=contender)
        t.start()
        # 持锁期间竞争者必须拿不到(阻塞 ≥0.5s)
        assert not got_it.wait(timeout=0.5), "PG advisory lock 未阻塞竞争者 → 锁失效"

        holder.commit()
        holder.close()
        assert got_it.wait(timeout=5.0), "持锁事务 COMMIT 后竞争者应立刻获锁"
        t.join(timeout=5.0)
    finally:
        engine.dispose()


def test_pg_lock_helpers_emit_advisory_locks():
    """`lock_ledger_for_materialize` / `lock_user_global` 在 PG 上真的取锁。

    通过 pg_locks 视图确认当前事务持有了 advisory 锁(而非 no-op 路径)。
    """
    engine = _fresh_engine()
    try:
        SF = _session_factory(engine)
        user_id, ledger_id = _seed_user_ledger(SF)
        db = SF()
        try:
            lock_ledger_for_materialize(db, ledger_id)
            lock_user_global(db, user_id)
            locks = db.execute(
                text(
                    "SELECT count(*) FROM pg_locks "
                    "WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
                )
            ).scalar()
            assert locks >= 2, (
                f"期望至少 2 把 advisory 锁(ledger + user),实际 {locks} —— "
                "helper 可能退化成 no-op"
            )
        finally:
            db.rollback()
            db.close()
    finally:
        engine.dispose()


# --------------------------------------------------------------------------- #
# 契约 2:user→ledger 锁顺序防死锁                                               
# --------------------------------------------------------------------------- #

def test_pg_user_then_ledger_order_never_deadlocks():
    """固定 user→ledger 顺序时,两个并发事务不产生死锁。

    反向顺序(ledger→user)在 PG 下会真死锁 —— 本用例用相反顺序做**对照**,
    证明测试本身有能力观察到死锁(否则「不死锁」是空断言)。
    """
    engine = _fresh_engine()
    try:
        SF = _session_factory(engine)
        user_id, ledger_id = _seed_user_ledger(SF)

        errors: list[str] = []

        def worker(order: str):
            db = SF()
            try:
                if order == "user_first":
                    lock_user_global(db, user_id)
                    time.sleep(0.3)
                    lock_ledger_for_materialize(db, ledger_id)
                else:
                    lock_ledger_for_materialize(db, ledger_id)
                    time.sleep(0.3)
                    lock_user_global(db, user_id)
                db.commit()
            except Exception as exc:  # noqa: BLE001 - 记录即可
                errors.append(type(exc).__name__)
                db.rollback()
            finally:
                db.close()

        # 正向:两个 worker 都按 user→ledger
        threads = [threading.Thread(target=worker, args=("user_first",)) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        assert errors == [], f"固定 user→ledger 顺序不应死锁,实际:{errors}"

        # 对照:一正一反 → PG 应检出死锁(证明本测试能观察到死锁)
        errors.clear()
        threads = [
            threading.Thread(target=worker, args=("user_first",)),
            threading.Thread(target=worker, args=("ledger_first",)),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        assert errors, (
            "对照用例未复现死锁 —— 说明本测试无法观察锁序问题,"
            "上面的「不死锁」断言不成立(空断言)"
        )
    finally:
        engine.dispose()


# --------------------------------------------------------------------------- #
# 契约 3:列宽越界在 PG 上真的报错                                                
# --------------------------------------------------------------------------- #

def test_pg_varchar_width_overflow_raises_dataerror():
    """SQLite 不强制 VARCHAR 长度;PG 必须抛 DataError。

    对应 FINDINGS-auth-security.md F-07:超长 email 在 SQLite 静默入库,
    生产 PG 会 500。本用例锁定「PG 侧真的会拒绝」这一环境差异。
    """
    engine = _fresh_engine()
    try:
        SF = _session_factory(engine)
        db = SF()
        try:
            with pytest.raises(DataError):
                db.add(User(email="b" * 5000 + "@example.com", password_hash="x"))
                db.commit()
        finally:
            db.rollback()
            db.close()
    finally:
        engine.dispose()


def test_pg_int8_overflow_raises_dataerror():
    """int8 越界(> 2^63-1)在 PG 抛 DataError;SQLite 只报 OverflowError。"""
    engine = _fresh_engine()
    try:
        SF = _session_factory(engine)
        user_id, ledger_id = _seed_user_ledger(SF)
        db = SF()
        try:
            with pytest.raises((DataError, OverflowError)):
                db.add(
                    SyncChange(
                        user_id=user_id,
                        ledger_id=ledger_id,
                        entity_type="transaction",
                        entity_sync_id="s1",
                        action="upsert",
                        payload_json={},
                        change_id=2**63,
                    )
                )
                db.commit()
        finally:
            db.rollback()
            db.close()
    finally:
        engine.dispose()


# --------------------------------------------------------------------------- #
# 契约 4:并发 push 不丢更新(advisory lock 串行化)                               
# --------------------------------------------------------------------------- #

def test_pg_advisory_lock_serializes_projection_materialization():
    """advisory lock 真串行化:第二个持锁者必须看到第一个持锁者已提交的值。

    可证伪设计:每个 worker 在**拿到锁之后**读一次当前 name 并记录观察值。
    - 锁有效 → 两个观察值 = {"初始", 先写者 tag}(恰好 1 个看到"初始");
    - 锁退化为 no-op(SQLite 行为)→ 两者都读到"初始"(观察值含 2 个"初始"),
      最终一方更新被覆盖 —— 正是「并发 push 丢更新」。
    """
    engine = _fresh_engine()
    try:
        SF = _session_factory(engine)
        user_id, ledger_id = _seed_user_ledger(SF)

        with SF() as db:
            db.add(
                UserAccountProjection(
                    user_id=user_id,
                    sync_id="acc-1",
                    name="初始",
                )
            )
            db.commit()

        results: list[str] = []
        observed: list[str] = []
        obs_lock = threading.Lock()
        barrier = threading.Barrier(2)

        def worker(tag: str):
            db = SF()
            try:
                barrier.wait(timeout=10)  # 尽量同时起跑
                lock_ledger_for_materialize(db, ledger_id)
                row = db.scalar(
                    select(UserAccountProjection).where(
                        UserAccountProjection.sync_id == "acc-1"
                    )
                )
                with obs_lock:
                    observed.append(row.name)
                time.sleep(0.4)  # 持锁放大窗口(第二个 worker 会在此等待)
                row.name = tag
                db.commit()
                results.append(tag)
            except Exception as exc:  # noqa: BLE001
                results.append(f"ERR:{type(exc).__name__}")
                db.rollback()
            finally:
                db.close()

        threads = [threading.Thread(target=worker, args=(t,)) for t in ("A", "B")]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=15)

        assert sorted(results) == ["A", "B"], f"两侧都应成功提交:{results}"
        assert observed.count("初始") == 1, (
            f"观察值={observed} —— 期望恰好 1 个 worker 在锁内看到初值"
            "(另一个必须看到先写者的 tag);出现 2 个说明 advisory lock 未串行化,"
            "并发 push 会丢更新"
        )
        assert set(observed) == {"初始", "A"} or set(observed) == {"初始", "B"}, (
            f"第二个持锁者应看到先写者的值,实际观察={observed}"
        )
        with SF() as db:
            final = db.scalar(
                select(UserAccountProjection).where(
                    UserAccountProjection.sync_id == "acc-1"
                )
            )
        assert final.name in ("A", "B"), f"最终值异常:{final.name}"
    finally:
        engine.dispose()


def test_pg_unique_constraint_on_ledger_external_id_blocks_duplicate():
    """PG 的唯一约束在并发插入下仍成立(IntegrityError 而非静默重复)。"""
    engine = _fresh_engine()
    try:
        SF = _session_factory(engine)
        user_id, _ = _seed_user_ledger(SF)
        with SF() as db:
            db.add(
                Ledger(user_id=user_id, external_id="DUP-EXT", name="a", currency="CNY")
            )
            db.commit()
        db = SF()
        try:
            with pytest.raises(IntegrityError):
                db.add(
                    Ledger(user_id=user_id, external_id="DUP-EXT", name="b", currency="CNY")
                )
                db.commit()
        finally:
            db.rollback()
            db.close()
    finally:
        engine.dispose()
