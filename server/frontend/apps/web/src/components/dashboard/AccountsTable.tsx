import { useMemo } from 'react'

import { Button, Table } from 'antd'
import type { TableColumnsType } from 'antd'
import { useT } from '@smartbook/ui'
import {
  Amount,
  TypeIcon,
  VALUATION_TYPES_SET,
  type AccountListRenderArgs,
  type AssetGroup,
} from '@smartbook/web-features'
import type { WorkspaceAccount } from '@smartbook/api-client'

/**
 * 资产页账户表格(方案 A 底部密集表格,替代彩卡网格)。
 *
 * 数据由 AccountsPanel 经 renderList 传入(已按类型分组 + 组内按名排序),这里用
 * antd Table 的树形数据(children)渲染分组表头:组头保留类型图标/名称/数量/负债
 * badge + 跨币种小计,展开后是账户行。账户行点按打开详情,编辑/删除按钮
 * stopPropagation 避免触发行点击。估值账户显示「当前估值」、信用卡显示「已用/额度」。
 */

type AccountRecord = {
  key: string
  group?: AssetGroup
  account?: WorkspaceAccount
  children?: AccountRecord[]
}

const displayBalance = (row: WorkspaceAccount) =>
  typeof row.balance === 'number' && row.balance !== null
    ? row.balance
    : row.initial_balance ?? 0
const isCreditCard = (row: WorkspaceAccount) => row.account_type === 'credit_card'
const isValuation = (row: WorkspaceAccount) =>
  VALUATION_TYPES_SET.has(row.account_type || 'other')
const creditLimit = (row: WorkspaceAccount) =>
  typeof row.credit_limit === 'number' ? row.credit_limit : null

export function AccountsTable({
  listGroups,
  canManage,
  onEdit,
  onDelete,
  onClickAccount,
}: AccountListRenderArgs) {
  const t = useT()

  const dataSource = useMemo<AccountRecord[]>(
    () =>
      listGroups.map((group) => ({
        key: `group:${group.type}`,
        group,
        children: group.rows.map((row) => ({
          key: row.id,
          group,
          account: row as WorkspaceAccount,
        })),
      })),
    [listGroups],
  )

  const columns = useMemo<TableColumnsType<AccountRecord>>(
    () => [
      {
        title: t('accounts.tableCol.account'),
        render: (_v, record) => {
          if (record.group) {
            const g = record.group
            return (
              <span className="inline-flex items-center gap-2">
                <TypeIcon type={g.type} size={18} />
                <span className="font-semibold">{g.label}</span>
                <span className="rounded-full bg-muted/60 px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">
                  {g.rows.length}
                </span>
                {g.isLiability ? (
                  <span className="rounded-md border border-destructive/40 bg-destructive/10 px-1.5 py-0.5 text-[10px] leading-none text-destructive">
                    {t('accounts.badge.liability')}
                  </span>
                ) : null}
              </span>
            )
          }
          const row = record.account!
          return (
            <span className="inline-flex items-center gap-2">
              <TypeIcon type={row.account_type || 'other'} size={18} />
              <span className="truncate">{row.name}</span>
            </span>
          )
        },
      },
      {
        title: t('accounts.tableCol.type'),
        width: 120,
        render: (_v, record) =>
          record.group ? null : (
            <span className="rounded bg-muted/60 px-1.5 py-0.5 text-[11px] text-muted-foreground">
              {record.group!.label}
            </span>
          ),
      },
      {
        title: t('accounts.tableCol.currency'),
        width: 90,
        render: (_v, record) =>
          record.group ? null : (
            <span className="rounded bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium uppercase text-primary">
              {(record.account!.currency || 'CNY').toUpperCase()}
            </span>
          ),
      },
      {
        title: t('accounts.tableCol.balance'),
        align: 'right',
        render: (_v, record) => {
          if (record.group) {
            const g = record.group
            return (
              <span className="inline-flex flex-col items-end gap-0.5">
                {g.subtotals.map((st) => (
                  <Amount
                    key={st.currency}
                    value={g.isLiability ? Math.abs(st.value) : st.value}
                    currency={st.currency}
                    showCurrency
                    compact={false}
                    bold
                    tone={g.isLiability ? 'negative' : 'default'}
                  />
                ))}
              </span>
            )
          }
          const row = record.account!
          const bal = displayBalance(row)
          return (
            <Amount
              value={bal}
              currency={row.currency}
              showCurrency
              compact={false}
              tone={bal < 0 ? 'negative' : 'positive'}
            />
          )
        },
      },
      {
        title: t('accounts.tableCol.monthIncome'),
        align: 'right',
        render: (_v, record) =>
          record.group ? null : (
            <Amount
              value={record.account!.income_total ?? 0}
              currency={record.account!.currency}
              showCurrency
              compact={false}
              tone="positive"
            />
          ),
      },
      {
        title: t('accounts.tableCol.monthExpense'),
        align: 'right',
        render: (_v, record) =>
          record.group ? null : (
            <Amount
              value={record.account!.expense_total ?? 0}
              currency={record.account!.currency}
              showCurrency
              compact={false}
              tone="negative"
            />
          ),
      },
      {
        title: t('accounts.tableCol.creditLimit'),
        render: (_v, record) => {
          if (record.group) return null
          const row = record.account!
          if (isValuation(row)) {
            return (
              <span className="text-muted-foreground">{t('accounts.bankcard.currentValue')}</span>
            )
          }
          if (isCreditCard(row)) {
            const limit = creditLimit(row)
            const owed = Math.max(0, -displayBalance(row))
            if (limit !== null) {
              return (
                <span className="text-muted-foreground">
                  {t('accounts.bankcard.creditUsed')}{' '}
                  <Amount value={owed} currency={row.currency} showCurrency compact={false} /> /{' '}
                  <Amount value={limit} currency={row.currency} showCurrency compact={false} />
                </span>
              )
            }
            return (
              <span className="text-muted-foreground">{t('accounts.bankcard.currentOwed')}</span>
            )
          }
          return <span className="text-muted-foreground">—</span>
        },
      },
      {
        title: t('accounts.tableCol.actions'),
        width: 140,
        render: (_v, record) => {
          if (record.group) return null
          const row = record.account!
          return (
            <span className="inline-flex items-center gap-1">
              <Button
                size="small"
                type="link"
                disabled={!canManage}
                onClick={(e) => {
                  e.stopPropagation()
                  onEdit(row)
                }}
              >
                {t('common.edit')}
              </Button>
              {onDelete ? (
                <Button
                  size="small"
                  type="link"
                  danger
                  disabled={!canManage}
                  onClick={(e) => {
                    e.stopPropagation()
                    onDelete(row)
                  }}
                >
                  {t('common.delete')}
                </Button>
              ) : null}
            </span>
          )
        },
      },
    ],
    [t, canManage, onEdit, onDelete],
  )

  return (
    <Table<AccountRecord>
      rowKey="key"
      columns={columns}
      dataSource={dataSource}
      pagination={false}
      size="middle"
      scroll={{ x: 900 }}
      expandable={{ defaultExpandAllRows: true }}
      onRow={(record) =>
        record.account
          ? { onClick: () => onClickAccount?.(record.account!), style: { cursor: 'pointer' } }
          : {}
      }
    />
  )
}
