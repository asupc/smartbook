"""POST /api/v1/ai/parse-tx-image — B2 截图记账。

流程(详见 .docs/web-cmdk-ai-paste-screenshot.md):
1. multipart upload image
2. 解析 user.ai_config_json 找 vision provider
3. 取 ledger categories / accounts 作 prompt hint
4. 调 vision LLM → 鲁棒 JSON parse → tx_drafts array
5. **同时缓存 image bytes**(关联 image_id)→ batch save 时取出来转 attachment

错误码(前端按 error_code 显示对应 fallback):
- AI_NO_VISION_PROVIDER (400):用户 mobile 没绑 vision 模型
- AI_IMAGE_TOO_LARGE (413):图 > 5MB
- AI_IMAGE_TYPE_INVALID (400):非 image/*
- AI_PROVIDER_ERROR (502):vision API 调用失败
- AI_PARSE_FAILED (422):LLM 输出无法 parse 为 JSON,重试仍失败
"""
from __future__ import annotations

import base64
import logging
import re
import time
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from ...database import get_db
from ...deps import get_current_user, require_any_scopes
from ...models import (
    Ledger,
    User,
    UserAccountProjection,
    UserCategoryProjection,
    UserProfile,
)
from ...security import SCOPE_APP_WRITE, SCOPE_WEB_WRITE
from ...services.ai import (
    ChatProviderConfig,
    ChatProviderError,
    JsonParseFailedError,
    NoVisionProviderError,
    build_parse_tx_image_messages,
    call_chat_json,
    get_user_custom_prompt,
    resolve_vision_provider,
)
from ...services.ai.analysis_log import token_count, write_ai_analysis_log
from ...services.ai.image_cache import store_image

logger = logging.getLogger(__name__)
router = APIRouter()


class SchemaInvalidError(ValueError):
    """LLM 输出 JSON 但不符合 tx_drafts schema(典型:返了顶层 array)。"""

_PARSE_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_WRITE)

_MAX_IMAGE_BYTES = 5 * 1024 * 1024  # 5MB
_ALLOWED_MIMES = {"image/jpeg", "image/png", "image/webp", "image/gif"}


