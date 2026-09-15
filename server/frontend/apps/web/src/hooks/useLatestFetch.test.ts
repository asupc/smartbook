import { describe, expect, it } from 'vitest'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'

import { useLatestFetch } from './useLatestFetch'

/**
 * 无 DOM / 无 testing-library 环境下的最小 hook 测试载体:
 * renderToStaticMarkup 同步执行函数组件本体,useRef / useCallback 语义与
 * 真实渲染一致;useLatestFetch 不含 effect,render 期间即可取回 begin。
 */
function renderHarness(): () => () => boolean {
  let begin: (() => () => boolean) | null = null
  const Harness = ({ onRender }: { onRender: (b: () => () => boolean) => void }) => {
    onRender(useLatestFetch())
    return null
  }
  renderToStaticMarkup(createElement(Harness, { onRender: (b) => (begin = b) }))
  if (!begin) throw new Error('harness did not capture begin')
  return begin
}

describe('useLatestFetch', () => {
  it('先发 A(慢)、后发 B(快):A 的落地被丢弃,最终 state 是 B', () => {
    const begin = renderHarness()
    // 同一数据流先后两轮请求:先发 A(慢响应),再发 B(快响应)
    const isStaleA = begin()
    const isStaleB = begin()

    let state = 'initial'
    const landA = () => {
      if (!isStaleA()) state = 'A'
    }
    const landB = () => {
      if (!isStaleB()) state = 'B'
    }

    // B 先返回(快请求)→ 未过期,落地生效
    landB()
    expect(state).toBe('B')
    // A 后返回(慢请求)→ 已被 B 顶掉,落地必须被丢弃
    landA()
    expect(state).toBe('B')
  })

  it('没有被更晚一轮顶掉时,守卫保持 current(不误伤正常单轮刷新)', () => {
    const begin = renderHarness()
    const isStale = begin()
    expect(isStale()).toBe(false)
    // 重复检查不消耗、不改变语义
    expect(isStale()).toBe(false)
  })

  it('同一轮的 isStale 可共享给并行兄弟流(refreshAllSections 模式),直到下一轮 begin 才整体作废', () => {
    const begin = renderHarness()
    const sharedIsStale = begin()
    // 兄弟流只"使用"守卫,不各自再 begin → 互相不作废
    expect(sharedIsStale()).toBe(false)
    // 下一轮 begin 后,上一轮整体过期
    const nextIsStale = begin()
    expect(sharedIsStale()).toBe(true)
    expect(nextIsStale()).toBe(false)
  })
})
