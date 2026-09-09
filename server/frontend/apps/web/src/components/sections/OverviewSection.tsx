import type {
  ReadBudget,
  WorkspaceAccount,
  WorkspaceAnalytics,
  WorkspaceAnalyticsSeriesItem,
  WorkspaceAnalyticsSummary,
  WorkspaceLedgerCounts,
  WorkspaceTag
} from '@smartbook/api-client'
import { useT } from '@smartbook/ui'
import type { BudgetUsage } from '@smartbook/web-features'

import { Layers, TrendingUp } from 'lucide-react'
import { useState } from 'react'
import { useLedgers } from '../../context/LedgersContext'
import {
  dispatchOpenDetailAccount,
  dispatchOpenDetailTag,
} from '../../lib/txDialogEvents'
import { HomeHero, type HeroScope } from '../dashboard/HomeHero'
import { HomeHabitStats } from '../dashboard/HomeHabitStats'
import { HomeYearHeatmap } from '../dashboard/HomeYearHeatmap'
import { HomeMonthCategoryDonut } from '../dashboard/HomeMonthCategoryDonut'
import { HomeTopTags } from '../dashboard/HomeTopTags'
import { HomeTopAccounts } from '../dashboard/HomeTopAccounts'
import { AssetCompositionDonut } from '../dashboard/AssetCompositionDonut'
import { MonthlyTrendBars } from '../dashboard/MonthlyTrendBars'
import { TopCategoriesList } from '../dashboard/TopCategoriesList'

interface Props {
  accounts: WorkspaceAccount[]
  tags: WorkspaceTag[]
  currentMonthSummary: WorkspaceAnalyticsSummary | null
  currentMonthSeries: WorkspaceAnalyticsSeriesItem[]
  currentMonthCategoryRanks: WorkspaceAnalytics['category_ranks']
  /** 上月(记账周期口径)收支 — hero「上月」视角,拉取失败时为 null。 */
  lastMonthSummary: WorkspaceAnalyticsSummary | null
  lastMonthSeries: WorkspaceAnalyticsSeriesItem[]
  currentYearSummary: WorkspaceAnalyticsSummary | null
  currentYearSeries: WorkspaceAnalyticsSeriesItem[]
  allTimeSummary: WorkspaceAnalyticsSummary | null
  allTimeSeries: WorkspaceAnalyticsSeriesItem[]
  analyticsData: WorkspaceAnalytics | null
  analyticsIncomeRanks: WorkspaceAnalytics['category_ranks']
  ledgerCounts: WorkspaceLedgerCounts | null
  /** 当前账本预算 + 各 budget 当周期 used。空数组 → BudgetUsagePanel 不显示。 */
  budgets: ReadBudget[]
  budgetUsageById: Record<string, BudgetUsage>
  onJumpToTransactionsWithQuery: (query: string) => void
  /** Top 卡片点击分类名时的钩子 — page 端反查 WorkspaceCategory 后派发详情。
   *  没传则 Top 卡片回退到 onJumpToTransactionsWithQuery。 */
  onCategoryClickFromTop?: (name: string, kind: 'expense' | 'income') => void
  onOpenAnnualReport?: (year?: number) => void
}

/**
 * 首页 overview dashboard —— 从 AppPage.tsx 抽出独立组件。
 *
 * 渲染顺序对应 mobile 首页对标 + Web 独有扩展分析:
 *   - HomeHero:核心指标(本月/本年/全期)+ 账本列表 hero
 *   - HomeHabitStats:习惯画像(连续记账天数等)
 *   - [扩展分析分割线]
 *   - HomeMonthCategoryDonut + HomeYearHeatmap 并排
 *   - AssetCompositionDonut + MonthlyTrendBars 并排
 *   - TopCategoriesList(支出 + 收入)并排
 *   - HomeTopTags + HomeTopAccounts 并排
 */
