import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { ArrowLeft, Pencil } from 'lucide-react'

import { Button, Card, Select } from 'antd'
import { useT, useToast } from '@smartbook/ui'
import {
  type ImportFieldMapping,
  type ImportSummary,
  previewImport,
  uploadImport,
} from '@smartbook/api-client'

import { FieldMappingDialog } from '../../components/import/FieldMappingDialog'
import { FileDropZone } from '../../components/import/FileDropZone'
import { ImportProgressDialog } from '../../components/import/ImportProgressDialog'
import { ImportStatsCard } from '../../components/import/ImportStatsCard'
import { TransactionsPreviewCard } from '../../components/import/TransactionsPreviewCard'
import { useAuth } from '../../context/AuthContext'
import { useLedgers } from '../../context/LedgersContext'
import { localizeError } from '../../i18n/errors'
import { consumePendingImportFile } from '../../lib/pwa-intake'

type Phase = 'idle' | 'uploading' | 'preview' | 'executing'

/**
 * 账本导入页 —— 设计 .docs/web-ledger-import.md
 *
 * 上传后默认显示**预览**:统计数字 + 实际交易(前 10 笔)。**映射默认折叠
 * 成顶部一个小标签**(自动识别 ✓ + 编辑按钮),不满意再点编辑出 dialog 改。
 * 「导入目标 / 冲突策略」做成紧凑一行,不抢主视野。
 */
