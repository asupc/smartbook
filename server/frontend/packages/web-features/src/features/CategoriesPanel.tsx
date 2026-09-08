import { useCallback, useEffect, useMemo, useState } from 'react'
import { Select as AntSelect } from 'antd'

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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  useT
} from '@smartbook/ui'

import type { ReadCategory, ReadTransaction, WorkspaceCategory, WorkspaceTransaction, WorkspaceTransactionPage } from '@smartbook/api-client'

import { Plus } from 'lucide-react'

import { CategoryIcon } from '../components/CategoryIcon'
import { TransactionList } from '../components/TransactionList'
import { getIconGroupsByKind, type CategoryIconItem } from '../lib/categoryIconGroups'
import { categoryDefaults, type CategoryForm } from '../forms'

type CategoryKind = 'expense' | 'income' | 'transfer'

/** 用户能新建的分类类型。`transfer` 是虚拟分类(转账自动归类),系统种子,
 *  app 端也不允许用户手动创建,这里同步限制。 */
const CREATABLE_KINDS: ReadonlyArray<Extract<CategoryKind, 'expense' | 'income'>> = [
  'expense',
  'income',
]

/** 「无父分类」下拉项的值 —— parent_name 为空字符串表示顶级分类。用一个不可能
 *  与真实分类名冲突的哨兵值,避免与某个叫 "__no_parent__" 的分类名撞车。 */
const PARENT_NONE = '__no_parent__'

/** 右栏详情「最近交易」加载器 —— 页面用 token 实现并传入(panel 在共享包里,
 *  不持有 auth)。返回分页 `{ items, total, limit, offset }`。 */
type CategoryRecentLoader = (
  categorySyncId: string,
  offset: number
) => Promise<WorkspaceTransactionPage>

/** 分类图标选择器。
 *
 * 跟 app 端 `lib/pages/category/icon_picker_page.dart` 行为一致:
 * - 按当前 `kind`(支出 / 收入)拿到分组(`getIconGroupsByKind`),组里都是
 *   app 已经在用的图标(8 组支出 + 4 组收入,≈70 个),所有 key 都在
 *   categoryIconMap.ts 的 KNOWN_NAMES / FLUTTER_RENAMES 里有定义,Material
 *   Symbols 字体一定能渲出来,不会再出现"图标渲成字面文字"的乱码。
 * - 顶部 group tabs(餐饮/出行/购物...)切换。
 * - 搜索框:有内容时切换为"跨组按 key 模糊匹配"的扁平结果(label 也参与匹配)。
 * - 选中后 onSelect 写回 form.icon 并关闭;stored 值保持跟 app 端 stored 值
 *   一致(例如"part_time" 这种 FLUTTER_RENAMES 的 key,保存的是 part_time
 *   不是 schedule,跨端解释靠 resolveMaterialIconName)。
 */
