import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'

import {
  createAccount,
  createTransaction,
  deleteAccount,
  fetchExchangeRateOverrides,
  fetchExchangeRates,
  fetchNetWorthHistory,
  fetchWorkspaceAccounts,
  fetchWorkspaceAnalytics,
  fetchWorkspaceTags,
  fetchWorkspaceTransactions,
  updateAccount,
  type ExchangeRateOverride,
  type ExchangeRatesResponse,
  type NetWorthHistory,
  type ReadAccount,
  type WorkspaceAccount,
  type WorkspaceAnalytics,
  type WorkspaceTag,
  type WorkspaceTransaction,
} from '@smartbook/api-client'
import { Button, Card, Drawer } from 'antd'
import { useT, useToast } from '@smartbook/ui'
import {
  AccountsPanel,
  AssetsCompositionMini,
  ConfirmDialog,
  CurrencyAssetCard,
  accountDefaults,
  computeCurrencySummary,
  computeTypeGroups,
  effectiveRateToBase,
  mergeGroupsToBase,
  periodLabel,
  resolveCurrencyFields,
  splitByCurrency,
  type AccountForm,
  type AdjustableAccount,
  type CurrencyBucket,
} from '@smartbook/web-features'

import { AssetKpiRow } from '../../components/dashboard/AssetKpiRow'
import { AccountsTable } from '../../components/dashboard/AccountsTable'
import { NetWorthTrend } from '../../components/dashboard/NetWorthTrend'
import { routePath } from '../../state/router'
import { dispatchOpenDetailAccount } from '../../lib/txDialogEvents'
import { useAuth } from '../../context/AuthContext'
import { useLedgers } from '../../context/LedgersContext'
import { usePageCache } from '../../context/PageDataCacheContext'
import { useSyncRefresh } from '../../context/SyncSocketContext'
import { localizeError } from '../../i18n/errors'
import { useLedgerWrite } from '../../app/useLedgerWrite'

const ACCOUNT_DETAIL_PAGE_SIZE = 20

/**
 * 账户 / 资产页 —— 账户列表 + CRUD(无 delete,web 只支持创建/编辑)
 * + 账户详情 dialog(点卡片弹出该账户的交易列表,无限滚动)。
 *
 * tags 独立 fetch 一份,只为 AccountDetailDialog 里 TransactionList 渲染
 * tag chip 用 —— 不跟其它 page 共享,每次进入该页现拉。
 *
 * 已知回归:AccountDetailDialog 的附件预览(resolveAttachmentPreviewUrl /
 * onPreviewAttachment)本轮留空,预览功能待 "附件预览共享 hook" 独立 task。
 */
