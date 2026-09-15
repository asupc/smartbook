import asyncio
import json
import logging

from fastapi import APIRouter, Query, WebSocket
from sqlalchemy import select

from ..database import SessionLocal
from ..metrics import metrics
from ..models import User
from ..security import SCOPE_APP_WRITE, SCOPE_WEB_WRITE, decode_token

logger = logging.getLogger(__name__)

router = APIRouter()

# W7:连接建立后等首条 auth 消息的超时 —— 超时未认证直接关,不让(已 accept
# 但未注册的)连接无限期挂着。10s 足够覆盖慢网络下的 TLS + 首帧往返。
AUTH_TIMEOUT_SECONDS = 10.0


def _validate_token(token: str) -> str | None:
    """校验 access token 与写 scope,返回 user_id;无效返回 None。"""
    if not token:
        return None
    try:
        payload = decode_token(token)
    except Exception:
        return None
    if payload.get("type") != "access":
        return None
    scopes = payload.get("scopes", [])
    if not isinstance(scopes, list):
        return None
    normalized = {str(scope) for scope in scopes if isinstance(scope, str)}
    if SCOPE_APP_WRITE not in normalized and SCOPE_WEB_WRITE not in normalized:
        return None
    user_id = payload.get("sub")
    if not user_id:
        return None
    return str(user_id)


def _user_exists(user_id: str) -> bool:
    db = SessionLocal()
    try:
        user = db.scalar(select(User).where(User.id == user_id))
        return user is not None
    finally:
        db.close()


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str = Query(default="")) -> None:
    # W7(2026-09):token 不再只走 URL query —— query 会进反代 / 服务端 access
    # log,与「token 不进日志」的安全口径矛盾。新鉴权流程(web 客户端):
    #   1. 客户端裸连 /ws(不带任何凭证);
    #   2. 连上后**第一条消息**发 {"type":"auth","token":"<jwt>"};
    #   3. 认证通过回 {"type":"auth_ok"},之后行为与旧版完全一致(ping/pong
    #      心跳 + 广播推送)。认证前的任何其它消息 / 超时(10s)未认证 →
    #      close(1008)。认证前连接不注册进 ws_manager,收不到任何广播。
    # 兼容:query token 形态保留 —— 既有 mobile 客户端(Flutter
    # SmartBookCloudRealtimeClient,queryParameters: {'token': ...})无法与
    # 本次改动同步发版,砍掉会直接断 App 的实时同步。
    used_first_message_auth = False
    user_id: str | None = None
    if token:
        user_id = _validate_token(token)
        if user_id is None or not _user_exists(user_id):
            await websocket.close(code=1008)
            return

    manager = websocket.app.state.ws_manager

    if user_id is None:
        used_first_message_auth = True
        await websocket.accept()
        try:
            raw = await asyncio.wait_for(
                websocket.receive_text(), timeout=AUTH_TIMEOUT_SECONDS
            )
        except asyncio.TimeoutError:
            await websocket.close(code=1008)
            return
        except Exception:
            # 客户端在认证前断开(WebSocketDisconnect 等)—— 直接结束。
            return
        try:
            msg = json.loads(raw)
        except ValueError:
            await websocket.close(code=1008)
            return
        if not isinstance(msg, dict) or msg.get("type") != "auth":
            # 认证前只接受 auth 帧,其余(ping / 数据)一律拒绝。
            await websocket.close(code=1008)
            return
        auth_token = msg.get("token")
        user_id = _validate_token(auth_token if isinstance(auth_token, str) else "")
        if user_id is None or not _user_exists(user_id):
            await websocket.close(code=1008)
            return
        # 注册进 manager。这里不能走 manager.connect():它内部会再 accept 一次,
        # starlette 状态机对已 accept 连接直接抛 RuntimeError —— 所以手动挂连接
        # 表 + 刷 gauge,效果与 connect() 的注册部分一致(仅少一次 accept)。
        manager._connections[user_id].add(websocket)
        metrics.set_gauge("smartbook_online_ws_users", float(len(manager._connections)))
        try:
            await websocket.send_text('{"type":"auth_ok"}')
        except Exception:
            manager.disconnect(user_id, websocket)
            return
    else:
        # 兼容路径(mobile query token):manager.connect 负责 accept。
        await manager.connect(user_id, websocket)

    logger.info("ws.connect user=%s", user_id)
    try:
        while True:
            msg = await websocket.receive_text()
            # Support client-initiated heartbeat: the client sends {"type":"ping"}
            # every ~25s and waits for a pong. If the socket is silently broken,
            # the pong won't arrive and the client's no-frames timer forces a
            # reconnect. Tolerate malformed payloads silently.
            if msg and '"ping"' in msg:
                try:
                    await websocket.send_text('{"type":"pong"}')
                except Exception:
                    break
    except Exception:
        pass
    finally:
        manager.disconnect(user_id, websocket)
        logger.info("ws.disconnect user=%s", user_id)