function IconPickerDialog({
  open,
  kind,
  currentIcon,
  onClose,
  onSelect,
}: {
  open: boolean
  /** 当前编辑的分类类型,决定 picker 显示支出还是收入图标分组 */
  kind: string
  currentIcon: string | null | undefined
  onClose: () => void
  onSelect: (icon: string) => void
}) {
  const t = useT()
  const groups = getIconGroupsByKind(kind)
  const [activeGroupIdx, setActiveGroupIdx] = useState(0)
  const [query, setQuery] = useState('')

  useEffect(() => {
    if (!open) {
      setQuery('')
      setActiveGroupIdx(0)
    }
  }, [open])

  // kind 改了重置选中 tab,避免上次留下的索引超出新 group 长度
  useEffect(() => {
    setActiveGroupIdx(0)
  }, [kind])

  const isSearching = query.trim().length > 0

  // 搜索:跨组按 key 包含 / label 包含 模糊匹配
  const searchResults = useMemo<CategoryIconItem[]>(() => {
    const q = query.trim().toLowerCase()
    if (!q) return []
    const seen = new Set<string>()
    const out: CategoryIconItem[] = []
    for (const group of groups) {
      for (const item of group.icons) {
        if (seen.has(item.key)) continue
        const matchKey = item.key.toLowerCase().includes(q)
        const matchLabel = item.label.toLowerCase().includes(q)
        if (matchKey || matchLabel) {
          seen.add(item.key)
          out.push(item)
        }
      }
    }
    return out
  }, [groups, query])

  const visibleIcons: CategoryIconItem[] = isSearching
    ? searchResults
    : groups[Math.min(activeGroupIdx, groups.length - 1)]?.icons ?? []

  const renderItem = (item: CategoryIconItem) => {
    const isSelected =
      (currentIcon || '').trim().toLowerCase() === item.key.toLowerCase()
    return (
      <button
        key={item.key}
        type="button"
        title={item.key}
        aria-label={item.label}
        onClick={() => {
          onSelect(item.key)
          onClose()
        }}
        className={`flex h-16 w-full flex-col items-center justify-center gap-1 rounded-lg border transition-all ${
          isSelected
            ? 'border-primary bg-primary/10 text-primary ring-1 ring-primary/50'
            : 'border-border/40 bg-card hover:border-primary/40 hover:bg-accent/40'
        }`}
      >
        <CategoryIcon icon={item.key} iconType="material" size={22} />
        <span className="truncate text-[10px] leading-none text-muted-foreground">
          {item.label}
        </span>
      </button>
    )
  }

  return (
    <Dialog open={open} onOpenChange={(next) => { if (!next) onClose() }}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{t('categories.iconPicker.title')}</DialogTitle>
        </DialogHeader>
        <div className="space-y-3">
          <Input
            placeholder={t('categories.iconPicker.search')}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />

          {/* group tabs:搜索时隐藏,搜索结果优先 */}
          {!isSearching ? (
            <div className="flex flex-wrap gap-1.5">
              {groups.map((group, idx) => {
                const active = idx === activeGroupIdx
                return (
                  <button
                    key={group.labelKey}
                    type="button"
                    onClick={() => setActiveGroupIdx(idx)}
                    className={`rounded-md px-2.5 py-1 text-xs font-medium transition-colors ${
                      active
                        ? 'bg-primary/15 text-primary ring-1 ring-primary/40'
                        : 'text-muted-foreground hover:bg-accent/40 hover:text-foreground'
                    }`}
                  >
                    {t(group.labelKey)}
                  </button>
                )
              })}
            </div>
          ) : null}

          <div className="max-h-[55vh] overflow-y-auto">
            {visibleIcons.length === 0 ? (
              <div className="py-8 text-center text-xs text-muted-foreground">
                {t('categories.iconPicker.empty')}
              </div>
            ) : (
              <div className="grid grid-cols-4 gap-2 sm:grid-cols-6">
                {visibleIcons.map(renderItem)}
              </div>
            )}
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {t('dialog.cancel')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

type CategoriesPanelProps = {
  form: CategoryForm
  rows: WorkspaceCategory[]
  iconPreviewUrlByFileId?: Record<string, string>
  canManage: boolean
  showCreatorColumn?: boolean
  /** category.id → 笔数。从 WorkspaceCategoryOut.tx_count 派生,跨账本聚合后
   *  的总笔数。CardBody 上展示 + 编辑 level=2 时父级候选过滤都会用。 */
  txCountById?: Record<string, number>
  onFormChange: (next: CategoryForm) => void
  /** 触发"新建"流程:外层负责把 form 重置成 categoryDefaults() 并打开 dialog。可带入预选的 kind。 */
  onCreate?: (defaultKind?: 'expense' | 'income') => void
  onSave: () => Promise<boolean> | boolean
  onReset: () => void
  onEdit: (row: ReadCategory) => void
  onDelete?: (row: ReadCategory) => void
  /** 点击列表行(整行点击,避开 Edit / Delete 按钮)的回调。不传则行不可点击。 */
  onRowClick?: (row: WorkspaceCategory) => void
  /** Upload a custom icon file to the cloud and return the refs to store in the form. */
  onUploadIcon?: (file: File) => Promise<{ fileId: string; sha256: string } | null>
  /** 受控 dialog 开关 — 让外层(如详情弹窗 → 编辑链)能命令式打开本 panel
   *  的编辑 dialog。不传时 panel 内部用 state 自己管;传了就 controlled。 */
  dialogOpen?: boolean
  onDialogOpenChange?: (next: boolean) => void
  /** 不渲染列表/EmptyState,只挂 Dialog + picker — 用于全局编辑容器复用。 */
  dialogOnlyMode?: boolean
  /** 右栏详情「最近交易」加载器。传了才在选中分类时拉取交易;不传则不显示
   *  交易区(仅用于 detail-only 场景,如对话框)。 */
  loadCategoryTransactions?: CategoryRecentLoader
  /**
   * 批量移动交易入口。页面负责把它接到后端 + 渲染 BatchMoveDialog。
   * 参数说明:
   *   - entryA(整分类):onBatchMove(source, undefined) —— "批量移动全部"。
   *   - entryB(勾选):onBatchMove(source, txIds) —— 移动选中的若干笔。
   */
  onBatchMove?: (source: WorkspaceCategory, txIds?: string[]) => void
}

/**
 * 分类管理面板 —— 「双栏树 + 详情」。
 *
 * PC 宽屏后台布局:
 * - 左栏 层级树(支出/收入/转账 tab + 可折叠父子节点,每节点带笔数徽章)。
 * - 右栏 选中项的详情(图标 + 类型/层级徽章 + KPI 笔数 + 子分类快捷列表
 *   + 最近交易 `TransactionList` 无限滚动)。
 *
 * 保留 app 能力与既有契约:
 * - 顶部"新建分类" CTA(EmptyState 同 CTA)
 * - kind 限 expense / income(transfer 是虚拟分类用户不能新建,跟 app
 *   _categoryRepo.createCategory 的契约一致)
 * - 父子层级:选了"父分类"自动 level=2,清空则 level=1。隐藏 level/sort 文本输
 *   入,避免用户填错。父分类候选按当前 kind 过滤、只列已存在的 level=1。
 * - 同 kind 同名前端查重(workspace 维度,server 兜底)
 * - 图标用 Material Symbols 网格选择器替代裸文本输入,~290 个图标 + 搜索;
 *   custom 模式仍走文件上传走 cloud attachment
 * - 编辑模式打开**所有字段**(原版只允许改名)
 *
 * 新建/编辑/删除弹窗与 picker 全部保留;`dialogOnlyMode` 时仅挂 Dialog+picker
 * (GlobalEditDialogs 复用场景)。
 */
export function CategoriesPanel({
  form,
  rows,
  iconPreviewUrlByFileId = {},
  canManage,
  showCreatorColumn = false,
  txCountById = {},
  onFormChange,
  onCreate,
  onSave,
  onReset,
  onEdit,
  onDelete,
  onRowClick,
  onUploadIcon,
  dialogOpen,
  onDialogOpenChange,
  dialogOnlyMode,
  loadCategoryTransactions,
  onBatchMove,
}: CategoriesPanelProps) {
  const t = useT()
  const [internalOpen, setInternalOpen] = useState(false)
  const open = dialogOpen ?? internalOpen
  const setOpen = (next: boolean) => {
    if (onDialogOpenChange) onDialogOpenChange(next)
    else setInternalOpen(next)
  }
  const [iconPickerOpen, setIconPickerOpen] = useState(false)
  const [duplicateError, setDuplicateError] = useState<string | null>(null)

  // 父分类候选:跟当前编辑/新建的 kind 一致 + 必须是 level=1(顶级) + 排除自
  // 己(避免自己挂自己当父的死循环)。app 端 createSubCategory 只允许 level=2
  // 挂 level=1 父,这里同 contract。
  const parentCandidateRows = useMemo(() => {
    const editingId = form.editingId
    return rows.filter((row) => {
      if (row.kind !== form.kind) return false
      if (Number(row.level) !== 1) return false
      if (editingId && row.id === editingId) return false
      return (row.name || '').trim().length > 0
    })
  }, [rows, form.kind, form.editingId])

  // 父级下拉的实际条目:候选列表 + (若有)当前已选但不在候选里的父级。后者
  // 兜底跨端乱数据,避免 Select 值悬空显示空白。
  const parentOptions = useMemo(() => {
    const opts = [...parentCandidateRows]
    const currentName = (form.parent_name || '').trim()
    if (currentName && !opts.some((r) => (r.name || '').trim() === currentName)) {
      const row = rows.find(
        (r) => r.kind === form.kind && (r.name || '').trim() === currentName,
      )
      if (row) opts.unshift(row)
    }
    return opts
  }, [parentCandidateRows, form.parent_name, rows, form.kind])

  // 当前编辑的分类是否已含子分类(仅编辑一级分类时读)。一个一级分类一旦有
  // 了子分类,就不能再降级为二级(否则它的子分类会按 parent_name 匹配到一
  // 个不再是顶级行的父级,变成孤儿)。无子分类的顶级才允许重新指定父级。
  const editingHasChildren = useMemo(() => {
    if (!form.editingId) return false
    const kind = form.kind
    const name = (form.name || '').trim().toLowerCase()
    if (!name) return false
    return rows.some(
      (row) =>
        row.id !== form.editingId &&
        row.kind === kind &&
        (row.parent_name || '').trim().toLowerCase() === name,
    )
  }, [rows, form.editingId, form.kind, form.name])

  // 同 kind 同名查重(workspace 维度。fetchWorkspaceCategories 已经按
  // current_user.id 过滤,所以 rows 自然是用户作用域的)。编辑模式排除自己以
  // 允许"改图标不改名"。case-insensitive,跟 server snapshot_mutator 对齐。
  const existingNamesLower = useMemo(() => {
    const set = new Set<string>()
    for (const row of rows) {
      if (form.editingId && row.id === form.editingId) continue
      if (row.kind !== form.kind) continue
      const name = (row.name || '').trim().toLowerCase()
      if (name) set.add(name)
    }
    return set
  }, [rows, form.kind, form.editingId])

  const renderIcon = (
    icon: string | null | undefined,
    iconType: string | null | undefined,
    iconCloudFileId?: string | null
  ) => (
    <CategoryIcon
      icon={icon}
      iconType={iconType}
      iconCloudFileId={iconCloudFileId}
      iconPreviewUrlByFileId={iconPreviewUrlByFileId}
      size={20}
      className="text-primary"
    />
  )

  const startCreate = (defaultKind?: 'expense' | 'income') => {
    if (!canManage) return
    setDuplicateError(null)
    onCreate?.(defaultKind)
    if (defaultKind) {
      onFormChange({
        ...categoryDefaults(),
        kind: defaultKind,
      })
    }
    setOpen(true)
  }

  const startEdit = (row: ReadCategory) => {
    setDuplicateError(null)
    onEdit(row)
    setOpen(true)
  }

  const handleSave = async () => {
    const trimmed = form.name.trim()
    if (!trimmed) {
      setDuplicateError(t('categories.error.nameRequired'))
      return
    }
    if (existingNamesLower.has(trimmed.toLowerCase())) {
      setDuplicateError(t('categories.error.nameDuplicate'))
      return
    }
    // 自定义图片必须有图。点了 remove 但还没重新上传就保存是非法状态:
    // server 落库会得到 icon_type='custom' 但 icon_cloud_file_id 空 → web/app
    // 渲不出来。这里前端拦下,要么用户重传图,要么改回 material。
    if (form.icon_type === 'custom') {
      const hasCloudFile = (form.icon_cloud_file_id || '').trim().length > 0
      const hasUrl = /^(https?:\/\/|data:image\/|\/)/.test((form.icon || '').trim())
      if (!hasCloudFile && !hasUrl) {
        setDuplicateError(t('categories.error.customIconRequired'))
        return
      }
    }
    setDuplicateError(null)
    const success = await onSave()
    if (success) {
      setOpen(false)
    }
  }

  const isEmpty = rows.length === 0

  return (
    <>
      {/* dialogOnlyMode: 全局编辑容器复用 Dialog + picker,不渲染列表 */}
      {!dialogOnlyMode && (
        <>
          {isEmpty ? (
            <EmptyState
              icon={
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none"
                     stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"
                     strokeLinejoin="round">
                  <path d="M3 6l3-3h12l3 3" />
                  <path d="M3 6v14a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1V6" />
                  <path d="M8 11h8" />
                </svg>
              }
              title={t('categories.empty.title')}
              description={t('categories.empty.desc')}
              action={
                onCreate && canManage ? (
                  <Button onClick={() => startCreate()}>{t('categories.button.create')}</Button>
                ) : undefined
              }
            />
          ) : (
            <CategoriesTwoPane
              rows={rows}
              txCountById={txCountById}
              canManage={canManage}
              showCreatorColumn={showCreatorColumn}
              renderIcon={renderIcon}
              onEdit={startEdit}
              onDelete={onDelete}
              onRowClick={onRowClick}
              loadTransactions={loadCategoryTransactions}
              onBatchMove={onBatchMove}
              onCreate={startCreate}
            />
          )}
        </>
      )}

      <Dialog open={open} onOpenChange={(next) => {
        setOpen(next)
        if (!next) setDuplicateError(null)
      }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{form.editingId ? t('categories.button.update') : t('categories.button.create')}</DialogTitle>
          </DialogHeader>
          <div className="grid gap-3">
            {/* 名称 */}
            <div className="space-y-1">
              <Label>{t('categories.table.name')}</Label>
              <Input
                placeholder={t('categories.placeholder.name')}
                value={form.name}
                onChange={(e) => {
                  if (duplicateError) setDuplicateError(null)
                  onFormChange({ ...form, name: e.target.value })
                }}
              />
              {duplicateError ? (
                <p className="text-xs text-destructive">{duplicateError}</p>
              ) : null}
            </div>

            {/* 类型(收/支)。transfer 不在选项里 —— 那是系统种子虚拟分类,用
                户不能手动创建,跟 app 行为对齐。
                **编辑模式下 kind 不可改**:跨 kind 变更会让所有引用此分类的交易
                归类错乱,且子分类按 (parent_name, kind) 匹配父级会错位,跟 app
                category_edit_page 的限制对齐。 */}
            <div className="space-y-1">
              <Label>{t('categories.table.kind')}</Label>
              {form.editingId ? (
                <div className="flex items-center justify-between rounded-md border border-border/40 bg-muted/30 px-3 py-2 text-sm">
                  <span>{t(`enum.txType.${form.kind}`)}</span>
                  <span className="text-xs text-muted-foreground">
                    {t('categories.kind.locked')}
                  </span>
                </div>
              ) : (
                <Select
                  value={CREATABLE_KINDS.includes(form.kind as 'expense' | 'income')
                    ? form.kind
                    : 'expense'}
                  onValueChange={(value) => {
                    // 改 kind 后,parent_name 可能跟新 kind 不匹配,清掉避免幻象。
                    onFormChange({
                      ...form,
                      kind: value as CategoryForm['kind'],
                      parent_name: '',
                      level: '1',
                    })
                  }}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {CREATABLE_KINDS.map((k) => (
                      <SelectItem key={k} value={k}>
                        {t(`enum.txType.${k}`)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>

            {/* 父分类。
                **新建**:可选,选了 → level=2(子分类),不选 → level=1(顶级)。
                **编辑 level=1(无子分类)**:可重新指定父级 → 降级为 level=2;
                有子分类时锁定(降级会让其子分类按 parent_name 匹配到非顶级父级
                → 孤儿)。
                **编辑 level=2**:可换到另一个同 kind 的父分类;也可点「无父分类」
                清空父级 → 升级回顶级(对齐 mobile 关闭子分类开关)。 */}
            <div className="space-y-1 relative z-20">
              <Label>{t('categories.placeholder.parent')}</Label>
              {form.editingId && form.level === '1' && editingHasChildren ? (
                <div className="flex items-center justify-between rounded-md border border-border/40 bg-muted/30 px-3 py-2 text-sm">
                  <span className="text-muted-foreground">
                    {t('common.none')}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {t('categories.parent.lockedTopLevel')}
                  </span>
                </div>
              ) : (
                <AntSelect
                  showSearch
                  className="w-full"
                  value={form.parent_name || PARENT_NONE}
                  placeholder={t('categories.placeholder.parent')}
                  optionFilterProp="label"
                  getPopupContainer={(triggerNode) => (triggerNode.parentElement as HTMLElement) || document.body}
                  onChange={(value) => {
                    if (value === PARENT_NONE) {
                      onFormChange({ ...form, parent_name: '', level: '1' })
                    } else {
                      onFormChange({ ...form, parent_name: value, level: '2' })
                    }
                  }}
                  options={[
                    { value: PARENT_NONE, label: t('common.none') },
                    ...parentOptions.map((row) => ({
                      value: row.name,
                      label: row.name,
                    })),
                  ]}
                />
              )}
            </div>

            {/* 图标:material 走网格选择器,custom 走文件上传 */}
            <div className="space-y-1">
              <Label>{t('categories.placeholder.iconType')}</Label>
              <Select
                value={form.icon_type || 'material'}
                onValueChange={(value) => onFormChange({ ...form, icon_type: value })}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="material">{t('categories.iconType.material')}</SelectItem>
                  <SelectItem value="custom">{t('categories.iconType.custom')}</SelectItem>
                </SelectContent>
              </Select>
            </div>

            {(form.icon_type || 'material') === 'material' ? (
              <div className="space-y-1">
                <Label>{t('categories.placeholder.icon')}</Label>
                <button
                  type="button"
                  onClick={() => setIconPickerOpen(true)}
                  className="flex h-10 w-full items-center gap-2 rounded-md border border-input bg-muted px-3 py-2 text-left text-sm shadow-sm transition-colors hover:bg-accent/40"
                >
                  <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/15">
                    {renderIcon(form.icon || 'category', 'material')}
                  </span>
                  <span className="flex-1 truncate font-mono text-xs text-muted-foreground">
                    {form.icon || t('categories.iconPicker.choose')}
                  </span>
                  <span className="text-xs text-muted-foreground opacity-60">▾</span>
                </button>
              </div>
            ) : null}

            {form.icon_type === 'custom' && onUploadIcon ? (
              <div className="space-y-1">
                <Label>{t('categories.placeholder.customIcon')}</Label>
                <div className="flex items-center gap-2">
                  <input
                    type="file"
                    accept="image/*"
                    className="text-sm"
                    onChange={async (e) => {
                      const file = e.target.files?.[0]
                      e.currentTarget.value = ''
                      if (!file) return
                      const res = await onUploadIcon(file)
                      if (res) {
                        onFormChange({
                          ...form,
                          icon_cloud_file_id: res.fileId,
                          icon_cloud_sha256: res.sha256
                        })
                      }
                    }}
                  />
                  {form.icon_cloud_file_id || form.custom_icon_path ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() =>
                        // 同时清掉 cloud refs(server 端 GC 孤儿 attachment)和
                        // custom_icon_path(app 端 _applyCategoryChange 收到 path 空 →
                        // 删本地 custom_icons 文件)。点 remove 是"彻底丢掉这张图"
                        // 的语义,不只是清云端引用。
                        onFormChange({
                          ...form,
                          icon_cloud_file_id: '',
                          icon_cloud_sha256: '',
                          custom_icon_path: '',
                        })
                      }
                    >
                      {t('common.remove')}
                    </Button>
                  ) : null}
                </div>
              </div>
            ) : null}

            {/* 预览 */}
            <div className="space-y-1">
              <Label>{t('categories.preview')}</Label>
              <div className="flex items-center gap-2 rounded-md border border-border/70 bg-muted/40 px-3 py-2">
                <div className="flex h-9 w-9 items-center justify-center rounded-md bg-primary/10">
                  {renderIcon(form.icon || 'category', form.icon_type, form.icon_cloud_file_id)}
                </div>
                <span className="text-sm font-medium">
                  {form.name.trim() || t('categories.placeholder.name')}
                </span>
                {form.parent_name ? (
                  <span className="text-xs text-muted-foreground">
                    ({form.parent_name})
                  </span>
                ) : null}
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
              {form.editingId ? t('categories.button.update') : t('categories.button.create')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <IconPickerDialog
        open={iconPickerOpen}
        kind={form.kind}
        currentIcon={form.icon}
        onClose={() => setIconPickerOpen(false)}
        onSelect={(icon) => onFormChange({ ...form, icon, icon_type: 'material' })}
      />
    </>
  )
}

// --------------------------------------------------------------------------
// 双栏「树 + 详情」视图
// --------------------------------------------------------------------------

type RenderIconFn = (
  icon: string | null | undefined,
  iconType: string | null | undefined,
  iconCloudFileId?: string | null
) => React.ReactNode

const KIND_ORDER: CategoryKind[] = ['expense', 'income', 'transfer']

/** 按 kind 分组 + 子级归属同一次 useMemo(供左树与右栏详情复用)。 */
function groupCategories(rows: WorkspaceCategory[]) {
  const parentsByKind: Record<CategoryKind, WorkspaceCategory[]> = {
    expense: [],
    income: [],
    transfer: [],
  }
  const childrenByParent: Record<string, WorkspaceCategory[]> = {}
  for (const row of rows) {
    const kind = (row.kind as CategoryKind) || 'expense'
    const parent = (row.parent_name || '').trim()
    if (parent) {
      const key = `${kind}::${parent.toLowerCase()}`
      childrenByParent[key] = childrenByParent[key] || []
      childrenByParent[key].push(row)
    } else {
      parentsByKind[kind].push(row)
    }
  }
  for (const kind of KIND_ORDER) {
    parentsByKind[kind].sort(
      (a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0) || a.name.localeCompare(b.name)
    )
  }
  for (const key of Object.keys(childrenByParent)) {
    childrenByParent[key].sort(
      (a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0) || a.name.localeCompare(b.name)
    )
  }
  return { parentsByKind, childrenByParent }
}

/**
 * 左栏树节点。父级可点击展开/收起子级并选中;叶子点击即选中。整行高亮
 * 选中项;右上角展开箭头只对"有子级"的父级显示。
 */
function CategoryTreeNode({
  category,
  level,
  hasChildren,
  expanded,
  selected,
  count,
  renderIcon,
  onToggle,
  onSelect,
}: {
  category: WorkspaceCategory
  level: number
  hasChildren: boolean
  expanded: boolean
  selected: boolean
  count: number
  renderIcon: RenderIconFn
  onToggle: () => void
  onSelect: () => void
}) {
  const t = useT()
  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onSelect()
        }
      }}
      className={`group flex w-full cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm transition-colors ${
        selected ? 'bg-primary/15 text-primary' : 'hover:bg-accent/40 hover:text-foreground'
      }`}
      style={{ paddingLeft: 8 + level * 18 }}
    >
      {hasChildren ? (
        <span
          role="button"
          tabIndex={0}
          aria-label={expanded ? 'collapse' : 'expand'}
          onClick={(e) => {
            e.stopPropagation()
            onToggle()
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              e.stopPropagation()
              onToggle()
            }
          }}
          className="flex h-4 w-4 shrink-0 items-center justify-center rounded text-xs text-muted-foreground hover:bg-accent"
        >
          <span className={`inline-block leading-none transition-transform ${expanded ? 'rotate-90' : ''}`}>▸</span>
        </span>
      ) : (
        <span className="h-4 w-4 shrink-0" />
      )}
      <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-muted/60">
        {renderIcon(category.icon, category.icon_type, category.icon_cloud_file_id)}
      </span>
      <span className="truncate">{category.name}</span>
      {count > 0 ? (
        <span className="ml-auto shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[10px] leading-none text-muted-foreground tabular-nums">
          {count}
        </span>
      ) : null}
    </div>
  )
}

/**
 * 右栏详情：命中项的信息 + KPI + 子分类/同级快捷列表 + 最近交易(无限滚动)。
 * 不做任何数据请求 —— transaction 由外层 `loadTransactions` 注入。
 */
function CategoryDetailPane({
  category,
  txCountById,
  canManage,
  showCreatorColumn,
  renderIcon,
  onEdit,
  onDelete,
  onRowClick,
  loadTransactions,
  onBatchMove,
  parentName,
}: {
  category: WorkspaceCategory | null
  txCountById: Record<string, number>
  canManage: boolean
  showCreatorColumn: boolean
  renderIcon: RenderIconFn
  onEdit: (row: ReadCategory) => void
  onDelete?: (row: ReadCategory) => void
  onRowClick?: (row: WorkspaceCategory) => void
  loadTransactions?: CategoryRecentLoader
  onBatchMove?: (source: WorkspaceCategory, txIds?: string[]) => void
  parentName: string | null
}) {
  const t = useT()
  const [page, setPage] = useState<{ items: WorkspaceTransactionPage['items']; total: number }>({
    items: [],
    total: 0,
  })
  const [loading, setLoading] = useState(false)
  // 勾选模式(entry B):选中若干交易后批量移动到其它分类。
  const [selectionMode, setSelectionMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())

  const resetPage = useCallback(() => {
    setPage({ items: [], total: 0 })
    setLoading(false)
  }, [])

  useEffect(() => {
    resetPage()
    if (!loadTransactions || !category?.id) return
    let cancelled = false
    setLoading(true)
    loadTransactions(category.id, 0)
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
  }, [category?.id, loadTransactions, resetPage])

  const loadMore = useCallback(() => {
    if (!loadTransactions || !category?.id || loading) return
    // 传入的 offset 用「已累计条数」。server 回显 offset,但 items 是权威来源。
    const nextOffset = page.items.length
    setLoading(true)
    loadTransactions(category.id, nextOffset)
      .then((pg) => {
        setPage((prev) => ({ items: [...prev.items, ...pg.items], total: pg.total }))
      })
      .finally(() => setLoading(false))
  }, [loadTransactions, category?.id, loading, page.items.length])

  const count = category ? txCountById[category.id] ?? 0 : 0
  const kindLabel = category ? t(`enum.txType.${category.kind}`) : ''
  const hasMore = page.total > page.items.length

  const toggleSelectActive = () => {
    setSelectionMode((m) => !m)
    setSelectedIds(new Set())
  }

  const handleToggleSelect = (row: ReadTransaction) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(row.id)) next.delete(row.id)
      else next.add(row.id)
      return next
    })
  }

  const moveSelected = () => {
    if (!category || selectedIds.size === 0) return
    onBatchMove?.(category, Array.from(selectedIds))
    setSelectionMode(false)
    setSelectedIds(new Set())
  }

  if (!category) {
    return (
      <div className="flex h-full min-h-[420px] items-center justify-center text-sm text-muted-foreground">
        {t('categories.list.select')}
      </div>
    )
  }

  return (
    <div className="flex h-full flex-col gap-4">
      {/* 头部:图标 + 名称 + 徽章 + 编辑/删除 */}
      <div className="flex items-start gap-3 border-b border-border/50 pb-4">
        <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl bg-primary/10">
          {renderIcon(category.icon, category.icon_type, category.icon_cloud_file_id)}
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h3 className="truncate text-lg font-semibold">{category.name}</h3>
            <span className="rounded-md bg-primary/15 px-2 py-0.5 text-[11px] font-medium text-primary">
              {kindLabel}
            </span>
            <span className="rounded-md bg-muted/70 px-2 py-0.5 text-[11px] text-muted-foreground">
              {Number(category.level) === 1 ? t('categories.detail.topLevel') : `父级 · ${parentName || category.parent_name || '-'}`}
            </span>
          </div>
          {showCreatorColumn ? (
            <div className="mt-1 text-xs text-muted-foreground">
              {category.created_by_email || category.created_by_user_id || '-'}
            </div>
          ) : null}
        </div>
        <div className="flex shrink-0 gap-2">
          <Button variant="outline" size="sm" disabled={!canManage} onClick={() => onEdit(category)}>
            {t('common.edit')}
          </Button>
          {onDelete ? (
            <Button
              variant="outline"
              size="sm"
              disabled={!canManage}
              style={{ color: 'hsl(var(--destructive))', borderColor: 'hsl(var(--destructive) / 0.5)' }}
              onClick={() => onDelete(category)}
            >
              {t('common.delete')}
            </Button>
          ) : null}
        </div>
      </div>

      {/* KPI 行 */}
      <div className="grid grid-cols-2 gap-3">
        <div className="rounded-xl border border-border/40 bg-card/50 p-3">
          <div className="text-xs text-muted-foreground">{t('categories.detail.txCount')}</div>
          <div className="mt-1 font-mono text-xl font-bold tabular-nums">{count}</div>
        </div>
        <div className="rounded-xl border border-border/40 bg-card/50 p-3">
          <div className="text-xs text-muted-foreground">{t('categories.detail.parent')}</div>
          <div className="mt-1 truncate text-sm font-semibold">
            {parentName || (Number(category.level) === 1 ? t('common.none') : category.parent_name || '-')}
          </div>
        </div>
      </div>

      {/* 最近交易 */}
      {loadTransactions ? (
        <div className="flex min-h-0 flex-1 flex-col">
          <div className="mb-2 flex shrink-0 items-center justify-between gap-2">
            <h4 className="text-xs font-semibold text-muted-foreground">
              {t('categories.detail.recentTransactions')}
            </h4>
            <div className="flex items-center gap-1.5">
              {onBatchMove ? (
                <>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={toggleSelectActive}
                    className="h-7 px-2 text-[11px]"
                  >
                    {selectionMode
                      ? t('categories.batchMove.cancelSelect')
                      : t('categories.batchMove.select')}
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    className="h-7 px-2 text-[11px]"
                    disabled={selectionMode && selectedIds.size === 0}
                    onClick={() =>
                      selectionMode ? moveSelected() : onBatchMove(category)
                    }
                  >
                    {selectionMode
                      ? t('categories.batchMove.moveSelected', { count: selectedIds.size })
                      : t('categories.batchMove.moveAll', { count })}
                  </Button>
                </>
              ) : null}
            </div>
          </div>
          <TransactionList
            items={page.items}
            variant="compact"
            loading={loading}
            hasMore={hasMore}
            onLoadMore={hasMore ? loadMore : undefined}
            className="min-h-0 flex-1 overflow-y-auto pr-1"
            emptyTitle={t('categories.detail.noTransactions')}
            selectionMode={selectionMode}
            selectedIds={selectedIds}
            onToggleSelect={(_row, _e) => handleToggleSelect(_row)}
          />
        </div>
      ) : null}
    </div>
  )
}

