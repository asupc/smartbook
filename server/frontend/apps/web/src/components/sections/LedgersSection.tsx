import { useEffect, useState, type CSSProperties } from 'react'
import { useNavigate } from 'react-router-dom'

import {
  BarChart3,
  Clock,
  MoreHorizontal,
  Pencil,
  Trash2,
  Upload,
  UserPlus,
  Users,
} from 'lucide-react'

import type { ReadLedger } from '@smartbook/api-client'
import { Button, Card, Drawer, Dropdown, Input, type MenuProps } from 'antd'
import { useT, useToast } from '@smartbook/ui'
import {
  Amount,
  CurrencySelectorTrigger,
  formatIsoDateTime,
  loadRatesToBase,
} from '@smartbook/web-features'

import { useLedgers } from '../../context/LedgersContext'
import { useAuth } from '../../context/AuthContext'
import { JoinSharedLedgerDialog } from '../JoinSharedLedgerDialog'
import { SharedLedgerManageDialog } from '../SharedLedgerManageDialog'
import { SharedLedgerStatsDialog } from '../SharedLedgerStatsDialog'

const fieldLabelStyle: CSSProperties = { fontWeight: 500, marginBottom: 4, display: 'block' }

interface Props {
  /** 点击账本卡片编辑入口的回调 */
  onEdit: (ledger: ReadLedger) => void
  onCreate: () => void
  /** 点删除按钮的回调 — page 端弹独立确认弹窗 + 调 deleteLedger。
   *  不传则卡片上不展示删除按钮(viewer 视角 / page 还没实现时兜底)。 */
  onDelete?: (ledger: ReadLedger) => void
}

/**
 * 账本列表 section。
 *
 * 现代化金融极简卡片：
 *   - 头部: 柔和渐变图标 + 账本名称 + 币种/角色/共享徽章 + 激活状态/操作菜单
 *   - 核心: 结余大字号展示 + 交易笔数 + 收入/支出动态双色比例进度条
 *   - 底部: 最近更新时间 + 快捷动作
 */
export function LedgersSection({ onEdit, onCreate, onDelete }: Props) {
  const t = useT()
  const toast = useToast()
  const { ledgers, activeLedgerId, setActiveLedgerId } = useLedgers()
  const [joinOpen, setJoinOpen] = useState(false)
  const [manageLedger, setManageLedger] = useState<ReadLedger | null>(null)
  const [statsLedger, setStatsLedger] = useState<ReadLedger | null>(null)

  const handleSelectActive = (ledger: ReadLedger) => {
    setActiveLedgerId(ledger.ledger_id)
    toast.success(
      t('shell.ledgerSwitched') || `已切换至「${ledger.ledger_name}」`,
      t('notice.success') || '成功',
    )
  }

  return (
    <div className="space-y-4">
      <Card
        size="small"
        className="bc-panel"
        title={<span className="text-base font-semibold">{t('ledgers.title')}</span>}
        extra={
          <div className="flex gap-2">
            {/* §7 共享账本:全局"加入共享账本"入口 — 跟 mobile 设置页一致 */}
            <Button size="small" variant="outlined" icon={<UserPlus className="h-3.5 w-3.5" />} onClick={() => setJoinOpen(true)}>
              {t('sharedLedger.joinAction')}
            </Button>
            <Button size="small" type="primary" onClick={onCreate}>
              {t('ledgers.button.create')}
            </Button>
          </div>
        }
        styles={{ body: { padding: '16px 20px 20px' } }}
      >
        <p className="mb-5 text-xs text-muted-foreground">
          {t('ledgers.subtitle')}
        </p>
        {ledgers.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('ledgers.empty')}</p>
        ) : (
          <LedgerGrid
            ledgers={ledgers}
            activeLedgerId={activeLedgerId}
            onEdit={onEdit}
            onDelete={onDelete}
            onManageMembers={(l) => setManageLedger(l)}
            onOpenStats={(l) => setStatsLedger(l)}
            onSelectActive={handleSelectActive}
          />
        )}
      </Card>
      <JoinSharedLedgerDialog open={joinOpen} onOpenChange={setJoinOpen} />
      <SharedLedgerManageDialog
        open={manageLedger != null}
        onOpenChange={(o) => { if (!o) setManageLedger(null) }}
        ledgerId={manageLedger?.ledger_id || ''}
        ledgerName={manageLedger?.ledger_name || ''}
        isOwner={manageLedger?.role === 'owner'}
      />
      <SharedLedgerStatsDialog
        open={statsLedger != null}
        onOpenChange={(o) => { if (!o) setStatsLedger(null) }}
        ledgerId={statsLedger?.ledger_id || ''}
        ledgerName={statsLedger?.ledger_name || ''}
      />
    </div>
  )
}

