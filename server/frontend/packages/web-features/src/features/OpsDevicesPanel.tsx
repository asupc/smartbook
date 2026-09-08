import { useMemo, useState } from 'react'

import {
  Badge,
  Button,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  useT
} from '@smartbook/ui'

import type { AdminDevice } from '@smartbook/api-client'

import { ListTableShell } from '../components/ListTableShell'
import { formatIsoDateTime } from '../format'

// 根据 platform 选一个图标 + 语义色。
function deviceIcon(row: AdminDevice): { glyph: string; color: string } {
  const platform = (row.platform || '').toLowerCase()
  if (platform === 'web') return { glyph: '🌐', color: '#3b82f6' }
  if (platform === 'ios') return { glyph: '📱', color: '#8b5cf6' }
  if (platform === 'android') return { glyph: '🤖', color: '#22c55e' }
  if (platform === 'macos' || platform === 'darwin') return { glyph: '💻', color: '#64748b' }
  if (platform === 'windows') return { glyph: '🪟', color: '#06b6d4' }
  return { glyph: '📟', color: '#94a3b8' }
}

// 相对时间。用闭包形式接受 i18n t() 做 lookup,这样组件切语言时自动跟随。
type TFn = (key: string) => string
function makeTimeAgo(t: TFn) {
  return (iso: string): string => {
    const ts = Date.parse(iso)
    if (!Number.isFinite(ts)) return '-'
    const diffSec = (Date.now() - ts) / 1000
    if (diffSec < 60) return t('time.justNow')
    if (diffSec < 3600) return `${Math.floor(diffSec / 60)}${t('time.minutesAgo')}`
    if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}${t('time.hoursAgo')}`
    if (diffSec < 86400 * 30) return `${Math.floor(diffSec / 86400)}${t('time.daysAgo')}`
    if (diffSec < 86400 * 365) return `${Math.floor(diffSec / 86400 / 30)}${t('time.monthsAgo')}`
    return `${Math.floor(diffSec / 86400 / 365)}${t('time.yearsAgo')}`
  }
}

type OpsDevicesPanelProps = {
  rows: AdminDevice[]
  onReload: () => void
}

type DeviceRow = AdminDevice & {
  session_count: number
}

function _normalizeFingerprintPart(value: string | null): string {
  return (value || '').trim().toLowerCase() || '__empty__'
}

function _deviceFingerprint(row: AdminDevice): string {
  return [
    _normalizeFingerprintPart(row.user_id),
    _normalizeFingerprintPart(row.name),
    _normalizeFingerprintPart(row.platform),
    _normalizeFingerprintPart(row.device_model),
    _normalizeFingerprintPart(row.os_version),
    _normalizeFingerprintPart(row.app_version),
  ].join('|')
}

function _safeTimestamp(value: string): number {
  const ts = Date.parse(value)
  return Number.isFinite(ts) ? ts : 0
}

export function OpsDevicesPanel({ rows, onReload }: OpsDevicesPanelProps) {
  const t = useT()
  const timeAgo = useMemo(() => makeTimeAgo(t), [t])
  const [showAllSessions, setShowAllSessions] = useState(false)

  const dedupedRows = useMemo<DeviceRow[]>(() => {
    const grouped = new Map<string, AdminDevice[]>()
    for (const row of rows) {
      const key = _deviceFingerprint(row)
      const bucket = grouped.get(key)
      if (bucket) {
        bucket.push(row)
      } else {
        grouped.set(key, [row])
      }
    }

    const out: DeviceRow[] = []
    for (const bucket of grouped.values()) {
      bucket.sort((a, b) => _safeTimestamp(b.last_seen_at) - _safeTimestamp(a.last_seen_at))
      const primary = bucket[0]
      out.push({
        ...primary,
        session_count: bucket.length,
      })
    }
    out.sort((a, b) => _safeTimestamp(b.last_seen_at) - _safeTimestamp(a.last_seen_at))
    return out
  }, [rows])

  const visibleRows = useMemo<DeviceRow[]>(
    () => (showAllSessions ? rows.map((row) => ({ ...row, session_count: 1 })) : dedupedRows),
    [showAllSessions, rows, dedupedRows]
  )

  return (
    <ListTableShell
      title={t('ops.devices.title')}
      actions={
        <>
          <Button
            size="sm"
            variant={showAllSessions ? 'outline' : 'default'}
            onClick={() => setShowAllSessions(false)}
          >
            {t('ops.devices.view.deduped')}
          </Button>
          <Button
            size="sm"
            variant={showAllSessions ? 'default' : 'outline'}
            onClick={() => setShowAllSessions(true)}
          >
            {t('ops.devices.view.allSessions')}
          </Button>
          <Button size="sm" variant="outline" onClick={onReload}>
            {t('shell.refresh')}
          </Button>
        </>
      }
    >
      <div className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="bc-table-head">{t('ops.devices.table.device')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.user')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.table.platform')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.model')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.os')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.lastSeen')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.createdAt')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.ip')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.table.sessions')}</TableHead>
              <TableHead className="bc-table-head">{t('ops.devices.id')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {visibleRows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={10} className="py-12 text-center text-sm text-muted-foreground">
                  {t('table.empty')}
                </TableCell>
              </TableRow>
            ) : null}
            {visibleRows.map((row) => {
              const { glyph, color } = deviceIcon(row)
              return (
                <TableRow
                  key={row.id}
                  className="group transition-colors duration-150 odd:bg-muted/[0.12] hover:bg-primary/[0.04] dark:hover:bg-primary/[0.07]"
                >
                  <TableCell>
                    <div className="flex items-center gap-2.5">
                      <span
                        className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-base shadow-2xs"
                        style={{ background: `${color}20` }}
                      >
                        {glyph}
                      </span>
                      <div className="min-w-0">
                        <div className="truncate text-sm font-semibold tracking-tight text-foreground">
                          {row.name || (row.device_model || row.platform || t('ops.device.unknownName'))}
                        </div>
                        <span
                          className={`mt-0.5 inline-flex items-center rounded-md px-1.5 py-0.2 text-[10px] font-semibold border ${
                            row.is_online
                              ? 'border-emerald-500/25 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400'
                              : 'border-slate-500/20 bg-muted/50 text-muted-foreground'
                          }`}
                        >
                          {row.is_online ? t('ops.devices.online') : t('ops.devices.offline')}
                        </span>
                      </div>
                    </div>
                  </TableCell>
                  <TableCell className="max-w-[180px]">
                    <div className="truncate text-xs font-medium text-foreground/90">{row.user_email || row.user_id}</div>
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-xs">
                    <span className="font-medium">{row.platform || '-'}</span>
                    {row.app_version ? <span className="ml-1 font-mono text-muted-foreground">v{row.app_version}</span> : null}
                  </TableCell>
                  <TableCell className="max-w-[160px]">
                    <div className="truncate text-xs text-muted-foreground">{row.device_model || '-'}</div>
                  </TableCell>
                  <TableCell className="max-w-[120px]">
                    <div className="truncate text-xs text-muted-foreground">{row.os_version || '-'}</div>
                  </TableCell>
                  <TableCell className="whitespace-nowrap font-mono tabular-nums text-xs text-muted-foreground">
                    <span title={formatIsoDateTime(row.last_seen_at)}>{timeAgo(row.last_seen_at)}</span>
                  </TableCell>
                  <TableCell className="whitespace-nowrap font-mono tabular-nums text-xs text-muted-foreground">
                    <span title={formatIsoDateTime(row.created_at)}>{timeAgo(row.created_at)}</span>
                  </TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground">
                    {row.last_ip ? (
                      <span className="rounded-md border border-border/60 bg-muted/40 px-1.5 py-0.5">
                        {row.last_ip}
                      </span>
                    ) : '-'}
                  </TableCell>
                  <TableCell>
                    <span className="inline-flex items-center rounded-md border border-border/60 bg-muted/40 px-2 py-0.5 font-mono text-[11px] font-medium text-muted-foreground">
                      {t('ops.devices.sessionCount', { count: row.session_count })}
                    </span>
                  </TableCell>
                  <TableCell className="max-w-[150px]">
                    <div className="truncate font-mono text-xs text-muted-foreground" title={row.id}>
                      {row.id}
                    </div>
                  </TableCell>
                </TableRow>
              )
            })}
          </TableBody>
        </Table>
      </div>
    </ListTableShell>
  )
}
