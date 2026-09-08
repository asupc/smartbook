import { useCallback, useEffect, useMemo, useState } from 'react'
import { Check, Loader2, Pencil, RefreshCw, RotateCcw, X } from 'lucide-react'

import { Button, Card, Input } from 'antd'
import { useT, useToast } from '@smartbook/ui'
import {
  ApiError,
  deleteExchangeRateOverride,
  fetchExchangeRateOverrides,
  fetchExchangeRates,
  fetchWorkspaceAccounts,
  setExchangeRateOverride,
  type ExchangeRateOverride,
  type ExchangeRatesResponse,
} from '@smartbook/api-client'
import { effectiveRateToBase } from '@smartbook/web-features'

import { useAuth } from '../../context/AuthContext'
import { localizeError } from '../../i18n/errors'

/**
 * 设置 - 汇率管理小节(挂在主币种选择器同页下方)。
 *
 * - `profileMe.primary_currency` 为空 → 渲染空态提示,**不发任何请求**。
 * - 否则并行拉:base 汇率(/read/exchange-rates) + 手动 override + 账户币种去重。
 * - 每行(使用中币种 ∪ override 币种 − base):展示 `1 quote = rate base`,
 *   优先 manual override,否则代理自动值取倒数(见 effectiveRateToBase);两边
 *   都没有 → 标记「未获取」。可行内编辑改 override,或一键恢复自动。
 *
 * 折算口径只读展示,真正的资产折算卡在 AccountsPage;这里只管理"汇率值本身"。
 */
