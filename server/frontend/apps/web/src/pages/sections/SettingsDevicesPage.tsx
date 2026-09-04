import { useCallback, useEffect, useState } from 'react'

import {
  fetchAdminDevices,
  fetchAdminUsers,
  type AdminDevice,
  type UserAdmin,
} from '@smartbook/api-client'
import { Input, Select } from 'antd'
import { useT, useToast } from '@smartbook/ui'
import { OpsDevicesPanel } from '@smartbook/web-features'

import { useAuth } from '../../context/AuthContext'
import { localizeError } from '../../i18n/errors'

type WindowDays = '30' | 'all'

/**
 * 设备管理页 —— 普通用户看自己的 session,admin 可以按用户筛选 + 看全量。
 * "窗口" 下拉控制 active_within_days(默认 30 天,全部 = 0 传给后端)。
 */
export function SettingsDevicesPage() {
  const t = useT()
  const toast = useToast()
  const { token, isAdmin, isAdminResolved } = useAuth()

  const [rows, setRows] = useState<AdminDevice[]>([])
  const [listQuery, setListQuery] = useState('')
  const [listUserFilter, setListUserFilter] = useState('__all__')
  const [windowDays, setWindowDays] = useState<WindowDays>('30')
  const [adminUsers, setAdminUsers] = useState<UserAdmin[]>([])

  const notifyError = useCallback(
    (err: unknown) => toast.error(localizeError(err, t), t('notice.error')),
    [toast, t]
  )

  const refresh = useCallback(async () => {
    try {
      const devices = await fetchAdminDevices(token, {
        user_id: isAdmin && listUserFilter !== '__all__' ? listUserFilter : undefined,
        q: listQuery || undefined,
        active_within_days: windowDays === 'all' ? 0 : 30,
        limit: 200,
      })
      setRows(devices.items)
    } catch (err) {
      notifyError(err)
    }
  }, [token, isAdmin, listUserFilter, listQuery, windowDays, notifyError])

  // admin 用户列表:仅 admin 才拉,非 admin 不渲染筛选下拉。
  useEffect(() => {
    if (!isAdminResolved || !isAdmin) return
    let cancelled = false
    const run = async () => {
      try {
        const users = await fetchAdminUsers(token, { limit: 500 })
        if (!cancelled) setAdminUsers(users.items)
      } catch (err) {
        if (!cancelled) notifyError(err)
      }
    }
    void run()
    return () => {
      cancelled = true
    }
  }, [token, isAdmin, isAdminResolved, notifyError])

  useEffect(() => {
    if (!isAdminResolved) return
    void refresh()
  }, [isAdminResolved, refresh])

  return (
    <div className="space-y-4">
      <div className="bc-toolbar flex flex-wrap items-center gap-3">
        <Input
          style={{ width: 220 }}
          placeholder={t('shell.placeholder.keyword')}
          value={listQuery}
          onChange={(event) => setListQuery(event.target.value)}
        />
        {isAdmin ? (
          <Select
            style={{ width: 240 }}
            value={listUserFilter}
            onChange={setListUserFilter}
            placeholder={t('shell.userFilter')}
            options={[
              { value: '__all__', label: t('shell.allUsers') },
              ...adminUsers.map((user) => ({ value: user.id, label: user.email })),
            ]}
          />
        ) : null}
        <Select
          style={{ width: 180 }}
          value={windowDays}
          onChange={(value) => setWindowDays(value as WindowDays)}
          options={[
            { value: '30', label: t('ops.devices.window.30d') },
            { value: 'all', label: t('ops.devices.window.all') },
          ]}
        />
      </div>
      <OpsDevicesPanel rows={rows} onReload={() => void refresh()} />
    </div>
  )
}
