import { useCallback, useEffect, useState } from 'react'

import { Button, Card, Checkbox, Image, Modal, Select } from 'antd'
import {
  Badge,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  useT,
  useToast,
} from '@smartbook/ui'
import {
  type AIAnalysisLogDetail,
  type AIAnalysisLogItem,
  batchDeleteAIAnalysisLogs,
  deleteAIAnalysisLog,
  getAIAnalysisLog,
  getAIAnalysisLogImage,
  listAIAnalysisLogs,
} from '@smartbook/api-client'
import { ConfirmDialog } from '@smartbook/web-features'
import { History } from 'lucide-react'

import { useAuth } from '../../context/AuthContext'
import { localizeError } from '../../i18n/errors'

/**
 * AI 调用记录 —— 独立菜单入口页面。
 *
 * 每次 AI 分析调用(文档问答 / 截图记账 / 文字记账)server 都落一行日志
 * (ai_analysis_logs,不设自动保留期、永久保留,只能手动删除单条——见
 * src/models.py AIAnalysisLog),这个页面是它的用户视角:列表(预览)+
 * 点行看全文 + 详情里删单条。接口见 @smartbook/api-client 的 aiLogs.ts。
 *
 * 历史:此前该卡片挂在「AI 配置」页底部(无独立入口,用户找不到),2026-09
 * 拆为独立页面 + 侧栏「设置 → AI 调用记录」菜单入口。
 */

const HISTORY_PAGE_SIZE = 25
const HISTORY_STATUS_FILTERS = ['all', 'ok', 'error'] as const
type HistoryStatusFilter = (typeof HISTORY_STATUS_FILTERS)[number]

const ENTRY_LABEL_KEYS: Record<string, string> = {
  ask: 'settings.aiLogs.entry.ask',
  parse_tx_image: 'settings.aiLogs.entry.parse_tx_image',
  parse_tx_text: 'settings.aiLogs.entry.parse_tx_text',
}

