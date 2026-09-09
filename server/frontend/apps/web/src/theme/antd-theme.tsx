import { useEffect, type PropsWithChildren } from 'react'
import { App as AntdApp, ConfigProvider, theme } from 'antd'
import enUS from 'antd/locale/en_US'
import zhCN from 'antd/locale/zh_CN'
import zhTW from 'antd/locale/zh_TW'
import dayjs from 'dayjs'
// antd v5 DatePicker 的月份/星期面板文字通过 locale.lang.locale(如 'zh-cn')
// 向 dayjs 取数据,dayjs 没注册对应 locale 时会静默回退英文(表现为
// RangePicker 月份显示 Jan/Feb…)。这里必须显式注册。
import 'dayjs/locale/zh-cn'
import 'dayjs/locale/zh-tw'

import { useLocale, usePrimaryColor, useTheme, type Locale } from '@smartbook/ui'

const LOCALE_ANTD: Record<Locale, typeof zhCN> = {
  'zh-CN': zhCN,
  'zh-TW': zhTW,
  en: enUS,
}

/**
 * antd 适配层 —— 挂在 ThemeProvider / PrimaryColorProvider / LocaleProvider
 * 之下,把现有主题体系同步给 antd:
 *   - algorithm:light/dark 跟随 useTheme().resolved,而不是再看一份
 *     localStorage(避免两套状态打架)
 *   - colorPrimary:取 PrimaryColorProvider 的 JS context 值 —— 主色由
 *     服务端下发(applyServerColor),不能从 --primary CSS 变量反解析
 *   - locale:与 LocaleProvider 同步,否则分页/Modal 确定取消/表格空数据
 *     等 antd 内置文案会混英文
 *
 * 同时包一层 antd <App>,让 App.useApp().message / modal.confirm 能吃到
 * ConfigProvider 主题(静态 API 不吃 token)。
 */
export function AntdProvider({ children }: PropsWithChildren) {
  const { resolved } = useTheme()
  const { color } = usePrimaryColor()
  const { locale } = useLocale()

  const isDark = resolved === 'dark'
  const antdLocale = LOCALE_ANTD[locale]

  // dayjs 全局 locale 跟 antd 同步 —— antd ConfigProvider 只管自己的组件,
  // 业务代码里直接 new dayjs() / dayjs().format('MMM') 的场景吃这个兜底。
  useEffect(() => {
    dayjs.locale(antdLocale.locale || 'en')
  }, [antdLocale])

  return (
    <ConfigProvider
      locale={antdLocale}
      theme={{
        algorithm: isDark ? theme.darkAlgorithm : theme.defaultAlgorithm,
        token: {
          colorPrimary: color || '#2563EB',
          borderRadius: 10,
          fontFamily:
            '"Plus Jakarta Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif',
          colorBgContainer: isDark ? '#111726' : '#ffffff',
          colorBgElevated: isDark ? '#1a2234' : '#ffffff',
          colorBgLayout: isDark ? '#090d16' : '#f8fafc',
          colorBorderSecondary: isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(15, 23, 42, 0.08)',
        },
        components: {
          Card: {
            borderRadiusLG: 16,
            headerHeight: 48,
          },
          Button: {
            borderRadius: 8,
          },
          Table: {
            borderRadius: 12,
            headerBg: isDark ? '#141c2e' : '#f8fafc',
            headerColor: isDark ? '#94a3b8' : '#475569',
            headerSplitColor: 'transparent',
            headerBorderRadius: 10,
            rowHoverBg: isDark ? 'rgba(37, 99, 235, 0.08)' : 'rgba(37, 99, 235, 0.04)',
            borderColor: isDark ? 'rgba(255, 255, 255, 0.06)' : 'rgba(15, 23, 42, 0.06)',
            cellPaddingBlock: 12,
            cellPaddingInline: 16,
            footerBg: isDark ? '#111726' : '#ffffff',
          },
          Modal: {
            borderRadiusLG: 16,
          },
          Menu: {
            itemBorderRadius: 8,
            itemMarginInline: 8,
          },
        },
      }}
    >
      <AntdApp>{children}</AntdApp>
    </ConfigProvider>
  )
}
