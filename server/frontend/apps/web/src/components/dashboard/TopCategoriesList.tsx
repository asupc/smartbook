import { Card } from 'antd'
import { useT } from '@smartbook/ui'

interface Rank {
  category_name: string
  total: number
  tx_count: number
}

type Variant = 'expense' | 'income'

interface Props {
  ranks: Rank[]
  variant?: Variant
  title?: string
  onClickCategory?: (name: string) => void
}

export function TopCategoriesList({ ranks, variant = 'expense', title, onClickCategory }: Props) {
  const t = useT()
  const top = ranks.slice(0, 5)
  const maxTotal = Math.max(1, ...top.map((r) => r.total))
  // 占比基数:**所有分类总和**(不只 top 5),反映真实分布。如果只用 top 5
  // 的 total 算占比,top 1 永远是 100% 这种数字,信息量 = 0。
  const grandTotal = Math.max(1, ranks.reduce((sum, r) => sum + r.total, 0))

  const fmt = (v: number) =>
    v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  const fmtPct = (v: number) => {
    // < 1% 显示 "<1%",避免 "0.4%" 之类极小看着像 0
    if (v < 1) return v < 0.05 ? '0%' : '<1%'
    return `${Math.round(v)}%`
  }

  const isExpense = variant === 'expense'
  const barClass = isExpense
    ? 'bg-gradient-to-r from-expense/70 to-expense group-hover:from-expense group-hover:to-expense/90'
    : 'bg-gradient-to-r from-income/70 to-income group-hover:from-income group-hover:to-income/90'
  const defaultTitle = isExpense ? t('home.topCat.expenseTitle') : t('home.topCat.incomeTitle')
  const emptyLabel = isExpense ? t('home.topCat.empty.expense') : t('home.topCat.empty.income')

  return (
    <Card
      className="h-full overflow-hidden border border-border/60 shadow-xs transition-all duration-200 hover:shadow-md hover:border-primary/20"
      size="small"
      title={
        <div className="flex items-center gap-2">
          <span className={`flex h-5 w-5 items-center justify-center rounded-md text-xs ${
            isExpense ? 'bg-rose-500/10 text-rose-600' : 'bg-emerald-500/10 text-emerald-600'
          }`}>
            {isExpense ? '📉' : '📈'}
          </span>
          <span className="text-sm font-bold text-foreground">{title || defaultTitle}</span>
        </div>
      }
      styles={{ body: { padding: '16px 20px 20px', flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' } }}
    >
        {top.length === 0 ? (
          <div className="flex h-32 items-center justify-center text-xs text-muted-foreground">
            {emptyLabel}
          </div>
        ) : (
          <ul className="space-y-2">
            {top.map((r, i) => {
              // 进度条用 maxTotal 归一化(Top 1 = 满条 = 视觉锚点);
              // 占比文字用 grandTotal 归一化(反映真实份额)。
              const barPct = (r.total / maxTotal) * 100
              const sharePct = (r.total / grandTotal) * 100
              const rankBadgeClass =
                i === 0
                  ? 'bg-amber-500/15 text-amber-600 dark:text-amber-400 border border-amber-500/30'
                  : i === 1
                    ? 'bg-slate-400/15 text-slate-600 dark:text-slate-300 border border-slate-400/30'
                    : i === 2
                      ? 'bg-amber-700/15 text-amber-700 dark:text-amber-500 border border-amber-700/30'
                      : 'bg-muted text-muted-foreground border border-transparent'
              return (
                <li
                  key={r.category_name}
                  className={`group rounded-lg p-1.5 transition-all hover:bg-muted/40 ${onClickCategory ? 'cursor-pointer' : ''}`}
                  onClick={() => onClickCategory?.(r.category_name)}
                >
                  <div className="flex items-center justify-between text-sm">
                    <span className="inline-flex items-center gap-2.5">
                      <span className={`flex h-5 w-5 items-center justify-center rounded-md text-[11px] font-bold ${rankBadgeClass}`}>
                        {i + 1}
                      </span>
                      <span className="font-semibold text-foreground">{r.category_name || t('home.topCat.uncategorized')}</span>
                      <span className="rounded bg-muted/60 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground">{r.tx_count} {t('home.topCat.countUnit')}</span>
                    </span>
                    <span className="inline-flex items-baseline gap-2 font-mono tabular-nums">
                      <span className="text-sm font-bold text-foreground">{fmt(r.total)}</span>
                      <span className="rounded bg-muted/50 px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">
                        {fmtPct(sharePct)}
                      </span>
                    </span>
                  </div>
                  <div className="mt-1.5 h-1.5 w-full overflow-hidden rounded-full bg-muted/60">
                    <div
                      className={`h-full rounded-full transition-all ${barClass}`}
                      style={{ width: `${barPct}%` }}
                    />
                  </div>
                </li>
              )
            })}
          </ul>
        )}
    </Card>
  )
}
