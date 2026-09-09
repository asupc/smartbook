import { useCallback, useEffect, useRef, useState } from 'react'
import { RefreshCcw } from 'lucide-react'

import type { AdminLogEntry, AdminLogList } from '@smartbook/api-client'
import { fetchAdminLogs } from '@smartbook/api-client'
import { Button, Input, Drawer, Select } from 'antd'
import { useT } from '@smartbook/ui'

interface Props {
  token: string
  open: boolean
  onOpenChange: (next: boolean) => void
}

const LEVEL_OPTIONS = ['ALL', 'DEBUG', 'INFO', 'WARNING', 'ERROR'] as const

// 日志来源预设;value 是 logger 名称前缀(多个前缀逗号分隔传给 server)。
// label 走 i18n,避免硬编码。
const SOURCE_OPTIONS: Array<{ key: string; value: string }> = [
  { key: 'all', value: '' },
  { key: 'access', value: 'smartbook.access' },
  { key: 'sync', value: 'src.routers.sync' },
  { key: 'write', value: 'src.routers.write' },
  { key: 'read', value: 'src.routers.read' },
  { key: 'profile', value: 'src.routers.profile' },
  { key: 'attachments', value: 'src.routers.attachments' },
  { key: 'auth', value: 'src.routers.auth' },
  { key: 'admin', value: 'src.routers.admin' },
  { key: 'ws', value: 'src.routers.ws,src.websocket_manager' },
  { key: 'uvicorn', value: 'uvicorn' }
]

// 自动刷新可选间隔(秒)。0 = 关闭。
const REFRESH_INTERVALS = [0, 2, 5, 10, 30] as const

const LEVEL_TONE: Record<string, string> = {
  DEBUG: 'text-muted-foreground',
  INFO: 'text-foreground',
  WARNING: 'text-amber-500',
  ERROR: 'text-rose-500',
  CRITICAL: 'text-rose-600 font-bold'
}

function formatTs(iso: string): string {
  try {
    const d = new Date(iso)
    const HH = String(d.getHours()).padStart(2, '0')
    const MM = String(d.getMinutes()).padStart(2, '0')
    const SS = String(d.getSeconds()).padStart(2, '0')
    return `${HH}:${MM}:${SS}`
  } catch {
    return iso
  }
}

// localStorage 里持久化筛选偏好,key 别按用户分桶 —— 日志是管理员工具,
// 同浏览器下无论切哪个 admin 账号都复用同一份偏好。q(搜索关键词)不持久化,
// 它太 ad-hoc,下次打开再输入更符合直觉。
const LS_LEVEL = 'smartbook:web:logsDialog:level'
const LS_SOURCE = 'smartbook:web:logsDialog:source'
const LS_AUTO_REFRESH = 'smartbook:web:logsDialog:autoRefreshSeconds'

function readLsString(key: string, fallback: string): string {
  if (typeof window === 'undefined') return fallback
  try {
    return window.localStorage.getItem(key) || fallback
  } catch {
    return fallback
  }
}
function readLsNumber(key: string, fallback: number): number {
  if (typeof window === 'undefined') return fallback
  try {
    const v = window.localStorage.getItem(key)
    if (v === null) return fallback
    const n = Number(v)
    return Number.isFinite(n) ? n : fallback
  } catch {
    return fallback
  }
}
function writeLs(key: string, value: string): void {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(key, value)
  } catch {
    // localStorage 超配额 / 私密模式 —— 持久化丢了也不致命。
  }
}

