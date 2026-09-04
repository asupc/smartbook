import type { PropsWithChildren } from 'react'
import { App as AntdApp, ConfigProvider, theme } from 'antd'
import enUS from 'antd/locale/en_US'
import zhCN from 'antd/locale/zh_CN'
import zhTW from 'antd/locale/zh_TW'

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

  return (
    <ConfigProvider
      locale={LOCALE_ANTD[locale]}
      theme={{
        algorithm: resolved === 'dark' ? theme.darkAlgorithm : theme.defaultAlgorithm,
        token: { colorPrimary: color },
      }}
    >
      <AntdApp>{children}</AntdApp>
    </ConfigProvider>
  )
}
