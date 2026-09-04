"""AI 分析调用历史的查询 endpoint。

数据来源:`services/ai/analysis_log.py` 在每次 AI 分析调用完成后写入的
`AIAnalysisLog` 表(ask / parse-tx-image / parse-tx-text)。

- `POST /ai/logs` — **客户端(App)上报自己发起的 AI 调用**(App 的 AI 记账是
  本地直连 AI 服务商,不经 /ai/* 路由,此前服务端无感)。鉴权只认 token 里的
  user_id,客户端字段只作业务元数据;client_ip 服务端自取。返回 201。
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
    File,
    Form,
    HTTPException,
    Query,
    Request,
    UploadFile,
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
from ...services.ai.analysis_log import (
    write_ai_analysis_log,
    write_ai_analysis_log_with_image,
)

logger = logging.getLogger(__name__)

router = APIRouter()

_AUTH_SCOPE_DEP = require_any_scopes(
    SCOPE_APP_WRITE, SCOPE_WEB_READ, SCOPE_WEB_WRITE
)

# 列表里的预览截断长度 — 帮用户快速认出"我那次问了什么",又避免列表 payload
# 无谓变大(全文在详情里)。
_PREVIEW_CHARS = 300

# 同时是列表 / admin 列表的合法过滤值 —— 与 ai_analysis_logs.entry_type 写入侧一致
_ENTRY_TYPE_PATTERN = "^(ask|parse_tx_image|parse_tx_text)$"

# App 上报截图原图:白名单 + 大小上限与 /ai/parse-tx-image 同口径(5MB)
_ALLOWED_IMAGE_MIMES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
_MAX_IMAGE_BYTES = 5 * 1024 * 1024

# multipart part 没带 content-type 时按文件后缀兜底(App 端 MultipartFile 默认
# 没设置 Content-Type,不能因此把真图拒了)
_SUFFIX_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
}


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
    has_image: bool = False
    called_at: datetime

    @field_serializer("called_at")
    def _ser_dt(self, v: datetime | None) -> str | None:
        return _utc_iso(v)


class AIAnalysisLogListResponse(BaseModel):
    total: int
    items: list[AIAnalysisLogItem]


class AIAnalysisLogCreate(BaseModel):
    """客户端(App)上报自己的 AI 调用。字段上限与 models.AIAnalysisLog 列
    类型对齐(PostgreSQL 对 varchar 长度是 enforce 的)。"""

    entry_type: str = Field(pattern=_ENTRY_TYPE_PATTERN)
    status: str = Field(pattern=r"^(ok|error)$")
    provider_id: str | None = Field(default=None, max_length=64)
    model: str | None = Field(default=None, max_length=128)
    # App 端记账用的本地 ledger id(int);来自服务端 projection 的 external id
    # / 本地 Drift id,两者都可能,原样存,只用于上下文定位。
    ledger_id: str | None = Field(default=None, max_length=128)
    input_text: str | None = None
    output_text: str | None = None
    error_message: str | None = None
    duration_ms: int = Field(default=0, ge=0)
    prompt_tokens: int | None = Field(default=None, ge=0)
    completion_tokens: int | None = Field(default=None, ge=0)
    total_tokens: int | None = Field(default=None, ge=0)


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


@router.post("/logs", status_code=status.HTTP_201_CREATED)
def create_ai_log(
    payload: AIAnalysisLogCreate,
    request: Request,
    _scopes: set[str] = Depends(_AUTH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, bool]:
    """App 上报自己发起的 AI 调用(通知记账 / 对话 / 截图 / 语音等)。

    user_id 取 token 身份,不信客户端;input/output 超长由 write 侧统一截断
    (50k/100k),与 Web 端 /ai/* 写入路径同语义。失败静默在 write 内部,
    上报方无感知 —— 与主流程解耦。
    """
    write_ai_analysis_log(
        user_id=current_user.id,
        entry_type=payload.entry_type,
        status=payload.status,
        provider_id=payload.provider_id,
        model=payload.model,
        ledger_id=payload.ledger_id,
        input_text=payload.input_text,
        output_text=payload.output_text,
        error_message=payload.error_message,
        duration_ms=payload.duration_ms,
        prompt_tokens=payload.prompt_tokens,
        completion_tokens=payload.completion_tokens,
        total_tokens=payload.total_tokens,
        client_ip=request.client.host if request.client else None,
    )
    return {"ok": True}


@router.post("/logs/image", status_code=status.HTTP_201_CREATED)
async def create_ai_log_with_image(
    request: Request,
    entry_type: str = Form(..., pattern=_ENTRY_TYPE_PATTERN),
    status_: str = Form(..., alias="status", pattern=r"^(ok|error)$"),
    provider_id: str | None = Form(default=None, max_length=64),
    model: str | None = Form(default=None, max_length=128),
    ledger_id: str | None = Form(default=None, max_length=128),
    input_text: str | None = Form(default=None),
    output_text: str | None = Form(default=None),
    error_message: str | None = Form(default=None),
    duration_ms: int = Form(default=0, ge=0),
    prompt_tokens: int | None = Form(default=None, ge=0),
    completion_tokens: int | None = Form(default=None, ge=0),
    total_tokens: int | None = Form(default=None, ge=0),
    image: UploadFile = File(...),
    _scopes: set[str] = Depends(_AUTH_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, bool]:
    """App 上报带输入图片的 AI 调用(截图记账原图,multipart 一次上传)。

    与 `POST /logs` 的关系:该端点处理「图像输入」场景,JSON 端点处理纯
    文本/语音;两者共用 write 侧(带图版调用
    [write_ai_analysis_log_with_image])。图片只允许白名单 mime、≤5MB;
    校验失败 → 4xx(客户端静默,不影响记账)。user_id 取 token 身份。
    """
    mime = (image.content_type or "").lower()
    if mime not in _ALLOWED_IMAGE_MIMES:
        suffix = Path(image.filename or "").suffix.lower()
        mime = _SUFFIX_MIME.get(suffix, "")
    if mime not in _ALLOWED_IMAGE_MIMES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_IMAGE_TYPE_INVALID",
                "message": f"unsupported image type: {image.content_type!r}; "
                f"allowed: {sorted(_ALLOWED_IMAGE_MIMES)}",
            },
        )
    image_bytes = await image.read()
    if len(image_bytes) > _MAX_IMAGE_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail={
                "error_code": "AI_IMAGE_TOO_LARGE",
                "message": f"image size {len(image_bytes)} exceeds 5MB",
            },
        )
    write_ai_analysis_log_with_image(
        user_id=current_user.id,
        entry_type=entry_type,
        status=status_,
        provider_id=provider_id,
        model=model,
        ledger_id=ledger_id,
        input_text=input_text,
        output_text=output_text,
        error_message=error_message,
        duration_ms=duration_ms,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
        client_ip=request.client.host if request.client else None,
        image_bytes=image_bytes,
        image_mime=mime,
    )
    return {"ok": True}


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
