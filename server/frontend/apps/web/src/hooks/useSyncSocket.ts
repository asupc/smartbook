import { useEffect, useRef, useState } from 'react'

/**
 * W7:连接状态。比旧的四态多了 authenticating / reconnecting / error:
 *   - idle          未登录(无 token,supervisor 挂起)
 *   - connecting    首次连接中
 *   - authenticating socket 已开,等首条 auth 帧的服务端应答(见下)
 *   - connected     认证通过(收到 auth_ok)
 *   - reconnecting  掉线后退避重连中
 *   - error         被服务端拒绝(close 1008:token 无效 / 认证超时等),
 *                   随后会照常退避重连(token 刷新后可自愈)
 */
export type SyncSocketStatus =
  | 'idle'
  | 'connecting'
  | 'authenticating'
  | 'connected'
  | 'reconnecting'
  | 'error'

export interface UseSyncSocketOptions {
  /** JWT access token. Supervisor pauses while null. */
  token: string | null
  /**
   * Base WebSocket URL builder. W7:URL 不应携带 token(query 会进反代/服务端
   * access log)—— 鉴权走连接后的首条 {"type":"auth"} 消息,token 由
   * useSyncSocket 自己在 onopen 后发送。buildUrl 的 token 参数仅为兼容旧
   * 签名保留,实现应忽略它。
   */
  buildUrl: (token: string) => string
  /** Fires when the server pushes a sync_change or backup_restore event. */
  onEvent?: (payload: unknown) => void
  /**
   * Fires when the supervisor is authenticated (re)connected — caller should
   * pull-drain. W7 起在收到 auth_ok 之后才触发(服务端在认证前不会把连接
   * 注册进广播表,onOpen 早了会漏事件)。
   */
  onOpen?: () => void
  /** Fires when the supervisor loses the socket and starts backing off. */
  onDisconnect?: () => void
}

export interface SyncSocketState {
  status: SyncSocketStatus
}

const HEARTBEAT_INTERVAL_MS = 25_000
const HEARTBEAT_TIMEOUT_MS = 45_000
const BACKOFF_BASE_MS = 500
const BACKOFF_MAX_MS = 30_000

function backoffDelay(attempt: number): number {
  const exp = Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** attempt)
  const jitter = Math.floor(Math.random() * 500)
  return exp + jitter
}

/**
 * Supervised WebSocket connection with exponential-backoff reconnect,
 * application level heartbeat, and visibility/network resumption.
 *
 * W7:鉴权改为**首条消息**——连接 URL 不再带 token;onopen 后立刻发送
 * {"type":"auth","token"},收到 {"type":"auth_ok"} 才算 connected(此前的
 * 事件 / onOpen 都不触发)。服务端在认证前只认 auth 帧,其余消息会被拒;
 * 心跳 ping 也因此只在认证通过后启动。
 */
