import { Info, Languages, LogOut, Moon, Sun } from 'lucide-react'

import { Dropdown } from 'antd'
import type { MenuProps } from 'antd'

import { useLocale, useT, useTheme } from '@smartbook/ui'

/**
 * 头像悬浮下拉菜单 —— 只保留 chrome 级操作。
 *
 * 分组结构(从上到下):
 *   - 头部:email + 平台角色标
 *   - Preferences:主题 / 语言(内联 Segment 切换)
 *   - Info:关于(版本对比 + 仓库链接 + 更新日志,合并自旧的「更新日志」+「GitHub 仓库」)
 *   - Actions:退出登录
 *
 * 导航性入口(记账/工具/设置/管理/年度报告)已全部移入左侧栏,由
 * AdminLayout 按 NAV_GROUPS 渲染,这里不再重复。
 *
 * 行为:跟原 inline 实现一致 —— pure CSS group-hover + focus-within,
 * hover 进 avatar 包裹区打开,离开后 150ms 淡出关闭。
 */
interface Props {
  profileMe: {
    email: string
    display_name: string | null
    avatar_url: string | null
    avatar_version: number | null
  }
  isAdminUser: boolean
  onLogout: () => void
  onOpenAbout: () => void
}

export function AvatarDropdown({ profileMe, isAdminUser, onLogout, onOpenAbout }: Props) {
  const t = useT()
  const { locale, setLocale } = useLocale()
  const { mode: themeMode, setMode: setThemeMode } = useTheme()

  const avatarSrc = withAvatarCacheBust(profileMe.avatar_url, profileMe.avatar_version)

  const menuItems: MenuProps['items'] = [
    {
      key: 'header',
      label: (
        <div className="flex items-center gap-1.5 py-1">
          <span className="min-w-0 flex-1 truncate text-[12px] font-medium text-muted-foreground" title={profileMe.email}>
            {profileMe.email}
          </span>
          <span
            className={`shrink-0 rounded-md px-1.5 py-0.5 text-[10px] font-semibold leading-none ${
              isAdminUser ? 'bg-primary/15 text-primary' : 'bg-muted text-muted-foreground'
            }`}
          >
            {isAdminUser ? t('enum.platformRole.admin') : t('enum.platformRole.user')}
          </span>
        </div>
      ),
      type: 'group',
    },
    { type: 'divider' },
    {
      key: 'preferences',
      label: t('avatar.group.preferences'),
      type: 'group',
      children: [
        {
          key: 'theme',
          label: (
            <div className="flex items-center gap-2 py-1 text-[12px] text-muted-foreground">
              {themeMode === 'dark' ? <Moon className="h-3.5 w-3.5" /> : <Sun className="h-3.5 w-3.5" />}
              <span className="flex-1 truncate">{t('shell.theme')}</span>
              <Segment
                setActive={(v) => setThemeMode(v as 'system' | 'light' | 'dark')}
                active={themeMode}
                options={[
                  { value: 'system', label: t('theme.systemShort') },
                  { value: 'light', icon: <Sun className="h-3 w-3" /> },
                  { value: 'dark', icon: <Moon className="h-3 w-3" /> },
                ]}
              />
            </div>
          ),
          disabled: true,
        },
        {
          key: 'language',
          label: (
            <div className="flex items-center gap-2 py-1 text-[12px] text-muted-foreground">
              <Languages className="h-3.5 w-3.5 shrink-0" />
              <span className="flex-1 truncate">{t('shell.language')}</span>
              <Segment
                setActive={(v) => setLocale(v as 'zh-CN' | 'zh-TW' | 'en')}
                active={locale}
                options={[
                  { value: 'zh-CN', label: '简' },
                  { value: 'zh-TW', label: '繁' },
                  { value: 'en', label: 'EN' },
                ]}
              />
            </div>
          ),
          disabled: true,
        },
      ],
    },
    { type: 'divider' },
    {
      key: 'info',
      label: t('avatar.group.info'),
      type: 'group',
      children: [{ key: 'about', label: t('avatar.about'), icon: <Info className="h-3.5 w-3.5" /> }],
    },
    { type: 'divider' },
    {
      key: 'logout',
      label: (
        <span className="flex items-center gap-2 text-[12px] text-destructive">
          <LogOut className="h-3.5 w-3.5" />
          {t('shell.logout')}
        </span>
      ),
      danger: true,
      onClick: onLogout,
    },
  ]

  const onMenuClick: MenuProps['onClick'] = ({ key }) => {
    if (key === 'about') onOpenAbout()
  }

  return (
    <Dropdown
      trigger={['hover', 'click']}
      menu={{ items: menuItems, onClick: onMenuClick }}
      placement="bottomRight"
      overlayStyle={{ minWidth: 240 }}
    >
      <button
        type="button"
        className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
        title={profileMe.display_name || profileMe.email}
      >
        {avatarSrc ? (
          <img
            // key 跟 avatar_version 绑定:服务端 bump 版本号后 React 会重挂载
            // <img>,彻底绕开浏览器 disk cache 把旧帧当新 URL 继续复用的场景
            key={profileMe.avatar_version ?? 0}
            src={avatarSrc}
            alt=""
            className="h-8 w-8 rounded-full border border-border/40 object-cover"
          />
        ) : (
          <div className="flex h-8 w-8 items-center justify-center rounded-full border border-border/40 bg-muted text-[11px] font-semibold text-muted-foreground">
            {profileMe.email.slice(0, 1).toUpperCase()}
          </div>
        )}
      </button>
    </Dropdown>
  )
}

/** 头像 URL cache-bust:服务端 bump version 时拼 `?v=<version>` 让浏览器
 *  disk cache 失效(不走 `key={version}` 只是 React 层重挂,不一定能迫使
 *  浏览器重下资源;两层兜底才稳)。 */
function withAvatarCacheBust(
  url: string | null | undefined,
  version: number | null | undefined,
): string {
  if (!url) return ''
  if (version == null) return url
  const separator = url.includes('?') ? '&' : '?'
  if (/[?&]v=\d+/.test(url)) {
    return url.replace(/([?&])v=\d+/, `$1v=${version}`)
  }
  return `${url}${separator}v=${version}`
}

// --- 小工具组件,本文件内自用,不 export ---

/** segmented 偏好选择:active 高亮主题色,其余 muted。 */
function Segment({
  active,
  setActive,
  options,
}: {
  active: string | null
  setActive: (value: string) => void
  options: { value: string; label?: React.ReactNode; icon?: React.ReactNode }[]
}) {
  return (
    <div className="inline-flex items-center overflow-hidden rounded-md border border-border/60">
      {options.map((opt) => (
        <button
          key={opt.value}
          type="button"
          onClick={() => setActive(opt.value)}
          className={`flex h-6 min-w-[26px] items-center justify-center px-1.5 text-[10px] font-medium transition-colors [&+button]:border-l [&+button]:border-border/60 ${
            active === opt.value
              ? "bg-primary/15 text-primary"
              : "bg-card text-muted-foreground hover:bg-muted"
          }`}
        >
          {opt.icon ?? opt.label}
        </button>
      ))}
    </div>
  )
}
