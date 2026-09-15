import { describe, expect, it } from 'vitest'

import { normalizeAvatarPath } from '@smartbook/web-features'

/**
 * S5:头像 URL 归一化 —— avatar 端点加鉴权后,img 直连 401,改 fetch+blob。
 * 这里锁 normalizeAvatarPath 的口径:相对/绝对 URL → authedGetBlob 的 API
 * 相对路径;version 参数替换/追加 `v`(缓存破坏语义保留,进 blob 缓存 key)。
 */
describe('normalizeAvatarPath (S5 头像 fetch+blob)', () => {
  it('根相对路径 strip API_BASE 前缀', () => {
    expect(normalizeAvatarPath('/api/v1/profile/avatar/u1')).toBe('/profile/avatar/u1')
  })

  it('绝对 URL 取 pathname+search 并 strip API_BASE', () => {
    expect(
      normalizeAvatarPath('https://demo.example.com/api/v1/profile/avatar/u1'),
    ).toBe('/profile/avatar/u1')
  })

  it('已是 API 相对路径(/profile/avatar/...)原样通过', () => {
    expect(normalizeAvatarPath('/profile/avatar/u1')).toBe('/profile/avatar/u1')
  })

  it('version 参数:无 v 时追加,有 v 时替换', () => {
    expect(normalizeAvatarPath('/api/v1/profile/avatar/u1', 7)).toBe(
      '/profile/avatar/u1?v=7',
    )
    // server 的 avatar_url 自带 v,客户端显式 version 覆盖之(bump 后取新图)
    expect(normalizeAvatarPath('/api/v1/profile/avatar/u1?v=3', 4)).toBe(
      '/profile/avatar/u1?v=4',
    )
    expect(
      normalizeAvatarPath('https://x.example/api/v1/profile/avatar/u1?v=3', 4),
    ).toBe('/profile/avatar/u1?v=4')
  })

  it('空值 / 非 http(s) 绝对地址 → null(调用方走占位兜底)', () => {
    expect(normalizeAvatarPath(null)).toBeNull()
    expect(normalizeAvatarPath('')).toBeNull()
    expect(normalizeAvatarPath('   ')).toBeNull()
    expect(normalizeAvatarPath('data:image/png;base64,xxx')).toBeNull()
    expect(normalizeAvatarPath('blob:xxx')).toBeNull()
  })
})
