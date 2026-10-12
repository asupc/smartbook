import { Component, type ErrorInfo, type ReactNode } from 'react'

import { Button } from 'antd'

import { useT } from '@smartbook/ui'

/**
 * 顶层渲染兜底 —— 之前全仓没有 ErrorBoundary,任何 render 期异常
 * (如路由解析、脏数据格式化)都会让 React 整棵树 unmount → 纯白屏,
 * 用户只能手动改地址栏救场。
 *
 * 现在改成:捕获 → 记日志 → 渲染可读错误卡片 + 「刷新」按钮(带
 * query 保留路径,刷新后若路径仍非法由 parseRoute 的兜底处理)。
 *
 * 类组件是 React 的硬约束(getDerivedStateFromError / componentDidCatch
 * 只能在 class 上用),这里没有 hooks 替代方案。
 */
type Props = {
  children: ReactNode
  /** 由外部注入的翻译函数(类组件不能用 hooks)。 */
  t: (key: string) => string
}

type State = { error: Error | null }

export class AppErrorBoundaryInner extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    // 保留原始堆栈,方便贴到 issue / docker logs。
    // eslint-disable-next-line no-console
    console.error('[AppErrorBoundary] render failed', error, info.componentStack)
  }

  render(): ReactNode {
    const { error } = this.state
    if (!error) return this.props.children
    return (
      <div className="flex min-h-screen items-center justify-center bg-background px-6">
        <div className="w-full max-w-md space-y-3 rounded-lg border border-border bg-card p-6 text-center shadow-sm">
          <div className="text-base font-medium text-foreground">{this.props.t('error.boundary.title')}</div>
          <p className="text-sm text-muted-foreground">{this.props.t('error.boundary.hint')}</p>
          <div className="flex justify-center pt-1">
            <Button onClick={() => window.location.reload()}>{this.props.t('common.refresh')}</Button>
          </div>
        </div>
      </div>
    )
  }
}

/**
 * 函数包装 —— 从 LocaleContext 取 `t` 再交给类组件,这样错误卡片
 * 跟随当前语言。
 */
export function AppErrorBoundary({ children }: { children: ReactNode }) {
  const t = useT()
  return (
    <AppErrorBoundaryInner t={(key: string) => t(key)}>
      {children}
    </AppErrorBoundaryInner>
  )
}
