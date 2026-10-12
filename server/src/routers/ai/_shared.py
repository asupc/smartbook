"""AI 路由组共享 helper。

按 CLAUDE.md 的路由组织约定:跨 endpoint 的共享逻辑放 `_shared.py`,不要
在各 entity 文件里各写一份。

目前只有一类内容:**SSRF host 策略错误 → HTTP 响应的归一**。

为什么必须集中:

- 2026-10-11 对抗缺陷 2(BLOCKER)的根因就是「同一个策略错误在不同入口被
  归一成不同的东西」——relay 做了 preflight 归一成 400,而
  `/ai/parse-tx-image` / `/ai/parse-tx-text` / `/ai/ask` 只捕获
  `ChatProviderError`,host 策略错误穿透到全局兜底 → 500 INTERNAL_ERROR。
  客户端把 500 当 transient 无限重试,而这是**配置类错误**,重试永远失败。

- `AiHostNotAllowedError` 现已继承 `ChatProviderError`(见
  `services/ai/outbound_policy.py`),因此**所有**捕获基类的地方都不会再
  500;但「400 + 明确 error_code」仍必须由每个入口显式给出 —— 基类只保证
  不 500,不保证语义正确。
"""
from __future__ import annotations

from fastapi import HTTPException, status

from ...services.ai.outbound_policy import AiHostNotAllowedError

__all__ = [
    "HOST_NOT_ALLOWED_STATUS",
    "host_not_allowed_http",
]

# 配置类错误 → 400(不是 502 transient,客户端不该重试)。
HOST_NOT_ALLOWED_STATUS = status.HTTP_400_BAD_REQUEST


def host_not_allowed_http(exc: AiHostNotAllowedError) -> HTTPException:
    """SSRF host 策略拒绝 → 400 `AI_PROVIDER_HOST_NOT_ALLOWED`。"""
    return HTTPException(
        status_code=HOST_NOT_ALLOWED_STATUS,
        detail={
            "error_code": "AI_PROVIDER_HOST_NOT_ALLOWED",
            "message": str(exc)[:200],
        },
    )
