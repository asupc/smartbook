import { useCallback, useState, type CSSProperties } from 'react'
import { Button, Input, Modal } from 'antd'

import {
  acceptLedgerInvite,
  previewLedgerInvite,
  type LedgerInvitePreview,
} from '@smartbook/api-client'
import { useT, useToast } from '@smartbook/ui'
import { localizeError } from '../i18n/errors'

import { useAuth } from '../context/AuthContext'
import { useLedgers } from '../context/LedgersContext'

const fieldLabelStyle: CSSProperties = { fontWeight: 500, marginBottom: 4, display: 'block' }

interface Props {
  open: boolean
  onOpenChange: (next: boolean) => void
}

/**
 * 加入共享账本对话框 — 输 6 位邀请码 → preview 显示账本信息 → accept。
 *
 * 对齐 mobile lib/pages/cloud/join_shared_ledger_page.dart 流程。
 * accept 成功后调 refreshLedgers 拉新账本到 sidebar。
 */
export function JoinSharedLedgerDialog({ open, onOpenChange }: Props) {
  const t = useT()
  const toast = useToast()
  const { token } = useAuth()
  const { refreshLedgers, setActiveLedgerId } = useLedgers()
  const [code, setCode] = useState('')
  const [preview, setPreview] = useState<LedgerInvitePreview | null>(null)
  const [loading, setLoading] = useState(false)
  const [accepting, setAccepting] = useState(false)

  const notifyError = useCallback(
    (err: unknown) => toast.error(localizeError(err, t), t('notice.error')),
    [toast, t],
  )
  const notifySuccess = useCallback(
    (msg: string) => toast.success(msg, t('notice.success')),
    [toast, t],
  )

  const reset = useCallback(() => {
    setCode('')
    setPreview(null)
    setLoading(false)
    setAccepting(false)
  }, [])

  const onPreview = useCallback(async () => {
    const normalized = code.trim().toUpperCase().replace(/[\s-]/g, '')
    if (!normalized) {
      notifyError(new Error(t('sharedLedger.codeRequired')))
      return
    }
    setLoading(true)
    try {
      const p = await previewLedgerInvite(token, normalized)
      setPreview(p)
    } catch (err) {
      notifyError(err)
      setPreview(null)
    } finally {
      setLoading(false)
    }
  }, [code, token, t, notifyError])

  const onAccept = useCallback(async () => {
    if (!preview) return
    setAccepting(true)
    try {
      const result = await acceptLedgerInvite(token, preview.code)
      notifySuccess(
        t('sharedLedger.joinedSuccess', { ledger: result.ledger_name || '' }),
      )
      await refreshLedgers()
      // 切到刚加入的账本,UI 立即看到新数据
      setActiveLedgerId(result.ledger_external_id)
      reset()
      onOpenChange(false)
    } catch (err) {
      notifyError(err)
    } finally {
      setAccepting(false)
    }
  }, [
    preview,
    token,
    t,
    notifyError,
    notifySuccess,
    refreshLedgers,
    setActiveLedgerId,
    reset,
    onOpenChange,
  ])

  return (
    <Modal
      open={open}
      onCancel={() => {
        reset()
        onOpenChange(false)
      }}
      title={
        <span className="text-base">
          🤝 {t('sharedLedger.joinTitle')}
        </span>
      }
      // footer 自定义:取消按钮保持原语义(不 reset,直接通知父级关闭);
      // onCancel(X / Esc / 遮罩)才走 reset。
      footer={[
        <Button key="cancel" variant="outlined" onClick={() => onOpenChange(false)}>
          {t('common.cancel')}
        </Button>,
        preview ? (
          <Button
            key="ok"
            type="primary"
            onClick={() => void onAccept()}
            loading={accepting}
          >
            {t('sharedLedger.acceptInvite')}
          </Button>
        ) : (
          <Button
            key="ok"
            type="primary"
            onClick={() => void onPreview()}
            loading={loading}
            disabled={loading || !code.trim()}
          >
            {t('sharedLedger.preview')}
          </Button>
        ),
      ]}
    >
      <div className="space-y-4">
        <div>
          <label htmlFor="invite-code" className="text-xs" style={fieldLabelStyle}>
            {t('sharedLedger.inviteCodeLabel')}
          </label>
          <Input
            id="invite-code"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="ABC 123"
            className="font-mono text-lg uppercase tracking-wider"
            autoFocus
            disabled={!!preview || accepting}
          />
          <p className="mt-1 text-xs text-muted-foreground">
            {t('sharedLedger.inviteCodeHint')}
          </p>
        </div>

        {preview ? (
          <div className="rounded border border-primary/30 bg-primary/5 p-3 text-sm">
            <div className="font-semibold">
              {preview.ledger_name || t('sharedLedger.untitled')}
            </div>
            <div className="mt-1 text-xs text-muted-foreground">
              {t('sharedLedger.inviteFrom')}: {preview.invited_by_display}
            </div>
            <div className="text-xs text-muted-foreground">
              {t('sharedLedger.targetRole')}:{' '}
              {preview.target_role === 'owner'
                ? t('sharedLedger.roleOwner')
                : t('sharedLedger.roleEditor')}
            </div>
            <div className="text-xs text-muted-foreground">
              {t('sharedLedger.expiresAt')}:{' '}
              {new Date(preview.expires_at).toLocaleString()}
            </div>
          </div>
        ) : null}
      </div>
    </Modal>
  )
}
