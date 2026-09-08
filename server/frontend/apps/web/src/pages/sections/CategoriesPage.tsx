import { useCallback, useEffect, useMemo, useState } from 'react'

import {
  batchMoveTransactions,
  createCategory,
  deleteCategory,
  fetchWorkspaceCategories,
  fetchWorkspaceTags,
  fetchWorkspaceTransactions,
  updateCategory,
  uploadAttachment,
  type ReadCategory,
  type WorkspaceCategory,
  type WorkspaceTag,
  type WorkspaceTransaction,
} from '@smartbook/api-client'
import { useT, useToast } from '@smartbook/ui'
import {
  BatchMoveDialog,
  CategoriesPanel,
  ConfirmDialog,
  categoryDefaults,
  type CategoryForm,
} from '@smartbook/web-features'

import { useLedgerWrite } from '../../app/useLedgerWrite'
import { dispatchOpenDetailCategory } from '../../lib/txDialogEvents'
import { useAttachmentCache } from '../../context/AttachmentCacheContext'
import { useAuth } from '../../context/AuthContext'
import { useLedgers } from '../../context/LedgersContext'
import { usePageCache } from '../../context/PageDataCacheContext'
import { useSyncRefresh } from '../../context/SyncSocketContext'
import { localizeError } from '../../i18n/errors'

/**
 * 分类管理页 —— 分类列表 + CRUD + 自定义图标的 preview URL 解析(拿
 * icon_cloud_file_id 去 downloadAttachment,转成 objectURL 给 CategoriesPanel
 * 的 `iconPreviewUrlByFileId` 用)。
 *
 * 图标 preview cache 随 Page unmount 时主动 revokeObjectURL 释放,避免
 * 长时间在该页停留积累 blob。
 */
