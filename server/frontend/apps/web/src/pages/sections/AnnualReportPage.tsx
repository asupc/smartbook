import { useCallback, useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Alert, Button, Card, Result, Spin, Tag, theme } from 'antd'
import {
  ArrowLeft,
  ArrowRight,
  BookOpen,
  Calendar,
  Flame,
  History,
  RotateCcw,
  Sparkles,
} from 'lucide-react'

import { fetchWorkspaceLedgerCounts } from '@smartbook/api-client'
import {
  AnnualReportPage as CarouselAnnualReportPage,
  fetchAnnualReportData,
  type AnnualReportData,
  ANNUAL_REPORT_TKEY as TKEY,
} from '@smartbook/web-features'
import { useT } from '@smartbook/ui'

import { useAuth } from '../../context/AuthContext'
import { useLedgers } from '../../context/LedgersContext'

/**
 * 年度报告专属页面：
 * 1. 深度链接/参数直达：`/app/annual-report?year=2026` 自动拉取该年数据并拉起全屏沉浸故事。
 * 2. 历年大厅（默认态）：展示当前账本历年报告归档卡片、状态与快速启播入口。
 */
export function AnnualReportPage() {
  const t = useT()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const { token } = useAuth()
  const { activeLedgerId, currentLedger, currency } = useLedgers()
  const { token: antdToken } = theme.useToken()

  const currentYear = new Date().getFullYear()
  const yearParam = searchParams.get('year')
  const selectedYear = yearParam ? parseInt(yearParam, 10) : null

  const [loading, setLoading] = useState(false)
  const [reportData, setReportData] = useState<AnnualReportData | null>(null)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  const [yearOptions, setYearOptions] = useState<number[]>([currentYear])
  const [loadingYears, setLoadingYears] = useState(true)

  // 拉取可选年份范围（从账本最早一笔交易年份至今）
  useEffect(() => {
    if (!token || !activeLedgerId) {
      setLoadingYears(false)
      return
    }
    let cancelled = false
    setLoadingYears(true)
    fetchWorkspaceLedgerCounts(token, { ledgerId: activeLedgerId })
      .then((counts) => {
        if (cancelled) return
        const firstYear = counts.first_tx_at
          ? new Date(counts.first_tx_at).getFullYear()
          : currentYear
        const years: number[] = []
        for (let y = currentYear; y >= firstYear; y--) {
          years.push(y)
        }
        setYearOptions(years.length > 0 ? years : [currentYear])
      })
      .catch(() => {
        if (cancelled) return
        setYearOptions([currentYear])
      })
      .finally(() => {
        if (!cancelled) setLoadingYears(false)
      })
    return () => {
      cancelled = true
    }
  }, [token, activeLedgerId, currentYear])

  // 当 URL 中带有 year 参数时，自动拉取对应年度报告数据
  const loadYearReport = useCallback(
    async (year: number) => {
      if (!token || !activeLedgerId) return
      setLoading(true)
      setErrorMsg(null)
      try {
        const ledger = {
          id: activeLedgerId,
          name: currentLedger?.ledger_name || '',
          currency: currency || 'CNY',
        }
        const data = await fetchAnnualReportData(token, ledger, year)
        if (!data.hasSufficientData) {
          setErrorMsg(`${t(TKEY.insufficientDataTitle)} — ${t(TKEY.insufficientDataBody)}`)
          setReportData(null)
        } else {
          setReportData(data)
        }
      } catch (err) {
        console.error('[AnnualReport] Failed to fetch annual report data', err)
        setErrorMsg(t(TKEY.entryBannerError))
        setReportData(null)
      } finally {
        setLoading(false)
      }
    },
    [token, activeLedgerId, currentLedger?.ledger_name, currency, t],
  )

  useEffect(() => {
    if (selectedYear && !isNaN(selectedYear)) {
      loadYearReport(selectedYear)
    } else {
      setReportData(null)
      setErrorMsg(null)
      setLoading(false)
    }
  }, [selectedYear, loadYearReport])

  const handleSelectYear = (year: number) => {
    setSearchParams({ year: String(year) })
  }

  const handleCloseReport = () => {
    // 关闭全屏报告：移除 year 参数回到历年大厅
    setSearchParams({})
  }

  // 1. 全屏沉浸式 12 屏展示态
  if (reportData && !loading) {
    return <CarouselAnnualReportPage data={reportData} onClose={handleCloseReport} />
  }

  // 2. 加载中全屏态
  if (loading) {
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 py-16 text-center">
        <Spin size="large" />
        <div className="space-y-1">
          <p className="text-base font-semibold text-foreground">
            {t(TKEY.entryBannerLoading)}
          </p>
          <p className="text-xs text-muted-foreground">
            正在聚合 {selectedYear} 年全量账单与习惯画像...
          </p>
        </div>
      </div>
    )
  }

  // 3. 数据不足或加载失败提示
  if (errorMsg && selectedYear) {
    return (
      <div className="mx-auto max-w-2xl py-12">
        <Card className="border border-border/70 shadow-sm">
          <Result
            status="warning"
            title={`${selectedYear} 年度报告暂时无法生成`}
            subTitle={errorMsg}
            extra={[
              <Button
                key="back"
                type="primary"
                icon={<ArrowLeft size={14} />}
                onClick={() => setSearchParams({})}
              >
                返回历年报告列表
              </Button>,
              <Button
                key="retry"
                icon={<RotateCcw size={14} />}
                onClick={() => loadYearReport(selectedYear)}
              >
                重试
              </Button>,
            ]}
          />
        </Card>
      </div>
    )
  }

  // 4. 历年报告大厅（Gallery 视图）
  return (
    <div className="space-y-6">
      {/* 顶部 Hero Banner */}
      <div
        className="relative overflow-hidden rounded-2xl border border-primary/20 p-6 sm:p-8 shadow-xs"
        style={{
          background:
            'linear-gradient(135deg, hsl(var(--primary)/0.12) 0%, hsl(var(--primary)/0.03) 60%, transparent 100%)',
        }}
      >
        <div className="relative z-10 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <span className="inline-flex h-8 w-8 items-center justify-center rounded-lg bg-primary/15 text-primary">
                <Sparkles size={18} />
              </span>
              <h2 className="text-xl font-bold tracking-tight text-foreground sm:text-2xl">
                {t('nav.annualReport')}
              </h2>
              <Tag color="gold" className="font-semibold">
                Story Recap
              </Tag>
            </div>
            <p className="text-sm text-muted-foreground">
              重温你在【{currentLedger?.ledger_name || '当前账本'}】的记账故事，探索消费足迹与生活画像。
            </p>
          </div>

          <div className="flex items-center gap-2">
            <Button
              type="default"
              icon={<ArrowLeft size={14} />}
              onClick={() => navigate('/app/overview')}
            >
              返回概览
            </Button>
          </div>
        </div>
      </div>

      {/* 历年归档卡片列表 */}
      <div>
        <div className="mb-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Calendar size={16} className="text-primary" />
            <h3 className="text-base font-semibold text-foreground">历年报告归档</h3>
          </div>
          <span className="text-xs text-muted-foreground">
            {yearOptions.length} 个年度账本记录
          </span>
        </div>

        {loadingYears ? (
          <div className="flex h-40 items-center justify-center">
            <Spin />
          </div>
        ) : (
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {yearOptions.map((year) => {
              const isCurrent = year === currentYear
              return (
                <Card
                  key={year}
                  hoverable
                  className={`group relative overflow-hidden border transition-all duration-200 ${
                    isCurrent
                      ? 'border-primary/40 shadow-sm ring-1 ring-primary/20'
                      : 'border-border/60 hover:border-primary/30 hover:shadow-md'
                  }`}
                  styles={{
                    body: {
                      padding: '24px',
                      display: 'flex',
                      flexDirection: 'column',
                      justifyContent: 'space-between',
                      height: '100%',
                      minHeight: '190px',
                    },
                  }}
                >
                  <div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-baseline gap-2">
                        <span className="font-mono text-3xl font-extrabold tracking-tight text-foreground">
                          {year}
                        </span>
                        <span className="text-xs font-medium text-muted-foreground">
                          年度总结
                        </span>
                      </div>
                      {isCurrent ? (
                        <Tag color="processing" icon={<Flame size={12} className="inline mr-1 text-amber-500" />}>
                          当年 · 进行中
                        </Tag>
                      ) : (
                        <Tag icon={<History size={12} className="inline mr-1" />}>
                          已归档
                        </Tag>
                      )}
                    </div>

                    <p className="mt-3 text-xs leading-relaxed text-muted-foreground">
                      {isCurrent
                        ? '查看截至当前的月度收支走势、消费高频时段与阶段性生活画像。'
                        : '完整的全年度记账盘点、分类排行、极值洞察与年度成就勋章。'}
                    </p>
                  </div>

                  <div className="mt-5 flex items-center justify-between pt-3 border-t border-border/40">
                    <span className="text-[11px] text-muted-foreground font-mono">
                      12 屏全景故事
                    </span>
                    <Button
                      type={isCurrent ? 'primary' : 'default'}
                      size="small"
                      icon={<ArrowRight size={13} />}
                      onClick={() => handleSelectYear(year)}
                      className="group-hover:translate-x-0.5 transition-transform"
                    >
                      开启回顾
                    </Button>
                  </div>
                </Card>
              )
            })}
          </div>
        )}
      </div>

      {/* 底部使用提示与说明 */}
      <Alert
        type="info"
        showIcon
        icon={<BookOpen size={16} />}
        message="关于智记年度报告"
        description="年度报告依托离线聚合算法，结合你的收支交易自动生成 12 屏沉浸式动画回顾。全屏浏览支持键盘 ← → 方向键翻页，末页可一键导出专属年度海报与朋友分享。"
        className="rounded-xl border border-primary/20 bg-primary/5"
      />
    </div>
  )
}
