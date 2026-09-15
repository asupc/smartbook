import type { LocaleMessages } from '@smartbook/ui'

/**
 * W1(P2 批次):开发期缺 key console.warn。
 *
 * t() 的实现(LocaleProvider,packages/ui)是 `active[key] || fallback[key] || key`
 * —— 缺 key 时返回 key 本身(非空),UI 上露出一串 raw key(如 GlobalEditDialogs
 * 成功 toast 显示 `notice.transactionUpdated` 的根因)。这里在 DEV 下把字典包成
 * Proxy:任何「读不到」的 key 访问都打 console.warn,让开发者在控制台第一眼
 * 看到缺 key,而不是等用户截图反馈。
 *
 * 为什么不直接改 LocaleProvider:它在 packages/ui(共享包),apps/web 侧用
 * Proxy 包装传入的字典即可达到同样效果,t() 行为零变化。
 *
 * 静态全量校验(三语 key diff + 代码中 t('...') 字面量引用扫描)走
 * `pnpm check:i18n`(scripts/check-i18n.mjs),可接 CI。
 */
const isDev = Boolean(import.meta.env?.DEV)

/** 常见的运行时探针属性(React/工具库会摸 __esModule、then 等),不算缺 key。 */
function isProbeProp(prop: string): boolean {
  return prop.startsWith('__') || prop.startsWith('$') || prop === 'then' || prop === 'catch'
}

export function withMissingKeyWarnings(name: string, dict: LocaleMessages): LocaleMessages {
  if (!isDev) return dict
  return new Proxy(dict, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, receiver)
      if (
        value === undefined &&
        typeof prop === 'string' &&
        prop.length > 0 &&
        !isProbeProp(prop)
      ) {
        // eslint-disable-next-line no-console
        console.warn(`[i18n] missing key "${prop}" in "${name}" — t() will fall back`)
      }
      return value
    },
  })
}
