import type { ReadAccount } from '@smartbook/api-client'

/** 可调整余额的日常账户类型(对齐 mobile account_type_utils:估值账户走「更新估值」
 *  直接改值,不出调整入口)。信用卡刻意不在列 —— 它走专属的「更新可用额度」:
 *  欠款 = 额度 − 可用,换算成目标余额后复用同一条调整交易通道。 */
export const ADJUSTABLE_ACCOUNT_TYPES = ['cash', 'bank_card', 'alipay', 'wechat', 'other']

/**
 * 信用卡「按可用额度记账」的换算:银行 App 只直接给可用额度,欠款 = 信用额度 −
 * 可用额度,账户余额记为 −欠款(即 available − limit;可用 > 额度 → 溢缴款,
 * 余额为正,与 assetAggregation 的负债符号契约一致)。任一入参非有限数返回 null。
 */
export function creditAvailableToBalance(
  creditLimit: number,
  availableCredit: number
): number | null {
  if (!Number.isFinite(creditLimit) || !Number.isFinite(availableCredit)) return null
  return availableCredit - creditLimit
}

export type AdjustableAccount = ReadAccount & {
  tx_count?: number | null
  income_total?: number | null
  expense_total?: number | null
  balance?: number | null
}
