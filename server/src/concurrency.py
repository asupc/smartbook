from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.orm import Session


def lock_ledger_for_materialize(db: Session, ledger_id: str) -> None:
    """Serialize snapshot materialization per ledger.

    Holds a transaction-scoped advisory lock keyed on the ledger's UUID string.
    Lock is released automatically at COMMIT/ROLLBACK.

    Without this lock, two concurrent pushes for the same ledger can each read
    the latest snapshot, merge only their own changes, and write competing new
    snapshots — losing one side's individual changes.

    SQLite (dev/test) is a no-op: it serializes writes at the file level.
    """
    dialect_name = db.bind.dialect.name if db.bind is not None else ""
    if dialect_name != "postgresql":
        return
    db.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
        {"k": ledger_id},
    )


def lock_user_global(db: Session, user_id: str) -> None:
    """Serialize user-global entity writes (account/category/tag) per user.

    Same mechanism as [lock_ledger_for_materialize], keyed on
    ``user_global:{user_id}``. Guards the race between a user-global rename
    cascade (SQL UPDATE refreshing read_tx_projection denorm columns — which
    may hit rows owned by a shared-ledger owner, not just the actor) and a
    concurrent ledger-scope tx upsert writing the same rows.

    Lock ORDER contract (see SYNC_ARCHITECTURE.md §4.7): always acquire user
    locks BEFORE ledger locks (user -> ledger). A path that already holds a
    ledger lock must not take this afterwards.

    SQLite (dev/test) is a no-op: it serializes writes at the file level.
    """
    dialect_name = db.bind.dialect.name if db.bind is not None else ""
    if dialect_name != "postgresql":
        return
    db.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
        {"k": f"user_global:{user_id}"},
    )
