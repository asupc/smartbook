import { useState } from 'react'
import { CheckCircle2, CircleDashed, Pencil, Plus, Trash2 } from 'lucide-react'

import { Button, Card } from 'antd'
import { useT } from '@smartbook/ui'
import {
  type AICapabilityBinding,
  type AIConfig,
  type AIProvider,
} from '@smartbook/api-client'

import { applyDeleteFallback, mergeAiConfig } from '../../lib/aiConfigMerge'

import { ProviderDeleteDialog } from './ProviderDeleteDialog'
import { ProviderEditDialog } from './ProviderEditDialog'

interface Props {
  config: Record<string, any> | null | undefined
  saving: boolean
  onSave: (next: AIConfig) => Promise<void> | void
}

export function ProvidersCard({ config, saving, onSave }: Props) {
  const t = useT()
  const providers: AIProvider[] = Array.isArray(config?.providers) ? config!.providers : []
  const binding: AICapabilityBinding =
    typeof config?.binding === 'object' && config?.binding ? config.binding : {}

  const [editTarget, setEditTarget] = useState<AIProvider | null>(null)
  const [editOpen, setEditOpen] = useState(false)
  const [deleteTarget, setDeleteTarget] = useState<AIProvider | null>(null)

  const openAdd = () => {
    setEditTarget(null)
    setEditOpen(true)
  }
  const openEdit = (p: AIProvider) => {
    setEditTarget(p)
    setEditOpen(true)
  }
  const openDelete = (p: AIProvider) => {
    if (p.isBuiltIn) return
    setDeleteTarget(p)
  }

  const saveProvider = async (next: AIProvider) => {
    const existingIdx = providers.findIndex((p) => p.id === next.id)
    const nextProviders =
      existingIdx >= 0
        ? providers.map((p, i) => (i === existingIdx ? next : p))
        : [...providers, next]
    await onSave(mergeAiConfig(config, { providers: nextProviders }))
    setEditOpen(false)
    setEditTarget(null)
  }

  const confirmDelete = async () => {
    if (!deleteTarget) return
    const result = applyDeleteFallback(providers, binding, deleteTarget.id)
    if (!result) {
      setDeleteTarget(null)
      return
    }
    await onSave(mergeAiConfig(config, result))
    setDeleteTarget(null)
  }

  return (
    <>
      <Card
        size="small"
        title={<span className="text-base">{t('ai.editor.providers.title')} ({providers.length})</span>}
        extra={
          <Button size="small" icon={<Plus className="h-3.5 w-3.5" />} onClick={openAdd} disabled={saving}>
            {t('ai.editor.providers.add')}
          </Button>
        }
        styles={{ body: { padding: '12px 16px 16px' } }}
      >
        <div className="space-y-2">
          {providers.length === 0 ? (
            <p className="rounded-md border border-dashed border-border/60 px-4 py-6 text-center text-xs text-muted-foreground">
              {t('ai.editor.providers.empty')}
            </p>
          ) : (
            providers.map((p) => (
              <ProviderRow
                key={p.id}
                provider={p}
                onEdit={() => openEdit(p)}
                onDelete={() => openDelete(p)}
                disabled={saving}
              />
            ))
          )}
        </div>
      </Card>

      <ProviderEditDialog
        open={editOpen}
        initial={editTarget}
        saving={saving}
        onClose={() => {
          setEditOpen(false)
          setEditTarget(null)
        }}
        onSave={saveProvider}
      />
      <ProviderDeleteDialog
        open={deleteTarget !== null}
        target={deleteTarget}
        binding={binding}
        saving={saving}
        onClose={() => setDeleteTarget(null)}
        onConfirm={() => void confirmDelete()}
      />
    </>
  )
}

function ProviderRow({
  provider,
  onEdit,
  onDelete,
  disabled,
}: {
  provider: AIProvider
  onEdit: () => void
  onDelete: () => void
  disabled?: boolean
}) {
  const t = useT()
  const hasKey = (provider.apiKey || '').trim().length > 0
  const supportedCaps: string[] = []
  if ((provider.textModel || '').trim()) supportedCaps.push(t('ai.binding.text') as string)
  if ((provider.visionModel || '').trim()) supportedCaps.push(t('ai.binding.vision') as string)
  if ((provider.audioModel || '').trim()) supportedCaps.push(t('ai.binding.speech') as string)

  return (
    <div className="flex items-start justify-between gap-3 rounded-lg border border-border/50 bg-card px-4 py-3">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          {hasKey ? (
            <CheckCircle2 className="h-3.5 w-3.5 text-emerald-500" />
          ) : (
            <CircleDashed className="h-3.5 w-3.5 text-muted-foreground" />
          )}
          <span className="text-sm font-semibold">{provider.name || '-'}</span>
          {provider.isBuiltIn ? (
            <span className="rounded-full border border-border/60 bg-muted px-2 py-0.5 text-[10px] uppercase tracking-wider text-muted-foreground">
              {t('ai.providers.badge.builtin')}
            </span>
          ) : null}
        </div>
        <p className="mt-1 truncate text-[11px] font-mono text-muted-foreground">
          {hasKey ? maskKey(provider.apiKey) : t('common.unset')}
          {' · '}
          {supportedCaps.length > 0
            ? supportedCaps.join(' / ')
            : t('ai.editor.providers.noModelsConfigured')}
        </p>
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <Button
          size="small"
          type="text"
          icon={<Pencil className="h-3.5 w-3.5" />}
          onClick={onEdit}
          disabled={disabled}
          aria-label={t('ai.editor.providers.edit') as string}
          title={t('ai.editor.providers.edit') as string}
        />
        {!provider.isBuiltIn ? (
          <Button
            size="small"
            type="text"
            danger
            icon={<Trash2 className="h-3.5 w-3.5" />}
            onClick={onDelete}
            disabled={disabled}
            aria-label={t('common.delete') as string}
            title={t('common.delete') as string}
          />
        ) : null}
      </div>
    </div>
  )
}

function maskKey(key: string | undefined): string {
  // 用户决策 1c:跟 mobile 一致默认明文。这里仍做 mask 是因为「列表行」不是
  // 编辑场景,展示明文长串噪声;真正想看 / 改 key 的去 dialog 里。
  if (!key) return ''
  const s = key.trim()
  if (s.length <= 8) return '•'.repeat(s.length)
  return `${s.slice(0, 4)}•••${s.slice(-4)}`
}

