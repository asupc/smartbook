import { useEffect, useMemo, useState } from 'react'

import {
  Badge,
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuTrigger,
  Input,
  Label,
  Pagination,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  useT
} from '@smartbook/ui'

import type {
  AttachmentRef,
  ReadAccount,
  ReadCategory,
  ReadTag,
  ReadTransaction,
} from '@smartbook/api-client'

import { CurrencySelectorTrigger } from '../components/CurrencySelector'
import { CategoryIcon } from '../components/CategoryIcon'
import { TagChip } from '../components/TagChip'
import { buildTagColorMap, tagTextColorOn } from '../lib/tagColorPalette'
import { currencySymbol } from '../lib/currencies'
import { composeTransactionRowTitle } from '../lib/transactionRowTitle'
import type { TxForm } from '../forms'

type TransactionsPanelProps = {
  form: TxForm
  /** 账本本位币(大写 ISO)。币种下拉默认值;选=本位币时 form.currency 存 ''。 */
  baseCurrency?: string
  /** v30 多币种:各币种对 baseCurrency 的汇率(1 quote ≈ x base),透传币种选择弹窗展示。 */
  currencyRates?: Record<string, number>
  rows: ReadTransaction[]
  total: number
  page: number
  pageSize: number
  accounts: ReadAccount[]
  categories: ReadCategory[]
  tags: ReadTag[]
  ledgerOptions: Array<{ ledger_id: string; ledger_name: string }>
  writeLedgerId: string
  onWriteLedgerIdChange: (ledgerId: string) => void
  onPageChange: (page: number) => void
  onPageSizeChange: (pageSize: number) => void
  canWrite: boolean
  dictionariesLoading?: boolean
  showCreatorColumn?: boolean
  showLedgerColumn?: boolean
  onFormChange: (next: TxForm) => void
  /** Dialog 显隐由外层控制。新建/编辑入口都靠 parent 在 setOpen(true) 之前
   *  把 form 初始化好,然后 setOpen(true)。这样 page 可以把"新建交易"按钮
   *  跟搜索/筛选放同一行,跟内嵌在 panel 内的 onCreate 解耦。 */
  dialogOpen: boolean
  onDialogOpenChange: (open: boolean) => void
  onSave: () => Promise<boolean> | boolean
  onReset: () => void
  onReload: () => void
  onPreviewAttachment: (
    refs: AttachmentRef[],
    startIndex: number
  ) => Promise<void>
  resolveAttachmentPreviewUrl: (ref: AttachmentRef) => Promise<string | null>
  /** 自定义分类图标的预签预览 URL 字典,TransactionList 里每行 CategoryIcon
   *  用来拿 blob URL 显示云端上传的 PNG 图标。material icon 不需要。 */
  iconPreviewUrlByFileId?: Record<string, string>
  onEdit: (row: ReadTransaction) => void
  onDelete: (row: ReadTransaction) => void
  /** 行整体点击 → 打开详情弹窗。如果不传则点行无效果(保留兼容性)。 */
  onSelect?: (row: ReadTransaction) => void
  /** dialogOnly:不渲染交易列表/分页,只挂编辑 Dialog + 内嵌 picker。
   *  让全局 edit 容器(GlobalEditTxDialog)能复用 panel 内置的所有字段渲染 +
   *  picker 联动逻辑,不必从头实现。 */
  dialogOnlyMode?: boolean
  /** 批量选择模式 —— 透传到 TransactionList。 */
  selectionMode?: boolean
  selectedIds?: Set<string>
  onToggleSelect?: (row: ReadTransaction, event: React.MouseEvent) => void
  /** §7 共享账本:开启后 tx 列表行末显示"谁记的"chip。 */
  showCreator?: boolean
  /** §7 共享账本:当前 caller user_id,自己创建+编辑的 tx 不显示 chip。 */
  currentUserId?: string | null
  /** 备注显示方式,透传到 TransactionList。默认 'category'。 */
  noteDisplayMode?: 'category' | 'note'
}

type AttachmentCarouselCellProps = {
  attachments: AttachmentRef[]
  onPreviewAttachment: (
    refs: AttachmentRef[],
    startIndex: number
  ) => Promise<void>
  resolveAttachmentPreviewUrl: (ref: AttachmentRef) => Promise<string | null>
  partialLabel: string
  metadataOnlyLabel: string
  notPreviewableLabel: string
  prevLabel: string
  nextLabel: string
}

