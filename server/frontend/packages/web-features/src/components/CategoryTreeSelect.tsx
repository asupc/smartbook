import React, { useMemo, useRef } from 'react'
import { TreeSelect } from 'antd'
import type { TreeSelectProps } from 'antd'
import type { ReadCategory, WorkspaceCategory } from '@smartbook/api-client'
import { CategoryIcon } from './CategoryIcon'

export type CategoryTreeSelectValueType = 'id' | 'name'

export interface CategoryTreeSelectProps {
  /** 完整分类列表（ReadCategory 或 WorkspaceCategory） */
  categories: readonly (ReadCategory | WorkspaceCategory)[]
  /** 当前选中的值（id 或 name） */
  value?: string | null
  /** 选中变更回调：输出 (value, name, categoryObject) */
  onChange?: (value: string, name: string, category?: ReadCategory | WorkspaceCategory) => void
  /**
   * 模式：
   * - 'filter': 筛选模式（默认 valueType='id'，支持全部分类，支持清空）
   * - 'form': 表单录入模式（默认 valueType='name'，根据收支方向联动）
   */
  mode?: 'filter' | 'form'
  /** 存储值的类型：'id' (sync_id) 或 'name' (分类名) */
  valueType?: CategoryTreeSelectValueType
  /** 过滤分类方向：'all' | 'expense' | 'income' | 'transfer' */
  kind?: string
  /** 占位提示文案 */
  placeholder?: string
  /** 是否禁用 */
  disabled?: boolean
  /** 是否允许一键清除 */
  allowClear?: boolean
  /** 自定义样式名 */
  className?: string
  /** 自定义行内样式 */
  style?: React.CSSProperties
  /** 控件尺寸 */
  size?: 'large' | 'middle' | 'small'
  /** 自定义图标云端预览 URL 字典 */
  iconPreviewUrlByFileId?: Record<string, string>
  /** 拥有子分类的父分类是否可直接选中（默认 true） */
  selectableParent?: boolean
  /** 下拉弹窗样式（已废弃，建议使用 styles.popup.root 或 popupStyle） */
  dropdownStyle?: React.CSSProperties
  /** 下拉弹窗内联样式 */
  popupStyle?: React.CSSProperties
  /** 自定义语义化 styles，透传给 antd TreeSelect */
  styles?: TreeSelectProps['styles']
  /** 筛选模式下「全部分类」文案（默认 "全部分类"） */
  allLabel?: string
  /** 外部指定的当前选中分类展示名（当 categories 尚未加载或已软删除时的兜底展示） */
  fallbackDisplayName?: string
  /** 自定义弹出容器挂载点 */
  getPopupContainer?: (triggerNode: HTMLElement) => HTMLElement
}

interface InternalTreeNode {
  title: React.ReactNode
  value: string
  key: string
  rawSearchText: string
  disabled?: boolean
  selectable?: boolean
  children?: InternalTreeNode[]
}

