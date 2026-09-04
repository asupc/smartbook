import { Card, Select } from 'antd'
import { useT } from '@smartbook/ui'
import {
  type AICapabilityBinding,
  type AIConfig,
  type AIProvider,
  BUILTIN_PROVIDER_ID,
} from '@smartbook/api-client'

import { mergeAiConfig } from '../../lib/aiConfigMerge'

interface Props {
  config: Record<string, any> | null | undefined
  saving: boolean
  onSave: (next: AIConfig) => Promise<void> | void
}

type Cap = 'text' | 'vision' | 'speech'

const FIELDS: { cap: Cap; bindingKey: keyof AICapabilityBinding; modelKey: keyof AIProvider; labelKey: string; notSupportedSuffix: string }[] = [
  { cap: 'text', bindingKey: 'textProviderId', modelKey: 'textModel', labelKey: 'ai.binding.text', notSupportedSuffix: 'text' },
  { cap: 'vision', bindingKey: 'visionProviderId', modelKey: 'visionModel', labelKey: 'ai.binding.vision', notSupportedSuffix: 'vision' },
  { cap: 'speech', bindingKey: 'speechProviderId', modelKey: 'audioModel', labelKey: 'ai.binding.speech', notSupportedSuffix: 'speech' },
]

export function CapabilityBindingCard({ config, saving, onSave }: Props) {
  const t = useT()
  const providers: AIProvider[] = Array.isArray(config?.providers) ? config!.providers : []
  const binding: AICapabilityBinding =
    typeof config?.binding === 'object' && config?.binding ? config.binding : {}

  const handleChange = async (cap: Cap, providerId: string) => {
    const field = FIELDS.find((f) => f.cap === cap)!
    const nextBinding: AICapabilityBinding = { ...binding, [field.bindingKey]: providerId }
    await onSave(mergeAiConfig(config, { binding: nextBinding }))
  }

  return (
    <Card
      size="small"
      title={<span className="text-base">{t('ai.editor.binding.title')}</span>}
      styles={{ body: { padding: '12px 16px 16px' } }}
    >
        <div className="space-y-2">
        {FIELDS.map(({ cap, bindingKey, modelKey, labelKey }) => {
          const currentId = (binding[bindingKey] as string | null | undefined) || BUILTIN_PROVIDER_ID
          return (
            <div
              key={cap}
              className="flex items-center justify-between gap-3 rounded-md border border-border/60 bg-muted/10 px-3 py-2"
            >
              <span className="text-sm">{t(labelKey)}</span>
              <Select
                style={{ width: 200 }}
                size="small"
                value={currentId}
                onChange={(v) => void handleChange(cap, v)}
                disabled={saving}
                options={providers.map((p) => {
                  const supports = !!(p[modelKey] as string | undefined)?.trim()
                  return {
                    value: p.id,
                    disabled: !supports && p.id !== currentId,
                    label: `${p.name}${!supports ? ` (${t('ai.editor.binding.notSupportedShort')})` : ''}`,
                  }
                })}
              />
            </div>
          )
        })}
        </div>
    </Card>
  )
}
