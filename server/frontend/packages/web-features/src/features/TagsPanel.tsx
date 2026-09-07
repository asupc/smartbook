import { useCallback, useEffect, useMemo, useState, type ChangeEvent } from 'react'

import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  EmptyState,
  Input,
  Label,
  useT
} from '@smartbook/ui'

import type { ReadTag, WorkspaceTag, WorkspaceTransactionPage } from '@smartbook/api-client'

import { TransactionList } from '../components/TransactionList'
import type { TagForm } from '../forms'
import {
  TAG_COLOR_PALETTE,
  tagTextColorOn,
} from '../lib/tagColorPalette'

/** 右栏详情「最近交易」加载器 —— 页面用 token 实现并传入(panel 在共享包里,
 *  不持有 auth)。返回分页 `{ items, total, limit, offset }`。 */
type TagRecentLoader = (tagSyncId: string, offset: number) => Promise<WorkspaceTransactionPage>

type TagsPanelProps = {
  form: TagForm
  rows: ReadTag[]
  canManage: boolean
  showCreatorColumn?: boolean
  /** 按 tag.id 查询的统计（交易数/支出/收入），未传则不展开详情。 */
  statsById?: Record<string, { count: number; expense: number; income: number }>
  onFormChange: (next: TagForm) => void
  /** 触发"新建"流程:外层负责把 form 重置成 tagDefaults() 并打开 dialog。 */
  onCreate?: () => void
  onSave: () => Promise<boolean> | boolean
  onReset: () => void
  onEdit: (row: ReadTag) => void
  onDelete?: (row: ReadTag) => void
  /** 点击卡片（非编辑/删除按钮）触发：外层用来打开"标签详情+交易"弹窗。 */
  onClickTag?: (tag: ReadTag) => void
  /** 右栏详情「最近交易」加载器。传了才在选中标签时拉取交易。 */
  loadTagTransactions?: TagRecentLoader
}

