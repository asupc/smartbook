import { useEffect, useState, type CSSProperties } from 'react'
import { Button, Modal, Select } from 'antd'

import { useT } from '@smartbook/ui'
import type { ImportFieldMapping } from '@smartbook/api-client'

const fieldLabelStyle: CSSProperties = { fontWeight: 500, marginBottom: 4, display: 'block' }

interface Props {
  open: boolean
  headers: string[]
  /** server 推断的默认 mapping —— 用作"重置"目标 */
  suggestedMapping: ImportFieldMapping
  /** 当前生效的 mapping */
  currentMapping: ImportFieldMapping
  saving?: boolean
  onClose: () => void
  /** 用户点「应用并预览」后调,父级走 preview API */
  onApply: (next: ImportFieldMapping) => void
}

const REQUIRED_FIELDS: Array<keyof ImportFieldMapping> = [
  'tx_type',
  'amount',
  'happened_at',
  'category_name',
]

const OPTIONAL_FIELDS: Array<keyof ImportFieldMapping> = [
  'subcategory_name',
  'account_name',
  'from_account_name',
  'to_account_name',
  'currency',
  'note',
]

const NONE_SENTINEL = '__none__'

/**
 * 字段映射 Dialog —— 默认隐藏,从预览页「编辑映射」按钮触发。
 *
 * 简化版(产品反馈):去掉「tags 多列合并」+ 三个 transformer 选项
 * (datetime_format / strip_currency / expense_is_negative)。这些 power
 * options 普通用户用不上,留给 server 默认值;真正需要时通过 Excel 预处理。
 */
export function FieldMappingDialog({
  open,
  headers,
  suggestedMapping,
  currentMapping,
  saving = false,
  onClose,
  onApply,
}: Props) {
  const t = useT()
  const [draft, setDraft] = useState<ImportFieldMapping>(currentMapping)

  // 每次打开 dialog 重新同步 draft 到当前生效 mapping
  useEffect(() => {
    if (open) setDraft(currentMapping)
  }, [open, currentMapping])

  const setField = (field: keyof ImportFieldMapping, value: string | null) => {
    setDraft((prev) => ({ ...prev, [field]: value || null }))
  }

  const apply = () => {
    onApply(draft)
    onClose()
  }
  const reset = () => setDraft({ ...suggestedMapping })

  return (
    <Modal
      open={open}
      width={512}
      onCancel={() => !saving && onClose()}
      title={<span className="text-base">{t('import.mapping.title')}</span>}
      // footer 布局与原顺序一致(reset 在最左,cancel/apply 靠右),
      // antd 默认 footer 无法表达中分,用自定义 ReactNode。
      footer={
        <div className="flex w-full items-center justify-between gap-2">
          <Button size="small" type="text" onClick={reset} disabled={saving}>
            {t('import.mapping.reset')}
          </Button>
          <div className="flex items-center gap-2">
            <Button size="small" variant="outlined" onClick={onClose} disabled={saving}>
              {t('common.cancel')}
            </Button>
            <Button size="small" type="primary" onClick={apply} disabled={saving}>
              {t('import.mapping.applyAndPreview')}
            </Button>
          </div>
        </div>
      }
    >
      <div className="space-y-3">
        <p className="text-[11px] text-muted-foreground">
          {t('import.mapping.hint')}
        </p>
        <div className="space-y-2.5">
          {REQUIRED_FIELDS.map((f) => (
            <FieldRow
              key={f}
              field={f}
              label={t(`import.mapping.field.${f}`)}
              required
              value={draft[f] as string | null}
              headers={headers}
              disabled={saving}
              onChange={(v) => setField(f, v)}
            />
          ))}
          {OPTIONAL_FIELDS.map((f) => (
            <FieldRow
              key={f}
              field={f}
              label={t(`import.mapping.field.${f}`)}
              value={draft[f] as string | null}
              headers={headers}
              disabled={saving}
              onChange={(v) => setField(f, v)}
            />
          ))}
        </div>
      </div>
    </Modal>
  )
}

function FieldRow({
  field,
  label,
  required,
  value,
  headers,
  disabled,
  onChange,
}: {
  field: keyof ImportFieldMapping
  label: string
  required?: boolean
  value: string | null
  headers: string[]
  disabled?: boolean
  onChange: (next: string | null) => void
}) {
  const selected = value || NONE_SENTINEL
  return (
    <div className="grid grid-cols-[120px_1fr] items-center gap-2">
      <label className="text-[11px]" style={fieldLabelStyle} htmlFor={`map-${field}`}>
        {label}
        {required ? <span className="ml-0.5 text-destructive">*</span> : null}
      </label>
      <Select
        value={selected}
        onChange={(v) => onChange(v === NONE_SENTINEL ? null : v)}
        disabled={disabled}
        options={[
          { value: NONE_SENTINEL, label: '—' },
          ...headers.map((h) => ({ value: h, label: h })),
        ]}
        style={{ width: '100%' }}
      />
    </div>
  )
}
