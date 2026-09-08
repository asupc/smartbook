import { useMemo } from 'react'
import { Card } from 'antd'
import { useT } from '@smartbook/ui'

import type { WorkspaceTag } from '@smartbook/api-client'
import { Amount } from '@smartbook/web-features'

interface Props {
  tags: WorkspaceTag[]
  currency?: string
  /** 点击某行 → 打开标签详情弹窗。优先级高于 onClickTag。 */
  onSelectTag?: (tag: WorkspaceTag) => void
  /** 老接口:仅传 tag 名,跳搜索之类的场景用。`onSelectTag` 没传时才生效。 */
  onClickTag?: (name: string) => void
}

/**
 * 使用最多的标签 Top 5。按 `tx_count` 降序，右侧显示笔数 + 当年支出金额。
 * bar 宽度相对第一名归一，一眼看出头部和尾部的差距。
 */
export function HomeTopTags({ tags, currency = 'CNY', onSelectTag, onClickTag }: Props) {
  const t = useT()
  const top = useMemo(() => {
    // 内层 map 回调故意不叫 t 避免和上面 useT() 的 t 冲突
    const withStats = tags
      .map((tag) => ({
        raw: tag,
        id: tag.id,
        name: tag.name,
        color: tag.color || '#94a3b8',
        count: tag.tx_count ?? 0,
        expense: tag.expense_total ?? 0
      }))
      .filter((tag) => tag.count > 0)
      .sort((a, b) => b.count - a.count)
      .slice(0, 5)
    const maxCount = withStats[0]?.count ?? 0
    return { list: withStats, maxCount }
  }, [tags])
  const clickable = Boolean(onSelectTag || onClickTag)

  return (
    <Card
      className="h-full overflow-hidden border border-border/60 shadow-xs transition-all duration-200 hover:shadow-md hover:border-primary/20"
      size="small"
      title={
        <div className="flex items-center gap-2">
          <span className="flex h-5 w-5 items-center justify-center rounded-md bg-purple-500/10 text-purple-600 text-xs">
            🏷️
          </span>
          <span className="text-sm font-bold text-foreground">{t('home.topTags.title')}</span>
        </div>
      }
      styles={{ body: { padding: '16px 20px 20px', flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' } }}
    >
        {top.list.length === 0 ? (
          <div className="flex h-32 items-center justify-center text-xs text-muted-foreground">
            {t('home.topTags.empty')}
          </div>
        ) : (
          <ul className="space-y-2">
            {top.list.map((tag, i) => {
              const pct = top.maxCount > 0 ? (tag.count / top.maxCount) * 100 : 0
              return (
                <li
                  key={tag.id || `${tag.name}-${i}`}
                  className={`group relative flex items-center gap-3 rounded-lg p-1.5 transition-all hover:bg-muted/40 ${
                    clickable ? 'cursor-pointer' : ''
                  }`}
                  onClick={() => {
                    if (onSelectTag) onSelectTag(tag.raw)
                    else onClickTag?.(tag.name)
                  }}
                >
                  <span
                    className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl text-xs font-bold text-white shadow-xs"
                    style={{ background: tag.color }}
                    aria-hidden
                  >
                    #
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate text-sm font-semibold text-foreground">{tag.name}</span>
                      <div className="shrink-0 text-xs text-muted-foreground">
                        <span className="rounded bg-muted/60 px-1.5 py-0.5 font-mono text-[10px] font-semibold tabular-nums text-muted-foreground">
                          {tag.count} {t('home.topTags.countUnit')}
                        </span>
                      </div>
                    </div>
                    <div className="mt-1.5 flex items-center gap-2">
                      <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted/60">
                        <div
                          className="h-full rounded-full transition-all"
                          style={{
                            width: `${pct}%`,
                            background: tag.color
                          }}
                        />
                      </div>
                      {tag.expense > 0 ? (
                        <Amount
                          value={tag.expense}
                          currency={currency}
                          size="xs"
                          bold
                          tone="muted"
                          className="shrink-0 font-mono"
                        />
                      ) : null}
                    </div>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
    </Card>
  )
}