export function CategoryTreeSelect({
  categories,
  value,
  onChange,
  mode = 'filter',
  valueType,
  kind = 'all',
  placeholder,
  disabled = false,
  allowClear = true,
  className,
  style,
  size = 'middle',
  iconPreviewUrlByFileId,
  selectableParent = true,
  dropdownStyle,
  popupStyle,
  styles,
  allLabel = '全部分类',
  fallbackDisplayName,
  getPopupContainer,
}: CategoryTreeSelectProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const effectiveValueType: CategoryTreeSelectValueType =
    valueType || (mode === 'form' ? 'name' : 'id')

  const effectivePlaceholder =
    placeholder || (mode === 'filter' ? allLabel : '请选择分类')

  // 构建树形数据
  const { treeData, knownValues } = useMemo(() => {
    const knownValues = new Set<string>()

    // 1. 根据 kind 过滤候选分类
    const filteredCategories = categories.filter((c) => {
      const catName = (c.name || '').trim()
      if (!catName) return false
      if (!kind || kind === 'all') return true
      return c.kind === kind
    })

    // 构建单类目下的节点
    const buildNodesForList = (cats: typeof filteredCategories): InternalTreeNode[] => {
      const topLevels: typeof filteredCategories = []
      const childrenByParent: Record<string, typeof filteredCategories> = {}

      for (const cat of cats) {
        const parent = (cat.parent_name || '').trim()
        if (parent) {
          const pKey = parent.toLowerCase()
          childrenByParent[pKey] = childrenByParent[pKey] || []
          childrenByParent[pKey].push(cat)
        } else {
          topLevels.push(cat)
        }
      }

      const sorter = (a: (typeof filteredCategories)[0], b: (typeof filteredCategories)[0]) =>
        (a.sort_order ?? 0) - (b.sort_order ?? 0) || (a.name || '').localeCompare(b.name || '')

      topLevels.sort(sorter)
      for (const k of Object.keys(childrenByParent)) {
        childrenByParent[k].sort(sorter)
      }

      return topLevels.map((parentCat) => {
        const pKey = parentCat.name.trim().toLowerCase()
        const childList = childrenByParent[pKey] || []
        const parentVal = effectiveValueType === 'id' ? parentCat.id : parentCat.name
        knownValues.add(parentVal)

        const childNodes: InternalTreeNode[] = childList.map((childCat) => {
          const childVal = effectiveValueType === 'id' ? childCat.id : childCat.name
          knownValues.add(childVal)
          return {
            title: (
              <div className="flex items-center gap-2 py-0.5 w-full">
                <CategoryIcon
                  icon={childCat.icon}
                  iconType={childCat.icon_type}
                  iconCloudFileId={childCat.icon_cloud_file_id}
                  iconPreviewUrlByFileId={iconPreviewUrlByFileId}
                  size={15}
                />
                <span className="truncate flex-1 text-xs">{childCat.name}</span>
              </div>
            ),
            value: childVal,
            key: childCat.id,
            rawSearchText: `${childCat.name} ${parentCat.name} ${childCat.kind}`,
          }
        })

        const hasChildren = childNodes.length > 0

        return {
          title: (
            <div className="flex items-center gap-2 py-0.5 w-full">
              <CategoryIcon
                icon={parentCat.icon}
                iconType={parentCat.icon_type}
                iconCloudFileId={parentCat.icon_cloud_file_id}
                iconPreviewUrlByFileId={iconPreviewUrlByFileId}
                size={16}
              />
              <span className="truncate flex-1 font-medium text-xs">{parentCat.name}</span>
              {hasChildren ? (
                <span className="text-[10px] text-muted-foreground/70 bg-muted/80 px-1.5 py-0.2 rounded-full tabular-nums">
                  {childNodes.length}
                </span>
              ) : null}
            </div>
          ),
          value: parentVal,
          key: parentCat.id,
          selectable: !hasChildren || selectableParent,
          rawSearchText: `${parentCat.name} ${childList.map((c) => c.name).join(' ')} ${parentCat.kind}`,
          children: hasChildren ? childNodes : undefined,
        }
      })
    }

    const nodes: InternalTreeNode[] = []

    // 筛选模式下：可提供「全部分类」顶层选项
    if (mode === 'filter') {
      nodes.push({
        title: (
          <div className="flex items-center gap-2 py-0.5 text-muted-foreground font-medium text-xs">
            <span className="text-[11px]">❖</span>
            <span>{allLabel}</span>
          </div>
        ),
        value: '__all__',
        key: '__all__',
        rawSearchText: `${allLabel} 全部 all`,
      })
      knownValues.add('__all__')
    }

    // 当未限定单一 kind 时（例如 'all'），如果同时包含支出和收入，分群呈现
    const hasMultipleKinds =
      (!kind || kind === 'all') &&
      filteredCategories.some((c) => c.kind === 'expense') &&
      filteredCategories.some((c) => c.kind === 'income')

    if (hasMultipleKinds) {
      const expenseCats = filteredCategories.filter((c) => c.kind === 'expense')
      const incomeCats = filteredCategories.filter((c) => c.kind === 'income')
      const otherCats = filteredCategories.filter(
        (c) => c.kind !== 'expense' && c.kind !== 'income'
      )

      if (expenseCats.length > 0) {
        nodes.push({
          title: (
            <span className="text-[11px] font-semibold tracking-wider text-rose-500/90 uppercase">
              支出分类
            </span>
          ),
          value: '__group_expense__',
          key: '__group_expense__',
          disabled: true,
          selectable: false,
          rawSearchText: '支出 支出分类 expense',
          children: buildNodesForList(expenseCats),
        })
      }

      if (incomeCats.length > 0) {
        nodes.push({
          title: (
            <span className="text-[11px] font-semibold tracking-wider text-emerald-500/90 uppercase">
              收入分类
            </span>
          ),
          value: '__group_income__',
          key: '__group_income__',
          disabled: true,
          selectable: false,
          rawSearchText: '收入 收入分类 income',
          children: buildNodesForList(incomeCats),
        })
      }

      if (otherCats.length > 0) {
        nodes.push({
          title: (
            <span className="text-[11px] font-semibold tracking-wider text-blue-500/90 uppercase">
              其他分类
            </span>
          ),
          value: '__group_other__',
          key: '__group_other__',
          disabled: true,
          selectable: false,
          rawSearchText: '其他 other',
          children: buildNodesForList(otherCats),
        })
      }
    } else {
      nodes.push(...buildNodesForList(filteredCategories))
    }

    // 针对历史脏数据或尚未在当前列表中的分类值做兜底展示
    if (value && value !== '__all__' && !knownValues.has(value)) {
      nodes.push({
        title: (
          <span className="text-muted-foreground text-xs italic">
            {fallbackDisplayName || value}
          </span>
        ),
        value,
        key: `fallback-${value}`,
        rawSearchText: `${fallbackDisplayName || value}`,
      })
    }

    return { treeData: nodes, knownValues }
  }, [
    categories,
    kind,
    effectiveValueType,
    iconPreviewUrlByFileId,
    selectableParent,
    mode,
    allLabel,
    value,
    fallbackDisplayName,
  ])

  // 处理选中变更
  const handleChange = (selectedVal: string | undefined) => {
    if (!selectedVal || selectedVal === '__all__') {
      onChange?.('', '', undefined)
      return
    }

    const matchedCat = categories.find((c) => {
      if (effectiveValueType === 'id') return c.id === selectedVal
      if (kind && kind !== 'all') return c.name === selectedVal && c.kind === kind
      return c.name === selectedVal
    })

    const displayName = matchedCat?.name || selectedVal
    onChange?.(selectedVal, displayName, matchedCat)
  }

  // 计算当前 TreeSelect 绑定的 value
  const currentValue = useMemo(() => {
    if (!value || value === '') {
      return mode === 'filter' ? undefined : undefined
    }
    if (value === '__all__') {
      return mode === 'filter' ? '__all__' : undefined
    }
    return value
  }, [value, mode])

  const mergedStyles: TreeSelectProps['styles'] = useMemo(() => {
    return {
      ...styles,
      popup: {
        ...styles?.popup,
        root: {
          maxHeight: 280,
          overflowY: 'auto',
          minWidth: 220,
          zIndex: 1050,
          ...dropdownStyle,
          ...popupStyle,
          ...styles?.popup?.root,
        },
      },
    }
  }, [dropdownStyle, popupStyle, styles])

  return (
    <div ref={containerRef} className="relative w-full">
      <TreeSelect
        showSearch
        allowClear={allowClear}
        disabled={disabled}
        size={size}
        className={className}
        style={style}
        value={currentValue}
        placeholder={effectivePlaceholder}
        treeData={treeData}
        treeDefaultExpandAll={true}
        treeNodeFilterProp="rawSearchText"
        filterTreeNode={(inputValue, treeNode) => {
          if (!inputValue || !inputValue.trim()) return true
          const text = String(
            (treeNode as unknown as InternalTreeNode)?.rawSearchText ||
              (treeNode as unknown as InternalTreeNode)?.value ||
              ''
          ).toLowerCase()
          return text.includes(inputValue.toLowerCase().trim())
        }}
        styles={mergedStyles}
        getPopupContainer={
          getPopupContainer ||
          ((triggerNode) => {
            const dialog = triggerNode.closest('[role="dialog"]')
            if (dialog) {
              return containerRef.current || (triggerNode.parentElement as HTMLElement) || (dialog as HTMLElement)
            }
            return document.body
          })
        }
        onChange={handleChange}
      />
    </div>
  )
}
