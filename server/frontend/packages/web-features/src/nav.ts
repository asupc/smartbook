export type AppSection =
  | 'overview'
  | 'transactions'
  | 'calendar'
  | 'accounts'
  | 'categories'
  | 'tags'
  | 'budgets'
  | 'ledgers'
  | 'settings-profile'
  | 'settings-appearance'
  | 'settings-health'
  | 'settings-devices'
  | 'settings-developer'
  | 'settings-ai'
  | 'settings-ai-logs'
  | 'settings-raw-evidence'
  | 'admin-users'
  | 'admin-backup'
  | 'admin-data-cleanup'
  | 'admin-duplicate-transactions'
  | 'import'
  | 'annual-report'

export type NavItem = {
  key: AppSection
  labelKey: string
}

export type NavGroup = {
  key: string
  titleKey: string
  items: NavItem[]
}

/** 侧栏 + 头像下拉共用的导航结构。
 *
 * 分组约定:
 *   - bookkeeping …… 记账主视图
 *   - tools …… 高频但非"主视图"级的工具入口(预算/账本/年度报告/导入)
 *   - settings …… 用户偏好类设置
 *   - admin …… 平台管理,仅 admin 用户可见(渲染侧按 isAdmin 过滤)
 */
export const NAV_GROUPS: NavGroup[] = [
  {
    key: 'bookkeeping',
    titleKey: 'nav.group.bookkeeping',
    items: [
      { key: 'overview', labelKey: 'nav.overview' },
      { key: 'transactions', labelKey: 'nav.transactions' },
      // calendar 不进主导航(高频但不是"主视图"等级,跟 transactions 重复语义);
      // 入口走 AppHeader 右上角图标 + ⌘K 即可。
      { key: 'accounts', labelKey: 'nav.accounts' },
      { key: 'categories', labelKey: 'nav.categories' },
      { key: 'tags', labelKey: 'nav.tags' }
    ]
  },
  {
    key: 'tools',
    titleKey: 'nav.group.tools',
    items: [
      { key: 'budgets', labelKey: 'nav.budgets' },
      { key: 'ledgers', labelKey: 'nav.ledgers' },
      { key: 'annual-report', labelKey: 'nav.annualReport' },
      { key: 'import', labelKey: 'nav.import' }
    ]
  },
  {
    key: 'settings',
    titleKey: 'nav.group.settings',
    items: [
      // 个人资料 + 外观合并:两者都是"我的偏好",心智上不该分两处。
      // 保留 `settings-appearance` AppSection 是为了兼容老的分享链接,
      // AppPage 把 appearance 的 route section 也渲染同一个卡片集。
      { key: 'settings-profile', labelKey: 'nav.profile' },
      { key: 'settings-ai', labelKey: 'nav.ai' },
      { key: 'settings-ai-logs', labelKey: 'nav.aiLogs' },
      { key: 'settings-raw-evidence', labelKey: 'nav.rawEvidence' },
      { key: 'settings-health', labelKey: 'nav.health' },
      { key: 'settings-devices', labelKey: 'nav.devices' },
      // PAT / MCP 管理 — 给 LLM 客户端发长期 token 的地方。
      { key: 'settings-developer', labelKey: 'nav.developer' }
    ]
  },
  {
    key: 'admin',
    titleKey: 'nav.group.admin',
    items: [
      { key: 'admin-users', labelKey: 'nav.users' },
      { key: 'admin-backup', labelKey: 'nav.backup' },
      { key: 'admin-data-cleanup', labelKey: 'nav.dataCleanup' },
      { key: 'admin-duplicate-transactions', labelKey: 'nav.duplicates' }
    ]
  }
]

export function groupKeyBySection(section: AppSection): string {
  const hit = NAV_GROUPS.find((group) => group.items.some((item) => item.key === section))
  return hit?.key || 'bookkeeping'
}
