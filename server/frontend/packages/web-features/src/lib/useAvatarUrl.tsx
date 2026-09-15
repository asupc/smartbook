import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'

import { API_BASE, authedGetBlob } from '@smartbook/api-client'

/**
 * 头像 fetch+blob 模式(S5 配套)—— 服务端给 `GET /profile/avatar/{user_id}`
 * 加了 get_current_user 鉴权后,`<img src="/api/v1/profile/avatar/...">` 这种
 * 直连(无法带 Authorization 头)一律 401。改为:
 *
 *   authedGetBlob(带 Bearer + 401 单飞 refresh 重放) → Blob → objectURL → img
 *
 * - `v`(cache-bust)语义保留:server 在 avatar_url 里已带 `?v=N`,调用方
 *   还可显式传 version 覆盖;v 进缓存 key —— 版本号 bump 即取新图。HTTP 层
 *   是 no-store,浏览器缓存不参与,v 的作用完全落在 blob 缓存 key 上。
 * - 模块级 session 缓存(`path(含 v) → objectURL`)+ inflight 去重:同一
 *   头像多处展示(行 chip / 详情 / 下拉)只发一次请求。objectURL 由缓存
 *   持有到会话结束,组件卸载不 revoke(头像小、按 user×version 有界)。
 * - 任何失败(401/404/网络)→ null,调用方渲染既有的首字母占位兜底。
 * - token 经 AvatarTokenContext 注入(AppShell 挂一次),web-features 内部
 *   的展示组件(TransactionRow / AdminUsersPanel)不必逐层 threading token。
 */
export const AvatarTokenContext = createContext<string | null>(null)

export function AvatarTokenProvider({
  token,
  children,
}: {
  token: string | null
  children: ReactNode
}) {
  return <AvatarTokenContext.Provider value={token}>{children}</AvatarTokenContext.Provider>
}

/** avatar_url(相对 / 绝对均可)→ authedGetBlob 要的 API 相对路径;version
 *  非 null 时替换/追加 `v` 参数。无头像 / 无法解析 → null。 */
export function normalizeAvatarPath(
  avatarUrl: string | null | undefined,
  version?: number | null,
): string | null {
  const raw = `${avatarUrl || ''}`.trim()
  if (!raw) return null
  let path = raw
  if (/^https?:\/\//i.test(raw)) {
    try {
      const u = new URL(raw)
      path = `${u.pathname}${u.search}`
    } catch {
      return null
    }
  } else if (!raw.startsWith('/')) {
    // 非 http(s) 绝对地址、也非根相对路径(data:/blob: 等)—— 不走鉴权拉取
    return null
  }
  // strip API_BASE 前缀(http.ts 会再拼回去):/api/v1/profile/avatar/x → /profile/avatar/x
  if (API_BASE) {
    const base = API_BASE.replace(/\/+$/, '')
    if (base && path.startsWith(`${base}/`)) {
      path = path.slice(base.length)
    }
  }
  if (version != null) {
    path = /[?&]v=\d+/.test(path)
      ? path.replace(/([?&])v=\d+/, `$1v=${version}`)
      : `${path}${path.includes('?') ? '&' : '?'}v=${version}`
  }
  return path
}

/** path(含 v) → objectURL;'' = 已知失败(本会话内不再重试,防 401 风暴)。 */
const objectUrlCache = new Map<string, string>()
const inflightFetches = new Map<string, Promise<string | null>>()

async function fetchAvatarObjectUrl(token: string, path: string): Promise<string | null> {
  const hit = objectUrlCache.get(path)
  if (hit !== undefined) return hit || null
  const pending = inflightFetches.get(path)
  if (pending) return pending
  const task = (async () => {
    let url: string | null = null
    try {
      const blob = await authedGetBlob(path, token)
      url = URL.createObjectURL(blob)
    } catch {
      url = null
    }
    objectUrlCache.set(path, url ?? '')
    inflightFetches.delete(path)
    return url
  })()
  inflightFetches.set(path, task)
  return task
}

export function useAvatarUrl(
  avatarUrl?: string | null,
  version?: number | null,
): string | null {
  const token = useContext(AvatarTokenContext)
  const path = normalizeAvatarPath(avatarUrl, version)
  const [url, setUrl] = useState<string | null>(() =>
    path ? objectUrlCache.get(path) ?? null : null,
  )

  useEffect(() => {
    if (!path || !token) {
      setUrl(null)
      return
    }
    const cached = objectUrlCache.get(path)
    if (cached !== undefined) {
      setUrl(cached || null)
      return
    }
    let cancelled = false
    void fetchAvatarObjectUrl(token, path).then((next) => {
      if (!cancelled) setUrl(next)
    })
    return () => {
      cancelled = true
    }
  }, [path, token])

  return path ? url : null
}
