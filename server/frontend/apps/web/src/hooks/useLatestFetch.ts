import { useCallback, useRef } from 'react'

/**
 * 列表请求竞态的「止血」守卫(P0-6,docs/design-flaw-fix-plan-2026-09-15)。
 *
 * 用法:每个数据流持有一个 hook 实例;异步加载函数开头
 * `const isStale = begin()`(每次调用递增内部 seq,把更早的一轮标记为
 * 过期),在每个 `await` 之后、setState 落地之前 `if (isStale()) return`。
 *
 * 场景:快速切账本 A→B 时两轮请求并发,B 更晚 begin;A 的响应回来时
 * isStale() 为 true,丢弃落地 —— 只有「最后一次发起」的响应才能写
 * state,列表不会再显示旧账本的数据(页头账本与列表内容不一致)。
 *
 * 注意:一个实例代表一条数据流。同一轮里并行的多条流(如
 * refreshAllSections 同时拉 transactions/tags/categories/accounts)必须
 * 共用同一轮 begin 出来的 isStale(作为参数传下去),而不是各自再
 * begin —— 否则后启动的流会把前面兄弟流的落地作废。
 *
 * 这是止血方案(不做请求去重 / 缓存失效);治本走 TanStack Query 排期。
 */
export function useLatestFetch(): () => () => boolean {
  const seqRef = useRef(0)
  const begin = useCallback(() => {
    const mySeq = ++seqRef.current
    return () => mySeq !== seqRef.current
  }, [])
  return begin
}
