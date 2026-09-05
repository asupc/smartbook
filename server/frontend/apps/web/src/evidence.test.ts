import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanupRawEvidence, deleteRawEvidence, getRawEvidence, listRawEvidence } from '@smartbook/api-client'
import { NAV_GROUPS } from '@smartbook/web-features'
import { parseRoute, routePath } from './state/router'
import en from './i18n/en'
import zhCN from './i18n/zh-CN'
import zhTW from './i18n/zh-TW'

afterEach(() => vi.unstubAllGlobals())

describe('raw evidence read-only channel', () => {
  it('serializes source, time and page filters without using normal sync', async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response(JSON.stringify({ total: 0, items: [] }), { status: 200 }))
    vi.stubGlobal('fetch', fetcher)
    await listRawEvidence('test-token', { source: 'screenText', from: '2026-09-01T00:00:00Z', to: '2026-09-05T00:00:00Z', limit: 25, offset: 50 })
    const [url, options] = fetcher.mock.calls[0]
    const parsed = new URL(String(url), 'https://example.test')
    expect(parsed.pathname).toBe('/api/v1/evidence/raw')
    expect(Object.fromEntries(parsed.searchParams)).toEqual({ source: 'screenText', from: '2026-09-01T00:00:00Z', to: '2026-09-05T00:00:00Z', limit: '25', offset: '50' })
    expect(options.headers.Authorization).toBe('Bearer test-token')
  })
  it('encodes detail/delete ids and scopes cleanup explicitly', async () => {
    const fetcher = vi.fn().mockImplementation(async () => new Response(JSON.stringify({ ok: true, deleted: 1 }), { status: 200 }))
    vi.stubGlobal('fetch', fetcher)
    await getRawEvidence('t', 'id/with?special')
    await deleteRawEvidence('t', 'id/with?special')
    await cleanupRawEvidence('t', { source: 'sms', before: '2026-09-05T00:00:00Z' })
    expect(fetcher.mock.calls[0][0]).toContain('/evidence/raw/id%2Fwith%3Fspecial')
    expect(fetcher.mock.calls[1][1].method).toBe('DELETE')
    expect(fetcher.mock.calls[2][0]).toContain('/evidence/raw/cleanup')
    expect(JSON.parse(fetcher.mock.calls[2][1].body)).toEqual({ source: 'sms', before: '2026-09-05T00:00:00Z' })
    expect(fetcher.mock.calls.every(([url]) => String(url).includes('/evidence/raw'))).toBe(true)
  })
  it('has a navigable settings entry and complete localized copy', () => {
    expect(NAV_GROUPS.flatMap(group => group.items).some(item => item.key === 'settings-raw-evidence')).toBe(true)
    const route = parseRoute('/app/settings/raw-evidence')
    expect(route.kind).toBe('app')
    if (route.kind !== 'app') return
    expect(route.section).toBe('settings-raw-evidence')
    expect(routePath(route)).toBe('/app/settings/raw-evidence')
    const keys = Object.keys(en).filter(key => key.startsWith('evidence.') || key === 'nav.rawEvidence')
    for (const key of keys) {
      expect((zhCN as Record<string, string>)[key], key).toBeTruthy()
      expect((zhTW as Record<string, string>)[key], key).toBeTruthy()
    }
  })
})