export function CategoriesPage() {
  const t = useT()
  const toast = useToast()
  const { token } = useAuth()
  const { activeLedgerId } = useLedgers()
  const { retryOnConflict, isWriteConflict } = useLedgerWrite()
  const { previewMap: iconPreviewByFileId, ensureLoadedMany } = useAttachmentCache()

  const [rows, setRows] = usePageCache<WorkspaceCategory[]>('categories:rows', [])
  const [form, setForm] = useState<CategoryForm>(categoryDefaults())
  const [pendingDelete, setPendingDelete] = useState<{ id: string; name: string } | null>(null)
  // 编辑 dialog 受控开关 — CategoriesPanel 行编辑、CategoryDetailDialog 联动
  // 编辑都通过这个 state 触发;由 panel 内部 onCreate/onEdit 也会切到 true。
  const [editDialogOpen, setEditDialogOpen] = useState(false)

  // 批量移动交易 —— 双入口共用:
  //  - batchMoveTxIds === undefined → entry A(整分类全量,还需拉全量 tx_ids)
  //  - batchMoveTxIds = string[]    → entry B(勾选的部分,直接提交)
  const [batchMoveSource, setBatchMoveSource] = useState<WorkspaceCategory | null>(null)
  const [batchMoveTxIds, setBatchMoveTxIds] = useState<string[] | undefined>(undefined)
  const [moveSaving, setMoveSaving] = useState(false)

  // detail 弹窗已迁到 GlobalEntityDialogs(AppShell 顶层)。本页只负责
  // dispatch openDetailCategory 让全局打开;同时监听 openEditCategory
  // 把 inline 编辑表单填上 + 打开。

  const notifyError = useCallback(
    (err: unknown) => toast.error(localizeError(err, t), t('notice.error')),
    [toast, t]
  )
  const notifySuccess = useCallback(
    (msg: string) => toast.success(msg, t('notice.success')),
    [toast, t]
  )

  const refresh = useCallback(async () => {
    try {
      setRows(await fetchWorkspaceCategories(token, { limit: 500 }))
    } catch (err) {
      notifyError(err)
    }
  }, [token, notifyError])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useSyncRefresh(() => {
    void refresh()
  })

  // 通过共享 AttachmentCache 惰性加载自定义图标。rows 更新时把所有
  // icon_cloud_file_id push 给 context,context 内部自己去重 + dedupe inflight。
  useEffect(() => {
    const ids = rows
      .map((row) => row.icon_cloud_file_id || '')
      .filter((value) => value.trim().length > 0)
    if (ids.length > 0) ensureLoadedMany(ids)
  }, [rows, ensureLoadedMany])

  const txCountById = useMemo(() => {
    const out: Record<string, number> = {}
    for (const row of rows) {
      if (!row.id) continue
      out[row.id] = row.tx_count ?? 0
    }
    return out
  }, [rows])

  const onSave = async (): Promise<boolean> => {
    if (!activeLedgerId) {
      toast.error(t('shell.selectLedgerFirst'), t('notice.error'))
      return false
    }
    try {
      const payload = {
        name: form.name,
        kind: form.kind,
        level: form.level ? Number(form.level) : null,
        sort_order: form.sort_order ? Number(form.sort_order) : null,
        icon: form.icon || null,
        icon_type: form.icon_type || null,
        custom_icon_path: form.custom_icon_path || null,
        icon_cloud_file_id: form.icon_cloud_file_id || null,
        icon_cloud_sha256: form.icon_cloud_sha256 || null,
        parent_name: form.parent_name || null,
      }
      await retryOnConflict(activeLedgerId, (base) =>
        form.editingId
          ? updateCategory(token, activeLedgerId, form.editingId, base, payload)
          : createCategory(token, activeLedgerId, base, payload)
      )
      setForm(categoryDefaults())
      await refresh()
      notifySuccess(form.editingId ? t('notice.categoryUpdated') : t('notice.categoryCreated'))
      return true
    } catch (err) {
      if (isWriteConflict(err)) await refresh()
      notifyError(err)
      return false
    }
  }

  const enterEdit = useCallback((row: ReadCategory) => {
    setForm({
      editingId: row.id,
      editingOwnerUserId: row.created_by_user_id || '',
      name: row.name,
      kind: row.kind,
      level: String(row.level ?? ''),
      sort_order: String(row.sort_order ?? ''),
      icon: row.icon || '',
      icon_type: row.icon_type || 'material',
      custom_icon_path: row.custom_icon_path || '',
      icon_cloud_file_id: row.icon_cloud_file_id || '',
      icon_cloud_sha256: row.icon_cloud_sha256 || '',
      parent_name: row.parent_name || '',
    })
    setEditDialogOpen(true)
  }, [])

  // 编辑分类的 openEditCategory 事件由 GlobalEditDialogs 全局接管,
  // 不需要在本页再注册一份监听(否则会双开 dialog)。本页只在用户直接
  // 点击行的「编辑」按钮时通过 onEdit prop 触发本页内置 dialog。

  const confirmDelete = async () => {
    if (!pendingDelete || !activeLedgerId) return
    try {
      await retryOnConflict(activeLedgerId, (base) =>
        deleteCategory(token, activeLedgerId, pendingDelete.id, base)
      )
      await refresh()
      notifySuccess(t('notice.categoryDeleted'))
    } catch (err) {
      if (isWriteConflict(err)) await refresh()
      notifyError(err)
    } finally {
      setPendingDelete(null)
    }
  }

  // 批量移动:打开选目标分类的 dialog。entry A(txIds undefined)表示"整分类
  // 全量",确认时才分页拉全量 tx_ids;entry B 直接带上勾选的 ids。
  const handleBatchMove = useCallback(
    (source: WorkspaceCategory, txIds?: string[]) => {
      if (!activeLedgerId) {
        toast.error(t('shell.selectLedgerFirst'), t('notice.error'))
        return
      }
      setBatchMoveSource(source)
      setBatchMoveTxIds(txIds)
    },
    [activeLedgerId, toast, t]
  )

  /** 分页拉某分类的全量 tx sync_ids(entry A)。limit 500 循环直到 total。 */
  const fetchAllCategoryTxIds = useCallback(
    async (categoryId: string): Promise<string[]> => {
      const ids: string[] = []
      let offset = 0
      let total = Infinity
      while (ids.length < total && offset < 10000) {
        const page = await fetchWorkspaceTransactions(token, {
          categorySyncId: categoryId,
          limit: 500,
          offset,
        })
        if (ids.length === 0) total = page.total
        for (const item of page.items) {
          if (item.id) ids.push(item.id)
        }
        offset += page.items.length
        if (page.items.length === 0) break
      }
      return ids
    },
    [token]
  )

  /** 把 tx_ids 切成 <=200 的组(server 单次上限)。 */
  const chunk = useCallback((ids: string[], size = 200): string[][] => {
    const out: string[][] = []
    for (let i = 0; i < ids.length; i += size) out.push(ids.slice(i, i + size))
    return out
  }, [])

  const confirmBatchMove = useCallback(
    async (target: WorkspaceCategory) => {
      if (!activeLedgerId || !batchMoveSource) return
      // 已选分类不可再作为目标(排除自身)
      if (target.id === batchMoveSource.id) {
        toast.error(t('categories.batchMove.sameSource'), t('notice.error'))
        return
      }
      setMoveSaving(true)
      try {
        let txIds = batchMoveTxIds
        if (txIds === undefined) {
          // entry A:先拉全量,再切批提交
          txIds = await fetchAllCategoryTxIds(batchMoveSource.id)
        }
        if (txIds.length === 0) {
          toast.info(t('categories.batchMove.noTransactions'), t('notice.info'))
          return
        }
        let movedCount = 0
        let failedCount = 0
        for (const group of chunk(txIds)) {
          const result = await retryOnConflict(activeLedgerId, (base) =>
            batchMoveTransactions(token, {
              ledgerId: activeLedgerId,
              txIds: group,
              targetCategoryId: target.id,
              baseChangeId: base,
            })
          )
          movedCount += result.moved_tx_ids.length
          failedCount += result.failed.length
        }
        setBatchMoveSource(null)
        setBatchMoveTxIds(undefined)
        // 旧的源/目标分类笔数会变,刷新整份 rows + 详情交易
        await refresh()
        notifySuccess(
          t('categories.batchMove.success', {
            moved: movedCount,
            failed: failedCount,
            target: target.name,
          })
        )
      } catch (err) {
        if (isWriteConflict(err)) await refresh()
        notifyError(err)
      } finally {
        setMoveSaving(false)
      }
    },
    [
      activeLedgerId,
      batchMoveSource,
      batchMoveTxIds,
      token,
      fetchAllCategoryTxIds,
      chunk,
      retryOnConflict,
      isWriteConflict,
      refresh,
      toast,
      t,
      notifySuccess,
      notifyError,
    ]
  )

  return (
    <>
      <CategoriesPanel
        form={form}
        rows={rows}
        iconPreviewUrlByFileId={iconPreviewByFileId}
        txCountById={txCountById}
        canManage
        dialogOpen={editDialogOpen}
        onDialogOpenChange={setEditDialogOpen}
        onFormChange={setForm}
        onCreate={(defaultKind) =>
          setForm({
            ...categoryDefaults(),
            ...(defaultKind ? { kind: defaultKind } : {}),
          })
        }
        onSave={onSave}
        onReset={() => setForm(categoryDefaults())}
        onEdit={enterEdit}
        onRowClick={(row) => dispatchOpenDetailCategory(row, { defaultScope: 'all' })}
        loadCategoryTransactions={async (categorySyncId, offset) =>
          fetchWorkspaceTransactions(token, { categorySyncId, limit: 20, offset })
        }
        onBatchMove={handleBatchMove}
        onDelete={(row) => {
          // 跟 mobile _deleteCategory 对齐:本分类 + 所有子分类加起来没有
          // 任何关联交易才允许删除;子分类随父分类一起级联删除(服务端
          // snapshot mutator 同步级联,并为每个子分类补 delete 事件)。
          const ws =
            (rows.find((r) => r.id === row.id) as WorkspaceCategory | undefined) ||
            (row as WorkspaceCategory)
          const children = rows.filter(
            (r) =>
              r.id !== ws.id &&
              r.parent_name === ws.name &&
              r.kind === ws.kind,
          )
          const familyTxCount =
            (ws.tx_count ?? 0) +
            children.reduce((acc, child) => acc + (txCountById[child.id] ?? 0), 0)
          if (familyTxCount > 0) {
            toast.error(
              t('categories.delete.blockedByTransactions', {
                name: ws.name,
                count: familyTxCount,
              }),
              t('notice.error'),
            )
            return
          }
          setPendingDelete({ id: ws.id, name: ws.name })
        }}
        onUploadIcon={async (file) => {
          if (!activeLedgerId) {
            toast.error(t('accounts.error.ledgerRequired'), t('notice.error'))
            return null
          }
          try {
            const out = await uploadAttachment(token, { ledger_id: activeLedgerId, file })
            return { fileId: out.file_id, sha256: out.sha256 }
          } catch (err) {
            notifyError(err)
            return null
          }
        }}
      />
      <ConfirmDialog
        open={!!pendingDelete}
        title={t('confirm.deleteCategory.title')}
        description={
          pendingDelete
            ? t('confirm.deleteCategory.desc').replace('{name}', pendingDelete.name)
            : ''
        }
        confirmText={t('confirm.delete')}
        cancelText={t('confirm.cancel')}
        onCancel={() => setPendingDelete(null)}
        onConfirm={() => void confirmDelete()}
      />
      {/* 批量移动交易 —— 选目标分类。候选 = 与源分类同 kind 的全部分类(排除源自身)。 */}
      <BatchMoveDialog
        open={!!batchMoveSource}
        onClose={() => {
          if (!moveSaving) {
            setBatchMoveSource(null)
            setBatchMoveTxIds(undefined)
          }
        }}
        count={
          batchMoveTxIds !== undefined
            ? batchMoveTxIds.length
            : txCountById[batchMoveSource?.id ?? ''] ?? batchMoveSource?.tx_count ?? 0
        }
        rows={
          batchMoveSource
            ? rows.filter(
                (r) => r.kind === batchMoveSource.kind && r.id !== batchMoveSource.id
              )
            : []
        }
        kind={(batchMoveSource?.kind as 'expense' | 'income') ?? 'expense'}
        iconPreviewUrlByFileId={iconPreviewByFileId}
        saving={moveSaving}
        onConfirm={(target) => void confirmBatchMove(target)}
      />
      {/* CategoryDetailDialog 已迁到 GlobalEntityDialogs。本页 onClickCategory 现
          dispatch openDetailCategory 让全局弹窗渲染。 */}
    </>
  )
}
