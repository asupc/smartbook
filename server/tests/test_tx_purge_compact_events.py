"""P1-A3 —— 交易物理 purge 时 compact 其 upsert 事件历史。

唯一物理 purge 入口:read/trash.py 的 purge 端点(手动「彻底删除」)。
(data_cleanup 的过期回收站清理已随「永久保留」改造删除。)
"""
from __future__ import annotations

from src.main import app
from tests.test_tx_batch_delete import (
    _create_ledger,
    _make_client,
    _register_and_login,
    _seed_txs,
)


def test_trash_purge_endpoint_compacts_upsert_events():
    """手动「彻底删除」端点:purge 后该 tx 只剩 delete 墓碑事件。"""
    client = _make_client()
    try:
        token = _register_and_login(client, "purge-compact@test.com")
        ledger_id = _create_ledger(client, token)
        victim, keeper = _seed_txs(client, token, ledger_id, n=2)

        # 软删(产生 upsert 历史 + delete 墓碑)
        r = client.request(
            "DELETE",
            f"/api/v1/write/ledgers/{ledger_id}/transactions/{victim}",
            json={"base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text

        # 彻底删除
        r = client.post(
            f"/api/v1/read/workspace/trash/{victim}/purge",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        assert r.json()["ok"] is True

        # _make_client 的 engine 在闭包里拿不到,经 API 断言:purge 后 restore
        # 应 404(行已物理删),事件面走 /sync/pull 检查。
        r = client.post(
            f"/api/v1/read/workspace/trash/{victim}/restore",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 404

        r = client.get(
            "/api/v1/sync/pull?since=0&limit=500",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        by_entity: dict[str, list[str]] = {}
        for c in r.json()["changes"]:
            if c.get("entity_type") == "transaction":
                by_entity.setdefault(c["entity_sync_id"], []).append(c["action"])
        # victim 只剩 delete 墓碑;keeper 的 upsert 完好
        assert by_entity.get(victim) == ["delete"], by_entity.get(victim)
        assert by_entity.get(keeper) == ["upsert"]
    finally:
        app.dependency_overrides.clear()
