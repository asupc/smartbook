import { describe, expect, it } from 'vitest'

import { parseRoute, routePath } from './router'

describe('router path mapping', () => {
  it('parses login path', () => {
    expect(parseRoute('/login')).toEqual({ kind: 'login' })
    expect(parseRoute('/')).toEqual({ kind: 'login' })
  })

  it('parses app route with section', () => {
    expect(parseRoute('/app/ledger-1/transactions')).toEqual({
      kind: 'app',
      ledgerId: 'ledger-1',
      section: 'transactions'
    })
expect(parseRoute('/app/workspace/transactions')).toEqual({
      kind: 'app',
      ledgerId: '',
      section: 'transactions'
    })
    expect(parseRoute('/app/transactions')).toEqual({
      kind: 'app',
      ledgerId: '',
      section: 'transactions'
    })
    expect(parseRoute('/app/annual-report')).toEqual({
      kind: 'app',
      ledgerId: '',
      section: 'annual-report'
    })
    // 回归:ledgers 曾漏出根级 section 守卫,被当成 legacy ledgerId 解析成
    // overview,侧栏高亮错误地落在「首页」。
    expect(parseRoute('/app/ledgers')).toEqual({
      kind: 'app',
      ledgerId: '',
      section: 'ledgers'
    })
    expect(parseRoute('/app/settings/health')).toEqual({
      kind: 'app',
      ledgerId: '',
      section: 'settings-health'
    })
  })

  it('falls back to overview for unknown section', () => {
    expect(parseRoute('/app/ledger-1/unknown')).toEqual({
      kind: 'app',
      ledgerId: 'ledger-1',
      section: 'transactions'
    })
  })

  it('creates path from app route', () => {
    expect(
      routePath({
        kind: 'app',
        ledgerId: 'ledger a',
        section: 'settings-devices'
      })
    ).toBe('/app/settings/devices')
    expect(
      routePath({
        kind: 'app',
        ledgerId: 'ledger a',
        section: 'settings-health'
      })
    ).toBe('/app/settings/health')
    expect(
      routePath({
        kind: 'app',
        ledgerId: 'ledger a',
        section: 'annual-report'
      })
    ).toBe('/app/annual-report')
  })
})
