import { useCallback, useEffect, useMemo, useState } from 'react'
import { AlertTriangle, Brush, CheckCircle2, RefreshCcw, Trash2 } from 'lucide-react'

import {
  executeDataCleanup,
  fetchDataCleanupScan,
  type DataCleanupRecord,
  type DataCleanupScanReport,
} from '@smartbook/api-client'
import { Button, Card } from 'antd'
import { useT, useToast } from '@smartbook/ui'
import { ConfirmDialog } from '@smartbook/web-features'

import { useAuth } from '../../context/AuthContext'
import { localizeError } from '../../i18n/errors'

/**
 * 管理员 · 数据清理页 —— 替代旧 SettingsHealth 下的 IntegrityPanel。
 *
 * 流程:scan → 三组孤儿数据列表 → 勾选 → 单删 / 批量删 → 自动重扫。
 * 跟 mobile OrphanCleanupPage 设计对齐(分组卡片 + 勾选 + 批量/单删 + 确认弹窗)。
 */
export function AdminDataCleanupPage() {
  const t = useT()
  const toast = useToast()
  const { token, isAdmin, isAdminResolved } = useAuth()

  const [report, setReport] = useState<DataCleanupScanReport | null>(null)
  const [loading, setLoading] = useState(false)
  const [cleaning, setCleaning] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [confirmPayload, setConfirmPayload] = useState<{
    records: DataCleanupRecord[]
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
      const result = await fetchDataCleanupScan(token)
      setReport(result)
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

  const allRecords = useMemo<DataCleanupRecord[]>(() => {
    if (!report) return []
    return [...report.db_orphans, ...report.file_orphans, ...report.sync_orphans]
  }, [report])

  const recordKey = (r: DataCleanupRecord) =>
    `${r.type}:${r.row_id || r.sync_id || r.file_path || ''}`

  const selectedRecords = useMemo(
    () => allRecords.filter((r) => selected.has(recordKey(r))),
    [allRecords, selected],
  )

  const toggleOne = useCallback((r: DataCleanupRecord) => {
    setSelected((prev) => {
      const next = new Set(prev)
      const key = recordKey(r)
      if (next.has(key)) {
        next.delete(key)
      } else {
        next.add(key)
      }
      return next
    })
  }, [])

  const toggleGroup = useCallback(
    (group: DataCleanupRecord[], select: boolean) => {
      setSelected((prev) => {
        const next = new Set(prev)
        for (const r of group) {
          if (select) {
            next.add(recordKey(r))
          } else {
            next.delete(recordKey(r))
          }
        }
        return next
      })
    },
    [],
  )

  const askClean = useCallback(
    (records: DataCleanupRecord[]) => {
      if (records.length === 0) return
      const message =
        records.length === 1
          ? t('admin.dataCleanup.confirmOne', { title: records[0].title })
          : t('admin.dataCleanup.confirmBatch', { count: records.length })
      setConfirmPayload({ records, message })
    },
    [t],
  )

  const runClean = useCallback(async () => {
    if (!confirmPayload) return
    const { records } = confirmPayload
    setConfirmPayload(null)
    setCleaning(true)
    try {
      const result = await executeDataCleanup(token, records)
      if (result.failures.length > 0) {
        toast.error(
          t('admin.dataCleanup.partial', {
            ok: result.success_count,
            fail: result.failures.length,
          }),
          t('notice.error'),
        )
      } else {
        notifySuccess(
          t('admin.dataCleanup.success', { count: result.success_count }),
        )
      }
      // 清掉成功 record 的勾选
      const failedKeys = new Set(
        result.failures.map((f) => f.record_key),
      )
      setSelected((prev) => {
        const next = new Set(prev)
        for (const r of records) {
          const k = recordKey(r)
          if (!failedKeys.has(k)) next.delete(k)
        }
        return next
      })
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

  const totalCount = report?.total_count ?? 0
  const totalSize = report?.total_size_bytes ?? 0

  return (
    <div className="space-y-4">
      {/* 顶部 banner */}
      <Card size="small">
          <div className="flex items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <Brush className="h-5 w-5 text-primary" />
            <div>
              <h3 className="text-sm font-medium">
                {t('admin.dataCleanup.title')}
              </h3>
              <p className="text-xs text-muted-foreground">
                {report
                  ? t('admin.dataCleanup.summary', {
                      count: totalCount,
                      size: humanSize(totalSize),
                    })
                  : t('admin.dataCleanup.subtitle')}
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
              ? t('admin.dataCleanup.scanning')
              : t('admin.dataCleanup.rescan')}
          </Button>
        </div>
      </Card>

      {report && totalCount === 0 ? (
        <Card size="small">
          <div className="flex flex-col items-center gap-2 py-6 text-center">
            <CheckCircle2 className="h-10 w-10 text-emerald-500" />
            <p className="text-sm text-muted-foreground">
              {t('admin.dataCleanup.empty')}
            </p>
          </div>
        </Card>
      ) : null}

      {report ? (
        <>
          <GroupCard
            title={t('admin.dataCleanup.group.db')}
            records={report.db_orphans}
            selected={selected}
            recordKey={recordKey}
            toggleOne={toggleOne}
            toggleGroup={toggleGroup}
            onDeleteOne={(r) => askClean([r])}
            cleaning={cleaning}
            t={t}
          />
          <GroupCard
            title={t('admin.dataCleanup.group.file')}
            records={report.file_orphans}
            selected={selected}
            recordKey={recordKey}
            toggleOne={toggleOne}
            toggleGroup={toggleGroup}
            onDeleteOne={(r) => askClean([r])}
            cleaning={cleaning}
            t={t}
          />
          <GroupCard
            title={t('admin.dataCleanup.group.sync')}
            records={report.sync_orphans}
            selected={selected}
            recordKey={recordKey}
            toggleOne={toggleOne}
            toggleGroup={toggleGroup}
            onDeleteOne={(r) => askClean([r])}
            cleaning={cleaning}
            t={t}
          />
        </>
      ) : null}

      {/* 底部固定操作栏 */}
      {report && totalCount > 0 ? (
        <Card size="small" className="sticky bottom-2 z-10">
          <div>
            <span className="text-sm text-muted-foreground">
              {t('admin.dataCleanup.selectedHint', {
                count: selectedRecords.length,
              })}
            </span>
            <div className="flex gap-2">
              <Button
                size="small"
                variant="outlined"
                onClick={() => toggleGroup(allRecords, selectedRecords.length === 0)}
                disabled={cleaning}
              >
                {selectedRecords.length === 0
                  ? t('admin.dataCleanup.selectAll')
                  : t('admin.dataCleanup.deselectAll')}
              </Button>
              <Button
                size="small"
                danger
                onClick={() => askClean(selectedRecords)}
                disabled={cleaning || selectedRecords.length === 0}
              >
                <Trash2 className="mr-1.5 h-3.5 w-3.5" />
                {t('admin.dataCleanup.cleanSelected')}
              </Button>
            </div>
          </div>
        </Card>
      ) : null}

      <ConfirmDialog
        open={confirmPayload !== null}
        title={t('admin.dataCleanup.confirmTitle')}
        description={confirmPayload?.message || ''}
        confirmText={t('admin.dataCleanup.cleanSelected')}
        cancelText={t('common.cancel')}
        loading={cleaning}
        onCancel={() => setConfirmPayload(null)}
        onConfirm={() => void runClean()}
      />
    </div>
  )
}

type TFunction = (key: string, vars?: Record<string, string | number>) => string

function GroupCard(props: {
  title: string
  records: DataCleanupRecord[]
  selected: Set<string>
  recordKey: (r: DataCleanupRecord) => string
  toggleOne: (r: DataCleanupRecord) => void
  toggleGroup: (group: DataCleanupRecord[], select: boolean) => void
  onDeleteOne: (r: DataCleanupRecord) => void
  cleaning: boolean
  t: TFunction
}) {
  const { title, records, selected, recordKey, toggleOne, toggleGroup, onDeleteOne, cleaning, t } =
    props
  if (records.length === 0) return null
  const allSelected = records.every((r) => selected.has(recordKey(r)))
  return (
    <Card size="small">
        <div className="flex items-center justify-between">
          <h4 className="text-sm font-semibold">
            {title} ({records.length})
          </h4>
          <Button
            size="small"
            type="text"
            onClick={() => toggleGroup(records, !allSelected)}
            disabled={cleaning}
          >
            {allSelected
              ? t('admin.dataCleanup.deselectAll')
              : t('admin.dataCleanup.selectAll')}
          </Button>
        </div>
        <div className="divide-y divide-border/60">
          {records.map((r) => {
            const key = recordKey(r)
            const isChecked = selected.has(key)
            return (
              <div
                key={key}
                className="flex items-center gap-3 py-2"
              >
                <input
                  type="checkbox"
                  className="h-4 w-4 cursor-pointer accent-primary"
                  checked={isChecked}
                  onChange={() => toggleOne(r)}
                  disabled={cleaning}
                />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">{r.title}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {r.subtitle}
                    {r.size_bytes ? ` · ${humanSize(r.size_bytes)}` : ''}
                  </p>
                </div>
                <Button
                  size="small"
                  type="text"
                  icon={<Trash2 className="h-4 w-4" />}
                  onClick={() => onDeleteOne(r)}
                  disabled={cleaning}
                  title={t('admin.dataCleanup.deleteOne')}
                />
              </div>
            )
          })}
        </div>
    </Card>
  )
}

function humanSize(bytes: number): string {
  if (bytes <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB']
  let v = bytes
  let i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`
}

// 防 lint 不用
void AlertTriangle