@router.post("/parse-tx-image")
async def parse_tx_image(
    request: Request,
    image: UploadFile = File(...),
    ledger_id: str | None = Form(default=None),
    locale: str = Form(default="zh"),
    _scopes: set[str] = Depends(_PARSE_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """同步返回 `{tx_drafts: [...], image_id: "..."}`,前端渲染 confirm UI。"""

    # 1. 校验 mime + size
    mime = (image.content_type or "").lower()
    if mime not in _ALLOWED_MIMES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_IMAGE_TYPE_INVALID",
                "message": f"unsupported image type: {mime!r}; allowed: {sorted(_ALLOWED_MIMES)}",
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

    # 2. 解析 vision provider
    profile = db.scalar(select(UserProfile).where(UserProfile.user_id == current_user.id))
    try:
        vision_cfg = resolve_vision_provider(current_user, profile)
    except NoVisionProviderError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_NO_VISION_PROVIDER", "message": str(exc)},
        )

    # 3. 取 ledger 上下文(categories + accounts 给 LLM 选)
    # 「父类有子分类」的父类不喂给 LLM(产品规则:tx 不能直接落到这种父类)
    cats, accts, ledger_currency = _load_ledger_context(db, ledger_id, current_user.id)
    logger.debug(
        "ai.parse_tx_image ledger_context cats=%d accts=%d base=%s sample_cats=%s",
        len(cats), len(accts), ledger_currency, cats[:10],
    )

    # 4. 拼 prompt + 调 vision LLM
    custom = get_user_custom_prompt(profile, key="parseTxImagePrompt")
    image_data_url = f"data:{mime};base64,{base64.b64encode(image_bytes).decode()}"
    messages = build_parse_tx_image_messages(
        categories=cats,
        accounts=accts,
        ledger_currency=ledger_currency,
        now=datetime.now(timezone.utc),
        locale=locale,
        image_data_url=image_data_url,
        custom_prompt_template=custom,
    )

    logger.info(
        "ai.parse_tx_image user=%s lang=%s image_size=%d provider=%s",
        current_user.id, locale, len(image_bytes), vision_cfg.provider_id,
    )

    # 调 LLM + normalize + 落一行 AI 分析日志(_parse_and_log 内部承担;
    # 失败已按原错误码 raise,行为与改造前一致)
    drafts = await _parse_and_log(
        user_id=current_user.id,
        entry_type="parse_tx_image",
        request=request,
        cfg=vision_cfg,
        messages=messages,
        ledger_id=ledger_id,
        input_text=f"image(mime={mime}, size={len(image_bytes)} bytes)",
    )

    # 5. 缓存 image bytes(就算识别空也缓存,user 可能想保留作附件)
    image_id = store_image(
        image_bytes=image_bytes, mime_type=mime, user_id=current_user.id,
    )

    return {"tx_drafts": drafts, "image_id": image_id}


# ──────────────────────────────────────────────────────────────────────


async def _parse_and_log(
    *,
    user_id: str,
    entry_type: str,
    request: Request,
    cfg: ChatProviderConfig,
    messages: list[dict[str, object]],
    ledger_id: str | None = None,
    input_text: str | None = None,
) -> list[dict]:
    """B2 / B3 共用的「调 LLM → normalize → 落一行 AI 分析日志」。

    成功返 drafts;失败按原错误码 raise HTTPException(422 AI_PARSE_FAILED /
    502 AI_PROVIDER_ERROR / 422 AI_SCHEMA_INVALID),与改造前的行为一致。
    finally 里写日志(成功返 drafts 时 status='ok' + 模型返回全文;错误路径
    已把 status 置 'error' 并附 raw 输出 / 错误信息) —— 写日志失败静默
    (analysis_log.write_ai_analysis_log 内部吞),不影响响应。
    """
    import json as _json

    t0 = time.perf_counter()
    log_status = "ok"  # 不用 `status` 变量名 — 会遮蔽 import 的 fastapi status 模块
    output_text: str | None = None
    error_message: str | None = None
    usage: dict | None = None
    result: object = None
    try:
        try:
            resp = await call_chat_json(config=cfg, messages=messages)
            result = resp.parsed
            usage = resp.usage
        except JsonParseFailedError as exc:
            log_status = "error"
            output_text = exc.raw_content[:10_000]
            error_message = str(exc)[:500]
            # 把 LLM 原始 raw 输出回给前端,user 能看到 LLM 实际吐了什么 —
            # 调试 prompt / 切换 provider 时关键。raw 限长 1000 char 防 payload 过大。
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail={
                    "error_code": "AI_PARSE_FAILED",
                    "message": str(exc)[:200],
                    "raw": exc.raw_content[:1000],
                },
            ) from exc
        except ChatProviderError as exc:
            log_status = "error"
            error_message = str(exc)[:500]
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"error_code": "AI_PROVIDER_ERROR", "message": str(exc)[:200]},
            ) from exc

        try:
            drafts = _normalize_drafts(result)
        except SchemaInvalidError as exc:
            # LLM JSON parsing 成功但 schema 不对(比如返了 list 顶层、缺 tx_drafts key)
            raw_dump = _json.dumps(result, ensure_ascii=False)[:1000]
            log_status = "error"
            output_text = raw_dump
            error_message = str(exc)[:500]
            logger.warning(
                "%s schema invalid: %s; raw=%s", entry_type, exc, raw_dump,
            )
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail={
                    "error_code": "AI_SCHEMA_INVALID",
                    "message": str(exc),
                    "raw": raw_dump,
                },
            ) from exc
        output_text = _json.dumps(result, ensure_ascii=False)
        return drafts
    finally:
        write_ai_analysis_log(
            user_id=user_id,
            entry_type=entry_type,
            status=log_status,
            provider_id=cfg.provider_id,
            model=cfg.model,
            ledger_id=ledger_id,
            input_text=input_text,
            output_text=output_text,
            error_message=error_message,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            prompt_tokens=token_count(usage, "prompt_tokens"),
            completion_tokens=token_count(usage, "completion_tokens"),
            total_tokens=token_count(usage, "total_tokens"),
            client_ip=request.client.host if request.client else None,
        )


