"""跨端序列化契约对抗测试(lead 亲自)。

方向:mobile(Flutter EntitySerializer / sync payload)→ server(merge spec /
projection upsert)。历史教训:「改键名会让标记跨设备静默丢失」。

攻击点:客户端**发得出**的字段,服务端**必须消费**;服务端**要求**的字段,
客户端不能不发。任何单向缺失都是一条静默丢数据路径。

这里的断言基于服务端源码的实际消费面(spec keys + projection upsert 里
显式 payload.get 的键),不依赖客户端代码——客户端字段清单在下方常量里
人工核对(来自 client/lib/cloud/sync/entity_serializer.dart, 2026-10-11
工作区版本)。
"""

from __future__ import annotations

import io
import re

SERVER_APPLIER = "src/sync_applier.py"
SERVER_PROJECTION = "src/projection.py"


def _read(path: str) -> str:
    return io.open(path, encoding="utf-8").read()


def _merge_spec_keys() -> dict[str, set[str]]:
    s = _read(SERVER_APPLIER)
    out: dict[str, set[str]] = {}
    for m in re.finditer(
        r'"(\w+)": _MergeSpec\([^,]+,\s*\[(.*?)\]\s*\)', s, re.S
    ):
        out[m.group(1)] = set(re.findall(r'\("(\w+)"', m.group(2)))
    return out


def _projection_consumed_keys() -> dict[str, set[str]]:
    """按 upsert_<entity> 函数作用域提取 payload.get("...") 键。

    不能取全文件并集:同名字段(如 sortOrder)出现在别的实体 upsert 里,
    会造成「该字段已被消费」的误判。按函数切片,key 用 upsert 后缀的实体名。
    """
    s = _read(SERVER_PROJECTION)
    out: dict[str, set[str]] = {}
    # 找所有顶层 def upsert_xxx 的起止位置
    matches = list(re.finditer(r"^def (upsert_\w+)\(", s, re.M))
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(s)
        body = s[start:end]
        entity = m.group(1)[len("upsert_"):]
        out[entity] = set(re.findall(r'payload\.get\(\s*[\'"]([A-Za-z0-9_]+)[\'"]', body))
    return out


# 客户端 EntitySerializer 实际发出的键(entity_serializer.dart,人工核对)。
CLIENT_EMITTED: dict[str, set[str]] = {
    "transaction": {
        "syncId", "type", "amount", "happenedAt", "note", "excludeFromStats",
        "excludeFromBudget", "currencyCode", "nativeAmount", "ledgerSyncId",
        "categoryName", "categoryKind", "categoryId", "accountName", "accountId",
        "fromAccountName", "fromAccountId", "toAccountName", "toAccountId",
        "tags", "tagIds", "attachments",
    },
    "account": {
        "syncId", "name", "type", "currency", "initialBalance", "sortOrder",
        "creditLimit", "billingDay", "paymentDueDay", "bankName",
        "cardLastFour", "note", "hidden",
    },
    "category": {
        "syncId", "name", "kind", "level", "sortOrder", "icon", "iconType",
        "customIconPath", "communityIconId", "iconCloudFileId",
        "iconCloudSha256", "parentName", "parentSyncId",
    },
    "tag": {"syncId", "name", "color", "sortOrder"},
    "budget": {
        "syncId", "ledgerSyncId", "type", "categoryId", "amount", "period",
        "startDay", "enabled",
    },
    "exchange_rate_override": {
        "syncId", "baseCurrency", "quoteCurrency", "rate", "updatedAt",
    },
    "account_adjustment": {
        "syncId", "accountId", "accountName", "amount", "balanceBefore",
        "balanceAfter", "happenedAt", "ledgerSyncId", "note",
    },
}

# 服务端在 merge/apply 之外**有意**不消费、由其它路径处理的键。
# 每条都必须写理由,否则测试失败(防止把真实缺陷注掉)。
SERVER_INTENTIONALLY_IGNORED: dict[str, set[str]] = {
    # ledgerSyncId 是对端 apply 的**路由提示**(找本地 ledger),服务端
    # materialize 时用外层 ledger_id 通道,不消费 payload 内该键。
    "transaction": {"ledgerSyncId"},
    "budget": {"ledgerSyncId"},
    "account_adjustment": {"ledgerSyncId"},
    # communityIconId 是 mobile 端的社区图标 id,云端 projection 没有该列;
    # web 端不展示,合并由 mobile 自己完成。属产品决定。
    "category": {"communityIconId"},
    # ADVERSE FINDING(medium,静默丢数据):account.sortOrder / tag.sortOrder
    # 是客户端**无条件发送**的字段,但云端 projection 无对应列
    # (src/models.py:871 UserAccountProjection / :992 UserTagProjection 均无
    # sort_order 列),merge spec 也不含该键 → 用户在 mobile 调整的账户/标签
    # 排序偏好不跨设备、不跨端。豁免是「已知产品缺口」而非「正确」;
    # 钉子测试见 test_account/tag_sort_order_is_silently_dropped_by_projection。
    "account": {"sortOrder"},
    "tag": {"sortOrder"},
}


