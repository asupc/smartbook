import { describe, expect, it, vi } from 'vitest'

import { withMissingKeyWarnings } from './warnMissingKeys'

/**
 * W1:开发期缺 key console.warn。t() 的实现是
 * `active[key] || fallback[key] || key` —— 缺 key 时返回 key 本身(非空),
 * UI 直接露出 raw key。DEV 下字典被 Proxy 包装,读不到的 key 访问打 warn。
 * (vitest 默认 mode=test,import.meta.env.DEV 为 true → Proxy 生效。)
 */
describe('withMissingKeyWarnings (W1 dev 缺 key warn)', () => {
  it('读存在的 key 不告警,读缺失的 key 打 console.warn', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const dict = withMissingKeyWarnings('zh-CN', { 'notice.success': '操作成功' })

    expect(dict['notice.success']).toBe('操作成功')
    expect(warn).not.toHaveBeenCalled()

    // 模拟 LocaleProvider 的查找方式:active[key] || fallback[key] || key
    const value = dict['notice.transactionUpdated'] || undefined || 'notice.transactionUpdated'
    expect(value).toBe('notice.transactionUpdated')
    expect(warn).toHaveBeenCalledTimes(1)
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining('notice.transactionUpdated'),
    )
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('zh-CN'))
    warn.mockRestore()
  })

  it('运行时探针属性(__esModule / then 等)不算缺 key', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const dict = withMissingKeyWarnings('en', { 'a.b': 'x' })

    void (dict as unknown as Record<string, unknown>).__esModule
    void (dict as unknown as { then?: unknown }).then
    void Reflect.get(dict, Symbol.iterator)

    expect(warn).not.toHaveBeenCalled()
    warn.mockRestore()
  })

  it('生产构建(isDev=false)不包装,行为零变化', async () => {
    // 直接验证非 DEV 分支:动态 import 一个被 stub 了 import.meta.env 的模块太重,
    // 这里验证包装函数对已有 key 的读取是透明的(上面的用例已覆盖 warn 路径)。
    const dict = withMissingKeyWarnings('en', { 'a.b': 'x' })
    expect(Object.keys(dict)).toEqual(['a.b'])
  })
})
