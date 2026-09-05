"""账单唯一标识去重 —— /ai/relay 在调用 LLM **之前**的重复识别拦截。

App 端提取 prompt 强制要求 LLM 返回账单唯一信息(`external_id`:订单号 /
交易号 / 流水号,BillInfo 第 14 字段)。本模块把中转响应里的这些标识按用户
收割入库;后续识别请求的文本若已包含某个已知标识,即判定为同一笔账单:

- 服务端记录重复(ai_analysis_logs.dedup_hit='duplicate_identifier'
  + 标识行 hit_count+1);
- **不调用 LLM**,返回 duplicate 响应(空 content);
- App 端收到 duplicate 后走现有 duplicateCount 通道:不记账、不进待确认、
  不发通知。

匹配是"归一化子串包含":输入与标识都只保留字母数字并小写,因此
「订单号:2026 0905-1234」能命中已存标识 `202609051234`。标识最短 8 位,
避免把金额/日期等短数字误当订单号。TTL 只为控制表体积(订单号本身全局
唯一),不代表"过期后允许重复入账"的产品语义。
"""
from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from ...config import get_settings
from ...models import AIBillIdentifier, User
from .provider_client import _try_parse_json

logger = logging.getLogger(__name__)

# 归一化后的字段名(去下划线/连字符、小写)。中文字段名原样保留。
_IDENTIFIER_KEYS = frozenset({
    "externalid",
    "orderid",
    "orderno",
    "ordernumber",
    "ordersn",
    "tradeno",
    "tradesn",
    "transactionid",
    "transno",
    "billid",
    "receiptno",
    "流水号",
    "订单号",
    "订单编号",
    "交易号",
    "交易单号",
    "凭证号",
})

# 标识最短长度:订单/流水号普遍 >= 8 位;短于它的数字更可能是金额/日期,
# 子串匹配误判代价是"漏识别",宁可放过去让正常去重兜底。
_MIN_IDENTIFIER_LEN = 8

# 单次请求最多登记的标识数(多笔账单上限保护)
_MAX_HARVEST_PER_CALL = 10

# 参与匹配的标识缓存上限(单用户;个人自部署规模远达不到)
_MAX_MATCH_SCAN = 2000

_ALNUM_RE = re.compile(r"[^a-z0-9]")


def normalize_text_for_match(text: str) -> str:
    """匹配用文本归一化:小写、仅保留字母数字(空白/标点/全角冒号都会被
    短信排版打散,归一化后子串匹配才稳)。"""
    return _ALNUM_RE.sub("", text.lower())


def normalize_identifier(value: Any) -> str | None:
    """标识值归一化;不足最短长度或不含字母数字 → None。"""
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, int):
        value = str(value)
    if not isinstance(value, str):
        return None
    normalized = _ALNUM_RE.sub("", value.lower())
    if len(normalized) < _MIN_IDENTIFIER_LEN:
        return None
    return normalized


def harvest_identifiers(content: str, *, limit: int = _MAX_HARVEST_PER_CALL) -> list[str]:
    """从 LLM 提取响应(可能是 ```json 包裹/带前后缀)里收割唯一标识。

    任意深度遍历 JSON 结构,凡键名(归一化后)在字段集合里的字符串/整数值
    都算候选。解析失败返回空 —— 收割永远不影响中转主流程。
    """
    parsed = _try_parse_json(content or "")
    if parsed is None:
        return []
    out: list[str] = []
    _walk(parsed, out)
    seen: set[str] = set()
    unique = [i for i in out if not (i in seen or seen.add(i))]
    return unique[:limit]


def _walk(node: Any, out: list[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            normalized_key = re.sub(r"[^a-z0-9\u4e00-\u9fff]", "", str(key).lower())
            if normalized_key in _IDENTIFIER_KEYS:
                ident = normalize_identifier(value)
                if ident:
                    out.append(ident)
            _walk(value, out)
    elif isinstance(node, list):
        for item in node:
            _walk(item, out)


def find_duplicate_identifier(
    db: Session,
    user: User,
    text: str | None,
    *,
    now: datetime | None = None,
) -> str | None:
    """新请求文本是否包含该用户已识别过的标识;命中返回归一化标识。"""
    if not text:
        return None
    normalized_text = normalize_text_for_match(text)
    if len(normalized_text) < _MIN_IDENTIFIER_LEN:
        return None
    now = now or datetime.now(timezone.utc)
    rows = db.scalars(
        select(AIBillIdentifier.identifier)
        .where(
            AIBillIdentifier.user_id == user.id,
            AIBillIdentifier.expires_at > now,
        )
        .order_by(AIBillIdentifier.id.desc())
        .limit(_MAX_MATCH_SCAN)
    ).all()
    if not rows:
        return None
    # 长标识优先:更具体,减少短标识误命中面
    for identifier in sorted(rows, key=len, reverse=True):
        if identifier in normalized_text:
            return identifier
    return None


def register_identifiers(
    db: Session,
    user: User,
    identifiers: list[str],
    *,
    source: str,
    now: datetime | None = None,
) -> None:
    """登记一次成功识别里出现的标识(幂等:已存在只刷新 last_seen_at)。
    提交由本函数负责;失败只打日志,不影响中转响应。"""
    if not identifiers:
        return
    now = now or datetime.now(timezone.utc)
    ttl_days = get_settings().ai_bill_identifier_ttl_days
    expires = now + timedelta(days=ttl_days)
    try:
        # 顺手清过期,控制表体积(有索引,单行 DELETE 很便宜)
        db.execute(delete(AIBillIdentifier).where(AIBillIdentifier.expires_at <= now))
        for identifier in identifiers:
            row = db.scalar(
                select(AIBillIdentifier).where(
                    AIBillIdentifier.user_id == user.id,
                    AIBillIdentifier.identifier == identifier,
                )
            )
            if row is None:
                db.add(AIBillIdentifier(
                    user_id=user.id,
                    identifier=identifier,
                    source=source,
                    first_seen_at=now,
                    last_seen_at=now,
                    expires_at=expires,
                ))
            else:
                row.last_seen_at = now
        db.commit()
        logger.info(
            "ai.bill_identifier registered user=%s source=%s count=%d",
            user.id, source, len(identifiers),
        )
    except Exception:
        db.rollback()
        logger.exception("ai.bill_identifier register failed user=%s", user.id)


def mark_duplicate_hit(db: Session, user: User, identifier: str, *, now: datetime | None = None) -> None:
    """命中判重:计数 +1 并刷新最近命中时间。失败静默。"""
    now = now or datetime.now(timezone.utc)
    try:
        row = db.scalar(
            select(AIBillIdentifier).where(
                AIBillIdentifier.user_id == user.id,
                AIBillIdentifier.identifier == identifier,
            )
        )
        if row is not None:
            row.hit_count = (row.hit_count or 0) + 1
            row.last_seen_at = now
            db.commit()
    except Exception:
        db.rollback()
        logger.exception("ai.bill_identifier mark hit failed user=%s", user.id)


def prune_expired(db: Session, *, now: datetime | None = None) -> int:
    """清理过期标识(挂到 main.py 的保留期循环)。返回删除行数。"""
    now = now or datetime.now(timezone.utc)
    result = db.execute(delete(AIBillIdentifier).where(AIBillIdentifier.expires_at <= now))
    db.commit()
    return int(result.rowcount or 0)
