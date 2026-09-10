import type { ReadAccount } from '@smartbook/api-client'

/** 所有类型账户都允许「调整余额」(无类型白名单;v2 起落独立「余额调整
 *  记录」,不进收支统计)。信用卡另有专属「更新可用额度」快捷入口(欠款 =
 *  额度 − 可用,换算成目标余额后复用同一条调整通道),与调整余额并存。
 *  负债类型(credit_card/loan)余额存负数,调整输入按「当前欠款」正数口径,
 *  提交时取负对齐(LIABILITY_TYPES)。 */

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
