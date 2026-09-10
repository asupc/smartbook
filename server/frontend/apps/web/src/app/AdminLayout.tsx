import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import { useLocation, useNavigate, Outlet } from 'react-router-dom'
import { Button, Layout, Menu, Select, theme } from 'antd'
import {
  Activity,
  Archive,
  ArrowUpDown,
  BookOpen,
  Bot,
  Brush,
  CalendarDays,
  Copy,
  History,
  Home,
  Key,
  LayoutGrid,
  LucideIcon,
  PiggyBank,
  Plus,
  Receipt,
  Search,
  ScrollText,
  ShieldCheck,
  Smartphone,
  Sparkles,
  Tag,
  Upload,
  User,
  Users,
  Wallet,
  Wrench,
} from 'lucide-react'

import { useT } from '@smartbook/ui'
import { NAV_GROUPS, type AppSection } from '@smartbook/web-features'

import { AvatarDropdown } from '../components/AvatarDropdown'
import { useAuth } from '../context/AuthContext'
import { useLedgers } from '../context/LedgersContext'
import { parseRoute, routePath } from '../state/router'

const { Header, Sider, Content } = Layout

// CommandPalette 不在首屏关键路径,只在用户主动打开时才需要,懒加载省体积
const CommandPalette = lazy(() =>
  import('../components/CommandPalette').then((m) => ({ default: m.CommandPalette })),
)

// 侧栏 Menu 的图标 —— 新增 AppSection 时在这里加一行即可。
const SECTION_ICONS: Record<string, LucideIcon> = {
  overview: Home,
  transactions: Receipt,
  calendar: CalendarDays,
  accounts: Wallet,
  adjustments: ArrowUpDown,
  categories: LayoutGrid,
  tags: Tag,
  budgets: PiggyBank,
  ledgers: BookOpen,
  import: Upload,
  'annual-report': Sparkles,
  'settings-profile': User,
  'settings-ai': Bot,
  'settings-ai-logs': History,
  'settings-raw-evidence': ScrollText,
  'settings-health': Activity,
  'settings-devices': Smartphone,
  'settings-developer': Key,
  'admin-users': Users,
  'admin-backup': Archive,
  'admin-data-cleanup': Brush,
  'admin-duplicate-transactions': Copy,
}

// 分组(SubMenu 标题)图标 —— 跟 SECTION_ICONS 同风格,14px。折叠态下 antd
// 只显示分组图标,这组图标承担全部导航语义。
const GROUP_ICONS: Record<string, LucideIcon> = {
  bookkeeping: Receipt,
  tools: Wrench,
  settings: User,
  admin: ShieldCheck,
}

interface Props {
  onOpenLogs: () => void
  onOpenAbout: () => void
}

/**
 * /app/* 的 antd 中后台外壳——可折叠 Sider(按 NAV_GROUPS 分组全量导航,
 * 钉在视口左侧,菜单过长时内部滚动)+ Header(账本选择 / ⌘K 搜索 / 日历 /
 * logs(admin) / 头像下拉)+ Content。
 *
 * 导航入口全在侧栏(记账/工具/设置/管理,含年度报告弹窗);头像下拉只保留
 * chrome:主题/语言偏好、关于、退出登录。
 */
