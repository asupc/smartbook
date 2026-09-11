import { useCallback, useEffect, useRef, useState } from 'react'
import { Alert, Button, Card, Modal, Popconfirm, Space, Table, Typography } from 'antd'
import { DeleteOutlined, RedoOutlined, ReloadOutlined } from '@ant-design/icons'
import {
  fetchTrashList,
  purgeTrashTx,
  restoreTrashTx,
  type TrashItem,
} from '@smartbook/api-client'
import { useT } from '@smartbook/ui'
import { useAuth } from '../../context/AuthContext'

const PAGE_SIZE = 20

const TYPE_SIGN: Record<string, string> = {
  expense: '-',
  income: '+',
  transfer: '',
}

/** 交易回收站(0030 软删):删除的交易保留 30 天,可恢复或彻底删除。 */
export function TrashPage() {
  const { token } = useAuth()
  return <TrashViewer key={token} token={token} />
}

function TrashViewer({ token }: { token: string }) {
  const t = useT()
  const [items, setItems] = useState<TrashItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [purgeTarget, setPurgeTarget] = useState<TrashItem | null>(null)
  const [refresh, setRefresh] = useState(0)
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  useEffect(() => {
    let current = true
    setLoading(true)
    setError(false)
    fetchTrashList(token, { limit: PAGE_SIZE, offset: (page - 1) * PAGE_SIZE })
      .then((result) => {
        if (!current) return
        if (page > 1 && result.items.length === 0) {
          setPage(1)
          return
        }
        setItems(result.items)
        setTotal(result.total)
      })
      .catch(() => {
        if (current) {
          setError(true)
          setTotal(0)
        }
      })
      .finally(() => {
        if (current) setLoading(false)
      })
    return () => {
      current = false
    }
  }, [token, page, refresh])

  const restore = useCallback(
    async (syncId: string) => {
      setBusyId(syncId)
      try {
        await restoreTrashTx(token, syncId)
        if (alive.current) setRefresh((v) => v + 1)
      } catch {
        // 错误细节不外显(与 RawEvidencePage 同隐私口径),只在顶部提示
        if (alive.current) setError(true)
      } finally {
        if (alive.current) setBusyId(null)
      }
    },
    [token],
  )

  const purge = useCallback(async () => {
    if (!purgeTarget) return
    setBusyId(purgeTarget.sync_id)
    try {
      await purgeTrashTx(token, purgeTarget.sync_id)
      if (alive.current) {
        setPurgeTarget(null)
        setRefresh((v) => v + 1)
      }
    } catch {
      if (alive.current) setError(true)
    } finally {
      if (alive.current) setBusyId(null)
    }
  }, [purgeTarget, token])

  return (
    <div className="space-y-4 p-4 md:p-6">
      <div className="flex items-center justify-between gap-2">
        <div>
          <Typography.Title level={4} className="!mb-1">
            {t('trash.title')}
          </Typography.Title>
          <Typography.Text type="secondary" className="text-xs">
            {t('trash.subtitle', { days: 30 })}
          </Typography.Text>
        </div>
        <Button
          icon={<ReloadOutlined />}
          onClick={() => setRefresh((v) => v + 1)}
          loading={loading}
        >
          {t('common.refresh')}
        </Button>
      </div>

      {error ? (
        <Alert
          type="error"
          showIcon
          message={t('trash.error.load')}
          closable
          onClose={() => setError(false)}
        />
      ) : null}

      <Card>
        <Table<TrashItem>
          rowKey="sync_id"
          size="small"
          loading={loading}
          dataSource={items}
          locale={{ emptyText: t('trash.empty') }}
          pagination={{
            current: page,
            pageSize: PAGE_SIZE,
            total,
            showSizeChanger: false,
            onChange: setPage,
          }}
          columns={[
            {
              title: t('trash.col.amount'),
              width: 110,
              render: (_, row) => (
                <span className="font-medium tabular-nums">
                  {TYPE_SIGN[row.tx_type] ?? ''}
                  {Number(row.amount).toFixed(2)}
                </span>
              ),
            },
            {
              title: t('trash.col.type'),
              width: 90,
              dataIndex: 'tx_type',
              render: (v: string) => t(`enum.txType.${v}`),
            },
            {
              title: t('trash.col.ledger'),
              width: 140,
              dataIndex: 'ledger_name',
              ellipsis: true,
            },
            {
              title: t('trash.col.note'),
              ellipsis: true,
              render: (_, row) => row.note || row.category_name || '—',
            },
            {
              title: t('trash.col.deletedAt'),
              width: 160,
              dataIndex: 'deleted_at',
              render: (v: string) => new Date(v).toLocaleString(),
            },
            {
              title: t('trash.col.daysLeft'),
              width: 100,
              dataIndex: 'days_left',
              render: (v: number) =>
                v === 0 ? (
                  <span className="text-red-500">{t('trash.daysLeft.today')}</span>
                ) : (
                  t('trash.daysLeft.value', { count: v })
                ),
            },
            {
              title: t('trash.col.actions'),
              width: 170,
              render: (_, row) => (
                <Space>
                  <Button
                    size="small"
                    icon={<RedoOutlined />}
                    loading={busyId === row.sync_id}
                    disabled={busyId !== null}
                    onClick={() => void restore(row.sync_id)}
                  >
                    {t('trash.action.restore')}
                  </Button>
                  <Button
                    size="small"
                    danger
                    icon={<DeleteOutlined />}
                    disabled={busyId !== null}
                    onClick={() => setPurgeTarget(row)}
                  >
                    {t('trash.action.purge')}
                  </Button>
                </Space>
              ),
            },
          ]}
        />
      </Card>

      <Modal
        open={Boolean(purgeTarget)}
        title={t('trash.purgeConfirm.title')}
        okText={t('trash.purgeConfirm.ok')}
        okButtonProps={{ danger: true }}
        cancelText={t('common.cancel')}
        onCancel={() => setPurgeTarget(null)}
        onOk={() => void purge()}
      >
        <p className="text-sm">
          {t('trash.purgeConfirm.description', {
            amount: (TYPE_SIGN[purgeTarget?.tx_type ?? ''] ?? '') +
              Number(purgeTarget?.amount ?? 0).toFixed(2),
          })}
        </p>
      </Modal>
    </div>
  )
}
