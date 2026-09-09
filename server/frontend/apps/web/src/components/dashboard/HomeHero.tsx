import { useMemo, useState } from 'react'
import { Area, AreaChart, ResponsiveContainer, Tooltip } from 'recharts'
import {
  ArrowDownLeft,
  ArrowRight,
  ArrowUpRight,
  CalendarDays,
  Receipt,
  Sparkles,
} from 'lucide-react'

import type {
  ReadBudget,
  ReadLedger,
  WorkspaceAnalyticsAnomalyMonth,
  WorkspaceAnalyticsSeriesItem,
  WorkspaceAnalyticsSummary
} from '@smartbook/api-client'
import { Amount, periodRangeText, previousPeriodRangeText, type BudgetUsage } from '@smartbook/web-features'
import { useT } from '@smartbook/ui'

import { HeroInsightsRow } from './HeroInsightsRow'

export type HeroScope = 'month' | 'lastMonth' | 'year' | 'all'

interface Props {
  ledgers: ReadLedger[]
  currentLedgerId?: string
  monthSummary?: WorkspaceAnalyticsSummary
  monthSeries?: WorkspaceAnalyticsSeriesItem[]
  /** 上月(记账周期口径)收支;拉取失败时缺省,视角内显示空态。 */
  lastMonthSummary?: WorkspaceAnalyticsSummary
  lastMonthSeries?: WorkspaceAnalyticsSeriesItem[]
  yearSummary?: WorkspaceAnalyticsSummary
  yearSeries?: WorkspaceAnalyticsSeriesItem[]
  allSummary?: WorkspaceAnalyticsSummary
  allSeries?: WorkspaceAnalyticsSeriesItem[]
  /** 当前账本预算配置 + 当周期 used,空数组 → chip 不显示。 */
  budgets?: ReadBudget[]
  budgetUsageById?: Record<string, BudgetUsage>
  /** 异常月份(scope=year analytics 返回),空数组 + hasEnoughMonths=true 显示 ✓ */
  anomalyMonths?: WorkspaceAnalyticsAnomalyMonth[]
  hasEnoughMonthsForAnomaly?: boolean
  /** 受控 scope:父级(OverviewSection)需要同一状态喂给 HomeHabitStats 等卡,
   *  传入后切换器走 onScopeChange 上报;不传则组件内部自持(向后兼容)。 */
  scope?: HeroScope
  onScopeChange?: (scope: HeroScope) => void
  onOpenAnnualReport?: (year?: number) => void
}

// 四个 scope 的 label/hint 在组件里 t() 时动态查,这里只留 value 列表
const SCOPE_VALUES: HeroScope[] = ['month', 'lastMonth', 'year', 'all']

/**
 * 首页 hero 卡。四视角切换（本月 / 上月 / 今年 / 汇总）：
 * - 大号结余 = 对应 scope 的 income - expense（对齐 mobile `monthlyTotals` /
 *   `yearlyTotals` / 全量聚合）
 * - 本月/上月/今年/全部 收入 + 支出 两个 HeroStat 跟随 scope 变
 * - 记账笔数 / 记账天数 同样跟随 scope:取对应周期 summary 的
 *   transaction_count / distinct_days(周期内有记账的天数),与收支同源
 * - 右侧 sparkline: month / lastMonth 按日累计；year / all 按月累计
 */