export function SettingsExchangeRatesSection() {
  const t = useT()
  const toast = useToast()
  const { token, profileMe } = useAuth()
  const base = profileMe?.primary_currency || ''

  const [auto, setAuto] = useState<ExchangeRatesResponse | null>(null)
  const [overrides, setOverrides] = useState<ExchangeRateOverride[]>([])
  const [accountCurrencies, setAccountCurrencies] = useState<string[]>([])
  const [loading, setLoading] = useState(false)
  const [refreshing, setRefreshing] = useState(false)

  // 行内编辑:正在编辑的 quote 币种 + 草稿值(1 quote = draft base)
  const [editingQuote, setEditingQuote] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [savingQuote, setSavingQuote] = useState<string | null>(null)

  const loadAll = useCallback(async () => {
    if (!base) return
    setLoading(true)
    try {
      const [rates, ovrs, accounts] = await Promise.all([
        fetchExchangeRates(token, base),
        fetchExchangeRateOverrides(token),
        fetchWorkspaceAccounts(token, { limit: 500 }),
      ])
      setAuto(rates)
      setOverrides(ovrs)
      const seen = new Set<string>()
      for (const a of accounts) {
        const cur = (a.currency || '').toUpperCase()
        if (cur) seen.add(cur)
      }
      setAccountCurrencies([...seen])
    } catch (err) {
      toast.error(localizeError(err, t), t('notice.error'))
    } finally {
      setLoading(false)
    }
  }, [base, token, toast, t])

  useEffect(() => {
    void loadAll()
    // base 变化(主币种切换)时整体重拉
  }, [loadAll])

  const reloadOverrides = useCallback(async () => {
    try {
      setOverrides(await fetchExchangeRateOverrides(token))
    } catch (err) {
      toast.error(localizeError(err, t), t('notice.error'))
    }
  }, [token, toast, t])

  const handleRefreshRates = async () => {
    if (!base || refreshing) return
    setRefreshing(true)
    try {
      setAuto(await fetchExchangeRates(token, base))
    } catch (err) {
      toast.error(localizeError(err, t), t('notice.error'))
    } finally {
      setRefreshing(false)
    }
  }

  // 行集合:使用中币种 ∪ override 币种,去掉 base 自身
  const quotes = useMemo(() => {
    const set = new Set<string>()
    for (const c of accountCurrencies) set.add(c)
    for (const o of overrides) {
      if (o.base_currency === base) set.add(o.quote_currency)
    }
    set.delete(base)
    return [...set].sort()
  }, [accountCurrencies, overrides, base])

  const startEdit = (quote: string) => {
    const eff = effectiveRateToBase(quote, base, auto, overrides)
    setDraft(eff ? String(eff.rate) : '')
    setEditingQuote(quote)
  }
  const cancelEdit = () => {
    setEditingQuote(null)
    setDraft('')
  }

  const submitEdit = async (quote: string) => {
    if (savingQuote) return
    const rate = Number(draft)
    if (!Number.isFinite(rate) || rate <= 0) {
      toast.error(t('accounts.error.balanceInvalid'), t('notice.error'))
      return
    }
    setSavingQuote(quote)
    try {
      await setExchangeRateOverride(token, {
        base_currency: base,
        quote_currency: quote,
        rate: String(rate),
      })
      await reloadOverrides()
      cancelEdit()
    } catch (err) {
      toast.error(localizeError(err, t), t('notice.error'))
    } finally {
      setSavingQuote(null)
    }
  }

  const resetToAuto = async (quote: string) => {
    if (savingQuote) return
    setSavingQuote(quote)
    try {
      await deleteExchangeRateOverride(token, base, quote)
      await reloadOverrides()
      if (editingQuote === quote) cancelEdit()
    } catch (err) {
      // 404 表示 override 本不存在(已删除或从未设置),视为成功:照常 reload。
      if (err instanceof ApiError && err.status === 404) {
        await reloadOverrides()
        if (editingQuote === quote) cancelEdit()
      } else {
        toast.error(localizeError(err, t), t('notice.error'))
      }
    } finally {
      setSavingQuote(null)
    }
  }

  return (
    <Card
      className="border-border/70 shadow-sm"
      size="small"
      title={
        <div className="flex items-center gap-2 py-1">
          <span className="text-base font-semibold">{t('rates.title')}</span>
          {base ? (
            <span className="rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
              {base}
            </span>
          ) : null}
        </div>
      }
      extra={
        base ? (
          <Button
            size="small"
            icon={refreshing ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
            onClick={() => void handleRefreshRates()}
            disabled={refreshing || loading}
          >
            {t('rates.refresh')}
          </Button>
        ) : null
      }
      styles={{ body: { padding: '16px 20px 20px' } }}
    >
      <div className="space-y-4">
        {!base ? (
          <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/70 bg-muted/10 px-4 py-8 text-center">
            <p className="text-sm font-medium text-foreground">{t('rates.emptyHint')}</p>
            <p className="mt-1 text-xs text-muted-foreground">{t('settings.primaryCurrency.hint')}</p>
          </div>
        ) : loading ? (
          <div className="flex items-center justify-center py-10 text-muted-foreground">
            <Loader2 className="h-5 w-5 animate-spin text-primary" />
            <span className="ml-2 text-xs">{t('common.loading')}</span>
          </div>
        ) : quotes.length === 0 ? (
          <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/70 bg-muted/10 px-4 py-8 text-center">
            <p className="text-sm text-muted-foreground">{t('rates.emptyHint')}</p>
          </div>
        ) : (
          <div className="grid gap-2.5 sm:grid-cols-2">
            {quotes.map((quote) => {
              const eff = effectiveRateToBase(quote, base, auto, overrides)
              const isEditing = editingQuote === quote
              const isSaving = savingQuote === quote
              const currencyLabel = t(`currency.${quote}`)

              return (
                <div
                  key={quote}
                  className="group relative flex flex-col justify-between rounded-xl border border-border/60 bg-card p-3.5 shadow-xs transition hover:border-primary/40 hover:shadow-sm"
                >
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <span className="flex h-7 items-center justify-center rounded-md bg-muted px-2 font-mono text-xs font-bold text-foreground">
                        {quote}
                      </span>
                      {currencyLabel && !currencyLabel.startsWith('currency.') ? (
                        <span className="text-xs text-muted-foreground">
                          {currencyLabel}
                        </span>
                      ) : null}
                    </div>

                    <div className="flex items-center gap-1.5">
                      {eff?.source === 'manual' ? (
                        <span className="rounded-full bg-primary/12 px-2 py-0.5 text-[10px] font-medium text-primary">
                          {t('rates.sourceManual')}
                        </span>
                      ) : eff?.source === 'auto' ? (
                        <span className="rounded-full bg-muted/80 px-2 py-0.5 text-[10px] text-muted-foreground" title={eff.date ? t('rates.updatedAt', { date: eff.date }) : undefined}>
                          {t('rates.sourceAuto')}
                          {eff.date ? ` · ${eff.date}` : ''}
                        </span>
                      ) : null}

                      {!isEditing ? (
                        <div className="flex items-center gap-1">
                          <Button
                            size="small"
                            type="text"
                            icon={<Pencil className="h-3.5 w-3.5" />}
                            aria-label={t('rates.edit') as string}
                            onClick={() => startEdit(quote)}
                            disabled={isSaving}
                            className="text-muted-foreground hover:text-foreground"
                          />
                          {eff?.source === 'manual' ? (
                            <Button
                              size="small"
                              type="text"
                              icon={isSaving ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RotateCcw className="h-3.5 w-3.5" />}
                              aria-label={t('rates.resetToAuto') as string}
                              onClick={() => void resetToAuto(quote)}
                              disabled={isSaving}
                              className="text-muted-foreground hover:text-primary"
                              title={t('rates.resetToAuto') as string}
                            />
                          ) : null}
                        </div>
                      ) : null}
                    </div>
                  </div>

                  {!isEditing ? (
                    <div className="mt-3 flex items-baseline justify-between pt-1">
                      <div className="flex items-baseline gap-1.5">
                        <span className="font-mono text-xs text-muted-foreground">1 {quote} =</span>
                        <span className="font-mono text-base font-semibold text-foreground">
                          {eff ? eff.rate.toPrecision(6) : '-'}
                        </span>
                        <span className="text-xs font-medium text-muted-foreground">{base}</span>
                      </div>
                      {!eff ? (
                        <span className="text-[11px] text-destructive">
                          {t('rates.notFetched')}
                        </span>
                      ) : null}
                    </div>
                  ) : (
                    <div className="mt-3 space-y-2 pt-1 border-t border-border/40">
                      <div className="flex items-center gap-2">
                        <span className="shrink-0 font-mono text-xs text-muted-foreground">
                          1 {quote} =
                        </span>
                        <Input
                          autoFocus
                          type="number"
                          value={draft}
                          onChange={(e) => setDraft(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') {
                              e.preventDefault()
                              void submitEdit(quote)
                            } else if (e.key === 'Escape') {
                              e.preventDefault()
                              cancelEdit()
                            }
                          }}
                          size="small"
                          suffix={<span className="text-xs text-muted-foreground">{base}</span>}
                          style={{ maxWidth: 160 }}
                          disabled={isSaving}
                        />
                        <Button
                          size="small"
                          type="primary"
                          icon={isSaving ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Check className="h-3.5 w-3.5" />}
                          aria-label={t('common.save') as string}
                          onClick={() => void submitEdit(quote)}
                          disabled={isSaving}
                        />
                        <Button
                          size="small"
                          icon={<X className="h-3.5 w-3.5" />}
                          aria-label={t('common.cancel') as string}
                          onClick={cancelEdit}
                          disabled={isSaving}
                        />
                      </div>
                      {(() => {
                        const r = Number(draft)
                        if (!Number.isFinite(r) || r <= 0) return null
                        return (
                          <p className="font-mono text-[11px] text-muted-foreground">
                            {t('rates.inverseHint', {
                              base,
                              rate: (1 / r).toPrecision(6),
                              quote,
                            })}
                          </p>
                        )
                      })()}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}

        {base ? (
          <div className="flex items-start gap-1.5 rounded-lg bg-muted/30 p-2.5 text-[11px] leading-relaxed text-muted-foreground">
            <span className="font-medium text-foreground">说明:</span>
            <span>{t('rates.disclaimer')}</span>
          </div>
        ) : null}
      </div>
    </Card>
  )
}
