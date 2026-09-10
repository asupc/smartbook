import { useCallback, useEffect, useMemo, useState } from 'react'

import {
  fetchAccountAdjustments,
  fetchWorkspaceAccounts,
  type AccountAdjustment,
  type WorkspaceAccount,
} from '@smartbook/api-client'
import { Card, Select, Table, theme } from 'antd'
import type { ColumnsType } from 'antd/es/table'
import { ArrowDownRight, ArrowUpRight } from 'lucide-react'
import { useT, useToast } from '@smartbook/ui'

import { useAuth } from '../../context/AuthContext'
import { useLedgers } from '../../context/LedgersContext'
import { useSyncRefresh } from '../../context/SyncSocketContext'
import { localizeError } from '../../i18n/errors'

/**
 * 余额调整记录页(v2 独立菜单):「调整余额」不再落交易,历史统一在这里看。
 * 表格形式:时间 / 账户 / 差额(带符号,红绿区分)/ 调整前后余额 / 备注。
 * 支持按账户筛选。
 *
 * 调整记录是**对账审计数据,append-only**:只增不删(用户决策)。记错就反向
 * 再调一笔,余额口径始终可回溯。
 *
 * 账户是 user-global,但调整记录是 ledger-scope —— 切账本看各自账本的记录。
 */
export function AccountAdjustmentsPage() {
  const t = useT()
  const toast = useToast()
  const { token } = useAuth()
  const { activeLedgerId } = useLedgers()
  const { token: antdToken } = theme.useToken()

  const [accounts, setAccounts] = useState<WorkspaceAccount[]>([])
  const [records, setRecords] = useState<AccountAdjustment[] | null>(null)
  const [accountFilter, setAccountFilter] = useState<string | undefined>(undefined)

  const refresh = useCallback(async () => {
    if (!activeLedgerId) return
    try {
      const [accRows, adjRows] = await Promise.all([
        fetchWorkspaceAccounts(token, { limit: 500 }),
        fetchAccountAdjustments(token, activeLedgerId).catch(
          () => [] as AccountAdjustment[],
        ),
      ])
      setAccounts(accRows)
      setRecords(adjRows)
    } catch (err) {
      toast.error(localizeError(err, t), t('notice.error'))
    }
  }, [token, activeLedgerId, toast, t])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useSyncRefresh(() => {
    void refresh()
  })

  const accountNameById = useMemo(() => {
    const map = new Map<string, string>()
    for (const acc of accounts) map.set(acc.id, acc.name)
    return map
  }, [accounts])

  const visible = useMemo(
    () => (records ?? []).filter((r) => !accountFilter || r.account_id === accountFilter),
    [records, accountFilter],
  )

  const columns: ColumnsType<AccountAdjustment> = useMemo(
    () => [
      {
        title: t('adjustments.col.time'),
        dataIndex: 'happened_at',
        key: 'happened_at',
        width: 170,
        render: (v: string) => (
          <span className="text-[13px] text-muted-foreground">
            {new Date(v).toLocaleString()}
          </span>
        ),
      },
      {
        title: t('adjustments.col.account'),
        dataIndex: 'account_id',
        key: 'account',
        width: 150,
        ellipsis: true,
        render: (_, rec) => (
          <span className="text-[13px]">
            {rec.account_name || accountNameById.get(rec.account_id) || rec.account_id}
          </span>
        ),
      },
      {
        title: t('adjustments.col.amount'),
        dataIndex: 'amount',
        key: 'amount',
        width: 130,
        align: 'right',
        render: (v: number) => {
          const positive = v >= 0
          return (
            <span
              className="inline-flex items-center gap-1 text-[13px] font-semibold"
              style={{ color: positive ? antdToken.colorSuccess : antdToken.colorError }}
            >
              {positive ? (
                <ArrowUpRight size={14} />
              ) : (
                <ArrowDownRight size={14} />
              )}
              {positive ? '+' : ''}
              {v.toFixed(2)}
            </span>
          )
        },
      },
      {
        title: t('adjustments.col.balance'),
        key: 'balance',
        width: 170,
        render: (_, rec) =>
          rec.balance_before != null && rec.balance_after != null ? (
            <span className="font-mono text-[13px] text-muted-foreground">
              {rec.balance_before.toFixed(2)} → {rec.balance_after.toFixed(2)}
            </span>
          ) : (
            <span className="text-muted-foreground">-</span>
          ),
      },
      {
        title: t('adjustments.col.note'),
        dataIndex: 'note',
        key: 'note',
        ellipsis: true,
        render: (v: string | null) =>
          v ? <span className="text-[13px]">{v}</span> : <span className="text-muted-foreground">-</span>,
      },
    ],
    [t, accountNameById, antdToken],
  )

  return (
    <Card
      size="small"
      title={<span className="text-base">{t('nav.adjustments')}</span>}
      styles={{ body: { padding: '12px 16px 16px' } }}
      extra={
        <Select
          allowClear
          size="small"
          value={accountFilter}
          onChange={(v) => setAccountFilter(v)}
          placeholder={t('adjustments.filterByAccount')}
          className="min-w-[180px]"
          popupMatchSelectWidth={false}
          options={accounts.map((acc) => ({ value: acc.id, label: acc.name }))}
        />
      }
    >
      {!activeLedgerId ? (
        <p className="text-sm text-muted-foreground">{t('shell.selectLedgerFirst')}</p>
      ) : (
        <Table<AccountAdjustment>
          size="small"
          rowKey="id"
          columns={columns}
          dataSource={visible}
          loading={records === null}
          pagination={{ pageSize: 20, showSizeChanger: false, showTotal: (total) => `${total}` }}
          locale={{ emptyText: t('detail.account.adjustHistoryEmpty') }}
        />
      )}
    </Card>
  )
}
