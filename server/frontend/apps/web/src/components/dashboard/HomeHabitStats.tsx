import { Flame, PiggyBank, Sparkles } from 'lucide-react'

import type { WorkspaceAnalyticsSummary, WorkspaceLedgerCounts } from '@smartbook/api-client'
import {
  Amount,
  periodDaysElapsed,
  periodLengthDays,
  previousMonthRange,
  yearDaysElapsed,
} from '@smartbook/web-features'
import { useT } from '@smartbook/ui'

import type { HeroScope } from './HomeHero'

interface Props {
  /** 当前 hero 选中的周期,三张卡的标题/数值/脚注都跟随它滚动。 */
  scope: HeroScope
  /** 各周期 summary:储蓄率、日均支出、笔数的取值来源,拉取失败缺省。 */
  monthSummary?: WorkspaceAnalyticsSummary
  lastMonthSummary?: WorkspaceAnalyticsSummary
  yearSummary?: WorkspaceAnalyticsSummary
  allSummary?: WorkspaceAnalyticsSummary
  /** 全量 counts,「汇总」视角的分母(开账至今天数)。 */
  ledgerCounts?: WorkspaceLedgerCounts
  /** 当前账本记账起始日(1..28),周期天数分母的口径。 */
  ledgerMonthStartDay?: number
  currency?: string
}

const summaryForScope = (
  scope: HeroScope,
  s: {
    month?: WorkspaceAnalyticsSummary
    lastMonth?: WorkspaceAnalyticsSummary
    year?: WorkspaceAnalyticsSummary
    all?: WorkspaceAnalyticsSummary
  },
): WorkspaceAnalyticsSummary | undefined => s[scope]

/**
 * 三张小卡并排,数值随 hero 周期切换器(本月/上月/今年/汇总)滚动:
 *  - 储蓄率 = (收入 - 支出) / 收入。收入为 0 则"暂无收入"。
 *  - 日均支出 = 支出 / 周期天数。本月/今年取已过天数(含今天),上月取整周期
 *    天数,汇总取从首笔记账到今天的天数。
 *  - 记账习惯 = 周期笔数 / 同上分母;汇总视角即原"累计"口径。
 *
 * 目的:把用户"记账这件事本身"的行为数据做可视化,跟具体账目互补。
 */
export function HomeHabitStats({
  scope,
  monthSummary,
  lastMonthSummary,
  yearSummary,
  allSummary,
  ledgerCounts,
  ledgerMonthStartDay = 1,
  currency = 'CNY',
}: Props) {
  const t = useT()

  const summary = summaryForScope(scope, {
    month: monthSummary,
    lastMonth: lastMonthSummary,
    year: yearSummary,
    all: allSummary,
  })
  const income = summary?.income_total ?? 0
  const expense = summary?.expense_total ?? 0
  const txCount = summary?.transaction_count ?? 0
  const scopeLabel = t(`home.scope.${scope}`)

  // 分母天数:进行中的周期取已过天数(含今天);上月是完整周期取总天数;
  // 汇总取从首笔记账到今天的跨度,跟旧版"累计"口径一致。
  const days =
    scope === 'month'
      ? periodDaysElapsed(ledgerMonthStartDay)
      : scope === 'lastMonth'
        ? periodLengthDays(previousMonthRange(ledgerMonthStartDay))
        : scope === 'year'
          ? yearDaysElapsed(ledgerMonthStartDay)
          : ledgerCounts?.days_since_first_tx ?? 0
  const daysLabel = days.toLocaleString()

  // 储蓄率:正值 = 有存下钱;负值 = 超支。收入 0 时显示占位。
  const savingRate = income > 0 ? ((income - expense) / income) * 100 : null

  const avgDailyExpense = days > 0 ? expense / days : 0
  const avgTxPerDay = days > 0 ? txCount / days : 0

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
            {t('home.habit.savingRate').replace('{scope}', scopeLabel)}
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
            ? t('home.habit.savingRate.noIncome').replace('{scope}', scopeLabel)
            : savingRate >= 0
              ? t('home.habit.savingRate.good').replace('{rate}', savingRate.toFixed(0))
              : t('home.habit.savingRate.bad').replace('{scope}', scopeLabel)}
        </div>
      </div>

      {/* 卡 2：日均支出 */}
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
            {t('home.habit.dailyExpense').replace('{scope}', scopeLabel)}
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
          {scope === 'month'
            ? t('home.habit.dailyExpense.footer')
                .replace('{day}', daysLabel)
                .replace('{total}', expense.toLocaleString(undefined, { maximumFractionDigits: 2 }))
            : scope === 'lastMonth'
              ? t('home.habit.dailyExpense.footer.lastMonth')
                  .replace('{day}', daysLabel)
                  .replace('{total}', expense.toLocaleString(undefined, { maximumFractionDigits: 2 }))
              : scope === 'year'
                ? t('home.habit.dailyExpense.footer.year')
                    .replace('{day}', daysLabel)
                    .replace('{total}', expense.toLocaleString(undefined, { maximumFractionDigits: 2 }))
                : t('home.habit.dailyExpense.footer.all')
                    .replace('{day}', daysLabel)
                    .replace('{total}', expense.toLocaleString(undefined, { maximumFractionDigits: 2 }))}
        </div>
      </div>

      {/* 卡 3：记账习惯 */}
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
          {scope === 'all'
            ? t('home.habit.routine.footer')
                .replace('{tx}', txCount.toLocaleString())
                .replace('{days}', daysLabel)
            : scope === 'lastMonth'
              ? t('home.habit.routine.footer.full')
                  .replace('{scope}', scopeLabel)
                  .replace('{tx}', txCount.toLocaleString())
                  .replace('{days}', daysLabel)
              : t('home.habit.routine.footer.progress')
                  .replace('{scope}', scopeLabel)
                  .replace('{tx}', txCount.toLocaleString())
                  .replace('{days}', daysLabel)}
        </div>
      </div>
    </div>
  )
}
