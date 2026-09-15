import { describe, expect, it, vi } from 'vitest'

import { attachSentinelObserver } from '@smartbook/web-features'

/**
 * W6:TransactionList 无限滚动 observer 重建 —— 调用方(GlobalEntityDialogs /
 * AccountDetailDialog)传 inline onLoadMore,旧实现把它放进 effect deps,
 * 每次父组件 render 都 disconnect + 重建 observer,弹窗打开瞬间可能双发
 * page-0。修法:onLoadMore 走 getter(组件里是 ref),observer 只建一次;
 * 触发时读到的是最新回调(无 stale closure)。这里对抽出的装配函数直接验证
 * 这两条性质(stub IntersectionObserver,无需 DOM)。
 */
class FakeIntersectionObserver {
  static instances: FakeIntersectionObserver[] = []
  callback: IntersectionObserverCallback
  observed: Element[] = []
  disconnected = false
  constructor(callback: IntersectionObserverCallback, _options?: IntersectionObserverInit) {
    this.callback = callback
    FakeIntersectionObserver.instances.push(this)
  }
  observe(target: Element): void {
    this.observed.push(target)
  }
  disconnect(): void {
    this.disconnected = true
  }
  /** 测试辅助:模拟 sentinel 进入视口。 */
  fireIntersecting(): void {
    const entry = { isIntersecting: true } as IntersectionObserverEntry
    this.callback([entry], this as unknown as IntersectionObserver)
  }
}

describe('attachSentinelObserver (W6 observer 单建)', () => {
  it('装配一次只建一个 observer,observe 目标,disconnect 可收尾', () => {
    FakeIntersectionObserver.instances = []
    const target = {} as Element
    const detach = attachSentinelObserver(
      target,
      () => undefined,
      FakeIntersectionObserver as unknown as typeof IntersectionObserver,
    )

    expect(FakeIntersectionObserver.instances).toHaveLength(1)
    const observer = FakeIntersectionObserver.instances[0]
    expect(observer.observed).toEqual([target])
    expect(observer.disconnected).toBe(false)

    detach()
    expect(observer.disconnected).toBe(true)
  })

  it('触发时调用「最新」的 onLoadMore —— 换了回调不换 observer,也无 stale closure', () => {
    FakeIntersectionObserver.instances = []
    const calls: string[] = []
    let current: (() => void) | undefined = () => calls.push('v1')

    attachSentinelObserver(
      {} as Element,
      () => current,
      FakeIntersectionObserver as unknown as typeof IntersectionObserver,
    )
    const observer = FakeIntersectionObserver.instances[0]

    // 模拟父组件 render 换了 inline onLoadMore(不重建 observer)
    observer.fireIntersecting()
    expect(calls).toEqual(['v1'])

    current = () => calls.push('v2')
    observer.fireIntersecting()
    observer.fireIntersecting()
    expect(calls).toEqual(['v1', 'v2', 'v2'])
    // 全程一个 observer 实例 —— 没有 disconnect/重建
    expect(FakeIntersectionObserver.instances).toHaveLength(1)
    expect(observer.disconnected).toBe(false)
  })

  it('回调缺省(onLoadMore 未传)时触发是 no-op,不抛错', () => {
    FakeIntersectionObserver.instances = []
    attachSentinelObserver(
      {} as Element,
      () => undefined,
      FakeIntersectionObserver as unknown as typeof IntersectionObserver,
    )
    expect(() =>
      FakeIntersectionObserver.instances[0].fireIntersecting(),
    ).not.toThrow()
  })

  it('非交叉帧(isIntersecting=false)不触发', () => {
    FakeIntersectionObserver.instances = []
    const onLoadMore = vi.fn()
    attachSentinelObserver(
      {} as Element,
      () => onLoadMore,
      FakeIntersectionObserver as unknown as typeof IntersectionObserver,
    )
    const observer = FakeIntersectionObserver.instances[0]
    observer.callback(
      [{ isIntersecting: false } as IntersectionObserverEntry],
      observer as unknown as IntersectionObserver,
    )
    expect(onLoadMore).not.toHaveBeenCalled()
  })
})