/**
 * 双栏主体:左栏树 + 右栏详情。点击树节点即切换选中项;父级可展开、子级缩进;
 * 右栏详情按选中项渲染 KPI/最近交易。
 */
function CategoriesTwoPane({
  rows,
  txCountById = {},
  canManage,
  showCreatorColumn,
  renderIcon,
  onEdit,
  onDelete,
  onRowClick,
  loadTransactions,
  onBatchMove,
  onCreate,
}: {
  rows: WorkspaceCategory[]
  txCountById?: Record<string, number>
  canManage: boolean
  showCreatorColumn: boolean
  renderIcon: RenderIconFn
  onEdit: (row: ReadCategory) => void
  onDelete?: (row: ReadCategory) => void
  onRowClick?: (row: WorkspaceCategory) => void
  loadTransactions?: CategoryRecentLoader
  onBatchMove?: (source: WorkspaceCategory, txIds?: string[]) => void
  onCreate?: (defaultKind?: 'expense' | 'income') => void
}) {
  const t = useT()
  const [activeKind, setActiveKind] = useState<CategoryKind>('expense')
  // 展开的父级集合(允许多开)
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const { parentsByKind, childrenByParent } = useMemo(() => groupCategories(rows), [rows])

  // 切换 kind 时清空选中与展开,避免不同 kind 的树节点互串。
  const switchKind = useCallback((k: CategoryKind) => {
    setActiveKind(k)
    setSelectedId(null)
    setExpanded(new Set())
  }, [])

  const parents = parentsByKind[activeKind]
  const toggleExpand = useCallback((id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }, [])

  const selectCategory = useCallback((cat: WorkspaceCategory) => {
    setSelectedId(cat.id)
  }, [])

  // 只有有子级才提供展开箭头
  const childrenOf = useCallback(
    (parent: WorkspaceCategory) => childrenByParent[`${activeKind}::${parent.name.toLowerCase()}`] || [],
    [childrenByParent, activeKind],
  )

  const selected = rows.find((r) => r.id === selectedId) ?? null
  // 右栏详情「父级」徽章/KPI 用的父级名 —— 只有子分类才有 parent_name。
  const selectedParentName: string | null =
    selected ? (selected.parent_name || '').trim() || null : null

  const emptyByKind = parents.length === 0

  // 默认选中当前分类树中的第一项，避免首次载入时右侧大面积留白
  useEffect(() => {
    if (!selectedId && parents.length > 0) {
      setSelectedId(parents[0].id)
    }
  }, [selectedId, parents])

  return (
    <div className="grid h-[calc(100vh-88px)] sm:h-[calc(100vh-104px)] lg:h-[calc(100vh-120px)] min-h-[480px] grid-cols-[280px_1fr] gap-4">
      {/* 左栏 树 */}
      <div className="flex min-h-0 flex-col overflow-hidden rounded-xl border border-border/50 bg-card/40">
        {/* 卡片头部: 标题 + 数量 + 新建操作 */}
        <div className="flex shrink-0 items-center justify-between border-b border-border/50 px-3 py-2">
          <div className="flex items-center gap-1.5">
            <span className="text-xs font-semibold text-foreground">
              {t('nav.categories')}
            </span>
            <span className="rounded-full bg-muted/80 px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground tabular-nums">
              {rows.length}
            </span>
          </div>
          {onCreate && canManage ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => onCreate(activeKind === 'income' ? 'income' : 'expense')}
              className="h-6 gap-1 px-1.5 text-xs font-medium text-primary hover:bg-primary/10"
            >
              <Plus className="h-3.5 w-3.5" />
              <span>{t('categories.button.create')}</span>
            </Button>
          ) : null}
        </div>

        <div className="flex min-h-0 flex-1 flex-col p-2">
          <div className="mb-2 flex shrink-0 gap-1 rounded-lg bg-muted/30 p-1">
          {KIND_ORDER.map((k) => {
            const active = k === activeKind
            return (
              <button
                key={k}
                type="button"
                aria-selected={active}
                onClick={() => switchKind(k)}
                className={`flex-1 rounded-md px-2 py-1.5 text-xs font-medium transition-all ${
                  active
                    ? 'bg-primary/15 text-primary ring-1 ring-primary/40'
                    : 'text-muted-foreground hover:bg-accent/40 hover:text-foreground'
                }`}
              >
                {t(`enum.txType.${k}`)}
                <span className="ml-1 rounded-full bg-muted/60 px-1.5 py-0.5 text-[10px] tabular-nums">
                  {parentsByKind[k].length}
                </span>
              </button>
            )
          })}
        </div>
        <div className="min-h-0 flex-1 space-y-0.5 overflow-y-auto">
          {emptyByKind ? (
            <div className="py-8 text-center text-xs text-muted-foreground">
              {t('categories.empty.byType')}
            </div>
          ) : (
            parents.map((parent) => {
              const kids = childrenOf(parent)
              const hasKids = kids.length > 0
              const isExpanded = expanded.has(parent.id)
              return (
                <div key={parent.id}>
                  <CategoryTreeNode
                    category={parent}
                    level={0}
                    hasChildren={hasKids}
                    expanded={isExpanded}
                    selected={selectedId === parent.id}
                    count={txCountById[parent.id] ?? 0}
                    renderIcon={renderIcon}
                    onToggle={() => toggleExpand(parent.id)}
                    onSelect={() => selectCategory(parent)}
                  />
                  {hasKids && isExpanded ? (
                    <div className="ml-3 border-l border-border/50 pl-1">
                      {kids.map((kid) => (
                        <CategoryTreeNode
                          key={kid.id}
                          category={kid}
                          level={1}
                          hasChildren={false}
                          expanded={false}
                          selected={selectedId === kid.id}
                          count={txCountById[kid.id] ?? 0}
                          renderIcon={renderIcon}
                          onToggle={() => {}}
                          onSelect={() => selectCategory(kid)}
                        />
                      ))}
                    </div>
                  ) : null}
                </div>
              )
            })
          )}
        </div>
      </div>
    </div>

      {/* 右栏 详情 */}
      <div className="min-h-0 overflow-y-auto rounded-xl border border-border/50 bg-card/40 p-4">
        <CategoryDetailPane
          category={selected}
          txCountById={txCountById}
          canManage={canManage}
          showCreatorColumn={showCreatorColumn}
          renderIcon={renderIcon}
          onEdit={onEdit}
          onDelete={onDelete}
          onRowClick={onRowClick}
          loadTransactions={loadTransactions}
          onBatchMove={onBatchMove}
          parentName={selectedParentName}
        />
      </div>
    </div>
  )
}
