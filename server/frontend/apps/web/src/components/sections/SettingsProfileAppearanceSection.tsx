import { useEffect, useMemo, useRef, useState } from 'react'
import {
  Brush,
  Camera,
  Check,
  ChevronDown,
  Clock,
  Coins,
  Copy,
  FileText,
  Loader2,
  Moon,
  MoonStar,
  Palette,
  Pencil,
  ShieldCheck,
  Sparkles,
  Sun,
  Sunrise,
  User,
  Wallet,
  X,
  type LucideIcon,
} from 'lucide-react'

import { Button, Card, Input, Modal, Select, Switch, Tooltip } from 'antd'
import {
  PrimaryColorPicker,
  useT,
  useToast,
  usePrimaryColor,
} from '@smartbook/ui'

import { patchProfileMe, uploadProfileAvatar } from '@smartbook/api-client'

import { useAuth } from '../../context/AuthContext'
import {
  HEADER_SKINS,
  HEADER_SKIN_GROUP_ORDER,
  boundPrimaryOf,
  headerSkinGroupLabelKey,
  headerSkinLabelKey,
} from '../../lib/header-skins'
import { localizeError } from '../../i18n/errors'
import { SettingsExchangeRatesSection } from './SettingsExchangeRatesSection'


const AVATAR_MAX_BYTES = 4 * 1024 * 1024 // 4 MB,跟 server 限制一致
const DISPLAY_NAME_MAX = 60

// 主币种候选列表 —— 跟 mobile prefs `baseCurrency` 常见取值对齐。当前值不在列表时
// 会在下方动态补进去,保证旧值也能正常展示 / 选中。
const PRIMARY_CURRENCY_OPTIONS = [
  'CNY', 'USD', 'EUR', 'JPY', 'HKD', 'GBP', 'KRW', 'SGD',
  'AUD', 'CAD', 'TWD', 'THB', 'MYR', 'RUB', 'INR', 'CHF',
]

/** 按本地时段返回欢迎语 i18n key + 配图 —— 5-11 / 11-13 / 13-18 / 18-23 / 23-5 */
function pickGreeting(): { key: string; icon: LucideIcon; tone: string; bgTone: string } {
  const h = new Date().getHours()
  if (h >= 5 && h < 11)
    return { key: 'profile.greeting.morning', icon: Sunrise, tone: 'text-amber-500', bgTone: 'bg-amber-500/10 text-amber-600 dark:text-amber-400' }
  if (h >= 11 && h < 13)
    return { key: 'profile.greeting.noon', icon: Sun, tone: 'text-amber-500', bgTone: 'bg-amber-500/10 text-amber-600 dark:text-amber-400' }
  if (h >= 13 && h < 18)
    return { key: 'profile.greeting.afternoon', icon: Sun, tone: 'text-orange-500', bgTone: 'bg-orange-500/10 text-orange-600 dark:text-orange-400' }
  if (h >= 18 && h < 23)
    return { key: 'profile.greeting.evening', icon: MoonStar, tone: 'text-violet-500', bgTone: 'bg-violet-500/10 text-violet-600 dark:text-violet-400' }
  return { key: 'profile.greeting.night', icon: Moon, tone: 'text-indigo-400', bgTone: 'bg-indigo-500/10 text-indigo-400' }
}

/**
 * 设置 - 账号 / 主题色 / 二次验证 / 同步偏好 section。
 *
 * 头像和收支配色现在 web 端也可写 —— 改完会推送 server,然后 server 广播
 * `profile_change` WS,mobile 端 sync_engine 自动 syncMyProfile() 拉新。
 * 实现见 .docs/web-tx-batch-actions.md(同期):API client 多了 patchProfileMe
 * 的 income_is_red / theme_primary_color / appearance 字段 + uploadProfileAvatar。
 */
