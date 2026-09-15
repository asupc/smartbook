import { describe, expect, it, vi } from 'vitest'

import { createObjectUrlWhenCurrent } from './blobUrl'

/**
 * W5:blob objectURL 竞态守卫 —— fetch resolve 晚于取消(effect 重跑/卸载)
 * 时不得 createObjectURL(否则 URL 无人 revoke + stale setState)。
 */
describe('createObjectUrlWhenCurrent (W5 竞态守卫)', () => {
  it('取消发生在 resolve 之前 → 不 createObjectURL,返回 null', async () => {
    const toUrl = vi.fn(() => 'blob:x')
    let cancelled = false
    const promise = createObjectUrlWhenCurrent(
      () => new Promise<{ size: number }>((resolve) => {
        setTimeout(() => resolve({ size: 1 }), 10)
      }),
      () => cancelled,
      toUrl,
    )
    cancelled = true // effect cleanup 在 fetch resolve 之前跑
    expect(await promise).toBeNull()
    expect(toUrl).not.toHaveBeenCalled()
  })

  it('未取消 → 正常 createObjectURL 并返回', async () => {
    const toUrl = vi.fn(() => 'blob:ok')
    const url = await createObjectUrlWhenCurrent(
      async () => ({ size: 2 }),
      () => false,
      toUrl,
    )
    expect(url).toBe('blob:ok')
    expect(toUrl).toHaveBeenCalledTimes(1)
  })

  it('fetch 失败 → 返回 null(由调用方决定是否提示)', async () => {
    const url = await createObjectUrlWhenCurrent(
      async () => {
        throw new Error('network')
      },
      () => false,
      vi.fn(),
    )
    expect(url).toBeNull()
  })
})
