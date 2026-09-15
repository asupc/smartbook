import type { LocaleDictionaries } from '@smartbook/ui'

import en from './en'
import zhCN from './zh-CN'
import zhTW from './zh-TW'
import { withMissingKeyWarnings } from './warnMissingKeys'

export const dictionaries: LocaleDictionaries = {
  en: withMissingKeyWarnings('en', en),
  'zh-CN': withMissingKeyWarnings('zh-CN', zhCN),
  'zh-TW': withMissingKeyWarnings('zh-TW', zhTW)
}

export type TranslationKey = keyof typeof en