function LedgerGrid({
  ledgers,
  activeLedgerId,
  onEdit,
  onDelete,
  onManageMembers,
  onOpenStats,
  onSelectActive,
}: {
  ledgers: ReadLedger[]
  activeLedgerId: string | null
  onEdit: (ledger: ReadLedger) => void
  onDelete?: (ledger: ReadLedger) => void
  onManageMembers: (ledger: ReadLedger) => void
  onOpenStats: (ledger: ReadLedger) => void
  onSelectActive: (ledger: ReadLedger) => void
}) {
  const t = useT()
  const navigate = useNavigate()
  return (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
      {ledgers.map((ledger) => (
        <LedgerCard
          key={ledger.ledger_id}
          ledger={ledger}
          isActive={activeLedgerId === ledger.ledger_id}
          onEdit={() => onEdit(ledger)}
          onDelete={onDelete ? () => onDelete(ledger) : undefined}
          onImport={() =>
            navigate(`/app/import?ledger=${encodeURIComponent(ledger.ledger_id)}`)
          }
          onManageMembers={() => onManageMembers(ledger)}
          onOpenStats={() => onOpenStats(ledger)}
          onSelectActive={() => onSelectActive(ledger)}
          roleLabel={roleLabelOf(ledger.role, t)}
        />
      ))}
    </div>
  )
}

function roleLabelOf(role: ReadLedger['role'], t: (key: string) => string): string {
  if (role === 'owner') return t('ledgers.role.owner')
  if (role === 'editor') return t('ledgers.role.editor')
  return t('ledgers.role.viewer')
}

const ACCENT_PALETTE = [
  {
    iconBg: 'bg-gradient-to-tr from-blue-600 to-indigo-500 text-white shadow-blue-500/25',
    glow: 'from-blue-500/10',
    accentText: 'text-blue-600 dark:text-blue-400',
  },
  {
    iconBg: 'bg-gradient-to-tr from-violet-600 to-purple-500 text-white shadow-purple-500/25',
    glow: 'from-purple-500/10',
    accentText: 'text-violet-600 dark:text-violet-400',
  },
  {
    iconBg: 'bg-gradient-to-tr from-emerald-600 to-teal-500 text-white shadow-emerald-500/25',
    glow: 'from-emerald-500/10',
    accentText: 'text-emerald-600 dark:text-emerald-400',
  },
  {
    iconBg: 'bg-gradient-to-tr from-amber-500 to-orange-500 text-white shadow-amber-500/25',
    glow: 'from-amber-500/10',
    accentText: 'text-amber-600 dark:text-amber-400',
  },
  {
    iconBg: 'bg-gradient-to-tr from-rose-500 to-pink-500 text-white shadow-rose-500/25',
    glow: 'from-rose-500/10',
    accentText: 'text-rose-600 dark:text-rose-400',
  },
  {
    iconBg: 'bg-gradient-to-tr from-cyan-600 to-blue-500 text-white shadow-cyan-500/25',
    glow: 'from-cyan-500/10',
    accentText: 'text-cyan-600 dark:text-cyan-400',
  },
]

function accentFor(name: string) {
  let h = 0
  for (let i = 0; i < name.length; i += 1) {
    h = (h * 31 + name.charCodeAt(i)) | 0
  }
  return ACCENT_PALETTE[Math.abs(h) % ACCENT_PALETTE.length]
}

interface LedgerCardProps {
  ledger: ReadLedger
  isActive: boolean
  roleLabel: string
  onEdit: () => void
  /** undefined 时不展示删除按钮(viewer / 非 owner / page 没接 handler 时) */
  onDelete?: () => void
  onImport: () => void
  onManageMembers: () => void
  onOpenStats: () => void
  onSelectActive: () => void
}

