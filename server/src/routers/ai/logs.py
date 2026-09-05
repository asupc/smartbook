"""AI 分析调用历史的查询 endpoint。

数据来源:服务端各 AI 调用路径完成后写入的 `AIAnalysisLog` 表 ——
/ai/parse-tx-*、/ai/ask、/ai/relay/*(App 中转)各自在调用完成时落行
(App 端直连时代的 `POST /ai/logs` / `POST /ai/logs/image` 自报通道已随
「LLM 经服务端中转」改造删除;写日志统一发生在服务端调用现场)。

- `GET /ai/logs` — 当前用户自己的记录,called_at 倒序,支持 entry_type /
  status 过滤。**列表只返截断预览**(全文字段可能很长,列表带全量会拖页面
  并把内容暴露进响应缓存);全文走详情 endpoint。
- `GET /ai/logs/{id}` — 单条全文,只允许本人,非本人 404。
- `DELETE /ai/logs/{id}` — 手动删除自己的单条记录(日志不设自动保留期,
  永久保留,删除是唯一清理入口;带图记录行删完后顺带删落盘图片)。
- `POST /ai/logs/batch-delete` — 批量删除(Web 多选删除,body `{ids}` ≤200,
  去重);只删属于本人的 id,不存在/他人的跳过(不泄露存在性),返回
  `{"deleted": n}`。

admin 全局查询(任意用户)在 `src/routers/admin.py`:
- `GET /admin/ai-analysis-logs` — 全量列表 + user_id 过滤,带 user_email
- `GET /admin/ai-analysis-logs/{id}` — 任意用户单条全文
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from pathlib import Path

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Query,
    status,
)
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, field_serializer
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ...database import get_db
from ...deps import get_current_user, require_any_scopes
from ...models import AIAnalysisLog, User
from ...security import SCOPE_APP_WRITE, SCOPE_WEB_READ, SCOPE_WEB_WRITE

logger = logging.getLogger(__name__)

router = APIRouter()

_AUTH_SCOPE_DEP = require_any_scopes(
    SCOPE_APP_WRITE, SCOPE_WEB_READ, SCOPE_WEB_WRITE
)

# 列表里的预览截断长度 — 帮用户快速认出"我那次问了什么",又避免列表 payload
# 无谓变大(全文在详情里)。
_PREVIEW_CHARS = 300

# 同时是列表 / admin 列表的合法过滤值 —— 与 ai_analysis_logs.entry_type 写入侧一致
# (写入侧:ask=RAG 问答 / parse_tx_*=记账提取 / chat=App 自由对话 / stt=语音转写)
_ENTRY_TYPE_PATTERN = "^(ask|parse_tx_image|parse_tx_text|chat|stt)$"


def _utc_iso(value: datetime | None) -> str | None:
    """跟 pats.py / mcp_calls.py 同一套 UTC 标记化序列化 — SQLite 读回 naive,
    前端按本地解析会偏。"""
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.isoformat()


def _preview(text: str | None) -> str | None:
    if not text:
        return None
    return text if len(text) <= _PREVIEW_CHARS else text[:_PREVIEW_CHARS - 1] + "…"


class AIAnalysisLogItem(BaseModel):
    id: int
    entry_type: str
    status: str
    provider_id: str | None
    model: str | None
    ledger_id: str | None
    input_preview: str | None
    output_preview: str | None
    error_message: str | None
    duration_ms: int
    prompt_tokens: int | None
    completion_tokens: int | None
    total_tokens: int | None
    client_ip: str | None
    # 非 null = 该行没有真正调用 LLM(识别前命中唯一标识判重跳过)
    dedup_hit: str | None = None
    called_at: datetime

    @field_serializer("called_at")
    def _ser_dt(self, v: datetime | None) -> str | None:
        return _utc_iso(v)


class AIAnalysisLogDetail(BaseModel):
    """单条全文 — input/output 不限长(写入侧已截断到 50k/100k)。

    [has_image] 仅供前端判断是否渲染输入图片;image_path 本身不暴露
    (内部路径无意义且可推测目录结构)。
    """

    id: int
    entry_type: str
    status: str
    provider_id: str | None
    model: str | None
    ledger_id: str | None
    input_text: str | None
    output_text: str | None
    error_message: str | None
    duration_ms: int
    prompt_tokens: int | None
    completion_tokens: int | None
    total_tokens: int | None
    client_ip: str | None
    dedup_hit: str | None = None
    has_image: bool = False
    called_at: datetime

    @field_serializer("called_at")
    def _ser_dt(self, v: datetime | None) -> str | None:
        return _utc_iso(v)


class AIAnalysisLogListResponse(BaseModel):
    total: int
    items: list[AIAnalysisLogItem]


def _to_item(row: AIAnalysisLog) -> AIAnalysisLogItem:
    return AIAnalysisLogItem(
        id=row.id,
        entry_type=row.entry_type,
        status=row.status,
        provider_id=row.provider_id,
        model=row.model,
        ledger_id=row.ledger_id,
        input_preview=_preview(row.input_text),
        output_preview=_preview(row.output_text),
        error_message=row.error_message,
        duration_ms=row.duration_ms,
        prompt_tokens=row.prompt_tokens,
        completion_tokens=row.completion_tokens,
        total_tokens=row.total_tokens,
        client_ip=row.client_ip,
        dedup_hit=row.dedup_hit,
        called_at=row.called_at,
    )


def _to_detail(row: AIAnalysisLog) -> AIAnalysisLogDetail:
    return AIAnalysisLogDetail(
        id=row.id,
        entry_type=row.entry_type,
        status=row.status,
        provider_id=row.provider_id,
        model=row.model,
        ledger_id=row.ledger_id,
        input_text=row.input_text,
        output_text=row.output_text,
        error_message=row.error_message,
        duration_ms=row.duration_ms,
        prompt_tokens=row.prompt_tokens,
        completion_tokens=row.completion_tokens,
        total_tokens=row.total_tokens,
        client_ip=row.client_ip,
        dedup_hit=row.dedup_hit,
        has_image=row.image_path is not None,
        called_at=row.called_at,
    )


def _filter_conditions(
    *, entry_type: str | None, status_: str | None,
) -> list[object]:
    conds: list[object] = []
    if entry_type:
        conds.append(AIAnalysisLog.entry_type == entry_type)
    if status_:
        conds.append(AIAnalysisLog.status == status_)
    return conds


@router.get("/logs", response_model=AIAnalysisLogListResponse)
def list_ai_logs(
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    entry_type: str | None = Query(default=None, pattern=_ENTRY_TYPE_PATTERN),
    status: str | None = Query(default=None, pattern=r"^(ok|error)$"),
    _scopes: set[str] = Depends(_AUTH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AIAnalysisLogListResponse:
    """分页列出当前用户的 AI 分析记录(按 called_at 倒序),支持过滤。"""
    filters = _filter_conditions(entry_type=entry_type, status_=status)
    count_q = select(func.count()).select_from(
        select(AIAnalysisLog.id)
        .where(AIAnalysisLog.user_id == current_user.id)
        .where(*filters)
        .subquery()
    )
    total = int(db.scalar(count_q) or 0)
    rows = db.scalars(
        select(AIAnalysisLog)
        .where(AIAnalysisLog.user_id == current_user.id)
        .where(*filters)
        .order_by(AIAnalysisLog.called_at.desc())
        .limit(limit)
        .offset(offset)
    ).all()
    return AIAnalysisLogListResponse(total=total, items=[_to_item(r) for r in rows])


@router.get("/logs/{log_id}", response_model=AIAnalysisLogDetail)
def get_ai_log_detail(
    log_id: int,
    _scopes: set[str] = Depends(_AUTH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AIAnalysisLogDetail:
    """单条全文(自己的)。非本人或不存在 → 404(不区分,不泄露存在性)。"""
    row = db.get(AIAnalysisLog, log_id)
    if row is None or row.user_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="log not found")
    return _to_detail(row)


@router.get("/logs/{log_id}/image")
def get_ai_log_image(
    log_id: int,
    _scopes: set[str] = Depends(_AUTH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> FileResponse:
    """单条记录的输入图片(App 上报的截图原图)。鉴权同详情:非本人/不存在
    /无图/文件丢失 → 404,均不泄露存在性。"""
    row = db.get(AIAnalysisLog, log_id)
    if row is None or row.user_id != current_user.id or not row.image_path:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="log not found")
    path = Path(row.image_path)
    if not path.exists():
        logger.warning("ai.log.image missing log_id=%s path=%s", log_id, row.image_path)
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="log image missing")
    return FileResponse(
        path=path,
        media_type=row.image_mime or "application/octet-stream",
        filename=path.name,
    )


@router.delete("/logs/{log_id}")
def delete_ai_log(
    log_id: int,
    _scopes: set[str] = Depends(_AUTH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, bool]:
    """手动删除一条自己的 AI 分析记录(日志不设自动保留期,删除是唯一清理入口)。

    非本人或不存在 → 404(同详情,不泄露存在性)。带图记录:行删完后顺带删
    落盘图片(图片不落 DB,不删会永久残留在磁盘);图片删除失败只打日志,
    行照删。
    """
    row = db.get(AIAnalysisLog, log_id)
    if row is None or row.user_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="log not found")
    stale_path = row.image_path
    db.delete(row)
    db.commit()
    if stale_path:
        try:
            Path(stale_path).unlink(missing_ok=True)
        except OSError:
            logger.warning(
                "ai.log.delete failed to remove image log_id=%s path=%s", log_id, stale_path,
            )
    return {"ok": True}


class AIAnalysisLogBatchDeleteRequest(BaseModel):
    ids: list[int] = Field(..., min_length=1, max_length=200)


@router.post("/logs/batch-delete")
def delete_ai_logs_batch(
    payload: AIAnalysisLogBatchDeleteRequest,
    _scopes: set[str] = Depends(_AUTH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, int]:
    """批量删除自己的 AI 分析记录(Web 多选删除)。

    只删属于本人的 id;不存在/他人的跳过(不泄露存在性,同单条语义)。
    带图记录:行删完后顺带删落盘图片,图片删除失败只打日志,行照删。
    返回实际删除条数。
    """
    unique_ids = list(dict.fromkeys(payload.ids))  # 去重,保持传入顺序
    rows = db.scalars(
        select(AIAnalysisLog).where(
            AIAnalysisLog.id.in_(unique_ids),
            AIAnalysisLog.user_id == current_user.id,
        )
    ).all()
    stale_paths = [r.image_path for r in rows if r.image_path]
    for row in rows:
        db.delete(row)
    db.commit()
    for p in stale_paths:
        try:
            Path(p).unlink(missing_ok=True)
        except OSError:
            logger.warning("ai.log.batch_delete failed to remove image path=%s", p)
    return {"deleted": len(rows)}
