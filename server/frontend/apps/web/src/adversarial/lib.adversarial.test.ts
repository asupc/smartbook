import { describe, expect, it, vi, afterEach } from 'vitest'

import {
  accountBalance,
  computeCurrencySummary,
  countryCodeForCurrency,
  creditAvailableToBalance,
  currencyDisplayName,
  currencySymbol,
  currentMonthRange,
  effectiveRateToBase,
  isForeignTx,
  mergeGroupsToBase,
  periodDaysElapsed,
  periodLabel,
  periodRangeText,
  previousPeriodLabel,
  splitByCurrency,
  yearDaysElapsed,
  type AssetGroup,
} from '@smartbook/web-features'
import type { ReadAccount } from '@smartbook/api-client'

import { applyDeleteFallback, capabilitiesBoundTo, mergeAiConfig } from '../lib/aiConfigMerge'
import {
  TX_FILTER_STORAGE_PREFIX,
  TX_FILTER_STORAGE_PREFIX_BASE,
  TX_FILTER_STORAGE_VERSION,
  clearTxFilterStorage,
} from '../lib/userScopedStorage'

/**
 * 对抗性测试 · lib 层(纯逻辑优先):
 *  1. userScopedStorage —— 多账号隔离 / 正则元字符 / 异常降级
 *  2. aiConfigMerge —— 原型污染(__proto__ / constructor.prototype)优先
 *  3. 聚合纯函数的未覆盖角(空 / 负 / NaN / 极大 / 原型名入参)
 */

function acc(p: Partial<ReadAccount> & { balance?: number | null }): ReadAccount {
  return p as ReadAccount
}

