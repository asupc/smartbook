import { Badge, Tooltip } from 'antd'
import type { BadgeProps } from 'antd'

import { useT } from '@smartbook/ui'

import { useSyncStatus } from '../context/SyncSocketContext'

/**
 * W7/附录 B5:同步连接状态指示 —— useSyncSocket 的 status 此前没有任何 UI
 * 出口,Web 端完全看不到「同步断开/出错」,用户以为数据在同步其实早停了。
 *
 * 头部小圆点 + tooltip(antd Badge),connected 时安静地绿着;异常态
 * (reconnecting / error)圆点变色并带文字,提示但不打扰。
 */
export function SyncStatusBadge() {
  const status = useSyncStatus()
  const t = useT()

  if (status === 'idle') return null

  const badgeStatus: BadgeProps['status'] =
    status === 'connected'
      ? 'success'
      : status === 'reconnecting'
        ? 'warning'
        : status === 'error'
          ? 'error'
          : 'default'

  const labelKey =
    status === 'connected'
      ? 'shell.syncStatus.connected'
      : status === 'reconnecting'
        ? 'shell.syncStatus.reconnecting'
        : status === 'error'
          ? 'shell.syncStatus.error'
          : 'shell.syncStatus.connecting'

  const showText = status === 'reconnecting' || status === 'error'

  return (
    <Tooltip title={t(labelKey)}>
      <span
        className="inline-flex cursor-default items-center gap-1.5 rounded-full px-1.5 py-0.5 text-xs text-muted-foreground"
        data-sync-status={status}
        aria-label={t(labelKey)}
      >
        <Badge status={badgeStatus} />
        {showText ? <span className="hidden lg:inline">{t(labelKey)}</span> : null}
      </span>
    </Tooltip>
  )
}
