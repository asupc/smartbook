import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  TX_FILTER_STORAGE_PREFIX,
  clearTxFilterStorage,
} from './userScopedStorage'

/**
 * W4:筛选存储 key 升 v2 后,登出清理必须把所有版本的该用户键都清掉
 * (旧清理只认 v1 前缀 → v2 键永久残留)。
 */
describe('clearTxFilterStorage (W4 登出清理)', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  function stubLocalStorage(): Map<string, string> {
    const store = new Map<string, string>()
    vi.stubGlobal('window', {
      localStorage: {
        get length() {
          return store.size
        },
        key: (i: number) => Array.from(store.keys())[i] ?? null,
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => store.set(k, v),
        removeItem: (k: string) => store.delete(k),
      },
    })
    return store
  }

  it('清掉该用户所有版本(v1/v2/未来 vN)的筛选键,保留他人与他类键', () => {
    const store = stubLocalStorage()
    const seed: Array<[string, string]> = [
      // user-1 的 v1 / v2 / 假想的 v3
      ['smartbook:web:txFilter:v1:user-1:L1', '{}'],
      [`smartbook:web:txFilter:v2:user-1:__all__`, '{}'],
      ['smartbook:web:txFilter:v2:user-1:L9', '{}'],
      ['smartbook:web:txFilter:v3:user-1:L2', '{}'],
      // 其它用户 / 其它前缀不动
      ['smartbook:web:txFilter:v2:user-2:__all__', '{}'],
      ['smartbook:web:txFilter:v2:user-10:__all__', '{}'],
      ['smartbook.active-ledger.user-1', 'L1'],
      ['theme', 'dark'],
    ]
    for (const [k, v] of seed) store.set(k, v)

    clearTxFilterStorage('user-1')

    expect(Array.from(store.keys()).sort()).toEqual([
      'smartbook.active-ledger.user-1',
      'smartbook:web:txFilter:v2:user-10:__all__',
      'smartbook:web:txFilter:v2:user-2:__all__',
      'theme',
    ])
  })

  it('共享常量拼出的当前 key 形态与清理正则匹配(双保险自洽)', () => {
    // TransactionsPage 用 TX_FILTER_STORAGE_PREFIX + `:${userId}:${ledger}` 建键,
    // 清理正则必须认得它 —— 升版只改 VERSION 也不会断。
    const store = stubLocalStorage()
    const key = `${TX_FILTER_STORAGE_PREFIX}:user-1:__all__`
    store.set(key, '{}')

    clearTxFilterStorage('user-1')

    expect(store.has(key)).toBe(false)
  })
})