export function SettingsProfileAppearanceSection() {
  const t = useT()
  const toast = useToast()
  const { token, profileMe, sessionUserId, isAdmin, refreshProfile } = useAuth()
  const { color: primaryColor } = usePrimaryColor()
  const [themeOpen, setThemeOpen] = useState(false)
  const [avatarUploading, setAvatarUploading] = useState(false)
  const [incomeColorSaving, setIncomeColorSaving] = useState(false)
  const [nameEditing, setNameEditing] = useState(false)
  const [nameDraft, setNameDraft] = useState('')
  const [nameSaving, setNameSaving] = useState(false)
  const [idCopied, setIdCopied] = useState(false)
  const fileInputRef = useRef<HTMLInputElement | null>(null)

  // 欢迎语随时段变化:每分钟刷一次 tick,刚好跨越 11/13/18/23 这些边界时
  // UI 自动更新。useState 持有 tick 数,变了就重新走 useMemo。
  const [greetingTick, setGreetingTick] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setGreetingTick((n) => n + 1), 60_000)
    return () => clearInterval(id)
  }, [])
  const greeting = useMemo(() => pickGreeting(), [greetingTick])
  // JSX 要求大写起始,把 icon 别名出来
  const GreetingIcon = greeting.icon

  const profileDisplayLabel = useMemo(
    () => profileMe?.display_name?.trim() || profileMe?.email || sessionUserId || '-',
    [profileMe, sessionUserId]
  )
  const profileInitial = useMemo(
    () => profileDisplayLabel.trim().charAt(0).toUpperCase() || '?',
    [profileDisplayLabel]
  )

  const handleAvatarPick = () => {
    fileInputRef.current?.click()
  }

  const handleAvatarSelected = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    // 选完后清掉 input,允许同名文件再次触发 onChange
    event.target.value = ''
    if (!file) return
    if (!file.type.startsWith('image/')) {
      toast.error(t('profile.avatar.upload.invalidType'))
      return
    }
    if (file.size > AVATAR_MAX_BYTES) {
      toast.error(t('profile.avatar.upload.tooLarge'))
      return
    }
    setAvatarUploading(true)
    try {
      await uploadProfileAvatar(token, file)
      // server 已广播 profile_change,WS 监听会触发 refreshProfile;这里也立即拉一次
      // 兜底,避免 WS 偶尔丢包或本地连接刚断开。
      await refreshProfile()
      toast.success(t('profile.avatar.upload.success'))
    } catch (err) {
      toast.error(localizeError(err, t))
    } finally {
      setAvatarUploading(false)
    }
  }

  const startNameEdit = () => {
    setNameDraft(profileMe?.display_name?.trim() || '')
    setNameEditing(true)
  }
  const cancelNameEdit = () => {
    setNameEditing(false)
    setNameDraft('')
  }
  const submitNameEdit = async () => {
    if (nameSaving) return
    const next = nameDraft.trim().slice(0, DISPLAY_NAME_MAX)
    const current = profileMe?.display_name?.trim() || ''
    if (next === current) {
      cancelNameEdit()
      return
    }
    setNameSaving(true)
    try {
      // 空字符串 → 允许清空 display_name(回退到展示 email);server 接受空串
      await patchProfileMe(token, { display_name: next })
      await refreshProfile()
      setNameEditing(false)
      setNameDraft('')
      toast.success(t('profile.displayName.saved'))
    } catch (err) {
      toast.error(localizeError(err, t))
    } finally {
      setNameSaving(false)
    }
  }

  const handleCopyUserId = async () => {
    const idToCopy = profileMe?.user_id || sessionUserId
    if (!idToCopy) return
    try {
      await navigator.clipboard.writeText(idToCopy)
      setIdCopied(true)
      toast.success(t('profile.userId.copied'))
      setTimeout(() => setIdCopied(false), 2000)
    } catch {
      toast.success(t('profile.userId.copied'))
    }
  }

  const incomeIsRed = profileMe?.income_is_red ?? true

  const handleIncomeColorChange = async (targetRed: boolean) => {
    if (incomeColorSaving || incomeIsRed === targetRed) return
    setIncomeColorSaving(true)
    try {
      await patchProfileMe(token, { income_is_red: targetRed })
      await refreshProfile()
      toast.success(t('profile.sync.incomeScheme.saved'))
    } catch (err) {
      toast.error(localizeError(err, t))
    } finally {
      setIncomeColorSaving(false)
    }
  }

  // 三个外观偏好(月装饰 / 紧凑金额 / 显示交易时间)—— 现在 web 也可写。
  // 改任一项时,把整个 appearance dict 一起 PATCH(server 是整体替换语义,
  // 单字段传过去会丢掉其它字段)。 :这里需要先合并出"完整的下一个 appearance"
  // 再发 patch,而不是只发改动的那个 key。
  const appearance = profileMe?.appearance ?? {}
  const headerSkin = appearance.header_skin ?? 'none'
  const compactAmount = appearance.compact_amount ?? false
  const showTransactionTime = appearance.show_transaction_time ?? false
  // 动态皮肤默认播放动效;关掉后 mobile 那边皮肤停在静态帧(省电)
  const skinAnimation = appearance.skin_animation ?? true
  const noteDisplayMode = appearance.note_display_mode ?? 'category'
  const [appearanceSaving, setAppearanceSaving] = useState(false)

  const saveAppearance = async (
    patch: Partial<NonNullable<typeof profileMe>['appearance']>,
  ) => {
    if (appearanceSaving) return
    setAppearanceSaving(true)
    try {
      await patchProfileMe(token, {
        // 整体替换语义:把 server 现有 appearance 全量带上再 patch,否则会清掉
        // mobile 设的 header_skin 等本页未直接管理的字段。
        appearance: { ...appearance, ...patch },
      })
      await refreshProfile()
      toast.success(t('profile.sync.appearanceSaved'))
    } catch (err) {
      toast.error(localizeError(err, t))
    } finally {
      setAppearanceSaving(false)
    }
  }

  // 切换皮肤。自带配色的皮肤(如周年蛋糕)在 mobile 上会把主题色
  // 锁成皮肤色,web 这边必须把同一个颜色也写回 server —— 否则 server 的
  // theme_primary_color 停在旧值,app 收到 appearance 广播时会先应用旧色再被本地
  // 绑定逻辑改回皮肤色,主题色在两个颜色之间闪。
  //
  // 顺序固定为「先颜色、后 appearance」:两者是 server 上两个字段、两次广播,
  // 先把颜色落地,对端收到 header_skin 变更时读到的颜色才是对的。
  const handleHeaderSkinChange = async (skinId: string) => {
    if (appearanceSaving || skinId === headerSkin) return
    const bound = boundPrimaryOf(skinId)
    setAppearanceSaving(true)
    try {
      if (bound) {
        await patchProfileMe(token, { theme_primary_color: bound })
      }
      await patchProfileMe(token, {
        appearance: { ...appearance, header_skin: skinId },
      })
      await refreshProfile()
      toast.success(t('profile.sync.appearanceSaved'))
    } catch (err) {
      toast.error(localizeError(err, t))
    } finally {
      setAppearanceSaving(false)
    }
  }

  // 主币种(本位币)—— 资产折算目标,跟 mobile prefs `baseCurrency` 同步。
  const primaryCurrency = profileMe?.primary_currency || ''
  const [primaryCurrencySaving, setPrimaryCurrencySaving] = useState(false)
  // 候选列表 ∪ 当前值(旧值可能不在内置列表,补进去保证可选中)
  const currencyOptions = useMemo(() => {
    const set = [...PRIMARY_CURRENCY_OPTIONS]
    if (primaryCurrency && !set.includes(primaryCurrency)) set.unshift(primaryCurrency)
    return set
  }, [primaryCurrency])

  const handlePrimaryCurrencyChange = async (code: string) => {
    if (primaryCurrencySaving || code === primaryCurrency) return
    setPrimaryCurrencySaving(true)
    try {
      await patchProfileMe(token, { primary_currency: code })
      await refreshProfile()
      toast.success(t('notice.profileUpdated'))
    } catch (err) {
      toast.error(localizeError(err, t))
    } finally {
      setPrimaryCurrencySaving(false)
    }
  }

  return (
    <div className="space-y-6">
      {/* 顶部 Page Header */}
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-bold tracking-tight text-foreground sm:text-2xl">
          {t('profile.page.title')}
        </h1>
        <p className="text-xs text-muted-foreground sm:text-sm">
          {t('profile.page.desc')}
        </p>
      </div>

      {/* 模块 1: 个人身份名片 (Profile Hero Card) */}
      <Card
        className="relative overflow-hidden border-border/70 shadow-sm"
        size="small"
        styles={{ body: { padding: '24px 28px' } }}
      >
        {/* 背景微光层 */}
        <div className="pointer-events-none absolute -right-20 -top-20 h-64 w-64 rounded-full bg-primary/10 blur-3xl" />
        <div className="pointer-events-none absolute inset-0 bg-gradient-to-br from-primary/10 via-primary/3 to-transparent" />

        <div className="relative flex flex-col gap-6 lg:flex-row lg:items-center lg:justify-between">
          {/* 左侧：头像 + 问候语 + 昵称 + 邮箱与ID */}
          <div className="flex flex-wrap items-center gap-5">
            {/* 头像 */}
            <div className="relative shrink-0">
              <button
                type="button"
                onClick={handleAvatarPick}
                disabled={avatarUploading}
                className="group relative h-[76px] w-[76px] overflow-hidden rounded-full border-2 border-background shadow-md ring-4 ring-primary/25 transition duration-200 hover:ring-primary/50 disabled:cursor-not-allowed"
                aria-label={t('profile.avatar.upload.button') as string}
                title={t('profile.avatar.upload.button') as string}
              >
                {profileMe?.avatar_url ? (
                  <img
                    alt={profileDisplayLabel}
                    className="h-full w-full object-cover transition duration-300 group-hover:scale-105"
                    src={profileMe.avatar_url}
                  />
                ) : (
                  <div className="flex h-full w-full items-center justify-center bg-muted text-xl font-bold text-muted-foreground">
                    {profileInitial}
                  </div>
                )}
                <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/45 opacity-0 backdrop-blur-[2px] transition duration-200 group-hover:opacity-100">
                  {avatarUploading ? (
                    <Loader2 className="h-5 w-5 animate-spin text-white" />
                  ) : (
                    <>
                      <Camera className="h-5 w-5 text-white" />
                      <span className="mt-1 text-[10px] font-medium text-white/90">更换</span>
                    </>
                  )}
                </div>
              </button>
              {/* 在线指示绿点 */}
              <span
                className="absolute bottom-1 right-1 h-3.5 w-3.5 rounded-full border-2 border-background bg-emerald-500 shadow-xs"
                title={t('profile.status.active')}
              />
              <input
                ref={fileInputRef}
                type="file"
                accept="image/*"
                className="hidden"
                onChange={handleAvatarSelected}
              />
            </div>

            {/* 用户主体信息 */}
            <div className="min-w-0 space-y-2">
              {/* 时段问候语与角色 Tag */}
              <div className="flex flex-wrap items-center gap-2">
                <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium ${greeting.bgTone}`}>
                  <GreetingIcon className={`h-3.5 w-3.5 ${greeting.tone}`} aria-hidden />
                  <span>{t(greeting.key)}</span>
                </span>
                {isAdmin ? (
                  <span className="inline-flex items-center gap-1 rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 text-[11px] font-semibold text-primary">
                    <ShieldCheck className="h-3 w-3" />
                    {t('profile.role.admin')}
                  </span>
                ) : (
                  <span className="inline-flex items-center gap-1 rounded-full border border-border/70 bg-muted/60 px-2 py-0.5 text-[11px] text-muted-foreground">
                    <User className="h-3 w-3" />
                    {t('profile.role.user')}
                  </span>
                )}
              </div>

              {/* 昵称 (展示 / 行内编辑) */}
              {nameEditing ? (
                <div className="flex flex-wrap items-center gap-2 pt-0.5">
                  <Input
                    autoFocus
                    onFocus={(e) => e.currentTarget.select()}
                    value={nameDraft}
                    onChange={(e) => setNameDraft(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') {
                        e.preventDefault()
                        void submitNameEdit()
                      } else if (e.key === 'Escape') {
                        e.preventDefault()
                        cancelNameEdit()
                      }
                    }}
                    maxLength={DISPLAY_NAME_MAX}
                    placeholder={t('profile.editName.placeholder')}
                    style={{ maxWidth: 260, fontSize: 16, fontWeight: 600 }}
                    disabled={nameSaving}
                  />
                  <Button
                    type="primary"
                    size="middle"
                    icon={nameSaving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
                    onClick={() => void submitNameEdit()}
                    disabled={nameSaving}
                    aria-label={t('common.save') as string}
                  >
                    {t('common.save')}
                  </Button>
                  <Button
                    size="middle"
                    icon={<X className="h-4 w-4" />}
                    onClick={cancelNameEdit}
                    disabled={nameSaving}
                    aria-label={t('common.cancel') as string}
                  >
                    {t('common.cancel')}
                  </Button>
                  <span className="text-xs text-muted-foreground">
                    {t('profile.editName.hint')}
                  </span>
                </div>
              ) : (
                <div className="flex items-center gap-2">
                  <h2 className="truncate text-xl font-bold tracking-tight text-foreground sm:text-2xl">
                    {profileDisplayLabel}
                  </h2>
                  <Tooltip title={t('profile.displayName.edit')}>
                    <Button
                      type="text"
                      size="small"
                      icon={<Pencil className="h-3.5 w-3.5 text-muted-foreground transition hover:text-foreground" />}
                      onClick={startNameEdit}
                      aria-label={t('profile.displayName.edit') as string}
                      className="rounded-full"
                    />
                  </Tooltip>
                </div>
              )}

              {/* 邮箱 & User ID 胶囊 */}
              <div className="flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
                <span className="font-medium text-foreground/80">{profileMe?.email || '-'}</span>
                <span className="text-border/80">|</span>
                <button
                  type="button"
                  onClick={handleCopyUserId}
                  className="group inline-flex items-center gap-1.5 rounded-md bg-muted/60 px-2 py-0.5 font-mono text-[11px] transition hover:bg-muted hover:text-foreground"
                  title="点击复制用户 ID"
                >
                  <span className="text-muted-foreground group-hover:text-foreground">UID:</span>
                  <span className="max-w-[120px] truncate sm:max-w-[180px]">
                    {profileMe?.user_id || sessionUserId || '-'}
                  </span>
                  {idCopied ? (
                    <Check className="h-3 w-3 text-emerald-500" />
                  ) : (
                    <Copy className="h-3 w-3 text-muted-foreground group-hover:text-foreground" />
                  )}
                </button>
              </div>
            </div>
          </div>

          {/* 右侧：快速配置状态胶囊卡 */}
          <div className="flex flex-wrap items-center gap-2.5 rounded-xl border border-border/60 bg-muted/25 p-2.5 lg:flex-col lg:items-stretch">
            {/* 主题色微组件 */}
            <button
              type="button"
              onClick={() => setThemeOpen(true)}
              className="group flex items-center justify-between gap-3 rounded-lg border border-border/50 bg-card px-3 py-2 text-left shadow-2xs transition hover:border-primary/40 hover:bg-muted/40"
            >
              <div className="flex items-center gap-2">
                <Palette className="h-4 w-4 text-primary" />
                <div>
                  <p className="text-[11px] font-medium text-muted-foreground">{t('profile.theme.current')}</p>
                  <p className="font-mono text-xs font-semibold text-foreground uppercase">
                    {primaryColor}
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-1.5">
                <span
                  className="h-4 w-4 rounded-full border border-black/10 shadow-xs ring-1 ring-background"
                  style={{ background: primaryColor }}
                  aria-hidden
                />
                <ChevronDown className="h-3.5 w-3.5 text-muted-foreground transition group-hover:translate-y-0.5" />
              </div>
            </button>

            {/* 本位币与收支微信息 */}
            <div className="flex items-center gap-2 px-1 text-xs text-muted-foreground">
              <span className="inline-flex items-center gap-1 rounded bg-muted px-2 py-1 font-mono text-[11px] font-semibold text-foreground">
                <Wallet className="h-3 w-3 text-muted-foreground" />
                {primaryCurrency || 'CNY'}
              </span>
              <span className="inline-flex items-center gap-1.5 rounded bg-muted px-2 py-1 text-[11px] font-medium text-foreground">
                <span
                  className="h-2 w-2 rounded-full"
                  style={{ background: 'rgb(var(--income-rgb))' }}
                />
                {incomeIsRed ? t('profile.sync.incomeScheme.red') : t('profile.sync.incomeScheme.green')}
              </span>
            </div>
          </div>
        </div>
      </Card>

      {/* 主题色弹窗 */}
      <Modal
        open={themeOpen}
        title={t('profile.theme.title')}
        onCancel={() => setThemeOpen(false)}
        width={400}
        footer={null}
        destroyOnClose
      >
        <p className="mb-4 text-xs text-muted-foreground leading-relaxed">
          {t('profile.theme.desc')}
        </p>
        <div className="py-1">
          <PrimaryColorPicker />
        </div>
      </Modal>

      {/* 模块 2: 界面与外观偏好 (Appearance & Preferences) */}
      <Card
        className="border-border/70 shadow-sm"
        size="small"
        title={
          <div className="flex flex-col py-1">
            <span className="text-base font-semibold">{t('profile.appearance.sectionTitle')}</span>
            <span className="text-xs font-normal text-muted-foreground">
              {t('profile.appearance.sectionDesc')}
            </span>
          </div>
        }
        styles={{ body: { padding: '20px 24px' } }}
      >
        <div className="space-y-6">
          {/* 子块 1: 收支配色方案选择器 (图形化双卡片对比) */}
          <div className="space-y-3">
            <div>
              <h3 className="text-sm font-semibold text-foreground">
                {t('profile.sync.incomeScheme.title')}
              </h3>
              <p className="text-xs text-muted-foreground">
                {t('profile.sync.incomeScheme.desc')}
              </p>
            </div>

            <div className="grid gap-3 sm:grid-cols-2">
              {/* 卡片 A: 红色收入 / 绿色支出 */}
              <button
                type="button"
                onClick={() => void handleIncomeColorChange(true)}
                disabled={incomeColorSaving}
                className={`relative flex flex-col rounded-xl border p-4 text-left transition duration-200 ${
                  incomeIsRed
                    ? 'border-primary bg-primary/5 shadow-xs ring-2 ring-primary/20'
                    : 'border-border/70 bg-card hover:border-border hover:bg-muted/20'
                }`}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className="flex items-center gap-1.5">
                      <span className="h-3.5 w-3.5 rounded-full bg-red-500 shadow-2xs" />
                      <span className="text-xs font-medium">{t('enum.txType.income')}</span>
                    </div>
                    <span className="text-muted-foreground">/</span>
                    <div className="flex items-center gap-1.5">
                      <span className="h-3.5 w-3.5 rounded-full bg-emerald-500 shadow-2xs" />
                      <span className="text-xs font-medium">{t('enum.txType.expense')}</span>
                    </div>
                  </div>
                  {incomeIsRed ? (
                    <span className="flex h-5 w-5 items-center justify-center rounded-full bg-primary text-primary-foreground">
                      <Check className="h-3.5 w-3.5" />
                    </span>
                  ) : null}
                </div>
                <div className="mt-2.5">
                  <p className="text-sm font-semibold text-foreground">
                    {t('profile.sync.incomeScheme.red')}
                  </p>
                  <p className="mt-0.5 text-xs text-muted-foreground">
                    {t('profile.sync.incomeScheme.redDesc')}
                  </p>
                </div>
              </button>

              {/* 卡片 B: 绿色收入 / 红色支出 */}
              <button
                type="button"
                onClick={() => void handleIncomeColorChange(false)}
                disabled={incomeColorSaving}
                className={`relative flex flex-col rounded-xl border p-4 text-left transition duration-200 ${
                  !incomeIsRed
                    ? 'border-primary bg-primary/5 shadow-xs ring-2 ring-primary/20'
                    : 'border-border/70 bg-card hover:border-border hover:bg-muted/20'
                }`}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className="flex items-center gap-1.5">
                      <span className="h-3.5 w-3.5 rounded-full bg-emerald-500 shadow-2xs" />
                      <span className="text-xs font-medium">{t('enum.txType.income')}</span>
                    </div>
                    <span className="text-muted-foreground">/</span>
                    <div className="flex items-center gap-1.5">
                      <span className="h-3.5 w-3.5 rounded-full bg-red-500 shadow-2xs" />
                      <span className="text-xs font-medium">{t('enum.txType.expense')}</span>
                    </div>
                  </div>
                  {!incomeIsRed ? (
                    <span className="flex h-5 w-5 items-center justify-center rounded-full bg-primary text-primary-foreground">
                      <Check className="h-3.5 w-3.5" />
                    </span>
                  ) : null}
                </div>
                <div className="mt-2.5">
                  <p className="text-sm font-semibold text-foreground">
                    {t('profile.sync.incomeScheme.green')}
                  </p>
                  <p className="mt-0.5 text-xs text-muted-foreground">
                    {t('profile.sync.incomeScheme.greenDesc')}
                  </p>
                </div>
              </button>
            </div>
          </div>

          {/* 子块 2: 主题色整行展示 */}
          <div className="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-border/60 bg-muted/15 p-4">
            <div className="flex items-start gap-3">
              <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
                <Palette className="h-4 w-4" />
              </div>
              <div>
                <p className="text-sm font-medium text-foreground">{t('profile.theme.title')}</p>
                <p className="max-w-xl text-xs text-muted-foreground leading-relaxed">
                  {t('profile.theme.desc')}
                </p>
              </div>
            </div>
            <div className="flex items-center gap-3">
              <div className="flex items-center gap-2 rounded-lg border border-border/60 bg-card px-3 py-1.5">
                <span
                  className="h-4 w-4 rounded-full border border-black/10 shadow-xs"
                  style={{ background: primaryColor }}
                />
                <span className="font-mono text-xs font-semibold uppercase">{primaryColor}</span>
              </div>
              <Button
                type="default"
                size="middle"
                icon={<Palette className="h-3.5 w-3.5" />}
                onClick={() => setThemeOpen(true)}
              >
                {t('profile.theme.customize')}
              </Button>
            </div>
          </div>

          {/* 子块 3: 界面与显示细节 (Settings Row List) */}
          <div className="space-y-3 pt-2">
            <h3 className="text-sm font-semibold text-foreground">
              {t('profile.sync.displayList.title')}
            </h3>

            <div className="divide-y divide-border/60 rounded-xl border border-border/70 bg-card">
              {/* 行 1: 顶部视觉皮肤 */}
              <div className="flex flex-wrap items-center justify-between gap-3 p-4 transition hover:bg-muted/10">
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted text-muted-foreground">
                    <Brush className="h-4 w-4" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-foreground">{t('profile.sync.headerSkin')}</p>
                    <p className="text-xs text-muted-foreground">{t('profile.sync.headerSkin.desc')}</p>
                  </div>
                </div>
                <Select
                  style={{ width: 190 }}
                  size="middle"
                  value={headerSkin}
                  onChange={(value) => void handleHeaderSkinChange(value)}
                  disabled={appearanceSaving}
                  options={[
                    { value: 'none', label: t('profile.sync.headerSkin.none') },
                    ...HEADER_SKIN_GROUP_ORDER.map((group) => ({
                      label: t(headerSkinGroupLabelKey(group)),
                      options: HEADER_SKINS.filter((s) => s.group === group).map((skin) => ({
                        value: skin.id,
                        label: (
                          <span className="flex items-center gap-1.5">
                            {t(headerSkinLabelKey(skin.id))}
                            {skin.animated ? (
                              <span className="rounded-xs bg-primary/12 px-1 text-[9px] font-medium leading-4 text-primary">
                                {t('profile.sync.headerSkin.animated')}
                              </span>
                            ) : null}
                            {skin.boundPrimary ? (
                              <span
                                aria-label={t('profile.sync.headerSkin.boundPalette')}
                                title={t('profile.sync.headerSkin.boundPalette')}
                                className="h-2.5 w-2.5 shrink-0 rounded-full ring-1 ring-border"
                                style={{ backgroundColor: skin.boundPrimary }}
                              />
                            ) : null}
                          </span>
                        ),
                      })),
                    })),
                  ]}
                />
              </div>

              {/* 行 2: 余额显示格式 */}
              <div className="flex flex-wrap items-center justify-between gap-3 p-4 transition hover:bg-muted/10">
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted text-muted-foreground">
                    <Coins className="h-4 w-4" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-foreground">{t('profile.sync.compactAmount')}</p>
                    <p className="text-xs text-muted-foreground">{t('profile.sync.compactAmount.desc')}</p>
                  </div>
                </div>
                <Select
                  style={{ width: 190 }}
                  size="middle"
                  value={compactAmount ? 'compact' : 'full'}
                  onChange={(value) =>
                    void saveAppearance({ compact_amount: value === 'compact' })
                  }
                  disabled={appearanceSaving}
                  options={[
                    { value: 'full', label: t('profile.sync.compactAmount.full') },
                    { value: 'compact', label: t('profile.sync.compactAmount.compact') },
                  ]}
                />
              </div>

              {/* 行 3: 备注显示方式 */}
              <div className="flex flex-wrap items-center justify-between gap-3 p-4 transition hover:bg-muted/10">
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted text-muted-foreground">
                    <FileText className="h-4 w-4" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-foreground">{t('profile.sync.noteDisplay')}</p>
                    <p className="text-xs text-muted-foreground">{t('profile.sync.noteDisplay.desc')}</p>
                  </div>
                </div>
                <Select
                  style={{ width: 190 }}
                  size="middle"
                  value={noteDisplayMode}
                  onChange={(value) =>
                    void saveAppearance({ note_display_mode: value as 'category' | 'note' })
                  }
                  disabled={appearanceSaving}
                  options={[
                    { value: 'category', label: t('profile.sync.noteDisplay.category') },
                    { value: 'note', label: t('profile.sync.noteDisplay.note') },
                  ]}
                />
              </div>

              {/* 行 4: 显示交易时间 */}
              <div className="flex flex-wrap items-center justify-between gap-3 p-4 transition hover:bg-muted/10">
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted text-muted-foreground">
                    <Clock className="h-4 w-4" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-foreground">{t('profile.sync.showTime')}</p>
                    <p className="text-xs text-muted-foreground">{t('profile.sync.showTime.desc')}</p>
                  </div>
                </div>
                <Switch
                  checked={showTransactionTime}
                  aria-label={t('profile.sync.showTime') as string}
                  disabled={appearanceSaving}
                  onChange={(checked) =>
                    void saveAppearance({ show_transaction_time: checked })
                  }
                />
              </div>

              {/* 行 5: 皮肤动效 */}
              <div className="flex flex-wrap items-center justify-between gap-3 p-4 transition hover:bg-muted/10">
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted text-muted-foreground">
                    <Sparkles className="h-4 w-4" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-foreground">{t('profile.sync.skinAnimation')}</p>
                    <p className="text-xs text-muted-foreground">{t('profile.sync.skinAnimation.desc')}</p>
                  </div>
                </div>
                <Switch
                  checked={skinAnimation}
                  aria-label={t('profile.sync.skinAnimation') as string}
                  disabled={appearanceSaving}
                  onChange={(checked) => void saveAppearance({ skin_animation: checked })}
                />
              </div>
            </div>
          </div>
        </div>
      </Card>

      {/* 模块 3: 货币与汇率管理中心 (Currency & Exchange Rates) */}
      <div className="space-y-4">
        {/* 本位币设置卡片 */}
        <Card
          className="border-border/70 shadow-sm"
          size="small"
          title={
            <div className="flex flex-col py-1">
              <span className="text-base font-semibold">{t('profile.currency.sectionTitle')}</span>
              <span className="text-xs font-normal text-muted-foreground">
                {t('profile.currency.sectionDesc')}
              </span>
            </div>
          }
          styles={{ body: { padding: '16px 20px' } }}
        >
          <div className="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-border/60 bg-muted/15 p-4">
            <div className="flex items-start gap-3">
              <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
                <Wallet className="h-4 w-4" />
              </div>
              <div>
                <p className="text-sm font-medium text-foreground">{t('settings.primaryCurrency')}</p>
                <p className="max-w-xl text-xs text-muted-foreground leading-relaxed">
                  {t('settings.primaryCurrency.hint')}
                </p>
              </div>
            </div>
            <div className="flex items-center gap-2.5">
              {primaryCurrencySaving ? (
                <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
              ) : null}
              <Select
                style={{ width: 180 }}
                size="middle"
                value={primaryCurrency || undefined}
                placeholder={t('settings.primaryCurrency.unset')}
                onChange={(value) => void handlePrimaryCurrencyChange(value)}
                disabled={primaryCurrencySaving}
                options={currencyOptions.map((code) => ({
                  value: code,
                  label: `${code} · ${t(`currency.${code}`)}`,
                }))}
              />
            </div>
          </div>
        </Card>

        {/* 汇率管理列表 (直接复用并升级后的 SettingsExchangeRatesSection) */}
        <SettingsExchangeRatesSection />
      </div>
    </div>
  )
}