export function ImportPage() {
  const t = useT()
  const toast = useToast()
  const navigate = useNavigate()
  const { token } = useAuth()
  const { ledgers, activeLedgerId } = useLedgers()
  const [searchParams] = useSearchParams()

  const [phase, setPhase] = useState<Phase>('idle')
  const [summary, setSummary] = useState<ImportSummary | null>(null)
  const [executeOpen, setExecuteOpen] = useState(false)
  const [mappingDialogOpen, setMappingDialogOpen] = useState(false)

  const initialLedger = searchParams.get('ledger') || activeLedgerId || ''

  const handleSelectFile = useCallback(
    async (file: File) => {
      setPhase('uploading')
      try {
        const sum = await uploadImport(token, {
          file,
          targetLedgerId: initialLedger || null,
        })
        setSummary(sum)
        setPhase('preview')
      } catch (err) {
        setPhase('idle')
        toast.error(localizeError(err, t))
      }
    },
    [token, initialLedger, toast, t],
  )

  // PWA Share Target / File Handler 入口:ShareIncomingPage 把 File 暂存到
  // pwa-intake 单例,这里挂载时 consume 一次,自动触发上传流程。useRef 守门
  // 避免 StrictMode 双 mount 重复消费。
  const pwaPickedRef = useRef(false)
  useEffect(() => {
    if (pwaPickedRef.current) return
    const file = consumePendingImportFile()
    if (!file) return
    pwaPickedRef.current = true
    void handleSelectFile(file)
  }, [handleSelectFile])

  const refreshPreview = useCallback(
    async (
      patch: {
        mapping?: ImportFieldMapping
        targetLedgerId?: string | null
        dedupStrategy?: 'skip_duplicates' | 'insert_all'
        autoTagNames?: string[]
      },
    ) => {
      if (!summary) return
      setPhase('uploading')
      try {
        const sum = await previewImport(token, summary.import_token, patch)
        setSummary(sum)
        setPhase('preview')
      } catch (err) {
        setPhase('preview')
        toast.error(localizeError(err, t))
      }
    },
    [summary, token, toast, t],
  )

  const handleExecute = () => {
    if (!summary) return
    if (!summary.target_ledger_id) {
      toast.error(t('import.exec.needLedger'))
      return
    }
    if (summary.stats.parse_errors_total > 0) {
      toast.error(t('import.exec.fixErrorsFirst'))
      return
    }
    setExecuteOpen(true)
    setPhase('executing')
  }

  const onSuccess = useCallback(
    (data: { created_tx_count: number; skipped_count: number }) => {
      toast.success(
        t('import.exec.successToast', {
          created: data.created_tx_count,
          skipped: data.skipped_count,
        }),
      )
    },
    [toast, t],
  )

  const requiredComplete = !!(
    summary?.current_mapping.tx_type &&
    summary?.current_mapping.amount &&
    summary?.current_mapping.happened_at
  )

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <Button
          size="small"
          icon={<ArrowLeft className="h-4 w-4" />}
          onClick={() => navigate(-1)}
          aria-label={t('common.back') as string}
        />
        <h1 className="text-lg font-semibold">{t('import.pageTitle')}</h1>
      </div>

      {phase === 'idle' || (phase === 'uploading' && !summary) ? (
        <Card size="small" styles={{ body: { padding: '16px 24px' } }}>
          <div className="space-y-3">
            <FileDropZone onSelect={handleSelectFile} disabled={phase === 'uploading'} />
            {phase === 'uploading' ? (
              <p className="text-center text-xs text-muted-foreground">
                {t('import.uploading')}
              </p>
            ) : null}
          </div>
        </Card>
      ) : null}

      {summary ? (
        <>
          {/* 紧凑信息栏:映射状态徽章(必填不全 → 红色) + 编辑映射按钮。
              「检测到来源」徽章去掉 — sniff 不一定对(用户清洗过的 SmartBook
              文件可能被识别成 alipay),展示反而误导。来源仅做内部分发用。 */}
          <Card size="small" styles={{ body: { padding: '12px 16px' } }}>
            <div className="flex flex-wrap items-center gap-3 text-xs">
              {requiredComplete ? (
                <span className="rounded-full border border-emerald-500/30 bg-emerald-500/5 px-2 py-0.5 text-emerald-600 dark:text-emerald-400">
                  ✓ {t('import.mappingBadge.auto')}
                </span>
              ) : (
                <span className="rounded-full border border-destructive/40 bg-destructive/5 px-2 py-0.5 text-destructive">
                  ⚠ {t('import.mappingBadge.incomplete')}
                </span>
              )}
              <Button
                size="small"
                icon={<Pencil className="h-3 w-3" />}
                onClick={() => setMappingDialogOpen(true)}
                disabled={phase === 'uploading'}
              >
                {t('import.mappingBadge.edit')}
              </Button>
              <span className="ml-auto text-muted-foreground">
                {t('import.detected.expiresAt', {
                  time: new Date(summary.expires_at).toLocaleTimeString(),
                })}
              </span>
            </div>
          </Card>

          {/* 统计卡 */}
          <ImportStatsCard stats={summary.stats} />

          {/* 实际交易预览(前 10 笔) */}
          <TransactionsPreviewCard
            samples={summary.sample_transactions}
            totalRows={summary.stats.total_rows}
          />

          {/* 紧凑导入目标行 + 主操作 */}
          <div className="flex flex-wrap items-center gap-3 rounded-md border border-border/60 bg-muted/20 px-4 py-3">
            <div className="flex items-center gap-2">
              <span className="text-[11px] text-muted-foreground">
                {t('import.target.ledger')}:
              </span>
              <Select
                style={{ width: 180 }}
                size="small"
                value={summary.target_ledger_id || undefined}
                onChange={(v) => void refreshPreview({ targetLedgerId: v || null })}
                disabled={phase === 'uploading'}
                placeholder={t('import.target.pickLedger')}
                options={ledgers.map((l) => ({
                  value: l.ledger_id,
                  label: l.ledger_name,
                }))}
              />
            </div>
            <div className="flex items-center gap-2">
              <span className="text-[11px] text-muted-foreground">
                {t('import.target.dedup')}:
              </span>
              <Select
                style={{ width: 160 }}
                size="small"
                value={summary.dedup_strategy}
                onChange={(v) =>
                  void refreshPreview({
                    dedupStrategy: v as 'skip_duplicates' | 'insert_all',
                  })
                }
                disabled={phase === 'uploading'}
                options={[
                  { value: 'skip_duplicates', label: t('import.target.dedup.skip') },
                  { value: 'insert_all', label: t('import.target.dedup.insertAll') },
                ]}
              />
            </div>
            <div className="ml-auto flex items-center gap-2">
              <Button
                size="small"
                onClick={() => {
                  setSummary(null)
                  setPhase('idle')
                }}
                disabled={phase === 'uploading' || phase === 'executing'}
              >
                {t('common.cancel')}
              </Button>
              <Button
                size="small"
                type="primary"
                onClick={handleExecute}
                disabled={
                  phase === 'uploading' ||
                  phase === 'executing' ||
                  !summary.target_ledger_id ||
                  summary.stats.parse_errors_total > 0
                }
              >
                {t('import.exec.button', { count: summary.stats.total_rows })}
              </Button>
            </div>
          </div>

          <FieldMappingDialog
            open={mappingDialogOpen}
            headers={summary.headers}
            suggestedMapping={summary.suggested_mapping}
            currentMapping={summary.current_mapping}
            saving={phase === 'uploading'}
            onClose={() => setMappingDialogOpen(false)}
            onApply={(mapping) => void refreshPreview({ mapping })}
          />
        </>
      ) : null}

      <ImportProgressDialog
        open={executeOpen}
        importToken={summary?.import_token || null}
        onClose={() => {
          setExecuteOpen(false)
          if (phase === 'executing') {
            navigate('/app/transactions')
          }
        }}
        onSuccess={onSuccess}
      />
    </div>
  )
}