function AttachmentCarouselCell({
  attachments,
  onPreviewAttachment,
  resolveAttachmentPreviewUrl,
  partialLabel,
  metadataOnlyLabel,
  notPreviewableLabel,
  prevLabel,
  nextLabel
}: AttachmentCarouselCellProps) {
  const [index, setIndex] = useState(0)
  const [previewUrl, setPreviewUrl] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const readyAttachments = attachments.filter(
    (attachment) => typeof attachment.cloudFileId === 'string' && attachment.cloudFileId.trim().length > 0
  )
  const current = readyAttachments[index]

  useEffect(() => {
    if (readyAttachments.length === 0) {
      setIndex(0)
      return
    }
    if (index >= readyAttachments.length) {
      setIndex(0)
    }
  }, [index, readyAttachments.length])

  useEffect(() => {
    let cancelled = false
    if (!current) {
      setPreviewUrl(null)
      setLoading(false)
      return () => {
        cancelled = true
      }
    }
    setLoading(true)
    void resolveAttachmentPreviewUrl(current)
      .then((url) => {
        if (cancelled) return
        setPreviewUrl(url)
      })
      .finally(() => {
        if (cancelled) return
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [current, resolveAttachmentPreviewUrl])

  if (attachments.length === 0) return <>-</>

  if (readyAttachments.length === 0) {
    return (
      <div className="flex items-center gap-2">
        <Badge variant="secondary">{attachments.length}</Badge>
        <span className="text-xs text-muted-foreground">{metadataOnlyLabel}</span>
      </div>
    )
  }

  return (
    <div className="space-y-2">
      <div className="relative h-24 w-40 overflow-hidden rounded-md border border-border/70 bg-muted/30">
        {previewUrl ? (
          <img
            alt={current?.originalName || current?.fileName || 'attachment-preview'}
            className="h-full w-full cursor-zoom-in object-cover"
            src={previewUrl}
            onClick={() => {
              if (!current) return
              void onPreviewAttachment(readyAttachments, index)
            }}
          />
        ) : (
          <div className="flex h-full items-center justify-center px-2 text-center text-[11px] text-muted-foreground">
            {loading ? '...' : notPreviewableLabel}
          </div>
        )}
        {readyAttachments.length > 1 ? (
          <>
            <Button
              aria-label={prevLabel}
              className="absolute left-1 top-1/2 h-6 w-6 -translate-y-1/2 bg-background/90 p-0"
              size="icon"
              type="button"
              variant="outline"
              onClick={() =>
                setIndex((prev) => (prev - 1 + readyAttachments.length) % readyAttachments.length)
              }
            >
              ‹
            </Button>
            <Button
              aria-label={nextLabel}
              className="absolute right-1 top-1/2 h-6 w-6 -translate-y-1/2 bg-background/90 p-0"
              size="icon"
              type="button"
              variant="outline"
              onClick={() => setIndex((prev) => (prev + 1) % readyAttachments.length)}
            >
              ›
            </Button>
          </>
        ) : null}
      </div>
      <div className="flex items-center gap-2">
        <Badge variant="default">{attachments.length}</Badge>
        {readyAttachments.length > 0 ? (
          <span className="text-xs text-muted-foreground">
            {Math.min(index + 1, readyAttachments.length)}/{readyAttachments.length}
          </span>
        ) : null}
        {readyAttachments.length < attachments.length ? (
          <span className="text-xs text-muted-foreground">{partialLabel}</span>
        ) : null}
      </div>
    </div>
  )
}

export function TransactionsPanel({
  form,
  baseCurrency = 'CNY',
  currencyRates,
  rows,
  total,
  page,
  pageSize,
  accounts,
  categories,
  tags,
  ledgerOptions,
  writeLedgerId,
  onWriteLedgerIdChange,
  onPageChange,
  onPageSizeChange,
  canWrite,
  dictionariesLoading = false,
  showCreatorColumn = false,
  showLedgerColumn = false,
  onFormChange,
  dialogOpen,
  onDialogOpenChange,
  onSave,
  onReset,
  onReload,
  onPreviewAttachment,
  resolveAttachmentPreviewUrl,
  iconPreviewUrlByFileId,
  onEdit,
  onDelete,
  onSelect,
  dialogOnlyMode,
  selectionMode = false,
  selectedIds,
  onToggleSelect,
  showCreator = false,
  currentUserId,
  noteDisplayMode = 'category'
}: TransactionsPanelProps) {
  const t = useT()
  const open = dialogOpen
  const setOpen = onDialogOpenChange

  const dedupSortNames = (names: string[]) =>
    names
      .filter((name) => name.length > 0)
      .filter((name, index, self) => self.indexOf(name) === index)
      .sort((a, b) => a.localeCompare(b))
  // 账户隐藏(issue #240):记账/转账选择器排除隐藏账户 —— 不能再往它记新账。
  const hiddenAccountNames = new Set(
    accounts.filter((row) => row.hidden).map((row) => row.name.trim())
  )
  const accountOptions = dedupSortNames(accounts.map((row) => row.name.trim()).filter((name) => !hiddenAccountNames.has(name)))
  // E1 唯一例外:编辑一笔本就挂在某隐藏账户上的历史交易时,选择器钉住显示该
  // 隐藏账户(带「已隐藏」灰标),让用户可原样保存;其它隐藏账户仍不出现。
  // 一旦改选走其它选项,该隐藏名字就不会再被钉回来(下次渲染 currentValue 已变)。
  const accountOptionsWithPinned = (currentValue: string) => {
    const trimmed = currentValue.trim()
    if (trimmed && hiddenAccountNames.has(trimmed)) {
      return dedupSortNames([...accountOptions, trimmed])
    }
    return accountOptions
  }
  // 分类下拉选项:跟当前 tx_type 一致、去重、按名排序。
  const categoryOptions = categories
    .filter((row) => row.kind === form.tx_type)
    .map((row) => row.name.trim())
    .filter((name) => name.length > 0)
    .filter((name, index, self) => self.indexOf(name) === index)
    .sort((a, b) => a.localeCompare(b))
  // tag 选择已改内联 DropdownMenu,不再用 TagPickerDialog。tagColorByName
  // 给触发器 chip + 列表项颜色块渲染上色用。
  const tagColorByName = new Map<string, string>()
  for (const row of tags) {
    const key = (row.name || '').trim().toLowerCase()
    if (!key) continue
    if (row.color && !tagColorByName.has(key)) tagColorByName.set(key, row.color)
  }

  const isTransfer = form.tx_type === 'transfer'
  // 非转账允许不选账户（与 mobile 保持一致，tx.accountId 本来就是 nullable）；
  // 转账必须两端都选（否则无法表达方向）。
  const canSubmit = Boolean(writeLedgerId.trim()) && (isTransfer
    ? Boolean(form.from_account_name.trim()) && Boolean(form.to_account_name.trim())
    : true)
  const selectedTags = form.tags
  const categoryValue = form.category_name.trim()

  const applyTxType = (nextType: TxForm['tx_type']) => {
    if (nextType === 'transfer') {
      // 转账两个标记都隐藏 → 清掉,避免残留脏值。
      // currency 一并清空:转账不支持跨币种且币种控件隐藏,不清会把转出/
      // 转入账户下拉锁死在之前手选的外币过滤里(审查发现)。
      onFormChange({
        ...form,
        tx_type: nextType,
        account_name: '',
        currency: '',
        category_name: '',
        category_kind: 'transfer',
        exclude_from_stats: false,
        exclude_from_budget: false
      })
      return
    }
    const keepCategory = form.category_kind === nextType ? form.category_name : ''
    onFormChange({
      ...form,
      tx_type: nextType,
      category_kind: nextType,
      category_name: keepCategory,
      from_account_name: '',
      to_account_name: '',
      // 不计入预算仅 expense 显示;切到 income 时清掉
      exclude_from_budget: nextType === 'expense' ? form.exclude_from_budget : false
    })
  }

  // 表列数:8 列(时间/金额/类型/分类/账户/标签/记录时间/操作)+ 选择模式首列。
  // showCreatorColumn/showLedgerColumn 不再映射为独立列(创建人 chip 内嵌于
  // 分类列),保留参数仅为 API 兼容。
  const colCount = 8 + (selectionMode ? 1 : 0)

  // 交易表行内 tag chip 配色字典(与 TransactionRow 同来源:buildTagColorMap)。
  const tagColorMap = useMemo(() => buildTagColorMap(tags as Array<{ name?: string; color?: string }>), [tags])

  return (
    <>
      {/* dialogOnlyMode: 全局编辑容器复用本 panel 的 Dialog + picker 联动,
          不渲染列表 / 分页。 */}
      {dialogOnlyMode ? null : (
        <div className="rounded-xl border border-border/50 bg-card overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                {selectionMode ? <TableHead className="bc-table-head w-[40px]"><input type="checkbox" aria-label="select" className="h-4 w-4 cursor-pointer accent-primary" /></TableHead> : null}
                <TableHead className="bc-table-head">{t('transactions.table.time')}</TableHead>
                <TableHead className="bc-table-head">{t('transactions.table.amount')}</TableHead>
                <TableHead className="bc-table-head">{t('transactions.table.type')}</TableHead>
                <TableHead className="bc-table-head">{t('transactions.table.category')}</TableHead>
                <TableHead className="bc-table-head">{t('transactions.table.account')}</TableHead>
                <TableHead className="bc-table-head">{t('transactions.table.tags')}</TableHead>
                <TableHead className="bc-table-head">{t('transactions.table.createdAt')}</TableHead>
                <TableHead className="bc-table-head">{t('transactions.table.ops')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={colCount} className="py-12 text-center text-sm text-muted-foreground">
                    {t('table.empty')}
                  </TableCell>
                </TableRow>
              ) : null}
              {rows.map((row) => (
                <TransactionRowCell
                  key={row.id}
                  row={row}
                  tagColorMap={tagColorMap}
                  noteDisplayMode={noteDisplayMode}
                  currencySymbolByCode={currencySymbol}
                  canManage={canWrite}
                  showCreator={showCreator}
                  currentUserId={currentUserId}
                  selectionMode={selectionMode}
                  selected={selectedIds?.has(row.id) ?? false}
                  onToggleSelect={onToggleSelect}
                  onSelect={onSelect}
                  onEdit={(r) => { onEdit(r); setOpen(true) }}
                  onDelete={onDelete}
                  onPreviewAttachment={onPreviewAttachment}
                  iconPreviewUrlByFileId={iconPreviewUrlByFileId}
                  categories={categories}
                />
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={pageSize}
            total={total}
            onPageChange={onPageChange}
            onPageSizeChange={onPageSizeChange}
          />
        </div>
      )}

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="flex max-h-[85vh] max-w-2xl flex-col gap-0 overflow-hidden p-0">
          <DialogHeader className="border-b border-border/60 px-6 py-4">
            <DialogTitle>{form.editingId ? t('transactions.button.update') : t('transactions.button.create')}</DialogTitle>
          </DialogHeader>
          <div className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
            <div className="grid gap-3 md:grid-cols-2">
              <div className="space-y-1">
              <Label>{t('shell.ledger')}</Label>
              <Select value={writeLedgerId || undefined} onValueChange={onWriteLedgerIdChange} disabled={Boolean(form.editingId)}>
                <SelectTrigger>
                  <SelectValue placeholder={t('shell.ledger')} />
                </SelectTrigger>
                <SelectContent>
                  {ledgerOptions.map((ledger) => (
                    <SelectItem key={ledger.ledger_id} value={ledger.ledger_id}>
                      {ledger.ledger_name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1">
              <Label>{t('transactions.table.type')}</Label>
              <Select value={form.tx_type} onValueChange={(value) => applyTxType(value as TxForm['tx_type'])}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="expense">{t('enum.txType.expense')}</SelectItem>
                  <SelectItem value="income">{t('enum.txType.income')}</SelectItem>
                  <SelectItem value="transfer">{t('enum.txType.transfer')}</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1">
              <Label>{t('transactions.table.amount')}</Label>
              <Input
                placeholder={t('transactions.placeholder.amount')}
                value={form.amount}
                onChange={(e) => onFormChange({ ...form, amount: e.target.value })}
              />
              {/* v30 多币种:币种另起一行,全宽显示币种全名+国旗(挨金额太窄会截断);
                  选非本位币 → 账户下拉按币种过滤 + 已选账户清空(币种优先联动,
                  transfer 不支持)。 */}
              {form.tx_type !== 'transfer' ? (
                <CurrencySelectorTrigger
                  value={form.currency || baseCurrency}
                  onChange={(code) =>
                    onFormChange({
                      ...form,
                      currency:
                        code.toUpperCase() === baseCurrency.toUpperCase()
                          ? ''
                          : code,
                      account_name: ''
                    })
                  }
                  ratesToBase={currencyRates}
                  rateBase={baseCurrency}
                />
              ) : null}
            </div>
            <div className="space-y-1">
              <Label>{t('transactions.table.time')}</Label>
              <Input
                type="datetime-local"
                step={60}
                value={isoToDatetimeLocal(form.happened_at)}
                onChange={(e) =>
                  onFormChange({
                    ...form,
                    happened_at: datetimeLocalToIso(e.target.value, form.happened_at)
                  })
                }
              />
            </div>
            <div className="space-y-1">
              <Label>{t('transactions.table.category')}</Label>
              {isTransfer ? (
                <Input disabled value={t('common.none')} />
              ) : (
                <Select
                  value={categoryValue || '__none__'}
                  disabled={dictionariesLoading}
                  onValueChange={(value) =>
                    onFormChange({
                      ...form,
                      category_name: value === '__none__' ? '' : value,
                      category_kind: form.tx_type,
                    })
                  }
                >
                  <SelectTrigger>
                    <SelectValue placeholder={t('transactions.placeholder.categoryName')} />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__none__">
                      <span className="text-muted-foreground">
                        {t('common.none')}
                      </span>
                    </SelectItem>
                    {categoryOptions.map((name) => (
                      <SelectItem key={name} value={name}>
                        {name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>

            {isTransfer ? (
              <>
                <div className="space-y-1">
                  <Label>{t('transactions.placeholder.fromAccountName')}</Label>
                  <Select
                    value={form.from_account_name || undefined}
                    disabled={dictionariesLoading}
                    onValueChange={(value) => onFormChange({ ...form, from_account_name: value })}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder={t('transactions.placeholder.fromAccountName')} />
                    </SelectTrigger>
                    <SelectContent>
                      {accountOptionsWithPinned(form.from_account_name).map((name) => (
                        <SelectItem key={name} value={name}>
                          {name}
                          {hiddenAccountNames.has(name) ? (
                            <span className="ml-1 text-xs text-muted-foreground">
                              {t('accounts.hidden.optionSuffix')}
                            </span>
                          ) : null}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label>{t('transactions.placeholder.toAccountName')}</Label>
                  <Select
                    value={form.to_account_name || undefined}
                    disabled={dictionariesLoading}
                    onValueChange={(value) => onFormChange({ ...form, to_account_name: value })}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder={t('transactions.placeholder.toAccountName')} />
                    </SelectTrigger>
                    <SelectContent>
                      {accountOptionsWithPinned(form.to_account_name).map((name) => (
                        <SelectItem key={name} value={name}>
                          {name}
                          {hiddenAccountNames.has(name) ? (
                            <span className="ml-1 text-xs text-muted-foreground">
                              {t('accounts.hidden.optionSuffix')}
                            </span>
                          ) : null}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </>
            ) : (
              <div className="space-y-1">
                <Label>{t('transactions.table.account')}</Label>
                <Select
                  // Radix SelectItem 不允许 value=""(undefined-state 由 placeholder
                  // 渲染),所以用 sentinel "__none__" 表示"不选账户"。和 form 的
                  // 真实空串状态在 value 和 onValueChange 两处来回翻译。
                  value={form.account_name ? form.account_name : '__none__'}
                  disabled={dictionariesLoading}
                  onValueChange={(value) =>
                    onFormChange({ ...form, account_name: value === '__none__' ? '' : value })
                  }
                >
                  <SelectTrigger>
                    <SelectValue placeholder={t('transactions.placeholder.accountName')} />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__none__">
                      <span className="text-muted-foreground">
                        {t('transactions.placeholder.noAccount')}
                      </span>
                    </SelectItem>
                    {accountOptionsWithPinned(form.account_name).map((name) => (
                      <SelectItem key={name} value={name}>
                        {name}
                        {hiddenAccountNames.has(name) ? (
                          <span className="ml-1 text-xs text-muted-foreground">
                            {t('accounts.hidden.optionSuffix')}
                          </span>
                        ) : null}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            )}

            <div className="space-y-1">
              <Label>{t('tags.title')}</Label>
              {/* tag 多选改为内联 DropdownMenu —— 无需打开弹窗,直接在触发器下
                  展开勾选列表,已选标签在触发器里以彩色 chip 缩略展示。 */}
              <DropdownMenu>
                <DropdownMenuTrigger
                  disabled={dictionariesLoading}
                  className="flex h-10 w-full items-center gap-2 rounded-md border border-input bg-muted px-3 py-2 text-left text-sm shadow-sm transition-colors hover:bg-accent/40 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <span className="flex flex-1 items-center gap-1 overflow-hidden">
                    {selectedTags.length === 0 ? (
                      <span className="text-muted-foreground">
                        {t('common.none')}
                      </span>
                    ) : (
                      <span className="flex flex-wrap items-center gap-1 overflow-hidden">
                        {selectedTags.slice(0, 3).map((name) => {
                          const color = tagColorByName.get(name.toLowerCase()) || '#94a3b8'
                          const fg = tagTextColorOn(color)
                          return (
                            <span
                              key={name}
                              className="inline-flex h-5 max-w-[120px] items-center rounded-full px-1.5 text-[11px] leading-none"
                              style={{ background: color, color: fg }}
                              title={name}
                            >
                              <span className="truncate">{name}</span>
                            </span>
                          )
                        })}
                        {selectedTags.length > 3 ? (
                          <span className="text-[11px] text-muted-foreground">
                            +{selectedTags.length - 3}
                          </span>
                        ) : null}
                      </span>
                    )}
                  </span>
                  <span className="text-xs text-muted-foreground opacity-60">▾</span>
                </DropdownMenuTrigger>
                <DropdownMenuContent className="w-56 max-h-72 overflow-y-auto">
                  {tags.map((tag) => {
                    const name = (tag.name || '').trim()
                    if (!name) return null
                    const color = tagColorByName.get(name.toLowerCase()) || '#94a3b8'
                    const fg = tagTextColorOn(color)
                    const checked = selectedTags.includes(name)
                    return (
                      <DropdownMenuCheckboxItem
                        key={name}
                        checked={checked}
                        onSelect={() => {
                          const next = checked
                            ? selectedTags.filter((n) => n !== name)
                            : [...selectedTags, name]
                          onFormChange({ ...form, tags: next })
                        }}
                      >
                        <span
                          className="mr-2 inline-block h-2 w-2 rounded-full"
                          style={{ background: color }}
                        />
                        <span className="truncate">{name}</span>
                      </DropdownMenuCheckboxItem>
                    )
                  })}
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
            <div className="space-y-1 md:col-span-2">
              <Label>{t('transactions.table.note')}</Label>
              <Input
                placeholder={t('transactions.placeholder.note')}
                value={form.note}
                onChange={(e) => onFormChange({ ...form, note: e.target.value })}
              />
            </div>
            {/* §三 标记开关 — 按当前 type 条件显示:
                  不计入收支:income / expense(转账本就不进收支,隐藏)
                  不计入预算:仅 expense(预算只统计支出) */}
            {form.tx_type !== 'transfer' ? (
              <div className="flex items-center justify-between rounded-lg border border-border/60 bg-muted/20 px-3 py-2 md:col-span-2">
                <p className="text-sm font-medium">{t('txFlagExcludeFromStats')}</p>
                <button
                  type="button"
                  role="switch"
                  aria-checked={form.exclude_from_stats}
                  aria-label={t('txFlagExcludeFromStats') as string}
                  onClick={() =>
                    onFormChange({ ...form, exclude_from_stats: !form.exclude_from_stats })
                  }
                  className={`relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full transition-colors ${
                    form.exclude_from_stats ? 'bg-primary' : 'bg-muted-foreground/30'
                  }`}
                >
                  <span
                    className={`inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform ${
                      form.exclude_from_stats ? 'translate-x-[18px]' : 'translate-x-0.5'
                    }`}
                  />
                </button>
              </div>
            ) : null}
            {form.tx_type === 'expense' ? (
              <div className="flex items-center justify-between rounded-lg border border-border/60 bg-muted/20 px-3 py-2 md:col-span-2">
                <p className="text-sm font-medium">{t('txFlagExcludeFromBudget')}</p>
                <button
                  type="button"
                  role="switch"
                  aria-checked={form.exclude_from_budget}
                  aria-label={t('txFlagExcludeFromBudget') as string}
                  onClick={() =>
                    onFormChange({ ...form, exclude_from_budget: !form.exclude_from_budget })
                  }
                  className={`relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full transition-colors ${
                    form.exclude_from_budget ? 'bg-primary' : 'bg-muted-foreground/30'
                  }`}
                >
                  <span
                    className={`inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform ${
                      form.exclude_from_budget ? 'translate-x-[18px]' : 'translate-x-0.5'
                    }`}
                  />
                </button>
              </div>
            ) : null}
          </div>
          </div>
          <DialogFooter className="shrink-0 border-t border-border/60 bg-card px-6 py-4">
            <Button
              variant="outline"
              onClick={() => {
                onReset()
                setOpen(false)
              }}
            >
              {t('dialog.cancel')}
            </Button>
            <Button
              disabled={!canWrite || !canSubmit}
              onClick={async () => {
                const success = await onSave()
                if (success) {
                  setOpen(false)
                }
              }}
            >
              {form.editingId ? t('transactions.button.update') : t('transactions.button.create')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}

/**
 * 把后端 ISO 时间（可能带 Z / 毫秒 / 时区 offset）转成 `<input type="datetime-local">`
 * 期望的 `YYYY-MM-DDTHH:mm` 字符串。用本地时区展示，避免用户看到的时间跟记录
 * 时间错位一个时区。
 */
function isoToDatetimeLocal(iso: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/**
 * datetime-local 返回的本地时间字符串反序列化成后端想要的 ISO。保留原 value
 * 的秒与时区（避免用户只改了分钟却把秒抹 0 + 跨时区）。
 */
function datetimeLocalToIso(local: string, fallback: string): string {
  if (!local) return fallback
  // `new Date('2026-04-17T23:32')` 会按本地时区解析；toISOString() 再转 UTC。
  const d = new Date(local)
  if (Number.isNaN(d.getTime())) return fallback
  return d.toISOString()
}

/**
 * 单笔交易在表格中的一行。把原 TransactionRow 的 2×2 tile 布局拍平成表行，
 * 渲染列：时间 / 类型 / 分类 / 账户 / 标签 / 金额 / 操作。
 *
 * 保留原行组件的交互语义：点行触发 onSelect(打开详情弹窗)，编辑/删除/标签/
 * 附件按钮 stopPropagation 不冒泡。
 */
function TransactionRowCell({
  row,
  tagColorMap,
  noteDisplayMode,
  currencySymbolByCode,
  canManage,
  showCreator,
  currentUserId,
  selectionMode,
  selected,
  onToggleSelect,
  onSelect,
  onEdit,
  onDelete,
  onPreviewAttachment,
  iconPreviewUrlByFileId,
  categories,
}: {
  row: ReadTransaction
  tagColorMap: Map<string, string>
  noteDisplayMode: 'category' | 'note'
  currencySymbolByCode: (code: string) => string
  canManage: boolean
  showCreator: boolean
  currentUserId?: string | null
  selectionMode: boolean
  selected: boolean
  onToggleSelect?: (row: ReadTransaction, event: React.MouseEvent) => void
  onSelect?: (row: ReadTransaction) => void
  onEdit: (row: ReadTransaction) => void
  onDelete: (row: ReadTransaction) => void
  onPreviewAttachment?: (refs: AttachmentRef[], startIndex: number) => Promise<void>
  iconPreviewUrlByFileId?: Record<string, string>
  categories: ReadCategory[]
}) {
  const t = useT()
  const attachments = Array.isArray(row.attachments) ? row.attachments : []
  const amountTone = row.tx_type === 'expense' ? 'negative' : row.tx_type === 'income' ? 'positive' : 'default'
  const sign = row.tx_type === 'expense' ? '-' : row.tx_type === 'income' ? '+' : ''
  const isForeignCurrency = !!row.currency_code && row.native_amount != null && row.native_amount !== row.amount
  const categoryText = row.category_name || (row.tx_type === 'transfer' ? t('enum.txType.transfer') : '-')
  const rowTitle = composeTransactionRowTitle({
    mode: noteDisplayMode,
    categoryName: row.category_name,
    categoryText,
    note: row.note,
  })
  const accountText = row.tx_type === 'transfer'
    ? `${row.from_account_name || '-'} → ${row.to_account_name || '-'}`
    : row.account_name || '-'

  // 分类图标:优先 category_id 精确匹配,退化按 name+kind 兜底(与 TransactionRow 同源)。
  const categoryEntry = (() => {
    const byId = row.category_id ? categories.find((c) => c.id === row.category_id) : null
    if (byId) return byId
    if (!row.category_name) return null
    return categories.find((c) => c.name === row.category_name && c.kind === row.category_kind) || null
  })()

  const hasAttachments = attachments.length > 0 && Boolean(onPreviewAttachment)
  const firstAttachment = attachments[0]

  const handleRowClick = (event: React.MouseEvent<HTMLTableRowElement>) => {
    if (selectionMode && onToggleSelect) {
      onToggleSelect(row, event as unknown as React.MouseEvent)
      return
    }
    if (onSelect) onSelect(row)
  }

  return (
    <TableRow
      onClick={handleRowClick}
      className={`odd:bg-muted/20 ${(selectionMode || onSelect) ? 'cursor-pointer' : ''} ${selectionMode && selected ? 'bg-primary/8' : ''}`}
    >
      {selectionMode ? (
        <TableCell className="w-[40px]">
          <input
            type="checkbox"
            checked={selected}
            onChange={() => undefined}
            onClick={(e) => {
              e.stopPropagation()
              if (onToggleSelect) onToggleSelect(row, e)
            }}
            aria-label={t('common.select') as string}
            className="h-4 w-4 cursor-pointer accent-primary"
          />
        </TableCell>
      ) : null}
      <TableCell className="whitespace-nowrap font-mono tabular-nums text-xs text-muted-foreground">
        {formatTableDateTime(row.happened_at)}
      </TableCell>
      <TableCell className="whitespace-nowrap text-left">
        <span className={`font-mono tabular-nums font-bold ${
          amountTone === 'positive' ? 'text-income'
            : amountTone === 'negative' ? 'text-expense'
              : 'text-foreground'
        }`}>
          {sign}
          {isForeignCurrency ? currencySymbolByCode(row.currency_code as string) : ''}
          {(row.amount ?? 0).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
        </span>
        {isForeignCurrency ? (
          <span className="ml-1 font-mono tabular-nums text-[10px] text-muted-foreground" title={t('transactions.convertedToBase')}>
            ≈{(row.native_amount as number).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
          </span>
        ) : null}
        {hasAttachments && firstAttachment ? (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation()
              void onPreviewAttachment?.(attachments, 0)
            }}
            className="ml-1 inline-flex items-center gap-1 rounded border border-border/60 bg-muted/30 px-1 py-0.5 text-[10px] text-muted-foreground hover:border-primary/40 hover:text-primary"
            title={firstAttachment.originalName || firstAttachment.fileName || t('attachment.default')}
          >
            <span aria-hidden>📎</span>
            <span className="font-mono tabular-nums">{attachments.length}</span>
          </button>
        ) : null}
      </TableCell>
      <TableCell className="whitespace-nowrap">
        <Badge variant={row.tx_type === 'transfer' ? 'secondary' : row.tx_type === 'income' ? 'outline' : 'default'}>
          {t(`enum.txType.${row.tx_type}`)}
        </Badge>
      </TableCell>
      <TableCell>
        <div className="flex min-w-0 items-center gap-1.5">
          {categoryEntry ? (
            <CategoryIcon
              icon={categoryEntry.icon}
              iconType={categoryEntry.icon_type}
              iconCloudFileId={categoryEntry.icon_cloud_file_id}
              iconPreviewUrlByFileId={iconPreviewUrlByFileId}
              size={16}
              className="shrink-0 text-muted-foreground"
            />
          ) : null}
          <span className="truncate text-sm font-medium">{rowTitle.primary}</span>
          {rowTitle.parenNote ? (
            <span className="truncate text-xs text-muted-foreground">({rowTitle.parenNote})</span>
          ) : null}
          {showCreator ? <CreatorBadge row={row} currentUserId={currentUserId} t={t} /> : null}
        </div>
      </TableCell>
      <TableCell className="max-w-[180px]">
        <span className="block truncate text-xs text-muted-foreground" title={accountText}>{accountText}</span>
      </TableCell>
      <TableCell className="max-w-[220px]">
        <div className="flex flex-wrap items-center gap-1">
          {row.tags_list && row.tags_list.length > 0 ? (
            row.tags_list.map((tagName) => (
              <TagChip key={tagName} name={tagName} color={tagColorMap.get(tagName.trim().toLowerCase())} />
            ))
          ) : (
            <span className="text-xs text-muted-foreground">-</span>
          )}
        </div>
      </TableCell>
      <TableCell className="whitespace-nowrap font-mono tabular-nums text-xs text-muted-foreground">
        {row.created_at ? formatTableDateTime(row.created_at) : '-'}
      </TableCell>
      <TableCell className="whitespace-nowrap">
        <div className="flex items-center gap-3">
          {canManage ? (
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); onEdit(row) }}
              className="text-sm text-foreground underline-offset-4 hover:text-primary hover:underline"
            >
              {t('common.edit')}
            </button>
          ) : null}
          {canManage ? (
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); onDelete(row) }}
              className="text-sm text-destructive underline-offset-4 hover:text-destructive/90 hover:underline"
            >
              {t('common.delete')}
            </button>
          ) : null}
        </div>
      </TableCell>
    </TableRow>
  )
}

/** 共享账本表行分类列后的「谁记的」轮廓 chip(简化版,仅展示名字)。 */
function CreatorBadge({
  row,
  currentUserId,
  t,
}: {
  row: ReadTransaction
  currentUserId?: string | null
  t: (key: string, vars?: Record<string, string>) => string
}) {
  const creatorUid = row.created_by_user_id || ''
  const editorUid = row.last_edited_by_user_id || creatorUid
  if (!creatorUid && !editorUid) return null
  const isCreatorMe = !!currentUserId && creatorUid === currentUserId
  const isEditorMe = !!currentUserId && editorUid === currentUserId
  if (isCreatorMe && isEditorMe) return null
  const creatorName = row.created_by_display_name || (row.created_by_email || '').split('@')[0] || '?'
  const editorName = row.last_edited_by_display_name || (row.last_edited_by_email || '').split('@')[0] || creatorName
  const sameUser = creatorUid && editorUid && creatorUid === editorUid
  const label = sameUser
    ? t('sharedLedger.tileCreatedAndEditedBy', { name: creatorName })
    : `${t('sharedLedger.tileCreatedBy', { name: creatorName })} · ${t('sharedLedger.tileEditedBy', { name: editorName })}`
  return (
    <span
      className="ml-1 inline-flex max-w-[120px] items-center truncate rounded bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium leading-none text-primary"
      title={label}
    >
      <span className="truncate">{creatorName}</span>
    </span>
  )
}

function formatTableDateTime(value: string | null | undefined): string {
  if (!value) return '-'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  const mm = String(d.getMonth() + 1).padStart(2, '0')
  const dd = String(d.getDate()).padStart(2, '0')
  const hh = String(d.getHours()).padStart(2, '0')
  const mi = String(d.getMinutes()).padStart(2, '0')
  return `${d.getFullYear()}-${mm}-${dd} ${hh}:${mi}`
}