export function AiLogsPage() {
  const t = useT()
  const toast = useToast()
  const { token } = useAuth()

  const [items, setItems] = useState<AIAnalysisLogItem[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(0)
  const [statusFilter, setStatusFilter] = useState<HistoryStatusFilter>('all')
  const [detail, setDetail] = useState<AIAnalysisLogDetail | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  // 输入图片(App 上报的截图原图):详情带 has_image 时拉 Blob → objectURL
  const [imageUrl, setImageUrl] = useState<string | null>(null)
  // 删除确认:详情里的「删除」→ ConfirmDialog → DELETE /ai/logs/{id} → 刷新
  const [pendingDelete, setPendingDelete] = useState<number | null>(null)
  const [deleting, setDeleting] = useState(false)
  // 多选删除:行勾选 → 顶部「删除所选」→ ConfirmDialog → 批量接口 → 刷新
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [batchConfirmOpen, setBatchConfirmOpen] = useState(false)
  const [batchDeleting, setBatchDeleting] = useState(false)

  useEffect(() => {
    if (!detail?.has_image) {
      setImageUrl(null)
      return
    }
    let revoke: string | null = null
    getAIAnalysisLogImage(token, detail.id)
      .then((blob) => {
        revoke = URL.createObjectURL(blob)
        setImageUrl(revoke)
      })
      .catch(() => setImageUrl(null))
    return () => {
      if (revoke) URL.revokeObjectURL(revoke)
    }
  }, [detail, token])

  const notifyError = useCallback(
    (err: unknown) => toast.error(localizeError(err, t), t('notice.error')),
    [toast, t],
  )

  const refresh = useCallback(async () => {
    setLoading(true)
    try {
      const res = await listAIAnalysisLogs(token, {
        limit: HISTORY_PAGE_SIZE,
        offset: page * HISTORY_PAGE_SIZE,
        status: statusFilter === 'all' ? undefined : statusFilter,
      })
      setItems(res.items)
      setTotal(res.total)
    } catch (err) {
      notifyError(err)
    } finally {
      setLoading(false)
    }
  }, [token, page, statusFilter, notifyError])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const openDetail = useCallback(
    async (id: number) => {
      setDetailLoading(true)
      try {
        setDetail(await getAIAnalysisLog(token, id))
      } catch (err) {
        notifyError(err)
      } finally {
        setDetailLoading(false)
      }
    },
    [token, notifyError],
  )

  const confirmDelete = useCallback(async () => {
    if (pendingDelete == null) return
    setDeleting(true)
    try {
      await deleteAIAnalysisLog(token, pendingDelete)
      setPendingDelete(null)
      setDetail(null)
      toast.success(t('settings.aiLogs.detail.deleted'), t('notice.success'))
      void refresh()
    } catch (err) {
      notifyError(err)
    } finally {
      setDeleting(false)
    }
  }, [pendingDelete, token, refresh, notifyError, toast, t])

  const toggleSelect = useCallback((id: number, checked: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev)
      if (checked) next.add(id)
      else next.delete(id)
      return next
    })
  }, [])

  const toggleAll = useCallback(
    (checked: boolean) => {
      setSelected(checked ? new Set(items.map((it) => it.id)) : new Set())
    },
    [items],
  )

  const allSelected = items.length > 0 && items.every((it) => selected.has(it.id))

  const confirmBatchDelete = useCallback(async () => {
    if (selected.size === 0) return
    setBatchDeleting(true)
    try {
      const res = await batchDeleteAIAnalysisLogs(token, Array.from(selected))
      setSelected(new Set())
      setBatchConfirmOpen(false)
      toast.success(t('settings.aiLogs.batchDeleted', { count: res.deleted }), t('notice.success'))
      void refresh()
    } catch (err) {
      notifyError(err)
    } finally {
      setBatchDeleting(false)
    }
  }, [selected, token, refresh, notifyError, toast, t])

  const totalPages = Math.max(1, Math.ceil(total / HISTORY_PAGE_SIZE))

  return (
    <div className="space-y-4">
      <Card
        size="small"
        title={<span className="flex items-center gap-2">
          <History className="h-5 w-5 text-muted-foreground" />
          <h2 className="text-base font-semibold">{t('settings.aiLogs.title')}</h2>
          <span className="hidden text-xs text-muted-foreground sm:inline">
            {t('settings.aiLogs.subtitleShort')}
          </span>
        </span>}
        extra={
          <Select
            value={statusFilter}
            onChange={(v) => { setStatusFilter(v as HistoryStatusFilter); setPage(0); setSelected(new Set()) }}
            options={[
              { value: 'all', label: t('settings.aiLogs.filter.all') },
              { value: 'ok', label: t('settings.aiLogs.filter.ok') },
              { value: 'error', label: t('settings.aiLogs.filter.error') },
            ]}
            style={{ width: 140 }}
          />
        }
        styles={{ body: { padding: '12px 16px 16px' } }}
      >
        {loading ? (
          <div className="py-6 text-center text-sm text-muted-foreground">{t('common.loading')}</div>
        ) : items.length === 0 ? (
          <div className="rounded-md border border-dashed py-10 text-center text-sm text-muted-foreground">
            {t('settings.aiLogs.empty')}
          </div>
        ) : (
          <>
            <div className="flex items-center justify-between gap-2 border-b border-border pb-2 text-xs">
              {/* 全选 checkbox 已移到表头;此处保留已选计数 + 批量删除按钮。 */}
              <div className="flex items-center gap-3">
                {selected.size > 0 ? (
                  <span className="text-muted-foreground">
                    {t('settings.aiLogs.selectedCount', { count: selected.size })}
                  </span>
                ) : null}
              </div>
              <Button
                size="small"
                danger
                disabled={selected.size === 0 || loading}
                onClick={() => setBatchConfirmOpen(true)}
              >
                {t('settings.aiLogs.batchDelete')}
                {selected.size > 0 ? ` (${selected.size})` : ''}
              </Button>
            </div>
            <div className="bc-table-panel overflow-x-auto shadow-xs">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="bc-table-head w-[48px]">
                      <Checkbox
                        checked={allSelected}
                        indeterminate={selected.size > 0 && !allSelected}
                        disabled={loading || items.length === 0}
                        onChange={(e) => toggleAll(e.target.checked)}
                      />
                    </TableHead>
                    <TableHead className="bc-table-head">{t('settings.aiLogs.table.status')}</TableHead>
                    <TableHead className="bc-table-head">{t('settings.aiLogs.table.entry')}</TableHead>
                    <TableHead className="bc-table-head">{t('settings.aiLogs.table.inputPreview')}</TableHead>
                    <TableHead className="bc-table-head">{t('settings.aiLogs.table.duration')}</TableHead>
                    <TableHead className="bc-table-head">{t('settings.aiLogs.table.calledAt')}</TableHead>
                    <TableHead className="bc-table-head text-right pr-6">{t('settings.aiLogs.table.ops')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {items.map((it) => (
                    <TableRow
                      key={it.id}
                      className="group cursor-pointer transition-colors duration-150 odd:bg-muted/[0.12] hover:bg-primary/[0.04] dark:hover:bg-primary/[0.07]"
                      onClick={() => void openDetail(it.id)}
                    >
                      <TableCell className="w-[48px]">
                        <Checkbox
                          checked={selected.has(it.id)}
                          onClick={(e) => e.stopPropagation()}
                          onChange={(e) => toggleSelect(it.id, e.target.checked)}
                        />
                      </TableCell>
                      <TableCell>
                        <span
                          className={`inline-flex items-center rounded-md px-2 py-0.5 text-[11px] font-semibold border ${
                            it.status === 'ok'
                              ? 'border-emerald-500/25 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400'
                              : 'border-destructive/25 bg-destructive/10 text-destructive'
                          }`}
                        >
                          {it.status === 'ok'
                            ? t('settings.aiLogs.filter.ok')
                            : t('settings.aiLogs.filter.error')}
                        </span>
                      </TableCell>
                      <TableCell className="font-semibold text-sm">
                        <div className="flex items-center gap-1.5">
                          <span>{t(ENTRY_LABEL_KEYS[it.entry_type] ?? it.entry_type)}</span>
                          {it.model ? (
                            <span className="rounded-md border border-border/60 bg-muted/50 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground">
                              {it.model}
                            </span>
                          ) : null}
                        </div>
                      </TableCell>
                      <TableCell className="max-w-[320px]">
                        <div className="truncate font-mono text-xs text-muted-foreground" title={it.input_preview || ''}>
                          {it.input_preview || '-'}
                        </div>
                      </TableCell>
                      <TableCell className="font-mono tabular-nums text-xs font-semibold text-muted-foreground">{it.duration_ms}ms</TableCell>
                      <TableCell className="font-mono tabular-nums text-xs text-muted-foreground">{new Date(it.called_at).toLocaleString()}</TableCell>
                      <TableCell className="text-right pr-6">
                        <Button size="small" type="text" className="text-xs font-medium text-muted-foreground hover:text-primary" onClick={(e) => { e.stopPropagation(); void openDetail(it.id) }}>
                          {t('settings.aiLogs.table.view')}
                        </Button>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            {total > HISTORY_PAGE_SIZE ? (
              <div className="mt-3 flex items-center justify-between text-xs text-muted-foreground">
                <span>{t('settings.aiLogs.totalCount', { total })}</span>
                <div className="flex items-center gap-2">
                  <Button type="text" size="small" disabled={page === 0} onClick={() => { setPage((p) => Math.max(0, p - 1)); setSelected(new Set()) }}>
                    {t('common.previous')}
                  </Button>
                  <span>
                    {page + 1} / {totalPages}
                  </span>
                  <Button type="text" size="small" disabled={page + 1 >= totalPages} onClick={() => { setPage((p) => p + 1); setSelected(new Set()) }}>
                    {t('common.next')}
                  </Button>
                </div>
              </div>
            ) : null}
          </>
        )}

        <Modal
          open={!!detail || detailLoading}
          onCancel={() => setDetail(null)}
          title={t('settings.aiLogs.detail.title')}
          footer={
            <>
              <Button
                danger
                disabled={!detail || detailLoading}
                onClick={() => setPendingDelete(detail?.id ?? null)}
              >
                {t('settings.aiLogs.detail.delete')}
              </Button>
              <Button type="primary" onClick={() => setDetail(null)}>
                {t('common.done')}
              </Button>
            </>
          }
          width={720}
        >
          {detail ? (
            <div className="space-y-4">
              <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                <span className="font-medium text-foreground">{t(ENTRY_LABEL_KEYS[detail.entry_type] ?? detail.entry_type)}</span>
                {detail.provider_id ? <code>{detail.provider_id}</code> : null}
                {detail.model ? <code>{detail.model}</code> : null}
                <span>{t('settings.aiLogs.duration', { ms: detail.duration_ms })}</span>
                {detail.total_tokens != null ? (
                  <span>{t('settings.aiLogs.tokens', { total: detail.total_tokens })}</span>
                ) : null}
                <span>{new Date(detail.called_at).toLocaleString()}</span>
              </div>
              <DetailBlock
                label={t('settings.aiLogs.detail.input')}
                text={detail.input_text}
              />
              {detail.has_image ? (
                <div className="space-y-1">
                  <div className="text-xs font-semibold text-muted-foreground">
                    {t('settings.aiLogs.detail.inputImage')}
                  </div>
                  {imageUrl ? (
                    // 点击打开 antd 全屏预览(缩放/旋转),cursor-zoom-in 提示可点
                    <Image
                      src={imageUrl}
                      alt={t('settings.aiLogs.detail.inputImage')}
                      className="max-h-96 rounded-md border border-border"
                      preview={{ mask: null }}
                      wrapperClassName="cursor-zoom-in max-w-fit rounded-md"
                    />
                  ) : (
                    <div className="text-xs text-muted-foreground">
                      {t('common.loading')}
                    </div>
                  )}
                </div>
              ) : null}
              <DetailBlock
                label={t('settings.aiLogs.detail.output')}
                text={detail.output_text}
              />
              {detail.error_message ? (
                <DetailBlock label={t('settings.aiLogs.detail.error')} text={detail.error_message} error />
              ) : null}
            </div>
          ) : (
            <div className="py-6 text-center text-sm text-muted-foreground">{t('common.loading')}</div>
          )}
        </Modal>
        <ConfirmDialog
          open={pendingDelete !== null}
          title={t('settings.aiLogs.detail.deleteTitle')}
          description={t('settings.aiLogs.detail.deleteDesc')}
          confirmText={t('confirm.delete')}
          cancelText={t('confirm.cancel')}
          loading={deleting}
          onCancel={() => setPendingDelete(null)}
          onConfirm={() => void confirmDelete()}
        />
        <ConfirmDialog
          open={batchConfirmOpen}
          title={t('settings.aiLogs.batchDeleteTitle', { count: selected.size })}
          description={t('settings.aiLogs.detail.deleteDesc')}
          confirmText={t('confirm.delete')}
          cancelText={t('confirm.cancel')}
          loading={batchDeleting}
          onCancel={() => setBatchConfirmOpen(false)}
          onConfirm={() => void confirmBatchDelete()}
        />
      </Card>
    </div>
  )
}

function DetailBlock({ label, text, error = false }: { label: string; text: string | null; error?: boolean }) {
  return (
    <div className="space-y-1">
      <div className="text-xs font-semibold text-muted-foreground">{label}</div>
      {text ? (
        <pre className={`max-h-64 overflow-auto whitespace-pre-wrap break-all rounded-md border p-3 text-xs ${error ? 'border-red-500/40 bg-red-500/5 text-destructive' : 'border-border bg-muted/40'}`}>
          {text}
        </pre>
      ) : (
        <div className="text-xs text-muted-foreground">—</div>
      )}
    </div>
  )
}
