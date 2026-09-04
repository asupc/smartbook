"""snapshot_mutator.delete_account 同名账户关联判定（syncId 精确匹配）。

回归背景：delete_account 曾用 accountName 名字匹配关联交易，同名账户时会把
「另一个同名账户的交易」误判成本账户的关联交易，导致删不掉（报
"account has linked transactions"）。修复后按 syncId 精确匹配。
"""

from __future__ import annotations


def _delete_account(snapshot: dict, account_id: str) -> dict:
    from src.snapshot_mutator import delete_account

    return delete_account(snapshot, account_id)


def test_delete_account_by_syncid_ignores_same_name_other_account():
    """同名两个账户：删除一个，另一个的同名交易不应阻断删除。"""
    snapshot = {
        "ledgerName": "L",
        "currency": "CNY",
        "accounts": [
            {"syncId": "acc-a", "name": "微信零钱"},
            {"syncId": "acc-b", "name": "微信零钱"},
        ],
        "items": [
            {
                "syncId": "tx-1",
                "type": "expense",
                "amount": 10.0,
                "happenedAt": "2026-06-22T00:00:00+00:00",
                "accountId": "acc-b",  # 交易挂在 acc-b
                "accountName": "微信零钱",
            }
        ],
    }
    out = _delete_account(snapshot, "acc-a")
    remaining = [a["syncId"] for a in out["accounts"]]
    assert remaining == ["acc-b"]
    # 删除 acc-a 后，acc-b 的交易字段应原样保留。
    tx = out["items"][0]
    assert tx["accountId"] == "acc-b"


def test_delete_account_still_blocks_when_linked_by_syncid():
    """同名场景反向验证：删除有真实关联交易的那个账户仍应被拒。"""
    import pytest

    snapshot = {
        "ledgerName": "L",
        "currency": "CNY",
        "accounts": [
            {"syncId": "acc-a", "name": "微信零钱"},
            {"syncId": "acc-b", "name": "微信零钱"},
        ],
        "items": [
            {
                "syncId": "tx-1",
                "type": "expense",
                "amount": 10.0,
                "happenedAt": "2026-06-22T00:00:00+00:00",
                "accountId": "acc-a",
                "accountName": "微信零钱",
            }
        ],
    }
    with pytest.raises(ValueError):
        _delete_account(snapshot, "acc-a")


def test_delete_account_legacy_name_fallback():
    """老数据缺 accountId 字段：回退名字匹配，有同名交易时仍阻断。"""
    import pytest

    snapshot = {
        "ledgerName": "L",
        "currency": "CNY",
        "accounts": [{"syncId": "acc-a", "name": "微信零钱"}],
        "items": [
            {
                "syncId": "tx-1",
                "type": "expense",
                "amount": 10.0,
                "happenedAt": "2026-06-22T00:00:00+00:00",
                "accountName": "微信零钱",  # 无 accountId
            }
        ],
    }
    with pytest.raises(ValueError):
        _delete_account(snapshot, "acc-a")