export function LogsDialog({ token, open, onOpenChange }: Props) {
  const t = useT()
  // 筛选偏好走 localStorage 持久化:首次进来默认 WARNING(业务拒绝 4xx 也可见,
  // 只看 ERROR 会漏掉「删除账户报 400」这类可预期失败),之后记住用户选择。
  const [level, setLevel] = useState<string>(() => readLsString(LS_LEVEL, 'WARNING'))
  const [sourceKey, setSourceKey] = useState<string>(() => readLsString(LS_SOURCE, 'all'))
  const [q, setQ] = useState('')
  const [autoRefreshSeconds, setAutoRefreshSeconds] = useState<number>(() =>
    readLsNumber(LS_AUTO_REFRESH, 0)
  )

  // 任一 select 改变都同步写 localStorage。
  useEffect(() => writeLs(LS_LEVEL, level), [level])
  useEffect(() => writeLs(LS_SOURCE, sourceKey), [sourceKey])
  useEffect(() => writeLs(LS_AUTO_REFRESH, String(autoRefreshSeconds)), [autoRefreshSeconds])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [data, setData] = useState<AdminLogList | null>(null)
  const scrollRef = useRef<HTMLDivElement | null>(null)
  // 记录用户是否手动滚离底部 —— 在自动刷新场景下,不在底部时不强制滚,避免
  // 打断阅读。
  const stickToBottomRef = useRef<boolean>(true)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const src = SOURCE_OPTIONS.find((s) => s.key === sourceKey)?.value || ''
      const res = await fetchAdminLogs(token, {
        level: level === 'ALL' ? undefined : level,
        q: q.trim() || undefined,
        source: src || undefined,
        limit: 500
      })
      setData(res)
      if (stickToBottomRef.current) {
        setTimeout(() => {
          const el = scrollRef.current
          if (el) el.scrollTop = el.scrollHeight
        }, 0)
      }
    } catch (err) {
      setError((err as Error).message || 'failed')
    } finally {
      setLoading(false)
    }
  }, [token, level, sourceKey, q])

  // 首次打开 + 过滤条件变化时立即拉一次
  useEffect(() => {
    if (!open) return
    void load()
  }, [open, load])

  // 自动刷新:仅在 open 且间隔 > 0 时启用轮询
  useEffect(() => {
    if (!open || autoRefreshSeconds <= 0) return
    const timer = window.setInterval(() => {
      void load()
    }, autoRefreshSeconds * 1000)
    return () => window.clearInterval(timer)
  }, [open, autoRefreshSeconds, load])

  // 追踪用户是否接近底部 —— 决定下次刷新要不要自动滚
  const onScroll = () => {
    const el = scrollRef.current
    if (!el) return
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
    stickToBottomRef.current = nearBottom
  }

  const items: AdminLogEntry[] = data?.items || []

  return (
    <Drawer
      open={open}
      onClose={() => onOpenChange(false)}
      title={
        <span className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 pr-6">
          <span>{t('logs.title')}</span>
          <span className="text-[11px] font-normal text-muted-foreground">
            {data
              ? t('logs.meta')
                  .replace('{count}', String(items.length))
                  .replace('{capacity}', String(data.capacity))
              : ''}
          </span>
        </span>
      }
      width={896}
      footer={null}
      styles={{ body: { display: 'flex', flexDirection: 'column', padding: 0, height: '85vh' } }}
    >
        <div className="flex flex-wrap items-center gap-2 border-b border-border/60 bg-muted/30 px-3 py-2.5 sm:px-5">
          <Select
            size="small"
            style={{ width: 112 }}
            value={level}
            onChange={setLevel}
            options={LEVEL_OPTIONS.map((lv) => ({
              value: lv,
              label: lv === 'ALL' ? t('logs.level.all') : lv,
            }))}
          />
          <Select
            size="small"
            style={{ width: 128 }}
            value={sourceKey}
            onChange={setSourceKey}
            options={SOURCE_OPTIONS.map((opt) => ({
              value: opt.key,
              label: t(`logs.source.${opt.key}`),
            }))}
          />
          <Input
            size="small"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void load()
            }}
            placeholder={t('logs.search.placeholder')}
            style={{ flex: 1, minWidth: 180 }}
          />
          <Select
            size="small"
            style={{ width: 112 }}
            value={String(autoRefreshSeconds)}
            onChange={(v) => setAutoRefreshSeconds(Number(v) || 0)}
            options={REFRESH_INTERVALS.map((sec) => ({
              value: String(sec),
              label: sec === 0
                ? t('logs.autoRefresh.off')
                : t('logs.autoRefresh.on').replace('{sec}', String(sec)),
            }))}
          />
          <Button
            size="small"
            icon={<RefreshCcw className={`h-3.5 w-3.5 ${loading ? 'animate-spin' : ''}`} />}
            onClick={() => void load()}
            disabled={loading}
          >
            {t('logs.refresh')}
          </Button>
        </div>

        <div
          ref={scrollRef}
          onScroll={onScroll}
          className="min-h-0 flex-1 overflow-y-auto bg-background/40 font-mono text-[11px] leading-5"
        >
          {error ? (
            <div className="px-3 py-6 text-center text-rose-500 sm:px-5">{error}</div>
          ) : items.length === 0 ? (
            <div className="px-3 py-10 text-center text-muted-foreground sm:px-5">
              {loading ? t('logs.loading') : t('logs.empty')}
            </div>
          ) : (
            <ul className="divide-y divide-border/40">
              {items.map((it) => (
                <li
                  key={it.seq}
                  className="flex flex-col gap-0.5 px-3 py-1.5 hover:bg-accent/30 sm:flex-row sm:gap-2 sm:px-5"
                >
                  {/* mobile: 上行 metadata(时间 · 级别 · logger),下行 message
                      —— 单列要全宽要 break-all;sm+ 恢复 4 列横排。 */}
                  <div className="flex shrink-0 items-center gap-2 sm:contents">
                    <span className="w-16 shrink-0 text-muted-foreground">{formatTs(it.ts)}</span>
                    <span className={`w-14 shrink-0 font-bold ${LEVEL_TONE[it.level] || 'text-foreground'}`}>
                      {it.level}
                    </span>
                    <span
                      className="min-w-0 flex-1 truncate text-muted-foreground sm:w-48 sm:flex-none"
                      title={it.logger}
                    >
                      {it.logger}
                    </span>
                  </div>
                  <span className="min-w-0 break-all text-foreground sm:flex-1">{it.message}</span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="flex items-center justify-between border-t border-border/60 bg-muted/20 px-3 py-2 text-[11px] text-muted-foreground sm:px-5">
          <span>{t('logs.footer.hint')}</span>
        </div>
    </Drawer>
  )
}
