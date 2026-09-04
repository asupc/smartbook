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
                  className="odd:bg-muted/20"
                >
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <span
                        className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-base"
                        style={{ background: `${color}20` }}
                      >
                        {glyph}
                      </span>
                      <div className="min-w-0">
                        <div className="truncate text-sm font-medium">
                          {row.name || (row.device_model || row.platform || t('ops.device.unknownName'))}
                        </div>
                        <Badge
                          variant={row.is_online ? 'default' : 'secondary'}
                          className="mt-0.5 shrink-0 text-[10px]"
                        >
                          {row.is_online ? t('ops.devices.online') : t('ops.devices.offline')}
                        </Badge>
                      </div>
                    </div>
                  </TableCell>
                  <TableCell className="max-w-[180px]">
                    <div className="truncate text-xs">{row.user_email || row.user_id}</div>
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-xs">
                    {row.platform || '-'}
                    {row.app_version ? <span className="ml-1 text-muted-foreground">v{row.app_version}</span> : null}
                  </TableCell>
                  <TableCell className="max-w-[160px]">
                    <div className="truncate text-xs">{row.device_model || '-'}</div>
                  </TableCell>
                  <TableCell className="max-w-[120px]">
                    <div className="truncate text-xs">{row.os_version || '-'}</div>
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-xs">
                    <span title={formatIsoDateTime(row.last_seen_at)}>{timeAgo(row.last_seen_at)}</span>
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-xs">
                    <span title={formatIsoDateTime(row.created_at)}>{timeAgo(row.created_at)}</span>
                  </TableCell>
                  <TableCell className="font-mono text-[10px]">{row.last_ip || '-'}</TableCell>
                  <TableCell>
                    <Badge variant="secondary" className="text-[10px]">
                      {t('ops.devices.sessionCount', { count: row.session_count })}
                    </Badge>
                  </TableCell>
                  <TableCell className="max-w-[150px]">
                    <div className="truncate font-mono text-[10px] text-muted-foreground" title={row.id}>
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
