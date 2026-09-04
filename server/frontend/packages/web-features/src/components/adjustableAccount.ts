import type { ReadAccount } from '@smartbook/api-client'

/** 可调整余额的日常账户类型(对齐 mobile account_type_utils:信用卡走欠款/还款
 *  概念,估值账户走「更新估值」直接改值,都不出调整入口)。 */
export const ADJUSTABLE_ACCOUNT_TYPES = ['cash', 'bank_card', 'alipay', 'wechat', 'other']

export type AdjustableAccount = ReadAccount & {
  tx_count?: number | null
  income_total?: number | null
  expense_total?: number | null
  balance?: number | null
}