function LedgerCard({
  ledger,
  isActive,
  roleLabel,
  onEdit,
  onDelete,
  onImport,
  onManageMembers,
  onOpenStats,
  onSelectActive,
}: LedgerCardProps) {
  const t = useT()
  const accent = accentFor(ledger.ledger_name || '?')
  const initial = (ledger.ledger_name || '?').trim().slice(0, 1).toUpperCase()

  // §7 共享账本: Owner 保留导入/编辑入口; 非 Owner 成员(Editor)卡片禁用编辑
  const editDisabled = !!ledger.is_shared && ledger.role !== 'owner'

  // 计算收支双色比例条
  const incomeVal = Math.max(0, ledger.income_total || 0)
  const expenseVal = Math.max(0, ledger.expense_total || 0)
  const totalFlow = incomeVal + expenseVal
  const incomePercent = totalFlow > 0 ? Math.round((incomeVal / totalFlow) * 100) : 50
  const expensePercent = 100 - incomePercent

  // 下拉菜单项收拢
  const menuItems: MenuProps['items'] = [
    ...(!editDisabled
      ? [
          {
            key: 'edit',
            icon: <Pencil className="h-3.5 w-3.5" />,
            label: t('common.edit'),
            onClick: onEdit,
          },
        ]
      : []),
    {
      key: 'members',
      icon: <Users className="h-3.5 w-3.5" />,
      label: t('sharedLedger.openManage') as string,
      onClick: onManageMembers,
    },
    ...(ledger.is_shared
      ? [
          {
            key: 'stats',
            icon: <BarChart3 className="h-3.5 w-3.5" />,
            label: t('sharedLedger.statsOpen') as string,
            onClick: onOpenStats,
          },
        ]
      : []),
    ...(!ledger.is_shared || ledger.role === 'owner'
      ? [
          {
            key: 'import',
            icon: <Upload className="h-3.5 w-3.5" />,
            label: t('ledgers.action.import') as string,
            onClick: onImport,
          },
        ]
      : []),
    ...(onDelete && (!ledger.is_shared || ledger.role === 'owner')
      ? [
          { type: 'divider' as const },
          {
            key: 'delete',
            danger: true,
            icon: <Trash2 className="h-3.5 w-3.5" />,
            label: t('ledgers.action.delete') as string,
            onClick: onDelete,
          },
        ]
      : []),
  ]

  const handleCardClick = () => {
    if (!isActive) {
      onSelectActive()
      return
    }
    if (!editDisabled) {
      onEdit()
    }
  }

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={handleCardClick}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          handleCardClick()
        }
      }}
      className={`group relative flex flex-col justify-between overflow-hidden rounded-2xl border bg-card p-4 text-left transition-all duration-200 cursor-pointer ${
        isActive
          ? 'border-primary/80 shadow-md shadow-primary/5 ring-2 ring-primary/20 bg-gradient-to-b from-primary/[0.03] to-transparent'
          : 'border-border/70 hover:-translate-y-0.5 hover:border-border hover:shadow-md'
      }`}
    >
      {/* 活跃账本右上角微光氛围 */}
      {isActive ? (
        <div
          className={`pointer-events-none absolute -right-10 -top-10 h-28 w-28 rounded-full bg-gradient-to-br ${accent.glow} to-transparent blur-2xl transition-all group-hover:scale-110`}
        />
      ) : null}

      <div>
        {/* 顶部 Header：图标 + 账本名/徽章 + 激活状态/操作 */}
        <div className="flex items-start justify-between gap-2.5">
          <div className="flex min-w-0 items-center gap-3">
            <div
              className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl text-base font-bold shadow-sm ${accent.iconBg}`}
              aria-hidden
            >
              {ledger.is_shared ? (
                <Users className="h-5 w-5" />
              ) : (
                <span>{initial}</span>
              )}
            </div>

            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-1.5">
                <h3 className="truncate text-sm sm:text-base font-bold text-foreground leading-snug group-hover:text-primary transition-colors">
                  {ledger.ledger_name || '—'}
                </h3>
              </div>
              <div className="mt-1 flex flex-wrap items-center gap-1.5 text-[11px]">
                <span className="rounded bg-muted/70 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground font-medium">
                  {ledger.currency}
                </span>
                <span className="text-muted-foreground/50">·</span>
                <span className={`font-medium ${accent.accentText}`}>
                  {roleLabel}
                </span>
                {ledger.is_shared ? (
                  <span className="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.2 text-[10px] font-medium text-primary">
                    <Users className="h-2.5 w-2.5" />
                    {ledger.member_count || 1} 人
                  </span>
                ) : null}
              </div>
            </div>
          </div>

          {/* 右侧：激活标识与操作按钮 */}
          <div className="flex shrink-0 items-center gap-1.5">
            {isActive ? (
              <span className="inline-flex items-center gap-1.5 rounded-full border border-primary/25 bg-primary/10 px-2.5 py-0.5 text-[11px] font-semibold text-primary shadow-xs">
                <span className="h-1.5 w-1.5 rounded-full bg-primary animate-pulse" />
                当前使用
              </span>
            ) : (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation()
                  onSelectActive()
                }}
                className="rounded-full border border-border/80 bg-background/80 px-2.5 py-0.5 text-[11px] font-medium text-muted-foreground transition hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
              >
                设为当前
              </button>
            )}

            {/* 更多操作 Dropdown */}
            <Dropdown
              menu={{ items: menuItems }}
              trigger={['click']}
              placement="bottomRight"
            >
              <button
                type="button"
                onClick={(e) => e.stopPropagation()}
                title="账本选项"
                aria-label="账本选项"
                className="rounded-lg p-1 text-muted-foreground transition hover:bg-muted hover:text-foreground"
              >
                <MoreHorizontal className="h-4 w-4" />
              </button>
            </Dropdown>
          </div>
        </div>

        {/* 核心资产大数字区域 */}
        <div className="my-3 rounded-xl border border-border/50 bg-muted/25 p-3.5 dark:bg-muted/15">
          <div className="flex items-baseline justify-between">
            <span className="text-[10px] font-medium uppercase tracking-wider text-muted-foreground">
              {t('ledgers.col.balance')}
            </span>
            <span className="font-mono text-xs text-muted-foreground">
              {ledger.transaction_count.toLocaleString()} {t('ledgers.col.tx')}
            </span>
          </div>
          <div className="mt-1">
            <Amount
              value={ledger.balance}
              currency={ledger.currency}
              size="lg"
              bold
              tone={ledger.balance < 0 ? 'negative' : 'default'}
              className="text-2xl font-bold tracking-tight"
            />
          </div>

          {/* 收支双色动态比例条 */}
          <div className="mt-3">
            <div className="mb-1 flex justify-between text-[11px] font-mono">
              <div className="flex items-center gap-1 text-income font-medium">
                <span className="h-1.5 w-1.5 rounded-full bg-income" />
                <span>{t('ledgers.col.income')}</span>
                <Amount value={ledger.income_total} currency={ledger.currency} size="xs" />
              </div>
              <div className="flex items-center gap-1 text-expense font-medium">
                <span>{t('ledgers.col.expense')}</span>
                <Amount value={ledger.expense_total} currency={ledger.currency} size="xs" />
                <span className="h-1.5 w-1.5 rounded-full bg-expense" />
              </div>
            </div>
            <div className="flex h-1.5 w-full overflow-hidden rounded-full bg-muted/70">
              {totalFlow > 0 ? (
                <>
                  <div
                    className="h-full bg-income transition-all duration-300"
                    style={{ width: `${incomePercent}%` }}
                  />
                  <div
                    className="h-full bg-expense transition-all duration-300"
                    style={{ width: `${expensePercent}%` }}
                  />
                </>
              ) : (
                <div className="h-full w-full bg-border/40" />
              )}
            </div>
          </div>
        </div>
      </div>

      {/* 底部元信息行：更新时间与快捷入口 */}
      <div className="flex items-center justify-between pt-0.5 text-xs text-muted-foreground">
        <div className="flex items-center gap-1 text-[11px]">
          <Clock className="h-3 w-3 text-muted-foreground/70" />
          <span className="font-mono">{formatIsoDateTime(ledger.updated_at)}</span>
        </div>

        <div className="flex items-center gap-2">
          {ledger.is_shared ? (
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                onOpenStats()
              }}
              className="text-[11px] font-medium text-primary hover:underline flex items-center gap-0.5"
            >
              <BarChart3 className="h-3 w-3" />
              分摊
            </button>
          ) : null}

          {!ledger.is_shared || ledger.role === 'owner' ? (
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                onImport()
              }}
              className="text-[11px] font-medium text-muted-foreground hover:text-primary transition"
            >
              {t('ledgers.action.import')}
            </button>
          ) : null}

          {!editDisabled ? (
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                onEdit()
              }}
              className="text-[11px] font-medium text-muted-foreground hover:text-primary transition"
            >
              {t('common.edit')}
            </button>
          ) : null}
        </div>
      </div>
    </div>
  )
}

/**
 * 编辑/新建账本通用 dialog。`mode='create'` 隐藏 ledgerId 字段(server 自动生成),
 * `mode='edit'` 锁定 ledgerId 文案显示。币种走 CurrencySelector。
 */
export type LedgerForm = {
  ledger_name: string
  currency: string
  month_start_day: number
}

interface LedgerEditDialogProps {
  open: boolean
  mode: 'create' | 'edit'
  form: LedgerForm
  onChange: (next: LedgerForm) => void
  onClose: () => void
  onSubmit: () => Promise<boolean> | boolean
  /** 编辑模式额外信息行,例如 ledger id / 创建者 / 角色。 */
  meta?: { label: string; value: string }[]
}

export function LedgerEditDialog({
  open,
  mode,
  form,
  onChange,
  onClose,
  onSubmit,
  meta,
}: LedgerEditDialogProps) {
  const t = useT()
  const { token } = useAuth()
  const [submitting, setSubmitting] = useState(false)
  // v30 多币种:币种选择弹窗展示各币种对账本主币种的汇率(1 该币种 ≈ x 主币种,含手动 override)。
  const rateBase = (form.currency || 'CNY').toUpperCase()
  const [ratesToBase, setRatesToBase] = useState<Record<string, number>>({})
  useEffect(() => {
    if (!open || !token) return
    let cancelled = false
    loadRatesToBase(token, rateBase)
      .then((m) => {
        if (!cancelled) setRatesToBase(m)
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [open, rateBase, token])
  const handleSubmit = async () => {
    setSubmitting(true)
    try {
      const ok = await onSubmit()
      if (ok) onClose()
    } finally {
      setSubmitting(false)
    }
  }
  return (
    <Drawer
      open={open}
      onClose={() => { if (!submitting) onClose() }}
      width={448}
      title={mode === 'create' ? t('ledgers.button.create') : t('ledgers.button.update')}
      footer={
        <div className="flex justify-end gap-2">
          <Button disabled={submitting} onClick={onClose}>
            {t('dialog.cancel')}
          </Button>
          <Button
            disabled={submitting}
            loading={submitting}
            type="primary"
            onClick={() => void handleSubmit()}
          >
            {mode === 'create' ? t('ledgers.button.create') : t('ledgers.button.update')}
          </Button>
        </div>
      }
    >
      <div className="space-y-3">
        <div className="space-y-1">
          <label style={fieldLabelStyle}>{t('ledgers.field.name')}</label>
          <Input
            placeholder={t('ledgers.placeholder.name')}
            value={form.ledger_name}
            onChange={(e) => onChange({ ...form, ledger_name: e.target.value })}
          />
        </div>
        <div className="space-y-1">
          <label style={fieldLabelStyle}>{t('ledgers.field.currency')}</label>
          <CurrencySelectorTrigger
            value={form.currency || 'CNY'}
            onChange={(code) => onChange({ ...form, currency: code })}
            ratesToBase={ratesToBase}
            rateBase={rateBase}
          />
        </div>
        <div className="space-y-1">
          <label htmlFor="ledger-month-start-day" style={fieldLabelStyle}>{t('ledgers.field.monthStartDay')}</label>
          <select
            id="ledger-month-start-day"
            name="month_start_day"
            className="h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
            value={form.month_start_day ?? 1}
            onChange={(e) =>
              onChange({ ...form, month_start_day: Number(e.target.value) })
            }
          >
            {Array.from({ length: 28 }, (_, i) => i + 1).map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </select>
          <p className="text-xs text-muted-foreground">
            {t('ledgers.monthStartDay.hint')}
          </p>
        </div>
        {meta && meta.length > 0 ? (
          <div className="space-y-1 rounded-md border border-border/50 bg-muted/30 px-3 py-2 text-xs">
            {meta.map((row) => (
              <div key={row.label} className="flex items-center justify-between gap-2">
                <span className="text-muted-foreground">{row.label}</span>
                <span className="truncate font-mono">{row.value}</span>
              </div>
            ))}
          </div>
        ) : null}
      </div>
    </Drawer>
  )
}
