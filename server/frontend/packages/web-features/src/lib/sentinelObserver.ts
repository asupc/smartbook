/**
 * W6:无限滚动 sentinel 的 IntersectionObserver 装配(单一 observer)。
 *
 * 症状(TransactionList):调用方(GlobalEntityDialogs / AccountDetailDialog)
 * 传 inline `onLoadMore`,旧 effect 把它放进 deps → 每次父组件 render 都
 * disconnect + 重建 observer —— 弹窗打开瞬间列表/字典 setState 连环触发
 * 多次重建,observer 重新计算可见性,可能对同一 sentinel 双发 page-0。
 *
 * 修法:onLoadMore 存 ref(effects 只依赖 hasMore),observer 只建一次;
 * 触发时读 ref 里的「最新」回调 —— inline 箭头函数的 stale closure 也一并
 * 消失。抽成纯函数方便单测(stub IntersectionObserver 即可,无需 DOM)。
 */
export function attachSentinelObserver(
  target: Element,
  getOnLoadMore: () => (() => void) | undefined,
  ObserverCtor: typeof IntersectionObserver = IntersectionObserver,
): () => void {
  const observer = new ObserverCtor(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) getOnLoadMore()?.()
      }
    },
    { rootMargin: '80px' },
  )
  observer.observe(target)
  return () => observer.disconnect()
}
