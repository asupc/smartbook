/**
 * W4:per-user localStorage 作用域工具 —— 交易筛选存储 key 的共享常量 + 登出清理。
 *
 * 背景:筛选 key 从 v1 升到 v2(加 amount/date/category/tag 过滤)后,
 * App.tsx 的登出清理仍只清 v1 前缀 → v2 键永久残留(隐私残留 + 膨胀)。
 *
 * 双保险:
 *   1. 共享常量 —— TransactionsPage 的 key 构造与登出清理同源,版本号再升
 *      也不会各改一处漏掉;
 *   2. 清理按 `smartbook:web:txFilter:<任何版本>:<userId>:` 正则遍历,
 *      v1/v2/未来 vN 一网打尽,不用每次升版改清理代码。
 */
export const TX_FILTER_STORAGE_PREFIX_BASE = 'smartbook:web:txFilter:'

/** 当前筛选 schema 版本(v2:amount range / date range / category / tag)。 */
export const TX_FILTER_STORAGE_VERSION = 'v2'

/** TransactionsPage 使用的完整前缀:`smartbook:web:txFilter:v2`。 */
export const TX_FILTER_STORAGE_PREFIX = `${TX_FILTER_STORAGE_PREFIX_BASE}${TX_FILTER_STORAGE_VERSION}`

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * 清掉指定用户的全部交易筛选存储键(所有版本)。匹配
 * `smartbook:web:txFilter:<version>:<userId>:<ledgerFilter>`。
 * 只动该用户的键 —— 多账号同浏览器并存的会话互不影响。
 */
export function clearTxFilterStorage(userId: string): void {
  if (typeof window === 'undefined' || !userId) return
  try {
    const pattern = new RegExp(
      `^${escapeRegExp(TX_FILTER_STORAGE_PREFIX_BASE)}(?:v\\d+:)?${escapeRegExp(userId)}:`
    )
    const doomed: string[] = []
    for (let i = 0; i < window.localStorage.length; i += 1) {
      const key = window.localStorage.key(i)
      if (key && pattern.test(key)) doomed.push(key)
    }
    for (const key of doomed) window.localStorage.removeItem(key)
  } catch {
    // localStorage 在 private mode / 超配额时可能抛异常,忽略即可。
  }
}
