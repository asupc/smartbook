import type { ReactNode } from 'react'

import { useT } from '@smartbook/ui'
import { Amount } from '@smartbook/web-features'

/**
 * 资产页 KPI 总览(方案 A):4 列 × 2 行。
 *   - 第一行「资产总览」:净资产 / 总资产 / 总负债 / 账户规模。
 *   - 第二行「收支统计」:本月收入 / 本月支出 / 本年收入 / 本年支出。
 * 纯展示组件,金额全部由上层传入(资产 4 项走 converted 折算口径,收支 4 项走
 * analytics summary),这里绝不另起汇率 / 聚合逻辑。approx=true 时(多币种折算)
 * 金额前加「≈」前缀,与折算汇总口径一致。
 */
export function AssetKpiRow({
  netWorth,
  assetTotal,
  liabilityTotal,
  accountCount,
  currencyCount,
  hiddenCount,
  monthIncome,
  monthExpense,
  yearIncome,
  yearExpense,
  base,
  approx = false,
}: {
  netWorth: number
  assetTotal: number
  liabilityTotal: number
  accountCount: number
  currencyCount: number
  hiddenCount: number
  monthIncome: number
  monthExpense: number
  yearIncome: number
  yearExpense: number
  base: string
  approx?: boolean
}) {
  const t = useT()
  return (
    <div className="space-y-3">
      <GroupLabel>{t('accounts.kpi.assetsGroup')}</GroupLabel>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <MoneyKpi
          label={t('accounts.kpi.netWorth')}
          value={netWorth}
          currency={base}
          tone={netWorth >= 0 ? 'positive' : 'negative'}
          approx={approx}
        />
        <MoneyKpi
          label={t('accounts.kpi.assets')}
          value={assetTotal}
          currency={base}
          tone="positive"
          approx={approx}
        />
        <MoneyKpi
          label={t('accounts.kpi.liabilities')}
          value={Math.abs(liabilityTotal)}
          currency={base}
          tone="negative"
          approx={approx}
        />
        <Kpi
          label={t('accounts.kpi.accountScale')}
          sub={t('accounts.kpi.accountSub', { currencyCount, hiddenCount })}
        >
          <span className="font-mono text-2xl font-bold leading-none">{accountCount}</span>
          <span className="text-sm text-muted-foreground">{t('accounts.kpi.accountUnit')}</span>
        </Kpi>
      </div>

      <GroupLabel>{t('accounts.kpi.incomeGroup')}</GroupLabel>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <MoneyKpi
          label={t('accounts.kpi.monthIncome')}
          value={monthIncome}
          currency={base}
          tone="positive"
          approx={approx}
        />
        <MoneyKpi
          label={t('accounts.kpi.monthExpense')}
          value={monthExpense}
          currency={base}
          tone="negative"
          approx={approx}
        />
        <MoneyKpi
          label={t('accounts.kpi.yearIncome')}
          value={yearIncome}
          currency={base}
          tone="positive"
          approx={approx}
        />
        <MoneyKpi
          label={t('accounts.kpi.yearExpense')}
          value={yearExpense}
          currency={base}
          tone="negative"
          approx={approx}
        />
      </div>
    </div>
  )
}

function GroupLabel({ children }: { children: ReactNode }) {
  return (
    <div className="flex items-center gap-3 text-[11px] font-semibold uppercase tracking-[0.18em] text-muted-foreground">
      <span className="h-px flex-1 bg-border/60" aria-hidden />
      <span className="whitespace-nowrap">{children}</span>
      <span className="h-px flex-1 bg-border/60" aria-hidden />
    </div>
  )
}

function Kpi({
  label,
  approx = false,
  sub,
  children,
}: {
  label: string
  approx?: boolean
  sub?: ReactNode
  children: ReactNode
}) {
  return (
    <div className="rounded-xl border border-border/60 bg-card/60 px-4 py-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="mt-1 flex items-baseline gap-1">
        {approx ? <span className="font-mono text-xs text-muted-foreground">≈</span> : null}
        {children}
      </div>
      {sub ? <div className="mt-1 text-[11px] text-muted-foreground">{sub}</div> : null}
    </div>
  )
}

function MoneyKpi({
  label,
  value,
  currency,
  tone,
  approx,
}: {
  label: string
  value: number
  currency: string
  tone: 'positive' | 'negative'
  approx?: boolean
}) {
  return (
    <Kpi label={label} approx={approx}>
      <Amount
        value={value}
        currency={currency}
        showCurrency
        compact={false}
        size="2xl"
        bold
        tone={tone}
        className="whitespace-nowrap"
      />
    </Kpi>
  )
}