export function HomeHero({
  ledgers,
  currentLedgerId,
  monthSummary,
  monthSeries,
  lastMonthSummary,
  lastMonthSeries,
  yearSummary,
  yearSeries,
  allSummary,
  allSeries,
  budgets,
  budgetUsageById,
  anomalyMonths,
  hasEnoughMonthsForAnomaly,
  scope: scopeProp,
  onScopeChange,
  onOpenAnnualReport,
}: Props) {
  const t = useT()
  const [fallbackScope, setFallbackScope] = useState<HeroScope>('month')
  const scope = scopeProp ?? fallbackScope
  const setScope = (next: HeroScope) => {
    setFallbackScope(next)
    onScopeChange?.(next)
  }

  const activeLedger =
    ledgers.find((l) => l.ledger_id === currentLedgerId) || ledgers[0]
  const currency = activeLedger?.currency || 'CNY'
  const ledgerMonthStartDay = Math.max(1, Math.min(28, activeLedger?.month_start_day ?? 1))

  const summaryByScope: Record<HeroScope, WorkspaceAnalyticsSummary | undefined> = {
    month: monthSummary,
    lastMonth: lastMonthSummary,
    year: yearSummary,
    all: allSummary
  }
  const seriesByScope: Record<HeroScope, WorkspaceAnalyticsSeriesItem[]> = {
    month: monthSeries || [],
    lastMonth: lastMonthSeries || [],
    year: yearSeries || [],
    all: allSeries || []
  }

  const activeSummary = summaryByScope[scope]
  const activeSeries = seriesByScope[scope]
  const scopeLabel = t(`home.scope.${scope}`)
  const scopeBalanceHint = t(`home.scope.${scope}.hint`)
  const periodRangeLabel =
    scope === 'month'
      ? periodRangeText(ledgerMonthStartDay)
      : scope === 'lastMonth'
        ? previousPeriodRangeText(ledgerMonthStartDay)
        : null

  const income = activeSummary?.income_total ?? 0
  const expense = activeSummary?.expense_total ?? 0
  const balance = activeSummary?.balance ?? income - expense

  // 笔数 / 天数跟随 scope:取对应周期 summary 的 transaction_count /
  // distinct_days(周期内有记账的天数),与收入/支出同口径滚动。
  const txCount = activeSummary?.transaction_count ?? 0
  const days = activeSummary?.distinct_days ?? 0

  // sparkline: 本月按日累计；年/全部按月累计。series 已按 bucket 分桶。
  const trendData = useMemo(() => {
    const sorted = activeSeries.slice().sort((a, b) => a.bucket.localeCompare(b.bucket))
    let running = 0
    return sorted.map((it) => {
      running += (it.income || 0) - (it.expense || 0)
      return { bucket: it.bucket, v: running }
    })
  }, [activeSeries])

  return (
    // overflow-visible:hero 内的 InsightsRow chip 用 popover 浮出详情,需要
    // 越出 hero 边界。装饰光斑挪到内层 overflow-hidden 子层去 clip。
    <div
      className="relative rounded-2xl border border-primary/25 shadow-xs"
      style={{
        background:
          'linear-gradient(135deg, hsl(var(--primary)/0.15) 0%, hsl(var(--primary)/0.03) 55%, transparent 100%)'
      }}
    >
      {/* 装饰光斑容器 — 单独 overflow-hidden + inset-0 + rounded-2xl 跟父
           容器对齐,光斑不漏到 hero 外。popover absolute 定位在 grid 容器
           内,跟这层平级,不被 clip。 */}
      <div
        className="pointer-events-none absolute inset-0 overflow-hidden rounded-2xl"
        aria-hidden
      >
        <div className="absolute -right-20 -top-20 h-72 w-72 rounded-full bg-primary/30 blur-3xl" />
        <div className="absolute -left-24 bottom-0 h-56 w-56 rounded-full bg-primary/15 blur-3xl" />
      </div>

      {/* 窄屏 p-4 / 桌面 p-6:mobile 视口下 hero 体积大,内容只占一列时
           24px padding 显得很空,16px 紧凑但不挤。grid gap 同步收一点。 */}
      <div className="relative grid gap-4 p-4 sm:gap-5 sm:p-6 lg:grid-cols-[1.4fr_1fr]">
        <div className="min-w-0">
          {/* 顶部：账本名 + 三视角切换 */}
          <div className="flex items-center justify-between gap-3">
            <div className="min-w-0">
              {/* flex-wrap + 分段 nowrap:窄屏被右侧切换器挤压时整段换行,
                  而不是 CJK 逐字断行(范围括号最多整体掉到第二行) */}
              <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] font-semibold uppercase tracking-[0.22em] text-muted-foreground">
                <CalendarDays className="h-3 w-3 shrink-0" />
                <span className="whitespace-nowrap">
                  {t('home.scope.current')} · {scopeLabel}
                </span>
                {periodRangeLabel && (
                  <span className="whitespace-nowrap font-normal normal-case tracking-normal text-muted-foreground/70">
                    ({periodRangeLabel})
                  </span>
                )}
              </div>
              <div className="mt-1 flex items-baseline gap-3">
                <span className="truncate text-xl font-bold">
                  {activeLedger?.ledger_name || '—'}
                </span>
                <span className="rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 text-[10px] font-medium text-primary">
                  {currency}
                </span>
              </div>
            </div>
            <div className="shrink-0">
              <ScopeSwitcher value={scope} onChange={setScope} />
            </div>
          </div>

          <div className="mt-4 text-[10px] font-semibold uppercase tracking-[0.22em] text-muted-foreground">
            {scopeBalanceHint}
          </div>
          <Amount
            value={balance}
            showCurrency
            currency={currency}
            size="4xl"
            bold
            animate
            tone={balance >= 0 ? 'positive' : 'negative'}
            className="mt-1 block font-black tracking-tight"
          />

          <div className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
            <HeroStat
              icon={<ArrowDownLeft className="h-3.5 w-3.5 text-income" />}
              label={t('home.hero.income').replace('{scope}', scopeLabel)}
              className="bee-rise-in"
              style={{ animationDelay: '0ms' }}
            >
              <Amount
                value={income}
                currency={currency}
                showCurrency
                bold
                animate
                animateDelay={0.45}
                size="xl"
                tone="positive"
                className="mt-0.5 block leading-tight"
              />
            </HeroStat>
            <HeroStat
              icon={<ArrowUpRight className="h-3.5 w-3.5 text-expense" />}
              label={t('home.hero.expense').replace('{scope}', scopeLabel)}
              className="bee-rise-in"
              style={{ animationDelay: '110ms' }}
            >
              <Amount
                value={expense}
                currency={currency}
                showCurrency
                bold
                animate
                animateDelay={0.55}
                size="xl"
                tone="negative"
                className="mt-0.5 block leading-tight"
              />
            </HeroStat>
            <HeroStat
              icon={<Receipt className="h-3.5 w-3.5 text-amber-500" />}
              label={t('home.hero.count').replace('{scope}', scopeLabel)}
              className="bee-rise-in"
              style={{ animationDelay: '220ms' }}
            >
              <div className="mt-0.5 font-mono text-xl font-bold tabular-nums leading-tight">
                {txCount.toLocaleString()}
                <span className="ml-1 text-[11px] font-normal text-muted-foreground">
                  {t('home.hero.countUnit')}
                </span>
              </div>
            </HeroStat>
            <HeroStat
              icon={<CalendarDays className="h-3.5 w-3.5 text-sky-500" />}
              label={t('home.hero.days').replace('{scope}', scopeLabel)}
              className="bee-rise-in"
              style={{ animationDelay: '330ms' }}
            >
              <div className="mt-0.5 font-mono text-xl font-bold tabular-nums leading-tight">
                {days.toLocaleString()}
                <span className="ml-1 text-[11px] font-normal text-muted-foreground">
                  {t('home.hero.daysUnit')}
                </span>
              </div>
            </HeroStat>
          </div>

          {/* 预算 + 异常归因 chip — 关键回顾信息一行带过,hover 出详情 */}
          <HeroInsightsRow
            budgets={budgets || []}
            budgetUsageById={budgetUsageById || {}}
            anomalyMonths={anomalyMonths || []}
            hasEnoughMonths={!!hasEnoughMonthsForAnomaly}
            currency={currency}
            ledgerMonthStartDay={ledgerMonthStartDay}
          />

          {scope === 'year' && onOpenAnnualReport ? (
            <div className="mt-3">
              <button
                type="button"
                onClick={() => onOpenAnnualReport(new Date().getFullYear())}
                className="group inline-flex items-center gap-1.5 rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-[11px] font-medium text-primary hover:bg-primary/20 transition-all shadow-xs cursor-pointer"
              >
                <Sparkles className="h-3.5 w-3.5 text-amber-500 animate-pulse" />
                <span>{t('home.hero.annualReportCta')}</span>
                <ArrowRight className="h-3 w-3 transition-transform group-hover:translate-x-0.5" />
              </button>
            </div>
          ) : null}
        </div>

        {/* 右侧：sparkline，随 scope 变 */}
        <div className="flex min-h-[220px] flex-col justify-between rounded-2xl border border-border/60 bg-background/75 p-4 shadow-xs backdrop-blur-md transition-all hover:border-primary/30">
          <div className="flex items-center justify-between text-[11px] uppercase tracking-wider text-muted-foreground">
            <span className="font-medium text-foreground/80">{t('home.hero.trend').replace('{scope}', scopeLabel)}</span>
            {trendData.length > 0 ? (
              <span className="rounded-md bg-muted/60 px-1.5 py-0.5 font-mono text-[10px] font-semibold tabular-nums text-muted-foreground">
                {trendData.length}
                {scope === 'month' || scope === 'lastMonth'
                  ? t('home.hero.trendUnit.day')
                  : scope === 'year'
                    ? t('home.hero.trendUnit.month')
                    : t('home.hero.trendUnit.period')}
              </span>
            ) : null}
          </div>
          <div className="flex-1">
            {trendData.length > 1 ? (
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart
                  data={trendData}
                  margin={{ left: 0, right: 0, top: 4, bottom: 0 }}
                >
                  <defs>
                    <linearGradient id="homeHeroGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop
                        offset="5%"
                        stopColor="hsl(var(--primary))"
                        stopOpacity={0.45}
                      />
                      <stop
                        offset="95%"
                        stopColor="hsl(var(--primary))"
                        stopOpacity={0.0}
                      />
                    </linearGradient>
                  </defs>
                  <Tooltip
                    cursor={false}
                    contentStyle={{
                      background: 'hsl(var(--popover))',
                      border: '1px solid hsl(var(--border))',
                      borderRadius: 8,
                      fontSize: 12,
                      boxShadow: '0 4px 12px rgba(0, 0, 0, 0.1)',
                    }}
                    formatter={
                      ((v: number) => [
                        v.toLocaleString(undefined, { maximumFractionDigits: 2 }),
                        t('home.hero.balanceAccum')
                      ]) as unknown as never
                    }
                    labelFormatter={(_label, payload) => {
                      const item = payload?.[0]?.payload as { bucket?: string }
                      return item?.bucket || ''
                    }}
                  />
                  <Area
                    type="monotone"
                    dataKey="v"
                    stroke="hsl(var(--primary))"
                    strokeWidth={2.5}
                    fill="url(#homeHeroGrad)"
                  />
                </AreaChart>
              </ResponsiveContainer>
            ) : (
              <div className="flex h-full items-center justify-center text-xs text-muted-foreground">
                {t('home.hero.noTx')}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

function ScopeSwitcher({
  value,
  onChange
}: {
  value: HeroScope
  onChange: (v: HeroScope) => void
}) {
  const t = useT()
  return (
    <div className="inline-flex rounded-xl border border-border/70 bg-background/80 p-1 shadow-xs backdrop-blur-md">
      {SCOPE_VALUES.map((scope) => {
        const active = scope === value
        return (
          <button
            key={scope}
            type="button"
            onClick={() => onChange(scope)}
            className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-all ${
              active
                ? 'bg-primary text-primary-foreground shadow-sm'
                : 'text-muted-foreground hover:text-foreground'
            }`}
          >
            {t(`home.scope.${scope}`)}
          </button>
        )
      })}
    </div>
  )
}

function HeroStat({
  icon,
  label,
  children,
  className,
  style
}: {
  icon: React.ReactNode
  label: string
  children: React.ReactNode
  className?: string
  style?: React.CSSProperties
}) {
  return (
    <div
      className={`rounded-xl border border-border/60 bg-background/75 p-3 shadow-xs backdrop-blur-md transition-all duration-200 hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md hover:bg-background/90${className ? ` ${className}` : ''}`}
      style={style}
    >
      <div className="flex items-center gap-1.5 text-[10.5px] font-medium uppercase tracking-wider text-muted-foreground">
        <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-md bg-muted/60">
          {icon}
        </span>
        <span className="truncate">{label}</span>
      </div>
      <div className="mt-1">{children}</div>
    </div>
  )
}
