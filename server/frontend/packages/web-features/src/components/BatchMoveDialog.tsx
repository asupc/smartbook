import { useState } from 'react'

import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  useT,
} from '@smartbook/ui'
import type { WorkspaceCategory } from '@smartbook/api-client'

import { CategorySelector } from './CategorySelector'

type BatchMoveDialogProps = {
  open: boolean
  onClose: () => void
  /** 要搬的交易笔数(展示用)。 */
  count: number
  /** 目标分类候选 —— 通常传源分类同 kind 的分类(排除自身)。 */
  rows: readonly WorkspaceCategory[]
  kind: 'expense' | 'income'
  iconPreviewUrlByFileId?: Record<string, string>
  saving: boolean
  /** 用户选中目标分类并点确认后回调。 */
  onConfirm: (target: WorkspaceCategory) => void
}

/**
 * 批量移动交易 —— 选目标分类 + 确认。
 *
 * 复用 [CategorySelector] 选目标分类(与交易/父级选取同交互),foot 放
 * 「确认移动」按钮。saving 时禁用确认 & 取消。这是"移动到某个分类"的
 * 正向确认,不同于批量删除的 destructive 语义,所以不做危险样式。
 */
export function BatchMoveDialog({
  open,
  onClose,
  count,
  rows,
  kind,
  iconPreviewUrlByFileId,
  saving,
  onConfirm,
}: BatchMoveDialogProps) {
  const t = useT()
  const [selected, setSelected] = useState<WorkspaceCategory | null>(null)

  const handleSelect = (cat: WorkspaceCategory) => {
    setSelected(cat)
  }

  const close = () => {
    if (saving) return
    setSelected(null)
    onClose()
  }

  const confirm = () => {
    if (!selected || saving) return
    onConfirm(selected)
  }

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) close() }}>
      <DialogContent className="w-[640px]">
        <DialogHeader>
          <DialogTitle>{t('categories.batchMove.title', { count })}</DialogTitle>
        </DialogHeader>
        <div className="space-y-3">
          <p className="text-sm text-muted-foreground">
            {t('categories.batchMove.hint')}
          </p>
          <div className="max-h-[55vh] overflow-y-auto rounded-lg border border-border/50 bg-card/40 p-3">
            <CategorySelector
              kind={kind}
              rows={rows}
              iconPreviewUrlByFileId={iconPreviewUrlByFileId}
              selectedId={selected?.id}
              onSelect={handleSelect}
              emptyText={t('categories.batchMove.empty')}
            />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={close} disabled={saving}>
            {t('dialog.cancel')}
          </Button>
          <Button onClick={confirm} disabled={!selected || saving}>
            {t('categories.batchMove.confirm', { count })}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