/** 标签详情 —— 右栏:色块 + 名称 + KPI + 最近交易(无限滚动)。 */
function TagDetailPane({
  tag,
  stats,
  showCreatorColumn,
  canManage,
  onEdit,
  onDelete,
  onClickTag,
  loadTransactions,
}: {
  tag: ReadTag
  stats?: { count: number; expense: number; income: number }
  showCreatorColumn: boolean
  canManage: boolean
  onEdit: (row: ReadTag) => void
  onDelete?: (row: ReadTag) => void
  onClickTag?: (tag: ReadTag) => void
  loadTransactions?: TagRecentLoader
}) {
  const t = useT()
  const [page, setPage] = useState<{ items: WorkspaceTransactionPage['items']; total: number }>({
    items: [],
    total: 0,
  })
  const [loading, setLoading] = useState(false)
  const color = tag.color || '#94a3b8'

  const resetPage = useCallback(() => {
    setPage({ items: [], total: 0 })
    setLoading(false)
  }, [])

  useEffect(() => {
    resetPage()
    if (!loadTransactions || !tag?.id) return
    let cancelled = false
    setLoading(true)
    loadTransactions(tag.id, 0)
      .then((pg) => {
        if (cancelled) return
        setPage({ items: pg.items, total: pg.total })
      })
      .catch(() => {
        if (!cancelled) resetPage()
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [tag?.id, loadTransactions, resetPage])

  const loadMore = useCallback(() => {
    if (!loadTransactions || !tag?.id || loading) return
    const nextOffset = page.items.length
    setLoading(true)
    loadTransactions(tag.id, nextOffset)
      .then((pg) => {
        setPage((prev) => ({ items: [...prev.items, ...pg.items], total: pg.total }))
      })
      .finally(() => setLoading(false))
  }, [loadTransactions, tag?.id, loading, page.items.length])

  const fmt = (v: number) =>
    v.toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  const hasMore = page.total > page.items.length

  return (
    <div className="flex h-full flex-col gap-4">
      {/* 头部 */}
      <div className="flex items-start gap-3 border-b border-border/50 pb-4">
        <span
          className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl text-lg font-bold text-white shadow-sm"
          style={{ background: color }}
        >
          #
        </span>
        <div className="min-w-0 flex-1">
          <h3 className="truncate text-lg font-semibold">{tag.name}</h3>
          <div className="mt-1 flex items-center gap-2 text-xs text-muted-foreground">
            {showCreatorColumn ? (
              <span>创建者 {tag.created_by_email || tag.created_by_user_id || '-'}</span>
            ) : null}
          </div>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => onEdit(tag)}>
            {t('common.edit')}
          </Button>
          {onDelete ? (
            <Button
              variant="outline"
              size="sm"
              disabled={!canManage}
              style={{ color: 'hsl(var(--destructive))', borderColor: 'hsl(var(--destructive) / 0.5)' }}
              onClick={() => onDelete(tag)}
            >
              {t('common.delete')}
            </Button>
          ) : null}
        </div>
      </div>

      {/* KPI */}
      <div className="grid grid-cols-3 gap-3">
        <div className="rounded-xl border border-border/40 bg-card/50 p-3">
          <div className="text-xs text-muted-foreground">{t('tags.detail.count')}</div>
          <div className="mt-1 font-mono text-xl font-bold tabular-nums">
            {stats?.count ?? 0}
          </div>
        </div>
        <div className="rounded-xl border border-border/40 bg-card/50 p-3">
          <div className="text-xs text-muted-foreground">{t('tags.detail.expense')}</div>
          <div className="mt-1 font-mono text-xl font-bold tabular-nums text-expense">
            {fmt(stats?.expense ?? 0)}
          </div>
        </div>
        <div className="rounded-xl border border-border/40 bg-card/50 p-3">
          <div className="text-xs text-muted-foreground">{t('tags.detail.income')}</div>
          <div className="mt-1 font-mono text-xl font-bold tabular-nums text-income">
            {fmt(stats?.income ?? 0)}
          </div>
        </div>
      </div>

      {/* 最近交易 */}
      {loadTransactions ? (
        <div className="min-h-0 flex-1">
          <h4 className="mb-2 text-xs font-semibold text-muted-foreground">
            {t('tags.detail.recentTransactions')}
          </h4>
          <TransactionList
            items={page.items}
            variant="compact"
            loading={loading}
            hasMore={hasMore}
            onLoadMore={hasMore ? loadMore : undefined}
            className="max-h-[360px] overflow-y-auto pr-1"
            emptyTitle={t('tags.detail.noTransactions')}
          />
        </div>
      ) : null}

      {/* 底部提示:点击可打开标准详情弹窗(若有 onClickTag) */}
      {onClickTag ? (
        <div className="mt-auto pt-2">
          <Button variant="ghost" size="sm" onClick={() => onClickTag(tag)}>
            {t('tags.detail.openFull')}
          </Button>
        </div>
      ) : null}
    </div>
  )
}

/** 标签管理面板 —— 双栏「列表 + 详情」。
 *
 * - 左栏 标签列表(色点 + # 名 + 笔数徽章)。
 * - 右栏 选中标签的详情(色块 + 名称 + KPI 笔数/支出/收入 + 最近交易)。
 *
 * 保留:
 * - "新建标签" 按钮(顶部右上角,以及 EmptyState CTA)
 * - 编辑/新建对话框里的 20 色调色板(`TAG_COLOR_PALETTE`,跟 app 一一对齐)
 * - 前端查重:保存前先用现有 `rows`(workspace tags,已按用户作用域查回)
 *   检查同名,不让用户走完一圈 server 才报错。server 自身仍然兜底 dedup,
 *   双重保险。
 */
export function TagsPanel({
  form,
  rows,
  canManage,
  showCreatorColumn = false,
  statsById,
  onFormChange,
  onCreate,
  onSave,
  onReset,
  onEdit,
  onDelete,
  onClickTag,
  loadTagTransactions,
}: TagsPanelProps) {
  const t = useT()
  const [open, setOpen] = useState(false)
  const [duplicateError, setDuplicateError] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const hasStats = Boolean(statsById)

  // 同名查重:把当前用户已有标签名字小写化收成 Set,提交时 O(1) 查。编辑模
  // 式下排除自己 (form.editingId 对应的行) 以允许"改色不改名"。
  const existingNamesLower = useMemo(() => {
    const set = new Set<string>()
    for (const row of rows) {
      if (form.editingId && row.id === form.editingId) continue
      const name = (row.name || '').trim().toLowerCase()
      if (name) set.add(name)
    }
    return set
  }, [rows, form.editingId])

  const startCreate = () => {
    if (!canManage) return
    setDuplicateError(null)
    onCreate?.()
    setOpen(true)
  }

  const startEdit = (row: ReadTag) => {
    setDuplicateError(null)
    onEdit(row)
    setOpen(true)
  }

  const handleSave = async () => {
    const trimmed = form.name.trim()
    if (!trimmed) {
      setDuplicateError(t('tags.error.nameRequired'))
      return
    }
    if (existingNamesLower.has(trimmed.toLowerCase())) {
      setDuplicateError(t('tags.error.nameDuplicate'))
      return
    }
    setDuplicateError(null)
    const success = await onSave()
    if (success) {
      setOpen(false)
    }
  }

  const isEmpty = rows.length === 0
  const selected = rows.find((r) => r.id === selectedId) ?? null

  return (
    <>
      {/* 顶部操作条:右上角"新建标签"。即使 rows 为空也保留(EmptyState 那边
          也会再放一个 CTA 按钮,两处都点都能创建)。 */}
      {onCreate && canManage ? (
        <div className="mb-4 flex justify-end">
          <Button onClick={startCreate}>{t('tags.button.create')}</Button>
        </div>
      ) : null}

      {isEmpty ? (
        <EmptyState
          icon={
            <svg width="28" height="28" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"
                 strokeLinejoin="round">
              <path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z" />
              <circle cx="7" cy="7" r="1.5" />
            </svg>
          }
          title={t('tags.empty.title')}
          description={t('tags.empty.desc')}
          action={
            onCreate && canManage ? (
              <Button onClick={startCreate}>{t('tags.button.create')}</Button>
            ) : undefined
          }
        />
      ) : (
        <div className="grid h-[calc(100vh-160px)] min-h-[420px] grid-cols-[280px_1fr] gap-4">
          {/* 左栏 列表 */}
          <div className="flex min-h-0 flex-col overflow-hidden rounded-xl border border-border/50 bg-card/40 p-2">
            <div className="min-h-0 flex-1 space-y-0.5 overflow-y-auto">
              {rows.map((row) => {
                const color = row.color || '#94a3b8'
                const count = statsById?.[row.id]?.count ?? 0
                const active = row.id === selectedId
                return (
                  <button
                    key={row.id}
                    type="button"
                    onClick={() => setSelectedId(row.id)}
                    className={`flex w-full cursor-pointer items-center gap-2 rounded-lg px-2 py-2 text-left text-sm transition-colors ${
                      active ? 'bg-primary/15 text-primary' : 'hover:bg-accent/40 hover:text-foreground'
                    }`}
                  >
                    <span
                      className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-xs font-bold text-white"
                      style={{ background: color }}
                    >
                      #
                    </span>
                    <span className="min-w-0 truncate">{row.name}</span>
                    {count > 0 ? (
                      <span className="ml-auto shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[10px] leading-none text-muted-foreground tabular-nums">
                        {count}
                      </span>
                    ) : null}
                  </button>
                )
              })}
            </div>
          </div>

          {/* 右栏 详情 */}
          <div className="min-h-0 overflow-y-auto rounded-xl border border-border/50 bg-card/40 p-4">
            {selected ? (
              <TagDetailPane
                tag={selected}
                stats={hasStats ? statsById?.[selected.id] : undefined}
                showCreatorColumn={showCreatorColumn}
                canManage={canManage}
                onEdit={startEdit}
                onDelete={onDelete}
                onClickTag={onClickTag}
                loadTransactions={loadTagTransactions}
              />
            ) : (
              <div className="flex h-full min-h-[420px] items-center justify-center text-sm text-muted-foreground">
                {t('tags.list.select')}
              </div>
            )}
          </div>
        </div>
      )}

      <Dialog open={open} onOpenChange={(next) => {
        setOpen(next)
        if (!next) setDuplicateError(null)
      }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{form.editingId ? t('tags.button.update') : t('tags.button.create')}</DialogTitle>
          </DialogHeader>
          <div className="grid gap-4">
            {/* 名称 */}
            <div className="space-y-1">
              <Label>{t('tags.table.name')}</Label>
              <Input
                placeholder={t('tags.placeholder.name')}
                value={form.name}
                onChange={(event: ChangeEvent<HTMLInputElement>) => {
                  // 用户输入时清掉错误提示,避免改完字还红着不放
                  if (duplicateError) setDuplicateError(null)
                  onFormChange({ ...form, name: event.target.value })
                }}
              />
              {duplicateError ? (
                <p className="text-xs text-destructive">{duplicateError}</p>
              ) : null}
            </div>

            {/* 颜色选择器:20 色调色板,grid 布局排成两行 */}
            <div className="space-y-2">
              <Label>{t('tags.table.color')}</Label>
              <div className="flex flex-wrap gap-2">
                {TAG_COLOR_PALETTE.map((hex) => {
                  const isSelected = form.color.toUpperCase() === hex.toUpperCase()
                  const checkColor = tagTextColorOn(hex)
                  return (
                    <button
                      key={hex}
                      type="button"
                      aria-label={hex}
                      title={hex}
                      onClick={() => onFormChange({ ...form, color: hex })}
                      className={`flex h-9 w-9 items-center justify-center rounded-full transition-all ${
                        isSelected
                          ? 'scale-110 ring-2 ring-offset-2 ring-foreground ring-offset-background shadow-md'
                          : 'hover:scale-105'
                      }`}
                      style={{ background: hex }}
                    >
                      {isSelected ? (
                        <svg
                          width="16"
                          height="16"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke={checkColor}
                          strokeWidth="3"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          aria-hidden
                        >
                          <polyline points="20 6 9 17 4 12" />
                        </svg>
                      ) : null}
                    </button>
                  )
                })}
              </div>
            </div>

            {/* 预览:用当前选的 color + name 渲染一个 hashtag 徽章,所见即所得 */}
            <div className="space-y-1">
              <Label>{t('tags.preview')}</Label>
              <div className="flex items-center gap-2 rounded-lg border border-border/40 bg-card/60 px-3 py-2">
                <span
                  className="flex h-7 w-7 items-center justify-center rounded-lg text-sm font-bold text-white shadow-sm"
                  style={{ background: form.color || '#94a3b8' }}
                >
                  #
                </span>
                <span className="text-sm font-medium">
                  {form.name.trim() || t('tags.placeholder.name')}
                </span>
              </div>
            </div>
          </div>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => {
                onReset()
                setDuplicateError(null)
                setOpen(false)
              }}
            >
              {t('dialog.cancel')}
            </Button>
            <Button
              disabled={!canManage}
              onClick={() => void handleSave()}
            >
              {form.editingId ? t('tags.button.update') : t('tags.button.create')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
