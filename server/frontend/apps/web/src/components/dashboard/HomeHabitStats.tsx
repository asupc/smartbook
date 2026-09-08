import { Flame, PiggyBank, Sparkles } from 'lucide-react'

import type { WorkspaceAnalyticsSummary, WorkspaceLedgerCounts } from '@smartbook/api-client'
import { Amount } from '@smartbook/web-features'
import { useT } from '@smartbook/ui'

interface Props {
  /** 本月 summary，用来算储蓄率、日均支出。 */
  monthSummary?: WorkspaceAnalyticsSummary
  /** 全量 counts，用来算平均每天/每笔。 */
  ledgerCounts?: WorkspaceLedgerCounts
  currency?: string
}

/**
 * 三张小卡并排：
 *  - 储蓄率 = (收入 - 支出) / 收入。收入为 0 则"未记账收入"。
 *  - 本月日均支出 = 支出 / 本月天数（到今天为止）。
 *  - 累计记账习惯 = 从第一天到今天的平均每天笔数 + 总笔数。
 *
 * 目的：把用户"记账这件事本身"的行为数据做可视化，跟具体账目互补。
 */
export function HomeHabitStats({ monthSummary, ledgerCounts, currency = 'CNY' }: Props) {
  const t = useT()
  const monthIncome = monthSummary?.income_total ?? 0
  const monthExpense = monthSummary?.expense_total ?? 0

  // 储蓄率：正值 = 有存下钱；负值 = 超支。收入 0 时显示占位。
  const savingRate =
    monthIncome > 0 ? ((monthIncome - monthExpense) / monthIncome) * 100 : null

  // 本月日均支出：取当月已过的天数为分母（含今天）。
  const now = new Date()
  const dayOfMonth = now.getDate()
  const avgDailyExpense = dayOfMonth > 0 ? monthExpense / dayOfMonth : 0

  // 累计每天笔数：全量 tx_count / 从首次记账到今天的天数。
  const totalTx = ledgerCounts?.tx_count ?? 0
  const totalDays = ledgerCounts?.days_since_first_tx ?? 0
  const avgTxPerDay = totalDays > 0 ? totalTx / totalDays : 0

  return (
    <div className="grid gap-4 md:grid-cols-3">
      {/* 卡 1：储蓄率 */}
      <div className="group relative overflow-hidden rounded-2xl border border-income/30 bg-card p-5 shadow-xs transition-all duration-200 hover:-translate-y-0.5 hover:shadow-md hover:border-income/50">
        <div
          className="pointer-events-none absolute inset-0 bg-gradient-to-br from-income/15 via-income/5 to-transparent"
          aria-hidden
        />
        <div
          className="pointer-events-none absolute -right-10 -top-10 h-28 w-28 rounded-full bg-income/20 blur-2xl"
          aria-hidden
        />
        <div className="relative flex items-center justify-between">
          <span className="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
            <span className="inline-flex h-7 w-7 items-center justify-center rounded-lg bg-income/15 text-income shadow-2xs">
              <PiggyBank className="h-4 w-4" />
            </span>
            {t('home.habit.savingRate')}
          </span>
        </div>
        <div className="relative mt-3 font-mono text-3xl font-extrabold tabular-nums tracking-tight leading-tight">
          {savingRate === null ? (
            <span className="text-muted-foreground">—</span>
          ) : (
            <span
              className={
                savingRate >= 0
                  ? 'text-income'
                  : 'text-expense'
              }
            >
              {savingRate.toFixed(1)}%
            </span>
          )}
        </div>
        <div className="relative mt-3">
          {/* 简单进度条 —— 0~100% 用绿，负数用红，超 100% 夹住 */}
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted/60">
            {savingRate !== null ? (
              <div
                className={
                  savingRate >= 0
                    ? 'h-full rounded-full bg-gradient-to-r from-income to-income/70'
                    : 'h-full rounded-full bg-gradient-to-r from-expense to-expense/70'
                }
                style={{
                  width: `${Math.min(100, Math.abs(savingRate))}%`
                }}
              />
            ) : null}
          </div>
        </div>
        <div className="relative mt-2 text-xs text-muted-foreground">
          {savingRate === null
            ? t('home.habit.savingRate.noIncome')
            : savingRate >= 0
              ? t('home.habit.savingRate.good').replace('{rate}', savingRate.toFixed(0))
              : t('home.habit.savingRate.bad')}
        </div>
      </div>

      {/* 卡 2：本月日均支出 */}
      <div className="group relative overflow-hidden rounded-2xl border border-expense/30 bg-card p-5 shadow-xs transition-all duration-200 hover:-translate-y-0.5 hover:shadow-md hover:border-expense/50">
        <div
          className="pointer-events-none absolute inset-0 bg-gradient-to-br from-expense/15 via-expense/5 to-transparent"
          aria-hidden
        />
        <div
          className="pointer-events-none absolute -right-10 -top-10 h-28 w-28 rounded-full bg-expense/20 blur-2xl"
          aria-hidden
        />
        <div className="relative flex items-center justify-between">
          <span className="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
            <span className="inline-flex h-7 w-7 items-center justify-center rounded-lg bg-expense/15 text-expense shadow-2xs">
              <Flame className="h-4 w-4" />
            </span>
            {t('home.habit.dailyExpense')}
          </span>
        </div>
        <Amount
          value={avgDailyExpense}
          currency={currency}
          showCurrency
          bold
          size="3xl"
          tone={avgDailyExpense > 0 ? 'negative' : 'default'}
          className="relative mt-3 block leading-tight font-mono tracking-tight"
        />
        <div className="relative mt-2 text-xs text-muted-foreground">
          {t('home.habit.dailyExpense.footer')
            .replace('{day}', String(dayOfMonth))
            .replace('{total}', monthExpense.toLocaleString(undefined, { maximumFractionDigits: 2 }))}
        </div>
      </div>

      {/* 卡 3：累计记账习惯 */}
      <div className="group relative overflow-hidden rounded-2xl border border-sky-500/30 bg-card p-5 shadow-xs transition-all duration-200 hover:-translate-y-0.5 hover:shadow-md hover:border-sky-500/50">
        <div
          className="pointer-events-none absolute inset-0 bg-gradient-to-br from-sky-500/15 via-sky-400/5 to-transparent"
          aria-hidden
        />
        <div
          className="pointer-events-none absolute -right-10 -top-10 h-28 w-28 rounded-full bg-sky-400/20 blur-2xl"
          aria-hidden
        />
        <div className="relative flex items-center justify-between">
          <span className="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
            <span className="inline-flex h-7 w-7 items-center justify-center rounded-lg bg-sky-500/15 text-sky-600 dark:text-sky-400 shadow-2xs">
              <Sparkles className="h-4 w-4" />
            </span>
            {t('home.habit.routine')}
          </span>
        </div>
        <div className="relative mt-3 font-mono text-3xl font-extrabold tabular-nums tracking-tight leading-tight">
          {avgTxPerDay.toFixed(2)}
          <span className="ml-1 text-sm font-normal text-muted-foreground">
            {t('home.habit.routine.unit')}
          </span>
        </div>
        <div className="relative mt-2 text-xs text-muted-foreground">
          {t('home.habit.routine.footer')
            .replace('{tx}', totalTx.toLocaleString())
            .replace('{days}', totalDays.toLocaleString())}
        </div>
      </div>
    </div>
  )
}