// ---------------------------------------------------------------------------
// 1. userScopedStorage —— 用户切换隔离
// ---------------------------------------------------------------------------
describe('[adversarial] clearTxFilterStorage 用户隔离', () => {
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

  it('两 user 交替读写 + 反复清理互不串(B 不受 A 的多次清理影响)', () => {
    const store = stubLocalStorage()
    const kA = `${TX_FILTER_STORAGE_PREFIX}:user-A:__all__`
    const kB = `${TX_FILTER_STORAGE_PREFIX}:user-B:__all__`

    // A 写 → B 写 → A 清 → B 仍在 → B 写新值 → A 再清 → B 新值仍在
    store.set(kA, '{"owner":"A"}')
    store.set(kB, '{"owner":"B"}')
    clearTxFilterStorage('user-A')
    expect(store.has(kA)).toBe(false)
    expect(store.get(kB)).toBe('{"owner":"B"}')

    store.set(kB, '{"owner":"B","v":2}')
    clearTxFilterStorage('user-A')
    clearTxFilterStorage('user-A')
    expect(store.get(kB)).toBe('{"owner":"B","v":2}')
  })

  it('userId 含正则元字符时只清自己的键(escapeRegExp 生效,不误伤)', () => {
    const store = stubLocalStorage()
    // user id 形如 a.b+c(regex 元字符)与 aXb1c(会被 a.b+c 若未转义匹配上)
    const mine = `${TX_FILTER_STORAGE_PREFIX}:a.b+c:L1`
    const other = `${TX_FILTER_STORAGE_PREFIX}:aXb1c:L1`
    const other2 = `${TX_FILTER_STORAGE_PREFIX}:abbc:L1`
    store.set(mine, '{}')
    store.set(other, '{}')
    store.set(other2, '{}')

    clearTxFilterStorage('a.b+c')

    expect(store.has(mine)).toBe(false)
    expect(store.has(other)).toBe(true)
    expect(store.has(other2)).toBe(true)
  })

  it('userId 为通配符串 ".*" 不会清空全部用户键', () => {
    const store = stubLocalStorage()
    store.set(`${TX_FILTER_STORAGE_PREFIX}:.*:L1`, '{}')
    store.set(`${TX_FILTER_STORAGE_PREFIX}:anybody:L1`, '{}')

    clearTxFilterStorage('.*')

    expect(store.has(`${TX_FILTER_STORAGE_PREFIX}:.*:L1`)).toBe(false)
    // 若未 escapeRegExp,.* 会把 everybody 的键也吃掉
    expect(store.has(`${TX_FILTER_STORAGE_PREFIX}:anybody:L1`)).toBe(true)
  })

  it('localStorage 访问抛异常(private mode / 配额)时静默降级,不抛出', () => {
    vi.stubGlobal('window', {
      localStorage: {
        get length(): number {
          throw new Error('QuotaExceededError')
        },
        key: () => {
          throw new Error('SecurityError')
        },
        removeItem: () => {
          throw new Error('QuotaExceededError')
        },
      },
    })

    expect(() => clearTxFilterStorage('user-1')).not.toThrow()
  })

  it('userId 为空串时直接 no-op(键保留)—— 与写入端 "anonymous" 归一化不对称', () => {
    const store = stubLocalStorage()
    // 写入端 TransactionsPage.txFilterStorageKey 把空 userId 归一成 'anonymous'
    const anonymousKey = `${TX_FILTER_STORAGE_PREFIX}:anonymous:__all__`
    const emptyKey = `${TX_FILTER_STORAGE_PREFIX}::L1`
    store.set(anonymousKey, '{}')
    store.set(emptyKey, '{}')

    clearTxFilterStorage('')

    // 早退分支:一个键都没清。HARDENING:记录该不对称 —— 若登出时 userId 为空,
    // 'anonymous' 键会成为永久残留(W4 要解决的隐私残留同类问题)。
    expect(store.has(anonymousKey)).toBe(true)
    expect(store.has(emptyKey)).toBe(true)
  })

  it('前缀常量自洽:BASE + VERSION = PREFIX,KEY 形态匹配清理正则', () => {
    expect(TX_FILTER_STORAGE_PREFIX).toBe(
      `${TX_FILTER_STORAGE_PREFIX_BASE}${TX_FILTER_STORAGE_VERSION}`
    )
    const store = stubLocalStorage()
    const key = `${TX_FILTER_STORAGE_PREFIX}:u9:__all__`
    store.set(key, '{}')
    clearTxFilterStorage('u9')
    expect(store.has(key)).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// 2. aiConfigMerge —— 原型污染优先
// ---------------------------------------------------------------------------
describe('[adversarial] aiConfigMerge 原型污染', () => {
  afterEach(() => {
    // 无论走哪个分支,Object.prototype 都必须干净 —— 每个用例结尾都复位校验。
    expect(({} as any).polluted).toBeUndefined()
    expect((Object.prototype as any).polluted).toBeUndefined()
  })

  it('current 含 __proto__ 注入时不污染 Object.prototype', () => {
    const current = JSON.parse('{"__proto__":{"polluted":true},"providers":[]}')
    const next = mergeAiConfig(current, {}) as Record<string, any>

    expect(({} as any).polluted).toBeUndefined()
    expect(Object.getPrototypeOf(next)).toBe(Object.prototype)
    // 结果必须仍是普通对象、providers 正常兜底
    expect(next.providers).toEqual([])
    expect(next.binding).toEqual({})
  })

  it('current 含 constructor.prototype 注入时不污染', () => {
    const current = JSON.parse('{"constructor":{"prototype":{"polluted":true}}}')
    const next = mergeAiConfig(current, {}) as Record<string, any>

    expect(({} as any).polluted).toBeUndefined()
    // own 'constructor' 属性可以透传(未来字段),但不得改到真实 Object.prototype
    expect((Object.prototype as any).polluted).toBeUndefined()
    expect(next.providers).toEqual([])
  })

  it('patch 自身带 __proto__ 时不污染', () => {
    const patch = JSON.parse('{"__proto__":{"polluted":true},"providers":[{"id":"a","name":"A"}]}')
    const next = mergeAiConfig({ providers: [], binding: {} }, patch) as Record<string, any>

    expect(({} as any).polluted).toBeUndefined()
    expect(next.providers).toHaveLength(1)
    expect(Object.getPrototypeOf(next)).toBe(Object.prototype)
  })

  it('applyDeleteFallback 对带 __proto__ 的 binding 做浅拷贝,不污染', () => {
    const binding = JSON.parse('{"textProviderId":"cust1","__proto__":{"polluted":true}}')
    const providers = [{ id: 'cust1', name: 'C' }]
    const res = applyDeleteFallback(providers, binding, 'cust1')

    expect(({} as any).polluted).toBeUndefined()
    expect(res).not.toBeNull()
    expect(res!.binding.textProviderId).toBe('zhipu_glm')
    expect(Object.getPrototypeOf(res!.binding)).toBe(Object.prototype)
  })

  it('binding 引用不共享:改返回值不影响入参(浅拷贝语义)', () => {
    const binding = { textProviderId: 'cust1' }
    const res = applyDeleteFallback([{ id: 'cust1', name: 'C' }], binding, 'cust1')!
    expect(res.binding).not.toBe(binding)
    expect(binding.textProviderId).toBe('cust1')
    res.binding.textProviderId = 'hacked'
    expect(binding.textProviderId).toBe('cust1')
  })
})

describe('[adversarial] aiConfigMerge 类型冲突 / 语义边界', () => {
  it('patch.providers = null 被当作"未指定"(?? 兜底),不会清空现有 providers', () => {
    const current = {
      providers: [{ id: 'keep', name: 'K' }],
      binding: { textProviderId: 'keep' },
      custom_prompt: 'p',
    }
    const next = mergeAiConfig(current, { providers: null as any }) as Record<string, any>
    expect(next.providers).toEqual([{ id: 'keep', name: 'K' }])
    // HARDENING:语义上"清空 providers"无法经由 null 表达(只能传 []),锁住该行为
    expect(next.custom_prompt).toBe('p')
  })

  it('patch.custom_prompt 显式 undefined 与缺省等价(不会覆盖成 undefined 键)', () => {
    const current = { providers: [], binding: {}, custom_prompt: 'mobile-prompt' }
    const explicit = mergeAiConfig(current, { custom_prompt: undefined }) as Record<string, any>
    expect('custom_prompt' in explicit).toBe(true)
    expect(explicit.custom_prompt).toBe('mobile-prompt')
  })

  it('capabilitiesBoundTo 对敌意 providerId(__proto__/constructor)安全', () => {
    const binding = JSON.parse('{"textProviderId":"__proto__","visionProviderId":"constructor"}')
    expect(capabilitiesBoundTo(binding, '__proto__')).toEqual(['text'])
    expect(capabilitiesBoundTo(binding, 'constructor')).toEqual(['vision'])
    expect(capabilitiesBoundTo(binding, 'toString')).toEqual([])
    expect(capabilitiesBoundTo({}, '__proto__')).toEqual([])
  })

  it('applyDeleteFallback 对 __proto__ 形 id 的内置目标拒绝删除(不抛)', () => {
    const providers = [
      { id: 'zhipu_glm', name: 'builtin', isBuiltIn: true },
      { id: '__proto__', name: 'weird' },
    ]
    expect(applyDeleteFallback(providers, {}, 'zhipu_glm')).toBeNull()
    // 非内置的 '__proto__' 可删,且不污染
    const res = applyDeleteFallback(providers, { textProviderId: '__proto__' }, '__proto__')
    expect(res).not.toBeNull()
    expect(res!.providers.map((p) => p.id)).toEqual(['zhipu_glm'])
    expect(res!.binding.textProviderId).toBe('zhipu_glm')
    expect(({} as any).polluted).toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// 3. 聚合纯函数 —— 既有测试未覆盖的角
// ---------------------------------------------------------------------------
describe('[adversarial] assetAggregation 边角', () => {
  it('空输入:所有汇总归零(不抛、不产生 NaN)', () => {
    const s = computeCurrencySummary([])
    expect(s).toEqual({ assetTotal: 0, liabilityTotal: 0, netWorth: 0 })
    expect(splitByCurrency([]).size).toBe(0)
  })

  it('balance = 0(合法数值)优先于 initial_balance(0 是权威值,不是缺省)', () => {
    expect(accountBalance(acc({ balance: 0, initial_balance: 999 }))).toBe(0)
    // NaN 是 number 类型 —— 锁住当前行为:会直接进入汇总(服务端 JSON 不会产生 NaN)
    expect(Number.isNaN(accountBalance(acc({ balance: Number.NaN })))).toBe(true)
  })

  it('currency 为 null/空串统一归 CNY,大小写混用不拆组', () => {
    const map = splitByCurrency([
      acc({ currency: null }),
      acc({ currency: '' }),
      acc({ currency: 'cny' }),
      acc({ currency: 'CNY' }),
    ])
    expect([...map.keys()]).toEqual(['CNY'])
    expect(map.get('CNY')).toHaveLength(4)
  })

  it('effectiveRateToBase:极大/极小汇率与 1/0 防护', () => {
    // auto rate 极小 → 倒数极大,仍是有限数
    const tiny = { rates: { USD: '1e-300' }, rate_date: 'x' } as any
    const r = effectiveRateToBase('USD', 'CNY', tiny, [])
    expect(r).not.toBeNull()
    expect(Number.isFinite(r!.rate)).toBe(true)
    // ADVERSE FINDING: raw 虽通过 Number.isFinite(raw) && raw > 0 校验,
    // 但 1/raw 可溢出成 Infinity —— 契约要求"无效汇率 → null",实际吐出 Infinity。
    const tiny2 = { rates: { USD: '1e-320' }, rate_date: 'x' } as any
    expect(effectiveRateToBase('USD', 'CNY', tiny2, [])).toBeNull()
    // 极大 rate → 倒数极小但有限
    const huge = { rates: { USD: '1e300' }, rate_date: 'x' } as any
    const rh = effectiveRateToBase('USD', 'CNY', huge, [])
    expect(rh).not.toBeNull()
    expect(rh!.rate).toBeGreaterThan(0)
    expect(rh!.rate).toBeLessThan(1e-299)
  })

  it('mergeGroupsToBase 不改写入参(frozen 输入不抛)', () => {
    const group: AssetGroup = Object.freeze({
      type: 'cash',
      label: 'cash',
      color: '#000',
      isLiability: false,
      rows: Object.freeze([acc({ id: 'a1' })]) as ReadAccount[],
      subtotals: Object.freeze([{ currency: 'CNY', value: 100 }]) as {
        currency: string
        value: number
      }[],
    }) as AssetGroup
    const buckets = Object.freeze([
      Object.freeze({ currency: 'CNY', groups: Object.freeze([group]) as AssetGroup[] }),
    ])
    const merged = mergeGroupsToBase(buckets as any, 'CNY', null, [])
    expect(merged).toHaveLength(1)
    expect(merged[0].subtotals[0].value).toBe(100)
    expect(group.subtotals[0].value).toBe(100)
    // 同一 group 进两个 bucket 时,累加发生在副本上,入参不被改
    mergeGroupsToBase(buckets as any, 'CNY', null, [])
    expect(group.subtotals[0].value).toBe(100)
  })

  it('mergeGroupsToBase:base 自身 bucket 走 rate=1,空 bucket 不产组', () => {
    const merged = mergeGroupsToBase(
      [
        { currency: 'CNY', groups: [] },
        { currency: 'cny', groups: [{ type: 'cash', label: 'c', color: '#0', isLiability: false, rows: [], subtotals: [{ currency: 'CNY', value: 7 }] }] },
      ],
      'CNY',
      null,
      []
    )
    expect(merged).toHaveLength(1)
    expect(merged[0].subtotals[0].value).toBe(7)
  })
})

describe('[adversarial] creditAvailableToBalance 边角', () => {
  it('负额度/负可用(脏数据)按公式透传 —— 只有非有限数才拒绝', () => {
    // 契约只声明"非有限数 → null";负值不拦截,锁住现状
    expect(creditAvailableToBalance(-100, 50)).toBe(150)
    expect(creditAvailableToBalance(100, -50)).toBe(-150)
    expect(creditAvailableToBalance(-1, -1)).toBe(0)
  })

  it('极端大值:有限入参可能产出非有限结果(记录该边界)', () => {
    // 1e308 + 1e308 溢出 → -Infinity;下游资产聚合会得到 Infinity 展示值
    const out = creditAvailableToBalance(1e308, -1e308)
    expect(out).toBe(-Infinity)
    expect(Number.isFinite(out!)).toBe(false)
    // 常规极大值不溢出
    expect(creditAvailableToBalance(Number.MAX_SAFE_INTEGER, 0)).toBe(-Number.MAX_SAFE_INTEGER)
  })

  it('0 - 0 产出 +0 而非 -0(展示层 toBe(-0) 会踩坑)', () => {
    expect(Object.is(creditAvailableToBalance(0, 0), 0)).toBe(true)
  })
})

describe('[adversarial] currencies 原型名/非法入参', () => {
  it('countryCodeForCurrency 对原型成员名(大写归一)不命中 Object.prototype', () => {
    // 'constructor'.toUpperCase() = 'CONSTRUCTOR',不得取到 Object 构造函数
    expect(countryCodeForCurrency('constructor')).toBe('CO')
    expect(countryCodeForCurrency('__proto__')).toBe('__')
    expect(countryCodeForCurrency('toString')).toBe('TO')
    expect(countryCodeForCurrency('')).toBeNull()
    expect(countryCodeForCurrency('C')).toBeNull()
  })

  it('currencyDisplayName / currencySymbol 对原型名与非法 locale 不抛', () => {
    expect(currencyDisplayName('constructor', 'en')).toBe('CONSTRUCTOR')
    expect(currencySymbol('constructor', 'en')).toBe('CONSTRUCTOR')
    expect(currencyDisplayName('usd', '')).toBe('USD')
    expect(currencySymbol('', 'zh-CN')).toBe('')
  })

  it('isForeignTx:0 值 / 空币种 / null 快照边界', () => {
    expect(isForeignTx({ currency_code: 'USD', native_amount: 0, amount: 0 })).toBe(false)
    expect(isForeignTx({ currency_code: '', native_amount: 1, amount: 2 })).toBe(false)
    expect(isForeignTx({ currency_code: 'USD', native_amount: null, amount: 2 })).toBe(false)
    expect(isForeignTx({ currency_code: 'USD', native_amount: 1, amount: 2 })).toBe(true)
  })
})

describe('[adversarial] previousPeriod/budget 周期计算边角', () => {
  const d = (s: string) => new Date(s)

  it('startDay 钳制:0/负数/小数/NaN/超 28 全部落到 1..28', () => {
    const base = d('2026-09-09')
    expect(periodLabel(base, 0)).toBe('2026-09')
    expect(periodLabel(base, -50)).toBe('2026-09')
    expect(periodLabel(base, Number.NaN)).toBe('2026-09')
    expect(periodLabel(base, 1.4)).toBe('2026-09') // round(1.4)=1 → 9/9 ≥ 1 → 归当月
    expect(periodLabel(base, 99)).toBe('2026-08') // clamp 28 → 9/9 < 28 → 上月
    expect(periodRangeText(99, base)).toBe('8.28-9.27')
    expect(currentMonthRange(Number.NaN, base).start.getDate()).toBe(1)
    expect(currentMonthRange(-3, base).start.getDate()).toBe(1)
  })

  it('today < startDay 但仍在年初:periodDaysElapsed 不为 0 / 不为负', () => {
    // 1/3 且 startDay=15 → 当前周期起点是上一年 12/15,已过 20 天(12/15..1/3 含端)
    expect(periodDaysElapsed(15, d('2026-01-03'))).toBe(20)
    // yearDaysElapsed:年周期起点(1/15)未到 → 收敛为 1(注释中的契约)
    expect(yearDaysElapsed(15, d('2026-01-03'))).toBe(1)
  })

  it('previousPeriodLabel 跨年 startDay=15(2026-01-10 → 上周期 2025-11)', () => {
    expect(previousPeriodLabel(d('2026-01-10'), 15)).toBe('2025-11')
    // 1/15 当天进入 2026-01 周期 → 上周期 2025-12
    expect(previousPeriodLabel(d('2026-01-15'), 15)).toBe('2025-12')
  })

  it('periodRangeText:2028 闰年 2/29 落在 1.28 起的周期内', () => {
    // 2028 闰年:2/29 存在,周期 [1/28, 2/28) 内 → 2/29 属于下一个周期
    expect(periodRangeText(28, d('2028-02-15'))).toBe('1.28-2.27')
    expect(periodRangeText(28, d('2028-02-29'))).toBe('2.28-3.27')
  })

  it('非法 Date(NaN 时间戳)入参:钳制后仍返回结构完整结果', () => {
    const bad = new Date(Number.NaN)
    const r = currentMonthRange(15, bad)
    expect(Number.isNaN(r.start.getTime())).toBe(true)
    expect(Number.isNaN(r.end.getTime())).toBe(true)
    // 不抛即可 —— 调用方 UI 层自行渲染 Invalid Date 的兜底
    expect(() => periodRangeText(15, bad)).not.toThrow()
  })
})
