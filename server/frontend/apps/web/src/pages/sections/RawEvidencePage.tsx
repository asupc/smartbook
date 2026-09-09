import { useEffect, useRef, useState } from 'react'
import { Alert, Button, Card, DatePicker, Descriptions, Drawer, Empty, Modal, Select, Space, Spin, Table, Typography } from 'antd'
import { ReloadOutlined } from '@ant-design/icons'
import { cleanupRawEvidence, deleteRawEvidence, getRawEvidence, listRawEvidence, type RawEvidence } from '@smartbook/api-client'
import { useT } from '@smartbook/ui'
import { useAuth } from '../../context/AuthContext'

const SOURCES = ['sms', 'notification', 'screenText', 'screenshot', 'sharedImage', 'deepLinkText', 'deepLinkDirect', 'import', 'recurring', 'manual']
const PAGE_SIZE = 25
const stamp = (value: string | null) => value ? new Date(value).toLocaleString() : '—'

/** Account-private, read-only evidence. No AI or transaction APIs are imported. */
export function RawEvidencePage() {
  const { token } = useAuth()
  // Remount on session changes so an old request can never display another
  // account's evidence, even when token restoration keeps the route mounted.
  return <EvidenceViewer key={token} token={token} />
}

function EvidenceViewer({ token }: { token: string }) {
  const t = useT()
  const [items, setItems] = useState<RawEvidence[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [source, setSource] = useState<string | undefined>()
  const [dates, setDates] = useState<{ from?: string; to?: string }>({})
  const [refresh, setRefresh] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)
  const [detailId, setDetailId] = useState<string | null>(null)
  const [detail, setDetail] = useState<RawEvidence | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [busy, setBusy] = useState(false)
  const [confirm, setConfirm] = useState<{ id?: string; source?: string; before?: string } | null>(null)
  const alive = useRef(true)
  useEffect(() => { alive.current = true; return () => { alive.current = false } }, [])

  useEffect(() => {
    let current = true
    setItems([])
    setLoading(true)
    setError(false)
    listRawEvidence(token, { source, ...dates, limit: PAGE_SIZE, offset: (page - 1) * PAGE_SIZE })
      .then(result => {
        if (!current) return
        if (page > 1 && !result.items.length) { setPage(1); return }
        setItems(result.items)
        setTotal(result.total)
      })
      .catch(() => { if (current) { setError(true); setTotal(0) } })
      .finally(() => { if (current) setLoading(false) })
    return () => { current = false }
  }, [token, source, dates, page, refresh])

  useEffect(() => {
    let current = true
    setDetail(null)
    setDetailLoading(Boolean(detailId))
    if (detailId) getRawEvidence(token, detailId)
      .then(result => { if (current) setDetail(result) })
      .catch(() => { if (current) { setError(true); setDetailId(null) } })
      .finally(() => { if (current) setDetailLoading(false) })
    return () => { current = false }
  }, [token, detailId])

  async function remove() {
    if (!confirm || busy) return
    setBusy(true)
    try {
      if (confirm.id) await deleteRawEvidence(token, confirm.id)
      else await cleanupRawEvidence(token, { source: confirm.source, before: confirm.before })
      if (!alive.current) return
      setConfirm(null)
      setDetailId(null)
      setRefresh(value => value + 1)
    } catch (_) {
      // A server error can contain sensitive input. Only show a generic notice.
      if (alive.current) setError(true)
    } finally { if (alive.current) setBusy(false) }
  }

  function reload() { setDetailId(null); setRefresh(value => value + 1) }
  const sourceName = (value?: string) => value ? (SOURCES.includes(value) ? t('evidence.source.' + value) : value) : t('evidence.allSources')

  return <Space direction="vertical" size="middle" style={{ width: '100%' }}>
    <Typography.Title level={3} style={{ margin: 0 }}>{t('evidence.title')}</Typography.Title>
    <Alert type="info" showIcon message={t('evidence.notice')} description={t('evidence.retentionNotice')} />
    {error && <Alert type="error" showIcon message={t('evidence.error')} action={<Button onClick={reload}>{t('evidence.refresh')}</Button>} />}
    <Card>
      <Space wrap style={{ marginBottom: 16 }}>
        <Select aria-label={t('evidence.source')} style={{ width: 180 }} value={source ?? ''} disabled={busy}
          options={[{ value: '', label: t('evidence.allSources') }, ...SOURCES.map(value => ({ value, label: sourceName(value) }))]}
          onChange={value => { setSource(value || undefined); setPage(1); setDetailId(null) }} />
        <DatePicker.RangePicker aria-label={t('evidence.dateRange')} disabled={busy}
          onChange={value => { setDates({ from: value?.[0]?.startOf('day').toISOString(), to: value?.[1]?.endOf('day').toISOString() }); setPage(1); setDetailId(null) }} />
        <Button icon={<ReloadOutlined />} onClick={reload} disabled={busy}>{t('evidence.refresh')}</Button>
        <Button danger disabled={busy || loading} onClick={() => setConfirm({ source, before: new Date().toISOString() })}>{t('evidence.cleanup')}</Button>
      </Space>
      <div className="bc-table-panel">
        <Table<RawEvidence> rowKey="id" dataSource={items} loading={loading} scroll={{ x: 850 }}
          locale={{ emptyText: <Empty description={t('evidence.empty')} /> }}
          pagination={{ current: page, pageSize: PAGE_SIZE, total, showSizeChanger: false, onChange: setPage, showTotal: count => t('evidence.total', { count }) }}
          columns={[
            {
              title: t('evidence.source'),
              dataIndex: 'source',
              width: 130,
              render: (value) => (
                <span className="inline-flex items-center rounded-md border border-primary/20 bg-primary/10 px-2 py-0.5 text-xs font-semibold text-primary">
                  {sourceName(value)}
                </span>
              ),
            },
            {
              title: t('evidence.actor'),
              dataIndex: 'actor',
              width: 150,
              ellipsis: true,
              render: (value) => <span className="text-xs font-medium text-muted-foreground">{value || '—'}</span>,
            },
            {
              title: t('evidence.preview'),
              key: 'preview',
              ellipsis: true,
              render: (_, row) => <span className="font-mono text-xs text-foreground">{row.title || row.body || '—'}</span>,
            },
            {
              title: t('evidence.capturedAt'),
              dataIndex: 'captured_at',
              width: 180,
              render: (value) => <span className="font-mono tabular-nums text-xs text-muted-foreground">{stamp(value)}</span>,
            },
            {
              title: t('evidence.expiresAt'),
              dataIndex: 'expires_at',
              width: 180,
              render: (value) => <span className="font-mono tabular-nums text-xs text-muted-foreground">{stamp(value)}</span>,
            },
            {
              title: t('evidence.actions'),
              key: 'actions',
              width: 130,
              render: (_, row) => (
                <Space size="small">
                  <Button type="link" size="small" onClick={() => { setError(false); setDetailId(row.id) }}>{t('evidence.view')}</Button>
                  <Button type="link" danger size="small" disabled={busy} onClick={() => setConfirm({ id: row.id })}>{t('evidence.delete')}</Button>
                </Space>
              ),
            },
          ]} />
      </div>
    </Card>
    <Drawer title={t('evidence.detail')} open={Boolean(detailId)} width={640} onClose={() => setDetailId(null)} destroyOnClose>
      {detailLoading ? <Spin /> : detail && <Space direction="vertical" size="middle" style={{ width: '100%' }}>
        <Descriptions bordered size="small" column={1} items={[
          { key: 'source', label: t('evidence.source'), children: sourceName(detail.source) },
          { key: 'actor', label: t('evidence.actor'), children: detail.actor || '—' },
          { key: 'channel', label: t('evidence.channel'), children: detail.source_channel || '—' },
          { key: 'key', label: t('evidence.eventKey'), children: <span style={{ overflowWrap: 'anywhere' }}>{detail.event_key}</span> },
          { key: 'captured', label: t('evidence.capturedAt'), children: stamp(detail.captured_at) },
          { key: 'expires', label: t('evidence.expiresAt'), children: stamp(detail.expires_at) },
        ]} />
        <Typography.Title level={5}>{detail.title || t('evidence.body')}</Typography.Title>
        <Typography.Paragraph style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{detail.body || '—'}</Typography.Paragraph>
        <Typography.Title level={5}>{t('evidence.metadata')}</Typography.Title>
        <pre style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{JSON.stringify(detail.metadata, null, 2)}</pre>
        <Button danger disabled={busy} onClick={() => setConfirm({ id: detail.id })}>{t('evidence.delete')}</Button>
      </Space>}
    </Drawer>
    <Modal title={t(confirm?.id ? 'evidence.deleteTitle' : 'evidence.cleanupTitle')} open={Boolean(confirm)}
      onCancel={() => { if (!busy) setConfirm(null) }} onOk={remove} confirmLoading={busy} okButtonProps={{ danger: true }} okText={t('evidence.confirmDelete')} cancelText={t('evidence.cancel')}>
      <Typography.Paragraph>{t(confirm?.id ? 'evidence.deleteNotice' : 'evidence.cleanupNotice', { source: sourceName(confirm?.source), before: stamp(confirm?.before ?? null) })}</Typography.Paragraph>
    </Modal>
  </Space>
}
