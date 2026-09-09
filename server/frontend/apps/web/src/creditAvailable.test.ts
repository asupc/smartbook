import { creditAvailableToBalance } from '@smartbook/web-features'
import { describe, expect, it } from 'vitest'

/**
 * 信用卡「按可用额度记账」换算契约:余额 = −欠款 = 可用 − 额度。
 * 欠款为负(assetAggregation 负债符号契约)、溢缴为正;非有限数拒绝(null)。
 */
describe('creditAvailableToBalance', () => {
  it('部分使用:欠款记为负(额度 10000、可用 4000 → 余额 −6000)', () => {
    expect(creditAvailableToBalance(10000, 4000)).toBe(-6000)
  })

  it('额度未动用:余额归零', () => {
    expect(creditAvailableToBalance(8000, 8000)).toBe(0)
  })

  it('可用 > 额度(溢缴款):余额为正,不再截断', () => {
    expect(creditAvailableToBalance(5000, 5200)).toBe(200)
  })

  it('非有限数(含 NaN/Infinity)返回 null', () => {
    expect(creditAvailableToBalance(NaN, 100)).toBeNull()
    expect(creditAvailableToBalance(10000, Number.NaN)).toBeNull()
    expect(creditAvailableToBalance(10000, Number.POSITIVE_INFINITY)).toBeNull()
  })
})