export function AccountsPage() {
  const t = useT()
  const toast = useToast()
  const navigate = useNavigate()
  const { token, profileMe } = useAuth()
  const { ledgers, activeLedgerId, currentLedger } = useLedgers()
  const { retryOnConflict, isWriteConflict } = useLedgerWrite()

  const base = profileMe?.primary_currency || ''

  // 主要数据走 PageDataCache —— 切走再切回来立刻显示上次的值,不闪烁。
  // rows 用 WorkspaceAccount(包含 tx_count / balance 等聚合字段),删除前需要
  // 看 tx_count 决定是否提示用户(对齐 mobile account_edit_page._delete)。
  const [rows, setRows] = usePageCache<WorkspaceAccount[]>('accounts:rows', [])
  const [tags, setTags] = usePageCache<WorkspaceTag[]>('accounts:tags', [])
  const [form, setForm] = useState<AccountForm>(accountDefaults())
  // 删除前的待确认账户。null = 无 pending。WorkspaceAccount 带 tx_count 字段,
  // confirm dialog 直接读它,不再发额外请求。
  const [pendingDelete, setPendingDelete] = useState<WorkspaceAccount | null>(null)
  const [deleting, setDeleting] = useState(false)

  // 分币种明细 dialog(折算汇总卡的「详情」入口;单币种时该卡不出详情按钮)。
  const [detailOpen, setDetailOpen] = useState(false)

  // 多币种折算(只读卡)。主币种存在且账户币种 ≥2 种时,并行拉汇率 + 手动 override,
  // 任一失败置 null 不阻塞账户列表。单币种 / 无主币种则不渲染卡(零变化)。
  // key 带 base 维度:切换主币种后不会复用旧 base 的汇率缓存。
  const [rates, setRates] = usePageCache<ExchangeRatesResponse | null>(
    base ? `accounts:rates:${base}` : 'accounts:rates:',
    null,
  )
  const [rateOverrides, setRateOverrides] = usePageCache<ExchangeRateOverride[]>(
    base ? `accounts:rateOverrides:${base}` : 'accounts:rateOverrides:',
    [],
  )

  // 净资产趋势(回算每月累积净值,对齐 App 资产页净资产卡的 sparkline)。
  // 按当前账本分桶:切账本读对应桶,失败置 null 不阻塞账户列表(同 rates/overrides 容错)。
  const [netWorthHistory, setNetWorthHistory] = usePageCache<NetWorthHistory | null>(
    // 净值趋势是全局资产(所有账本所有账户),与账本无关 —— 缓存键不带 activeLedgerId。
    'accounts:netWorthHistory',
    null,
  )

  // KPI 收支数据(本月 / 本年)。analytics 是账本维度,故缓存键按 activeLedgerId
  // 分桶,切账本不串号;失败置 null 不阻塞账户列表(同 rates/overrides 容错)。
  const kpiBucket = activeLedgerId || '__none__'
  const [monthSummary, setMonthSummary] = usePageCache<WorkspaceAnalytics['summary'] | null>(
    `accounts:${kpiBucket}:monthSummary`,
    null,
  )
  const [yearSummary, setYearSummary] = usePageCache<WorkspaceAnalytics['summary'] | null>(
    `accounts:${kpiBucket}:yearSummary`,
    null,
  )

  // detail 弹窗已迁到 GlobalEntityDialogs(AppShell 顶层),本页只负责
  // dispatch openDetailAccount 事件,弹窗在全局渲染。

  const notifyError = useCallback(
    (err: unknown) => toast.error(localizeError(err, t), t('notice.error')),
    [toast, t]
  )
  const notifySuccess = useCallback(
    (msg: string) => toast.success(msg, t('notice.success')),
    [toast, t]
  )

  const refresh = useCallback(async () => {
    try {
      const now = new Date()
      const tzOffsetMinutes = -now.getTimezoneOffset()
      // 本月口径与 OverviewPage 一致:由账本自定义起始日 month_start_day 算出当前周期。
      const msd = Math.max(1, Math.min(28, currentLedger?.month_start_day ?? 1))
      const currentPeriod = periodLabel(now, msd)
      const [accountRows, tagRows, history, monthA, yearA] = await Promise.all([
        fetchWorkspaceAccounts(token, { limit: 500 }),
        fetchWorkspaceTags(token, { limit: 500 }),
        // 净值趋势是全局资产(账户为 user-global、跨所有账本),绝不按当前账本过滤 ——
        // 否则切到无交易的账本时趋势会空,而净资产卡(全局账户余额)仍有数据,口径不一致。
        fetchNetWorthHistory(token, { tzOffsetMinutes }).catch(() => null),
        // KPI 收支:summary 同时含 income_total/expense_total,metric 只影响 category_ranks,
        // 故 month/year 各拉一次即可(任一失败置 null,不阻塞账户列表)。
        fetchWorkspaceAnalytics(token, {
          scope: 'month',
          metric: 'expense',
          period: currentPeriod,
          ledgerId: activeLedgerId || undefined,
          tzOffsetMinutes,
        }).catch(() => null),
        fetchWorkspaceAnalytics(token, {
          scope: 'year',
          metric: 'expense',
          ledgerId: activeLedgerId || undefined,
          tzOffsetMinutes,
        }).catch(() => null),
      ])
      setRows(accountRows)
      setTags(tagRows)
      setNetWorthHistory(history)
      setMonthSummary(monthA?.summary ?? null)
      setYearSummary(yearA?.summary ?? null)

      // 只有"主币种存在 + 账户涉及 ≥2 种币种"才需要折算卡。其余情况清空缓存,
      // 让卡不渲染。汇率请求任一失败置 null,不影响账户列表正常展示。
      const distinct = new Set<string>()
      for (const a of accountRows) {
        const cur = (a.currency || '').toUpperCase()
        if (cur) distinct.add(cur)
      }
      if (base && distinct.size >= 2) {
        const [r, o] = await Promise.all([
          fetchExchangeRates(token, base).catch(() => null),
          fetchExchangeRateOverrides(token).catch(() => [] as ExchangeRateOverride[]),
        ])
        setRates(r)
        setRateOverrides(o)
      } else {
        setRates(null)
        setRateOverrides([])
      }
    } catch (err) {
      notifyError(err)
    }
  }, [token, base, activeLedgerId, currentLedger, notifyError])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useSyncRefresh(() => {
    void refresh()
  })

  const onSave = async (): Promise<boolean> => {
    if (!activeLedgerId) {
      toast.error(t('shell.selectLedgerFirst'), t('notice.error'))
      return false
    }
    const trimmedName = form.name.trim()
    if (!trimmedName) {
      toast.error(t('accounts.error.nameRequired'), t('notice.error'))
      return false
    }
    // mobile account_edit_page 也禁止重名,跨端一致。编辑自己时跳过。
    const duplicate = rows.find(
      (row) =>
        (row.name || '').trim().toLowerCase() === trimmedName.toLowerCase() &&
        row.id !== form.editingId,
    )
    if (duplicate) {
      toast.error(t('accounts.error.nameDuplicate'), t('notice.error'))
      return false
    }
    const initialBalanceNum = Number(form.initial_balance || 0)
    if (!Number.isFinite(initialBalanceNum)) {
      toast.error(t('accounts.error.balanceInvalid'), t('notice.error'))
      return false
    }
    // 信用卡日期校验:1-31,空字符串视作未填(null)。其他类型不要这两个字段,
    // 走 onFormChange 切换类型时已经清空,这里再 guard 一次。
    const billingDayNum =
      form.account_type === 'credit_card' && form.billing_day.trim()
        ? Math.round(Number(form.billing_day))
        : null
    if (billingDayNum !== null && (!Number.isFinite(billingDayNum) || billingDayNum < 1 || billingDayNum > 31)) {
      toast.error(t('accounts.error.billingDayInvalid'), t('notice.error'))
      return false
    }
    const paymentDueDayNum =
      form.account_type === 'credit_card' && form.payment_due_day.trim()
        ? Math.round(Number(form.payment_due_day))
        : null
    if (paymentDueDayNum !== null && (!Number.isFinite(paymentDueDayNum) || paymentDueDayNum < 1 || paymentDueDayNum > 31)) {
      toast.error(t('accounts.error.paymentDueDayInvalid'), t('notice.error'))
      return false
    }
    const creditLimitRaw = form.credit_limit.trim()
    const creditLimitNum =
      form.account_type === 'credit_card' && creditLimitRaw ? Number(creditLimitRaw) : null
    if (creditLimitNum !== null && (!Number.isFinite(creditLimitNum) || creditLimitNum < 0)) {
      toast.error(t('accounts.error.creditLimitInvalid'), t('notice.error'))
      return false
    }
    try {
      const isCreditCard = form.account_type === 'credit_card'
      const isBankOrCredit = isCreditCard || form.account_type === 'bank_card'
      const payload = {
        name: trimmedName,
        account_type: form.account_type || null,
        currency: form.currency || null,
        // 初始值仅创建时可设,编辑只读展示(服务端 mutate/push 双路径同样忽略);
        // 余额变更走「调整余额」(下文的 handleAdjustBalance)。
        ...(form.editingId ? {} : { initial_balance: initialBalanceNum }),
        // 扩展字段:non-credit_card 类型显式传 null 清空 server 上残留的值;
        // bank_card / credit_card 才有 bank_name / card_last_four。
        note: form.note.trim() || null,
        credit_limit: isCreditCard ? creditLimitNum : null,
        billing_day: isCreditCard ? billingDayNum : null,
        payment_due_day: isCreditCard ? paymentDueDayNum : null,
        bank_name: isBankOrCredit ? form.bank_name.trim() || null : null,
        card_last_four: isBankOrCredit ? form.card_last_four.trim() || null : null,
        // 账户隐藏(issue #240):新建默认 false;编辑时带当前切换状态。
        hidden: form.hidden,
      }
      await retryOnConflict(activeLedgerId, (base) =>
        form.editingId
          ? updateAccount(token, activeLedgerId, form.editingId, base, payload)
          : createAccount(token, activeLedgerId, base, payload)
      )
      setForm(accountDefaults())
      await refresh()
      notifySuccess(form.editingId ? t('notice.accountUpdated') : t('notice.accountCreated'))
      return true
    } catch (err) {
      if (isWriteConflict(err)) {
        await refresh()
        notifyError(err)
        return false
      }
      notifyError(err)
      return false
    }
  }


  // 「已隐藏」分区卡片上的快捷「恢复」按钮 —— 不经编辑弹窗,直接 PATCH
  // hidden=false(对齐产品设计:恢复"即时生效,卡片回到在用分区")。
  // 入参用 ReadAccount(跟 AccountsPanel.onRestore 的回调签名对齐,只用得到 id)。
  const onRestore = async (row: ReadAccount) => {
    if (!activeLedgerId) {
      toast.error(t('shell.selectLedgerFirst'), t('notice.error'))
      return
    }
    try {
      await retryOnConflict(activeLedgerId, (base) =>
        updateAccount(token, activeLedgerId, row.id, base, { hidden: false }),
      )
      await refresh()
      notifySuccess(t('notice.accountRestored'))
    } catch (err) {
      if (isWriteConflict(err)) {
        await refresh()
      }
      notifyError(err)
    }
  }

  // 当前激活账本是否可写 — 决定编辑弹窗里「调整余额」按钮是否可用。
  const activeLedgerWritable =
    !!activeLedgerId && ledgers.some((l) => l.ledger_id === activeLedgerId &&
      (l.role === 'owner' || l.role === 'editor'))

  /**
   * 「调整余额」提交(编辑账户弹窗入口,原在账户详情弹窗):输入调整后余额
   * → 差额记一笔排除统计/预算的调整交易(income 调整或 expense 调整),
   * 与 mobile account_edit_page 同逻辑。
   *
   * 账本归属:账户是 user-global(ledger_id 为空),调整交易落进「当前激活
   * 账本」— 与记账/新建交易默认账本一致。
   */
  const handleAdjustBalance = useCallback(
    async (acc: AdjustableAccount, targetBalance: number): Promise<boolean> => {
      const ledgerId = (activeLedgerId || '').trim()
      if (!ledgerId || !ledgers.some((l) => l.ledger_id === ledgerId &&
          (l.role === 'owner' || l.role === 'editor'))) {
        toast.error(t('shell.selectLedgerFirst'), t('notice.error'))
        return false
      }
      const current =
        typeof acc.balance === 'number' ? acc.balance! : (acc.initial_balance ?? 0)
      const diff = targetBalance - current
      const amount = Math.abs(diff)
      const isIncome = diff > 0

      // 多币种:账户币种 ≠ 账本主币种时按 server 汇率折算(与 TransactionsPage
      // 提交同一 helper)。币种相同时不发字段(默认本位币)。
      const ledgerBase = (
        ledgers.find((l) => l.ledger_id === ledgerId)?.currency || 'CNY'
      )
        .trim()
        .toUpperCase()
      const accCurrency = (acc.currency || '').trim().toUpperCase()
      let currencyFields: { currency_code?: string; native_amount?: number } = {}
      if (accCurrency && accCurrency !== ledgerBase) {
        try {
          const resolved = await resolveCurrencyFields({
            token,
            ledgerBase,
            currency: accCurrency,
            amount,
          })
          if (resolved) currencyFields = resolved
        } catch {
          toast.error(t('transactions.error.rateMissing'), t('notice.error'))
          return false
        }
      }

      try {
        await retryOnConflict(ledgerId, (base) =>
          createTransaction(token, ledgerId, base, {
            tx_type: isIncome ? 'income' : 'expense',
            amount,
            happened_at: new Date().toISOString(),
            note: t('detail.account.adjustBalanceNote'),
            account_name: acc.name,
            account_id: acc.id,
            // 对齐 mobile:调整账不计入统计/预算,只影响余额(审计留痕);
            // budget 标记仅支出有意义(服务端规则,收入不发)。
            exclude_from_stats: true,
            exclude_from_budget: !isIncome,
            ...currencyFields,
          }),
        )
      } catch (err) {
        notifyError(err)
        return false
      }

      await refresh()
      notifySuccess(t('detail.account.adjustBalanceRecorded'))
      return true
    },
    [token, activeLedgerId, ledgers, t, retryOnConflict, notifyError, notifySuccess, refresh],
  )

  // 删除流程:点删除按钮 → 弹 ConfirmDialog,dialog 里根据 tx_count 决定文案。
  // 跟 mobile account_edit_page._delete 对齐:有交易则警示总条数 + 红色按钮。
  const onConfirmDelete = async () => {
    if (!pendingDelete) return
    if (!activeLedgerId) {
      toast.error(t('shell.selectLedgerFirst'), t('notice.error'))
      return
    }
    setDeleting(true)
    try {
      await retryOnConflict(activeLedgerId, (base) =>
        deleteAccount(token, activeLedgerId, pendingDelete.id, base),
      )
      setPendingDelete(null)
      await refresh()
      notifySuccess(t('notice.accountDeleted'))
    } catch (err) {
      if (isWriteConflict(err)) {
        await refresh()
      }
      notifyError(err)
    } finally {
      setDeleting(false)
    }
  }

  // 资产汇总(统一折算视图):按币种分组 → 每币种 summary(netWorth/assetTotal/
  // liabilityTotal)× 汇率累加到主币种。复用 assetAggregation 铁律原语确保负债符号
  // 契约单点。缺失汇率的币种进 missing 列表、不计入任何总额 / donut(整币种剔除),
  // **绝不按 1 折算**。
  //   - null:无账户(byCur 为空),不出汇总卡(空态由 AccountsPanel 引导)。
  //   - { needsBase: true }:多币种但未设主币种 —— 渲染处出「设置主币种」引导卡。
  //   - 否则:有效主币种 effectiveBase(已设则用之;单币种且未设则取该唯一币种,
  //     此时折算率恒为 1、missing 必空、rateDate 置 undefined 不显脚注/≈)。
  //   - buckets:每币种 summary + 分组,既给合并 donut(mergeGroupsToBase),也给详情 dialog 的分币种卡复用。
  //   - mergedGroups:各币种 groups × 汇率折算后按 type 聚合成一份主币种构成,喂 donut(currency=effectiveBase)。
  const converted = useMemo(() => {
    const byCur = splitByCurrency(rows)
    if (byCur.size === 0) return null
    // 主币种未设时:单币种回退到该唯一币种(折算率 1,零误差);多币种则无从折算。
    const effectiveBase = base || (byCur.size === 1 ? [...byCur.keys()][0] : '')
    if (!effectiveBase) return { needsBase: true } as const
    // 单币种(effectiveBase 即本币 且 仅 1 种)不显汇率脚注 / ≈ 前缀。
    const singleCurrency = byCur.size === 1

    const buckets: CurrencyBucket[] = []
    let netWorth = 0
    let assetTotal = 0
    let liabilityTotal = 0
    const missing = new Set<string>()
    for (const [cur, curRows] of byCur) {
      const summary = computeCurrencySummary(curRows)
      // 详情 dialog 复用 CurrencyAssetCard,需要全部币种(含缺失汇率的)原样展示。
      buckets.push({ currency: cur, summary, groups: computeTypeGroups(curRows, t) })
      const eff = effectiveRateToBase(cur, effectiveBase, rates, rateOverrides)
      if (!eff) {
        missing.add(cur)
        continue
      }
      netWorth += summary.netWorth * eff.rate
      assetTotal += summary.assetTotal * eff.rate
      liabilityTotal += summary.liabilityTotal * eff.rate
    }
    // donut 与上面总额同口径:mergeGroupsToBase 内部对缺失汇率币种同样剔除。
    const mergedGroups = mergeGroupsToBase(buckets, effectiveBase, rates, rateOverrides)
    return {
      needsBase: false as const,
      base: effectiveBase,
      // 单币种不带「按汇率折算」语义:不显 ≈ / 脚注(rateDate 置 undefined)。
      singleCurrency,
      netWorth,
      assetTotal,
      liabilityTotal,
      mergedGroups,
      buckets: buckets.sort(
        (a, b) =>
          b.summary.assetTotal +
          Math.abs(b.summary.liabilityTotal) -
          (a.summary.assetTotal + Math.abs(a.summary.liabilityTotal)),
      ),
      missing: [...missing].sort(),
      rateDate: singleCurrency ? undefined : rates?.rate_date,
    }
  }, [base, rows, rates, rateOverrides, t])

  return (
    <>
      {/* 资产汇总(统一折算视图)—— 四态:
          - converted===null(无账户):不出卡,账户空态由 AccountsPanel 内部引导。
          - converted.needsBase(多币种未设主币种):出「设置主币种」引导卡,按钮跳设置页。
          - 否则:KPI 总览(8 项)+ 构成/走势双图并排 + 汇率脚注卡。多币种带 ≈ + 汇率脚注;
            单币种(rateDate 为空)不显 ≈ / 脚注 / 详情按钮(只有一种币种,无需明细)。
          分币种「每币种一张卡」整块已下线,统一并入本卡的折算口径。 */}
      {converted === null ? null : converted.needsBase ? (
        <Card size="small" className="mb-4">
          <div className="flex flex-col items-start gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0 space-y-1">
              <p className="text-sm font-medium">{t('accounts.needBaseCurrency.title')}</p>
              <p className="text-xs text-muted-foreground">
                {t('accounts.needBaseCurrency.desc')}
              </p>
            </div>
            <Button
              size="small"
              className="shrink-0"
              onClick={() =>
                navigate(routePath({ kind: 'app', ledgerId: '', section: 'settings-profile' }))
              }
            >
              {t('accounts.needBaseCurrency.action')}
            </Button>
          </div>
        </Card>
      ) : (
        <div className="mb-4 space-y-4">
          {/* KPI 总览(方案 A:4 列 × 2 行,资产 4 项 + 收支 4 项)。
              资产 4 项走 converted 折算口径(缺失汇率币种已剔除),收支 4 项走
              analytics summary;这里绝不另起汇率/聚合逻辑。 */}
          <AssetKpiRow
            netWorth={converted.netWorth}
            assetTotal={converted.assetTotal}
            liabilityTotal={converted.liabilityTotal}
            accountCount={rows.length}
            currencyCount={new Set(rows.map((r) => (r.currency || 'CNY').toUpperCase())).size}
            hiddenCount={rows.filter((r) => r.hidden).length}
            monthIncome={monthSummary?.income_total ?? 0}
            monthExpense={monthSummary?.expense_total ?? 0}
            yearIncome={yearSummary?.income_total ?? 0}
            yearExpense={yearSummary?.expense_total ?? 0}
            base={converted.base}
            approx={Boolean(converted.rateDate)}
          />

          {/* 双图并排:资产构成 + 净资产趋势(去掉「构成/走势」tab,两者同屏)。
              构成复用 converted 折算口径(mergedGroups 已折到主币种),多币种 approx=true;
              走势用自带 Card 的 full 版(内部净资产/总资产/总负债三条线切换)。 */}
          <div className="grid gap-4 lg:grid-cols-[5fr_6fr]">
            <AssetsCompositionMini
              groups={converted.mergedGroups}
              currency={converted.base}
              showCurrency
              approx={Boolean(converted.rateDate)}
            />
            <NetWorthTrend data={netWorthHistory} />
          </div>

          {/* 脚注 + 详情:仅多币种折算态出现(单币种 rateDate 为空,
              既无汇率脚注也无分币种明细可看)。 */}
          {converted.rateDate ? (
            <Card size="small">
              <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-0.5">
                  <span className="text-[11px] text-muted-foreground">
                    {t('accounts.converted.footnote', { date: converted.rateDate })}
                  </span>
                  {converted.missing.length > 0 ? (
                    <span className="text-[11px] text-amber-600 dark:text-amber-500">
                      {t('accounts.converted.missing', {
                        currencies: converted.missing.join(', '),
                      })}
                    </span>
                  ) : null}
                </div>
                <Button size="small" onClick={() => setDetailOpen(true)}>
                  {t('accounts.converted.detail')}
                </Button>
              </div>
            </Card>
          ) : null}
        </div>
      )}
      <AccountsPanel
        form={form}
        rows={rows}
        canManage
        hideCurrencyCards
        onFormChange={setForm}
        onSave={onSave}
        onReset={() => setForm(accountDefaults())}
        onEdit={(row) => {
          setForm({
            editingId: row.id,
            editingOwnerUserId: row.created_by_user_id || '',
            name: row.name,
            account_type: row.account_type || '',
            currency: row.currency || '',
            initial_balance: String(row.initial_balance ?? 0),
            note: row.note ?? '',
            credit_limit: row.credit_limit !== null && row.credit_limit !== undefined
              ? String(row.credit_limit)
              : '',
            billing_day: row.billing_day !== null && row.billing_day !== undefined
              ? String(row.billing_day)
              : '',
            payment_due_day: row.payment_due_day !== null && row.payment_due_day !== undefined
              ? String(row.payment_due_day)
              : '',
            bank_name: row.bank_name ?? '',
            card_last_four: row.card_last_four ?? '',
            hidden: row.hidden ?? false,
          })
        }}
        onRestore={(row) => void onRestore(row)}
        onAdjustBalance={handleAdjustBalance}
        adjustBalanceDisabled={!activeLedgerWritable}
        onClickAccount={(row) =>
          dispatchOpenDetailAccount(row as WorkspaceAccount, { defaultScope: 'all' })
        }
        onDelete={(row) => {
          // 严格策略:有关联交易直接拒绝,不弹"是否强制删除"。先要求用户在
          // 详情页/交易页把这些交易改/删/迁走,账户回到 0 笔再来删。比 mobile
          // 现在的"warn + allow orphan"更严格 —— 避免误删导致一堆 ungrouped
          // 交易污染 ledger。
          const ws = rows.find((r) => r.id === row.id) || (row as WorkspaceAccount)
          if ((ws.tx_count ?? 0) > 0) {
            toast.error(
              t('accounts.delete.blockedByTransactions', {
                name: ws.name,
                count: ws.tx_count ?? 0,
              }),
              t('notice.error'),
            )
            return
          }
          setPendingDelete(ws)
        }}
        renderList={(args) => <AccountsTable {...args} />}
      />
      {/* AccountDetailDialog 已迁到 GlobalEntityDialogs */}
      {/* 删除确认 — 有 tx 时显示 warning 文案 + count(对齐 mobile);无 tx
          就普通确认。dialog confirm 后调 deleteAccount,server 端会 silent
          orphan 关联交易(snapshot_mutator.delete_account 已实现 strip
          accountName)—— 跟 mobile 同款语义。 */}
      <ConfirmDialog
        open={pendingDelete !== null}
        onCancel={() => {
          if (!deleting) setPendingDelete(null)
        }}
        onConfirm={() => void onConfirmDelete()}
        loading={deleting}
        title={t('dialog.confirm')}
        description={t('accounts.delete.confirmMessage', { name: pendingDelete?.name || '' })}
        confirmText={t('common.delete')}
        confirmVariant="destructive"
      />
      {/* 分币种明细 dialog —— 折算汇总卡(多币种态)的「详情」入口,复用
          CurrencyAssetCard 按网格逐币种渲染(含缺失汇率币种,原样不折算)。
          needsBase / 单币种态不会打开此 dialog。 */}
      <Drawer
        open={detailOpen}
        onClose={() => setDetailOpen(false)}
        title={t('accounts.converted.detailTitle')}
        width={896}
        footer={null}
        styles={{ body: { overflowY: 'auto' } }}
      >
          {converted && !converted.needsBase ? (
            <div className="grid gap-3 sm:grid-cols-2">
              {converted.buckets.map((entry) => (
                <CurrencyAssetCard key={entry.currency} entry={entry} />
              ))}
            </div>
          ) : null}
      </Drawer>
    </>
  )
}
