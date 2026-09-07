import { useCallback, useEffect, useMemo, useState } from 'react'
import { CheckCircle2, Copy, RefreshCcw, Trash2 } from 'lucide-react'

import {
  executeDuplicateCleanup,
  fetchDuplicateTransactions,
  type DuplicateDeleteItem,
  type DuplicateGroup,
  type DuplicateRecord,
} from '@smartbook/api-client'
import { Button, Card, Checkbox, Tag } from 'antd'
import { useT, useToast } from '@smartbook/ui'
import { ConfirmDialog } from '@smartbook/web-features'

import { useAuth } from '../../context/AuthContext'
import { localizeError } from '../../i18n/errors'

/**
 * 管理员 · 重复交易清理页。
 *
 * 扫描「同账本 + 同金额 + 同分钟」的交易分组,让 admin 逐笔勾选要删除的
 * 重复项(每组默认勾选非 keeper 的笔),批量删除后自动重扫。
 */
export function AdminDuplicateTransactionsPage() {
  const t = useT()
  const toast = useToast()
  const { token, isAdmin, isAdminResolved } = useAuth()

  const [groups, setGroups] = useState<DuplicateGroup[]>([])
  const [loading, setLoading] = useState(false)
  const [cleaning, setCleaning] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [confirmPayload, setConfirmPayload] = useState<{
    items: DuplicateDeleteItem[]
    message: string
  } | null>(null)

  const notifyError = useCallback(
    (err: unknown) => toast.error(localizeError(err, t), t('notice.error')),
    [toast, t],
  )
  const notifySuccess = useCallback(
    (msg: string) => toast.success(msg, t('notice.success')),
    [toast, t],
  )

  const refresh = useCallback(async () => {
    if (!isAdmin) return
    setLoading(true)
    try {
      const result = await fetchDuplicateTransactions(token)
      setGroups(result)
      // 默认勾选每组里非 keeper 的重复笔,一键清理最方便。
      setSelected(new Set(collectDefaultSelected(result)))
    } catch (err) {
      notifyError(err)
    } finally {
      setLoading(false)
    }
  }, [token, isAdmin, notifyError])

  useEffect(() => {
    if (!isAdminResolved || !isAdmin) return
    void refresh()
  }, [isAdminResolved, isAdmin, refresh])

  const itemKey = (r: DuplicateRecord) => `${r.ledger_id}:${r.sync_id}`

  const selectedItems = useMemo(
    () =>
      groups.flatMap((g) => g.items).filter((r) => selected.has(itemKey(r))),
    [groups, selected],
  )

  const toggleOne = useCallback((r: DuplicateRecord) => {
    setSelected((prev) => {
      const next = new Set(prev)
      const key = itemKey(r)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }, [])

  const askClean = useCallback(
    (items: DuplicateDeleteItem[]) => {
      if (items.length === 0) return
      const message =
        items.length === 1
          ? t('admin.duplicates.confirmOne')
          : t('admin.duplicates.confirmBatch', { count: items.length })
      setConfirmPayload({ items, message })
    },
    [t],
  )

  const runClean = useCallback(async () => {
    if (!confirmPayload) return
    const { items } = confirmPayload
    setConfirmPayload(null)
    setCleaning(true)
    try {
      const result = await executeDuplicateCleanup(token, items)
      if (result.failures.length > 0) {
        toast.error(
          t('admin.duplicates.partial', {
            ok: result.success_count,
            fail: result.failures.length,
          }),
          t('notice.error'),
        )
      } else {
        notifySuccess(
          t('admin.duplicates.success', { count: result.success_count }),
        )
      }
      await refresh()
    } catch (err) {
      notifyError(err)
    } finally {
      setCleaning(false)
    }
  }, [confirmPayload, token, refresh, notifyError, notifySuccess, toast, t])

  if (!isAdminResolved) {
    return null
  }

  if (!isAdmin) {
    return (
      <Card size="small">
        <p className="py-2 text-center text-sm text-muted-foreground">
          {t('admin.users.noPermission')}
        </p>
      </Card>
    )
  }

  const totalGroups = groups.length
  const totalDupes = groups.reduce((sum, g) => sum + g.items.length - 1, 0)

  return (
    <div className="space-y-4">
      <Card size="small">
        <div className="flex items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <Copy className="h-5 w-5 text-primary" />
            <div>
              <h3 className="text-sm font-medium">
                {t('admin.duplicates.title')}
              </h3>
              <p className="text-xs text-muted-foreground">
                {groups.length > 0
                  ? t('admin.duplicates.summary', {
                      groups: totalGroups,
                      dupes: totalDupes,
                    })
                  : t('admin.duplicates.subtitle')}
              </p>
            </div>
          </div>
          <Button
            size="small"
            variant="outlined"
            onClick={() => void refresh()}
            disabled={loading || cleaning}
          >
            <RefreshCcw className="mr-1.5 h-3.5 w-3.5" />
            {loading
              ? t('admin.duplicates.scanning')
              : t('admin.duplicates.rescan')}
          </Button>
        </div>
      </Card>

      {groups.length === 0 && !loading ? (
        <Card size="small">
          <div className="flex flex-col items-center gap-2 py-6 text-center">
            <CheckCircle2 className="h-10 w-10 text-emerald-500" />
            <p className="text-sm text-muted-foreground">
              {t('admin.duplicates.empty')}
            </p>
          </div>
        </Card>
      ) : null}

      {groups.map((g) => {
        const groupKeys = g.items.map(itemKey)
        const allSelected = groupKeys.every((k) => selected.has(k))
        const anySelected = groupKeys.some((k) => selected.has(k))
        return (
          <Card key={`${g.ledger_id}:${g.happened_at}:${g.amount}`} size="small">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Checkbox
                  checked={allSelected}
                  indeterminate={anySelected && !allSelected}
                  onChange={(e) => {
                    setSelected((prev) => {
                      const next = new Set(prev)
                      for (const k of groupKeys) {
                        if (e.target.checked) next.add(k)
                        else next.delete(k)
                      }
                      return next
                    })
                  }}
                />
                <h4 className="text-sm font-semibold">
                  {formatAmount(g.amount)}{' '}
                  <span className="text-xs font-normal text-muted-foreground">
                    {formatTime(g.happened_at)} · {g.ledger_name || g.ledger_id}
                  </span>
                </h4>
              </div>
              <Tag color="orange">
                {t('admin.duplicates.dupCount', { count: g.count })}
              </Tag>
            </div>

            <div className="mt-2 divide-y divide-border/60">
              {g.items.map((r) => {
                const key = itemKey(r)
                return (
                  <div key={key} className="flex items-center gap-3 py-2">
                    <Checkbox
                      checked={selected.has(key)}
                      onChange={() => toggleOne(r)}
                      disabled={cleaning}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm">
                        {r.note || t('admin.duplicates.noNote')}
                        {r.is_keeper ? (
                          <Tag color="green" className="ml-2">
                            {t('admin.duplicates.keeper')}
                          </Tag>
                        ) : null}
                      </p>
                      <p className="truncate text-xs text-muted-foreground">
                        {r.tx_type} · {r.account_name || '-'} · {r.category_name || '-'}
                        {r.tags_csv ? ` · ${r.tags_csv}` : ''}
                      </p>
                      <p className="truncate text-xs text-muted-foreground">
                        {r.created_at
                          ? t('admin.duplicates.recordedAt', { time: formatTime(r.created_at) })
                          : t('admin.duplicates.noRecordedAt')}
                      </p>
                    </div>
                    <span className="text-sm font-medium">
                      {formatAmount(r.amount)}
                    </span>
                  </div>
                )
              })}
            </div>
          </Card>
        )
      })}

      {groups.length > 0 ? (
        <Card size="small" className="sticky bottom-2 z-10">
          <div>
            <span className="text-sm text-muted-foreground">
              {t('admin.duplicates.selectedHint', {
                count: selectedItems.length,
              })}
            </span>
            <div className="flex gap-2">
              <Button
                size="small"
                variant="outlined"
                onClick={() =>
                  askClean(
                    selectedItems.map((r) => ({
                      ledger_id: r.ledger_id,
                      sync_id: r.sync_id,
                    })),
                  )
                }
                disabled={cleaning || selectedItems.length === 0}
              >
                <Trash2 className="mr-1.5 h-3.5 w-3.5" />
                {t('admin.duplicates.cleanSelected')}
              </Button>
            </div>
          </div>
        </Card>
      ) : null}

      <ConfirmDialog
        open={confirmPayload !== null}
        title={t('admin.duplicates.confirmTitle')}
        description={confirmPayload?.message || ''}
        confirmText={t('admin.duplicates.cleanSelected')}
        cancelText={t('common.cancel')}
        loading={cleaning}
        onCancel={() => setConfirmPayload(null)}
        onConfirm={() => void runClean()}
      />
    </div>
  )
}

function collectDefaultSelected(groups: DuplicateGroup[]): string[] {
  return groups.flatMap((g) =>
    g.items.filter((r) => !r.is_keeper).map((r) => `${r.ledger_id}:${r.sync_id}`),
  )
}

function formatAmount(amount: number): string {
  return `¥${amount.toFixed(2)}`
}

function formatTime(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}