export function useSyncSocket({
  token,
  buildUrl,
  onEvent,
  onOpen,
  onDisconnect
}: UseSyncSocketOptions): SyncSocketState {
  const [status, setStatus] = useState<SyncSocketStatus>('idle')
  const socketRef = useRef<WebSocket | null>(null)
  const attemptRef = useRef(0)
  const heartbeatIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const heartbeatTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const reconnectTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const destroyedRef = useRef(false)
  /** 最近一次 close 是否为策略拒绝(1008)—— 决定 reconnecting vs error 展示。 */
  const policyRejectionRef = useRef(false)
  const handlersRef = useRef({ onEvent, onOpen, onDisconnect })
  handlersRef.current = { onEvent, onOpen, onDisconnect }

  useEffect(() => {
    destroyedRef.current = false
    if (!token) {
      setStatus('idle')
      return () => {
        destroyedRef.current = true
        teardown()
      }
    }

    function teardown() {
      if (heartbeatIntervalRef.current) {
        clearInterval(heartbeatIntervalRef.current)
        heartbeatIntervalRef.current = null
      }
      if (heartbeatTimeoutRef.current) {
        clearTimeout(heartbeatTimeoutRef.current)
        heartbeatTimeoutRef.current = null
      }
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current)
        reconnectTimeoutRef.current = null
      }
      const socket = socketRef.current
      socketRef.current = null
      if (socket) {
        try {
          socket.close()
        } catch (_) {
          // Socket may already be in closing state — ignore.
        }
      }
    }

    function scheduleReconnect() {
      if (destroyedRef.current) return
      handlersRef.current.onDisconnect?.()
      setStatus(policyRejectionRef.current ? 'error' : 'reconnecting')
      const delay = backoffDelay(attemptRef.current)
      attemptRef.current += 1
      reconnectTimeoutRef.current = setTimeout(() => {
        if (destroyedRef.current) return
        connect()
      }, delay)
    }

    function armHeartbeatTimeout() {
      if (heartbeatTimeoutRef.current) clearTimeout(heartbeatTimeoutRef.current)
      heartbeatTimeoutRef.current = setTimeout(() => {
        // No frames received in time — assume dead socket, force reconnect.
        const socket = socketRef.current
        socketRef.current = null
        if (socket) {
          try {
            socket.close()
          } catch (_) {
            // ignore
          }
        }
        scheduleReconnect()
      }, HEARTBEAT_TIMEOUT_MS)
    }

    function startHeartbeat(socket: WebSocket) {
      heartbeatIntervalRef.current = setInterval(() => {
        if (socket.readyState !== WebSocket.OPEN) return
        try {
          socket.send(JSON.stringify({ type: 'ping' }))
        } catch (_) {
          // will trigger onclose
        }
      }, HEARTBEAT_INTERVAL_MS)
    }

    function connect() {
      if (destroyedRef.current) return
      setStatus('connecting')
      let socket: WebSocket
      try {
        socket = new WebSocket(buildUrl(token!))
      } catch (_) {
        scheduleReconnect()
        return
      }
      socketRef.current = socket

      socket.onopen = () => {
        if (destroyedRef.current) return
        attemptRef.current = 0
        // W7:首条消息鉴权 —— URL 不带 token,onopen 后立刻发 auth 帧。
        // 在此之前不置 connected、不启动心跳、不触发 onOpen(服务端认证前
        // 会拒绝 ping,也不广播事件给未认证连接)。
        setStatus('authenticating')
        try {
          socket.send(JSON.stringify({ type: 'auth', token: token! }))
        } catch (_) {
          // send 失败会伴随 onclose,交给重连逻辑。
          return
        }
        armHeartbeatTimeout()
      }

      socket.onmessage = (event) => {
        armHeartbeatTimeout()
        let payload: unknown = null
        try {
          payload = JSON.parse(event.data)
        } catch (_) {
          return
        }
        if (payload && typeof payload === 'object') {
          const type = (payload as { type?: unknown }).type
          if (type === 'pong') return
          if (type === 'auth_ok') {
            // 认证通过:现在才算 connected —— 注册 onOpen(drainPull)与心跳。
            if (socketRef.current === socket && !heartbeatIntervalRef.current) {
              setStatus('connected')
              handlersRef.current.onOpen?.()
              startHeartbeat(socket)
            }
            return
          }
        }
        handlersRef.current.onEvent?.(payload)
      }

      socket.onerror = () => {
        // onclose will follow; let that drive the backoff.
      }

      socket.onclose = (event) => {
        if (destroyedRef.current) return
        if (heartbeatIntervalRef.current) {
          clearInterval(heartbeatIntervalRef.current)
          heartbeatIntervalRef.current = null
        }
        if (heartbeatTimeoutRef.current) {
          clearTimeout(heartbeatTimeoutRef.current)
          heartbeatTimeoutRef.current = null
        }
        socketRef.current = null
        // 1008 = policy violation:auth 帧无效 / 认证前发别的消息 / 认证超时。
        policyRejectionRef.current = event.code === 1008
        scheduleReconnect()
      }
    }

    function handleOnline() {
      if (destroyedRef.current) return
      if (socketRef.current?.readyState !== WebSocket.OPEN) {
        if (reconnectTimeoutRef.current) clearTimeout(reconnectTimeoutRef.current)
        attemptRef.current = 0
        connect()
      }
    }
    function handleVisibility() {
      if (typeof document === 'undefined') return
      if (document.hidden) return
      handleOnline()
      // If the socket is up, also trigger a pull to fill gaps created while tab was hidden.
      if (socketRef.current?.readyState === WebSocket.OPEN) {
        handlersRef.current.onOpen?.()
      }
    }

    window.addEventListener('online', handleOnline)
    document.addEventListener('visibilitychange', handleVisibility)
    connect()

    return () => {
      destroyedRef.current = true
      window.removeEventListener('online', handleOnline)
      document.removeEventListener('visibilitychange', handleVisibility)
      teardown()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token, buildUrl])

  return { status }
}