export function AdminLayout({ onOpenLogs, onOpenAbout }: Props) {
  const t = useT()
  const navigate = useNavigate()
  const location = useLocation()
  const { profileMe, isAdmin, logout } = useAuth()
  const { ledgers, activeLedgerId, setActiveLedgerId } = useLedgers()
  const { token } = theme.useToken()

  const [collapsed, setCollapsed] = useState(false)
  const [paletteOpen, setPaletteOpen] = useState(false)
  const [openKeys, setOpenKeys] = useState<string[]>(() => {
    const parsed = parseRoute(location.pathname)
    const section = parsed.kind === 'app' ? parsed.section : 'transactions'
    return [parentGroupKey(section)]
  })

  // Cmd+K (Mac) / Ctrl+K (其他) 打开命令面板
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        setPaletteOpen((v) => !v)
        return
      }
      if (e.key === 'Escape' && paletteOpen) {
        setPaletteOpen(false)
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [paletteOpen])

  const currentSection: AppSection = useMemo(() => {
    const parsed = parseRoute(location.pathname)
    return parsed.kind === 'app' ? parsed.section : 'transactions'
  }, [location.pathname])

  // 深链(如 /app/admin/users 直接刷新)或点侧栏跳转时,自动展开所在分组,
  // 但不收起其他已展开组,保留用户折叠状态。
  useEffect(() => {
    const parent = parentGroupKey(currentSection)
    setOpenKeys((prev) => (prev.includes(parent) ? prev : [...prev, parent]))
  }, [currentSection])

  const goToSection = useCallback(
    (section: AppSection) => {
      navigate(routePath({ kind: 'app', ledgerId: '', section }))
    },
    [navigate],
  )

  const menuItems = useMemo(() => {
    const groups = NAV_GROUPS.filter((group) => (group.key === 'admin' ? isAdmin : true))
    return groups.map((group) => {
      const GroupIcon = GROUP_ICONS[group.key]
      return {
        key: group.key,
        label: t(group.titleKey),
        icon: GroupIcon ? <GroupIcon size={14} /> : undefined,
        children: group.items.map((item) => {
          const Icon = SECTION_ICONS[item.key]
          return {
            key: item.key,
            label: t(item.labelKey),
            icon: Icon ? <Icon size={14} /> : undefined,
          }
        }),
      }
    })
  }, [isAdmin, t])

  const ledgerOptions = useMemo(
    () =>
      ledgers.map((ledger) => ({
        value: ledger.ledger_id,
        label: (
          <span className="inline-flex items-center gap-1.5">
            {ledger.ledger_name}
            {/* §7 共享账本:🤝 emoji + 成员数放账本名后面,跟 mobile UI 对齐 */}
            {ledger.is_shared ? (
              <span
                className="inline-flex items-center gap-0.5 text-[10px] text-primary"
                title={`共享账本 · ${ledger.member_count || 1} 人`}
              >
                🤝
                <span className="font-mono">{ledger.member_count || 1}</span>
              </span>
            ) : null}
          </span>
        ),
      })),
    [ledgers],
  )

  const collapsedWidth = 64

  return (
    <Layout className="min-h-screen">
      <Sider
        collapsible
        collapsed={collapsed}
        onCollapse={setCollapsed}
        collapsedWidth={collapsedWidth}
        theme="light"
        width={220}
        style={{
          // 侧栏钉在视口左侧:内容页出现滚动条时只有内容列滚,侧栏保持可见;
          // 菜单项过多时由 Menu 自身内部滚动(antd trigger 是 fixed 定位 + Sider
          // padding-bottom 留位,底部不会互相遮挡)。
          position: 'sticky',
          top: 0,
          height: '100vh',
          borderRight: `1px solid ${token.colorSplit}`,
          background: token.colorBgContainer,
        }}
      >
        <div className="flex h-full min-h-0 flex-col">
          <button
            type="button"
            onClick={() => goToSection('overview')}
            className="flex h-16 w-full shrink-0 items-center gap-2 overflow-hidden px-4 text-left"
            style={{ color: token.colorText }}
            aria-label={t('shell.goHome')}
          >
            <img
              alt={t('shell.appName')}
              className="h-8 w-8 shrink-0"
              src="/branding/smartbook_icon.svg"
            />
            {!collapsed ? (
              <div className="flex min-w-0 flex-col leading-none">
                <p className="whitespace-nowrap text-[13px] font-bold">
                  {t('shell.appName')}
                </p>
                <span
                  className="mt-0.5 whitespace-nowrap font-mono text-[9px]"
                  style={{ color: token.colorTextTertiary }}
                  title={`SmartBook 智记 v${__APP_VERSION__}`}
                >
                  v{__APP_VERSION__}
                </span>
              </div>
            ) : null}
          </button>
          <Menu
            mode="inline"
            items={menuItems}
            selectedKeys={[currentSection]}
            openKeys={collapsed ? undefined : openKeys}
            onOpenChange={setOpenKeys}
            onClick={({ key }) => {
              goToSection(key as AppSection)
            }}
            style={{ borderInlineEnd: 'none', flex: 1, minHeight: 0, overflowY: 'auto' }}
          />
        </div>
      </Sider>
      <Layout>
        <Header
          className="sticky top-0 z-30 flex h-14 items-center justify-between gap-2 backdrop-blur-md transition-colors"
          style={{
            background: token.colorBgContainer === '#ffffff' ? 'rgba(255, 255, 255, 0.85)' : 'rgba(17, 23, 38, 0.85)',
            borderBottom: `1px solid ${token.colorSplit}`,
            paddingInline: 20,
          }}
        >
          <div className="flex min-w-0 items-center gap-2">
            {ledgers.length > 0 ? (
              <Select
                size="middle"
                value={activeLedgerId || undefined}
                options={ledgerOptions}
                onChange={(v) => setActiveLedgerId(v)}
                placeholder={t('shell.ledger')}
                className="min-w-[160px]"
                popupMatchSelectWidth={false}
              />
            ) : (
              // 用户首次登录(自部署 admin)时还没账本,把账本选择器位置换成
              // 「+ 新建账本」CTA。点击跳 /app/ledgers?create=1,LedgersPage
              // 检测到 query 自动打开新建 dialog。
              <Button
                type="primary"
                ghost
                icon={<Plus size={14} />}
                onClick={() => navigate('/app/ledgers?create=1')}
              >
                {t('shell.ledger.empty')}
              </Button>
            )}
          </div>

          <div className="flex shrink-0 items-center gap-1">
            <Button
              type="text"
              title={t('cmdk.headerButton')}
              aria-label={t('cmdk.headerButton')}
              icon={<Search size={16} />}
              onClick={() => setPaletteOpen(true)}
            >
              <span>{t('cmdk.headerButton')}</span>
              <kbd
                className="ml-1 rounded px-1.5 py-0.5 text-[12px] font-semibold leading-none"
                style={{ background: token.colorFillTertiary }}
              >
                {navigator.platform.includes('Mac') ? '⌘ K' : '⌃ K'}
              </kbd>
            </Button>
            <Button
              type="text"
              title={t('nav.calendar')}
              aria-label={t('nav.calendar')}
              icon={<CalendarDays size={16} />}
              onClick={() => goToSection('calendar')}
            />
            {isAdmin ? (
              <Button
                type="text"
                title={t('logs.open')}
                aria-label={t('logs.open')}
                icon={<ScrollText size={16} />}
                onClick={onOpenLogs}
              />
            ) : null}
            {profileMe?.email ? (
              <AvatarDropdown
                profileMe={{
                  email: profileMe.email,
                  display_name: profileMe.display_name ?? null,
                  avatar_url: profileMe.avatar_url ?? null,
                  avatar_version: profileMe.avatar_version ?? null,
                }}
                isAdminUser={isAdmin}
                onLogout={logout}
                onOpenAbout={onOpenAbout}
              />
            ) : null}
          </div>
        </Header>
        <Content className="overflow-y-auto">
          <div className="mx-auto w-full max-w-[1560px] space-y-6 p-4 sm:p-6 lg:p-8">
            <Outlet />
          </div>
        </Content>
      </Layout>
      {paletteOpen ? (
        <Suspense fallback={null}>
          <CommandPalette
            open={paletteOpen}
            onClose={() => setPaletteOpen(false)}
            onOpenAnnualReport={() => goToSection('annual-report')}
          />
        </Suspense>
      ) : null}
    </Layout>
  )
}

function parentGroupKey(section: AppSection): string {
  const hit = NAV_GROUPS.find((group) =>
    group.items.some((item) => item.key === section),
  )
  return hit?.key || 'bookkeeping'
}
