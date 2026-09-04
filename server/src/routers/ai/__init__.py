"""AI 子路由聚合。

- A1: /ask — 文档 Q&A,见 .docs/web-cmdk-ai-doc-search.md
- B2: /parse-tx-image — 截图记账,见 .docs/web-cmdk-ai-paste-screenshot.md
- B3: /parse-tx-text — 文字记账,见 .docs/web-cmdk-ai-paste-text.md
- /logs — AI 分析调用历史查询(用户自己;admin 全局在 routers/admin.py)
"""
from fastapi import APIRouter

from . import ask, logs, parse_tx_image, parse_tx_text, test_provider

router = APIRouter()
router.include_router(ask.router)
router.include_router(parse_tx_image.router)
router.include_router(parse_tx_text.router)
router.include_router(test_provider.router)
router.include_router(logs.router)

__all__ = ["router"]