# CLIENT_EMITTED 的实体名 → projection upsert 函数名后缀的映射。
ENTITY_TO_UPSERT = {
    "transaction": "tx",
    "account": "account",
    "category": "category",
    "tag": "tag",
    "budget": "budget",
    "exchange_rate_override": "exchange_rate_override",
    "account_adjustment": "account_adjustment",
}


def test_client_emitted_keys_are_all_consumed_or_whitelisted() -> None:
    """客户端发出的每个键,要么被服务端消费,要么在显式豁免表里。"""
    spec_keys = _merge_spec_keys()
    projection_keys = _projection_consumed_keys()
    problems: list[str] = []
    for entity, keys in CLIENT_EMITTED.items():
        allowed = spec_keys.get(entity, set())
        allowed |= projection_keys.get(ENTITY_TO_UPSERT[entity], set())
        ignored = SERVER_INTENTIONALLY_IGNORED.get(entity, set())
        for key in sorted(keys - allowed - ignored):
            problems.append(f"{entity}.{key}")
    assert not problems, (
        "客户端发出但服务端不消费(静默丢失路径): " + ", ".join(problems)
    )


def test_account_sort_order_is_silently_dropped_by_projection() -> None:
    """ADVERSE:account.sortOrder 是静默丢失路径(钉子测试,非红线)。

    客户端 serializeAccount 无条件发 sortOrder;服务端 ReadAccountProjection
    无 sort_order 列,merge spec 也不含该键 → 排序偏好不跨设备。
    此断言把现状钉住:一旦服务端补列/客户端停发,此测试失败提醒同步更新
    豁免表与文档。
    """
    spec_keys = _merge_spec_keys()
    consumed = spec_keys["account"] | _projection_consumed_keys().get("account", set())
    assert "sortOrder" not in consumed, (
        "服务端开始消费 account.sortOrder —— 请更新 CLIENT_EMITTED 豁免与文档"
    )


def test_tag_sort_order_is_silently_dropped_by_projection() -> None:
    """ADVERSE:tag.sortOrder 同上(客户端发、服务端无列)。"""
    spec_keys = _merge_spec_keys()
    consumed = spec_keys["tag"] | _projection_consumed_keys().get("tag", set())
    assert "sortOrder" not in consumed, (
        "服务端开始消费 tag.sortOrder —— 请更新豁免与文档"
    )


def test_server_required_transaction_keys_are_all_emitted_by_client() -> None:
    """服务端 transaction merge spec 的键(除 txIndex/actor 外)客户端必须发。

    txIndex 由服务端快照内分配;createdByUserId/updatedByUserId 由服务端
    snapshot_mutator 写入,客户端不发也正确(merge 缺键保留既有值)。
    """
    spec_keys = _merge_spec_keys()["transaction"]
    server_side = {"txIndex", "createdByUserId", "updatedByUserId"}
    required = spec_keys - server_side
    missing = required - CLIENT_EMITTED["transaction"]
    assert not missing, (
        "服务端 merge spec 要求但客户端不发的键(服务端会读到 None): "
        + ", ".join(sorted(missing))
    )


def test_category_parent_sync_id_is_consumed_by_projection() -> None:
    """客户端发的 parentSyncId 必须在 projection 里被消费(共享账本二级分类)。"""
    assert "parentSyncId" in _projection_consumed_keys().get("category", set()), (
        "parentSyncId 未被 projection 消费 —— 二级分类父子关系会退化为按名字反查"
    )


def test_account_hidden_flag_roundtrip_keys() -> None:
    """hidden 标志双侧一致(issue #240)。"""
    spec_keys = _merge_spec_keys()
    assert "hidden" in spec_keys["account"], "merge spec 缺 hidden"
    assert "hidden" in CLIENT_EMITTED["account"], "客户端不发 hidden"
    assert "hidden" in _projection_consumed_keys().get("account", set()), "projection 不消费 hidden"


def test_transaction_bill_flags_roundtrip_keys() -> None:
    """excludeFromStats / excludeFromBudget 双侧一致(D2 账单标记)。"""
    spec_keys = _merge_spec_keys()["transaction"]
    for key in ("excludeFromStats", "excludeFromBudget"):
        assert key in spec_keys, f"merge spec 缺 {key}"
        assert key in CLIENT_EMITTED["transaction"], f"客户端不发 {key}"


def test_native_amount_roundtrip_keys() -> None:
    """v30 交易级多币种两列双侧一致。"""
    spec_keys = _merge_spec_keys()["transaction"]
    for key in ("currencyCode", "nativeAmount"):
        assert key in spec_keys, f"merge spec 缺 {key}"
        assert key in CLIENT_EMITTED["transaction"], f"客户端不发 {key}"
