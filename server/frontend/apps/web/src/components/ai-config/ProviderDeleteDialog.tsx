import { Modal } from 'antd'
import { useT } from '@smartbook/ui'
import { AlertTriangle } from 'lucide-react'

import { type AICapabilityBinding, type AIProvider } from '@smartbook/api-client'

import { capabilitiesBoundTo } from '../../lib/aiConfigMerge'

interface Props {
  open: boolean
  target: AIProvider | null
  binding: AICapabilityBinding | null
  saving?: boolean
  onConfirm: () => void
  onClose: () => void
}

/**
 * 删除 provider 二次确认 —— 跟 mobile delete 路径行为对齐。删除已绑定的会
 * 显式提示:fallback 哪些能力到「智谱GLM」。
 */
export function ProviderDeleteDialog({
  open,
  target,
  binding,
  saving = false,
  onConfirm,
  onClose,
}: Props) {
  const t = useT()
  if (!target) return null

  const boundCaps = capabilitiesBoundTo(binding, target.id)
  const capLabels = boundCaps
    .map((c) =>
      c === 'text'
        ? t('ai.binding.text')
        : c === 'vision'
          ? t('ai.binding.vision')
          : t('ai.binding.speech'),
    )
    .join('、')

  return (
    <Modal
      open={open}
      width={448}
      onCancel={() => !saving && onClose()}
      title={
        <span className="flex items-center gap-2 text-base">
          <AlertTriangle className="h-4 w-4 text-destructive" />
          {t('ai.editor.providers.delete.title', { name: target.name })}
        </span>
      }
      okText={t('common.delete')}
      cancelText={t('common.cancel')}
      okButtonProps={{ danger: true }}
      cancelButtonProps={{ disabled: saving }}
      confirmLoading={saving}
      onOk={onConfirm}
    >
      <div className="text-sm">
        {boundCaps.length > 0 ? (
          <p className="text-foreground">
            {t('ai.editor.providers.delete.bodyBound', { capabilities: capLabels })}
          </p>
        ) : (
          <p className="text-muted-foreground">
            {t('ai.editor.providers.delete.body')}
          </p>
        )}
      </div>
    </Modal>
  )
}
