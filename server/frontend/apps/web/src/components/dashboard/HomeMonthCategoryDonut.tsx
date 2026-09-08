import { useMemo } from 'react'
import { Card } from 'antd'
import { useT } from '@smartbook/ui'

import type { WorkspaceAnalyticsCategoryRank } from '@smartbook/api-client'
import { Amount } from '@smartbook/web-features'

interface Props {
  /** 本月支出类别排行（scope=month&metric=expense 返回的 category_ranks）。 */
  ranks: WorkspaceAnalyticsCategoryRank[]
  currency?: string
}

/**
 * 本月支出分类占比环。SVG conic-gradient 做分段，Top 5 各一段，之外合并为
 * "其他"。参考 `AccountsPanel.AssetsCompositionMini`，同样风格避免引入 recharts
 * 分段饼图的多余依赖。
 */
export function HomeMonthCategoryDonut({ ranks, currency = 'CNY' }: Props) {
  const t = useT()
  const otherLabel = t('home.monthDonut.other')
  const { slices, total } = useMemo(() => {
    const sorted = ranks
      .slice()
      .sort((a, b) => b.total - a.total)
      .filter((r) => r.total > 0)
    const top = sorted.slice(0, 5)
    const rest = sorted.slice(5)
    const restTotal = rest.reduce((s, r) => s + r.total, 0)
    const restCount = rest.reduce((s, r) => s + r.tx_count, 0)
    const all = top.map((r) => ({
      name: r.category_name || t('home.monthDonut.uncategorized'),
      total: r.total,
      count: r.tx_count
    }))
    if (restTotal > 0) {
      all.push({ name: otherLabel, total: restTotal, count: restCount })
    }
    const sum = all.reduce((s, r) => s + r.total, 0)
    return { slices: all, total: sum }
  }, [ranks, otherLabel, t])

  // 配色：前 5 用 SmartBook mobile 常用调色盘，"其他"用中性灰
  const PALETTE = ['#ef4444', '#f59e0b', '#3b82f6', '#10b981', '#a855f7']
  const OTHER_COLOR = '#94a3b8'

  const conic = useMemo(() => {
    if (total <= 0) return 'hsl(var(--muted))'
    let acc = 0
    const stops: string[] = []
    slices.forEach((s, i) => {
      const color = s.name === otherLabel ? OTHER_COLOR : PALETTE[i % PALETTE.length]
      const start = (acc / total) * 100
      acc += s.total
      const end = (acc / total) * 100
      stops.push(`${color} ${start.toFixed(3)}% ${end.toFixed(3)}%`)
    })
    return `conic-gradient(from -90deg, ${stops.join(',')})`
  }, [slices, total, otherLabel])

  return (
    <Card
      className="h-full overflow-hidden border border-border/60 shadow-xs transition-all duration-200 hover:shadow-md hover:border-primary/20"
      size="small"
      title={
        <div className="flex items-center gap-2">
          <span className="flex h-5 w-5 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 text-xs">
            🥧
          </span>
          <span className="text-sm font-bold text-foreground">{t('home.monthDonut.title')}</span>
        </div>
      }
      extra={
        <span className="text-[11px] text-muted-foreground">
          {t('home.monthDonut.total')}{' '}
          <Amount
            value={total}
            currency={currency}
            size="xs"
            tone="negative"
            bold
            className="inline"
          />
        </span>
      }
      styles={{ body: { padding: '16px 20px 20px', flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' } }}
    >
        {slices.length === 0 ? (
          <div className="flex h-48 items-center justify-center text-xs text-muted-foreground">
            {t('home.monthDonut.empty')}
          </div>
        ) : (
          <div className="flex items-center gap-5">
            <div className="relative h-40 w-40 shrink-0">
              <div
                className="absolute inset-0 rounded-full"
                style={{ background: conic }}
                aria-hidden
              />
              <div className="absolute inset-[18%] rounded-full bg-card" aria-hidden />
              <div className="absolute inset-0 flex flex-col items-center justify-center">
                <div className="text-[10px] uppercase tracking-wider text-muted-foreground">
                  {t('home.monthDonut.center')}
                </div>
                <Amount
                  value={total}
                  currency={currency}
                  size="sm"
                  bold
                  tone="negative"
                  className="mt-0.5"
                />
                <div className="mt-0.5 text-[10px] text-muted-foreground">
                  {t('home.monthDonut.categoryCount').replace('{count}', String(slices.length))}
                </div>
              </div>
            </div>
            <ul className="min-w-0 flex-1 space-y-2">
              {slices.map((s, i) => {
                const color =
                  s.name === otherLabel ? OTHER_COLOR : PALETTE[i % PALETTE.length]
                const pct = total > 0 ? (s.total / total) * 100 : 0
                return (
                  <li key={`${s.name}-${i}`} className="flex items-center gap-2.5 text-xs">
                    <span
                      className="h-2.5 w-2.5 shrink-0 rounded-sm shadow-xs"
                      style={{ background: color }}
                      aria-hidden
                    />
                    <span className="flex-1 truncate font-medium text-foreground">{s.name}</span>
                    <span className="rounded bg-muted/60 px-1.5 py-0.5 font-mono text-[10.5px] font-semibold tabular-nums text-muted-foreground">
                      {pct.toFixed(1)}%
                    </span>
                    <Amount
                      value={s.total}
                      currency={currency}
                      size="xs"
                      bold
                      className="w-20 text-right font-mono"
                    />
                  </li>
                )
              })}
            </ul>
          </div>
        )}
    </Card>
  )
}