def _load_ledger_context(
    db: Session, ledger_id: str | None, user_id: str,
) -> tuple[list[str], list[tuple[str, str | None, str | None, str | None, str | None]], str]:
    """取当前账本的 category / account / 本位币(给 LLM hint)。

    没传 ledger_id → 跨账本聚合所有用户可见的(让 LLM 至少有现成名字可选);
    此时本位币取「用户只有一个账本就用它,否则 CNY」—— 草稿的落库账本要等
    用户在前端选,这里只能给 best-effort 上下文。

    账户返回 `(名称, 币种, 类型, 银行名, 卡尾号)`:
    - 币种:多币种记账要让 LLM 能选中外币账户(.docs/multi-currency-ai A3)
    - 类型 / 银行名 / 卡尾号:帮助 LLM 判断截图中的「招商银行(1234)」该
      归属哪个账户(见 prompts._format_accounts_hint)
    """
    fallback_currency = "CNY"
    if ledger_id:
        ledger = db.scalar(
            select(Ledger).where(
                Ledger.external_id == ledger_id, Ledger.user_id == user_id,
            )
        )
        if ledger is None:
            return [], [], fallback_currency
        ledger_int_ids = [ledger.id]
        ledger_currency = (ledger.currency or fallback_currency).strip().upper()
    else:
        all_ledgers = db.scalars(select(Ledger).where(Ledger.user_id == user_id)).all()
        ledger_int_ids = [l.id for l in all_ledgers]
        ledger_currency = (
            (all_ledgers[0].currency or fallback_currency).strip().upper()
            if len(all_ledgers) == 1
            else fallback_currency
        )

    if not ledger_int_ids:
        return [], [], ledger_currency

    # category 是 user-global,按 user_id 拉(跨 ledger 统一)。
    cat_rows = db.scalars(
        select(UserCategoryProjection).where(
            UserCategoryProjection.user_id == user_id
        )
    ).all()
    # 「有子分类的父类」**不能被选作交易分类**(产品规则跟 mobile 一致 —
    # 父类是 grouping,要落到具体子类)。所以喂给 LLM 的候选要排除这些。
    parent_names_with_children: set[str] = set()
    for c in cat_rows:
        if c.parent_name:
            parent_names_with_children.add(c.parent_name)

    selectable_cats: list[str] = []
    for c in cat_rows:
        if not c.name:
            continue
        if c.parent_name:
            # 子分类,可选
            selectable_cats.append(c.name)
        elif c.name not in parent_names_with_children:
            # 父分类无子,可选
            selectable_cats.append(c.name)
        # else: 父分类有子 → 跳过,LLM 看不到它,只看到具体的子分类

    # 账户隐藏(#240):隐藏账户不再作为新交易的记账目标 —— 不喂给 LLM 作候选,
    # 与 mobile 的 AiExtractionContext / 手动选择器口径一致。
    acct_rows = db.scalars(
        select(UserAccountProjection).where(
            UserAccountProjection.user_id == user_id
        )
    ).all()
    accts = sorted(
        {
            (
                a.name,
                (a.currency or "").strip().upper() or None,
                a.account_type,
                a.bank_name,
                a.card_last_four,
            )
            for a in acct_rows
            if a.name and not a.hidden
        },
        key=lambda t: t[0],
    )
    return sorted(set(selectable_cats)), accts, ledger_currency


_ISO_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


def _norm_currency(raw: object) -> str:
    """LLM 给的币种 → ISO 4217 大写码;不合法返 ""(= 跟账本主币种)。

    **server 端基本不做别名映射**(「美元」→USD 之类):server 既没有 App 的 151
    币种表,也没有账本上下文做 `¥` 消歧,统一让 prompt 直出 ISO 更可控。
    App 侧面对本地/口语输入才做宽松解析(.docs/multi-currency-ai §3.2)。

    唯一例外是裸 `$` → USD:实测 LLM 明明识别出「45 美元」却常把字段回成
    `"$"`,而这条映射既不需要币种表也不需要上下文(要区分 AUD/CAD/SGD/HKD 时
    书写惯例都是 `A$`/`C$`/`S$`/`HK$`)。`¥` 仍**不映射** —— CNY 与 JPY 都写裸
    `¥`,猜错是 ~20 倍金额差,宁可退回账本主币种。
    """
    if not isinstance(raw, str):
        return ""
    code = raw.strip().upper()
    if code == "$":
        return "USD"
    return code if _ISO_CURRENCY_RE.match(code) else ""


def _normalize_drafts(result: object) -> list[dict]:
    """**严格** 校验 LLM 输出 schema:必须是 `{"tx_drafts": [...]}`。

    其它结构(顶层 array、单笔 dict、用 `items` / `transactions` 等其它 key)
    →  raise SchemaInvalidError,endpoint 把 raw 错误回给前端,user 能看到根因。
    不在 server 静默兼容 — 兼容会让 prompt 漂移,LLM 永远不会自我修正。
    """
    if not isinstance(result, dict):
        raise SchemaInvalidError(
            f"expected JSON object with `tx_drafts` key, got {type(result).__name__}"
        )
    drafts = result.get("tx_drafts")
    if not isinstance(drafts, list):
        present_keys = list(result.keys())[:5]
        raise SchemaInvalidError(
            f"`tx_drafts` missing or not array; top-level keys present: {present_keys}"
        )
    out: list[dict] = []
    for d in drafts:
        if not isinstance(d, dict):
            continue
        amt = d.get("amount")
        if not isinstance(amt, (int, float)):
            continue
        tx_type = d.get("type", "expense")
        if tx_type not in {"expense", "income", "transfer"}:
            tx_type = "expense"
        out.append({
            "type": tx_type,
            "amount": float(abs(amt)),  # 强制正数
            # 交易级多币种(.docs/multi-currency-ai A4):"" = 跟账本主币种。
            # 非法值降级成 "" 而不是丢弃整笔 —— AI 幻觉出的假币种不该让记账失败。
            "currency": _norm_currency(d.get("currency")),
            "happened_at": d.get("happened_at") or "",
            "category_name": (d.get("category_name") or "").strip(),
            "account_name": (d.get("account_name") or "").strip(),
            "from_account_name": (d.get("from_account_name") or "").strip() or None,
            "to_account_name": (d.get("to_account_name") or "").strip() or None,
            "note": (d.get("note") or "").strip(),
            "tags": [t for t in (d.get("tags") or []) if isinstance(t, str) and t.strip()],
            "confidence": d.get("confidence") if d.get("confidence") in {"high", "medium", "low"} else "medium",
        })
    return out