export function OverviewSection({
  accounts,
  tags,
  currentMonthSummary,
  currentMonthSeries,
  currentMonthCategoryRanks,
  lastMonthSummary,
  lastMonthSeries,
  currentYearSummary,
  currentYearSeries,
  allTimeSummary,
  allTimeSeries,
  analyticsData,
  analyticsIncomeRanks,
  ledgerCounts,
  budgets,
  budgetUsageById,
  onJumpToTransactionsWithQuery,
  onCategoryClickFromTop,
  onOpenAnnualReport,
}: Props) {
  const t = useT()
  const { ledgers, activeLedgerId, currency } = useLedgers()

  // hero 周期切换器状态提升:HomeHabitStats 三张小卡的数值/文案跟随同一 scope
  const [heroScope, setHeroScope] = useState<HeroScope>('month')

  const activeLedger =
    ledgers.find((l) => l.ledger_id === activeLedgerId) || ledgers[0]
  const ledgerMonthStartDay = Math.max(
    1,
    Math.min(28, activeLedger?.month_start_day ?? 1),
  )

  // 预算 + 异常归因被合并进 HomeHero 顶部 chip(hover 出详情),不再独占
  // 卡片占首页空间。月份够算 baseline 的判定跟 server 算法一致(已发生月份 ≥ 3)。
  const yearOccurredMonths = (analyticsData?.series || []).filter(
    (s) => s.expense > 0,
  ).length

  return (
    <div className="space-y-6">
      <HomeHero
        ledgers={ledgers}
        currentLedgerId={activeLedgerId || undefined}
        monthSummary={currentMonthSummary || undefined}
        monthSeries={currentMonthSeries}
        lastMonthSummary={lastMonthSummary || undefined}
        lastMonthSeries={lastMonthSeries}
        yearSummary={currentYearSummary || undefined}
        yearSeries={currentYearSeries}
        allSummary={allTimeSummary || undefined}
        allSeries={allTimeSeries}
        budgets={budgets}
        budgetUsageById={budgetUsageById}
        anomalyMonths={analyticsData?.anomaly_months || []}
        hasEnoughMonthsForAnomaly={yearOccurredMonths >= 3}
        scope={heroScope}
        onScopeChange={setHeroScope}
        onOpenAnnualReport={onOpenAnnualReport}
      />

      <HomeHabitStats
        scope={heroScope}
        monthSummary={currentMonthSummary || undefined}
        lastMonthSummary={lastMonthSummary || undefined}
        yearSummary={currentYearSummary || undefined}
        allSummary={allTimeSummary || undefined}
        ledgerCounts={ledgerCounts || undefined}
        ledgerMonthStartDay={ledgerMonthStartDay}
        currency={currency}
      />

      {/* 分区 2: 走势与资产结构 */}
      <div className="flex flex-wrap items-center justify-between gap-3 pt-2 border-t border-border/60">
        <div className="flex items-center gap-2.5">
          <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary/10 text-primary shadow-xs">
            <TrendingUp size={15} />
          </div>
          <div>
            <h3 className="text-sm font-bold text-foreground tracking-tight">收支趋势与资产结构</h3>
            <p className="text-xs text-muted-foreground">月度支出分类、全年度支出热力、资产构成与 12 期走势</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <span className="inline-flex items-center gap-1.5 rounded-full border border-primary/20 bg-primary/5 px-2.5 py-0.5 text-[11px] font-medium text-primary">
            <span className="h-1.5 w-1.5 rounded-full bg-primary animate-pulse" />
            {t('analytics.ext.title')}
          </span>
        </div>
      </div>

      <div className="grid gap-5 lg:grid-cols-2 items-stretch">
        <HomeMonthCategoryDonut ranks={currentMonthCategoryRanks} currency={currency} />
        <HomeYearHeatmap
          yearSeries={currentYearSeries}
          currency={currency}
          onOpenAnnualReport={onOpenAnnualReport}
        />
      </div>

      <div className="grid gap-5 lg:grid-cols-2 items-stretch">
        <AssetCompositionDonut accounts={accounts} />
        <MonthlyTrendBars data={analyticsData?.series || []} />
      </div>

      {/* 分区 3: 分类排行与高频资产 */}
      <div className="flex flex-wrap items-center justify-between gap-3 pt-2 border-t border-border/60">
        <div className="flex items-center gap-2.5">
          <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-indigo-500/10 text-indigo-600 shadow-xs">
            <Layers size={15} />
          </div>
          <div>
            <h3 className="text-sm font-bold text-foreground tracking-tight">分类排行与高频资产</h3>
            <p className="text-xs text-muted-foreground">收支 Top 5 分类分布、常用标签与高频活跃账户</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <span className="inline-flex items-center gap-1 rounded-full border border-border/70 bg-muted/40 px-2.5 py-0.5 text-[11px] font-medium text-muted-foreground">
            Top 5 洞察
          </span>
        </div>
      </div>

      <div className="grid gap-5 md:grid-cols-2 items-stretch">
        <TopCategoriesList
          ranks={analyticsData?.category_ranks || []}
          variant="expense"
          title={t('analytics.expenseTop5')}
          onClickCategory={
            onCategoryClickFromTop
              ? (name) => onCategoryClickFromTop(name, 'expense')
              : onJumpToTransactionsWithQuery
          }
        />
        <TopCategoriesList
          ranks={analyticsIncomeRanks}
          variant="income"
          title={t('analytics.incomeTop5')}
          onClickCategory={
            onCategoryClickFromTop
              ? (name) => onCategoryClickFromTop(name, 'income')
              : onJumpToTransactionsWithQuery
          }
        />
      </div>

      <div className="grid gap-5 md:grid-cols-2 items-stretch">
        <HomeTopTags
          tags={tags}
          currency={currency}
          onSelectTag={(tag) =>
            dispatchOpenDetailTag(tag, { defaultScope: 'current' })
          }
        />
        <HomeTopAccounts
          accounts={accounts}
          currency={currency}
          onSelectAccount={(acc) =>
            dispatchOpenDetailAccount(acc, { defaultScope: 'current' })
          }
        />
      </div>
    </div>
  )
}
