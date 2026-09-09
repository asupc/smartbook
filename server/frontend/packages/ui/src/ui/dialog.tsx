import * as React from 'react'
import * as DialogPrimitive from '@radix-ui/react-dialog'
import { forwardRef, type ComponentPropsWithoutRef, type ElementRef } from 'react'
import { X } from 'lucide-react'

import { cn } from '../lib/cn'

const Dialog = DialogPrimitive.Root

const DialogTrigger = DialogPrimitive.Trigger

const DialogPortal = DialogPrimitive.Portal

const DialogClose = DialogPrimitive.Close

const DialogOverlay = forwardRef<
  ElementRef<typeof DialogPrimitive.Overlay>,
  ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Overlay
    ref={ref}
    className={cn(
      'fixed inset-0 z-50 bg-black/50 backdrop-blur-[1px]',
      'data-[state=open]:animate-fade-in data-[state=closed]:animate-fade-out',
      className
    )}
    {...props}
  />
))
DialogOverlay.displayName = DialogPrimitive.Overlay.displayName

/**
 * 右侧抽屉形态的 Dialog 内容区(2026-09 交互统一:内容/表单弹窗改右侧抽屉)。
 *
 * - 全高贴右,默认宽 440px;需要更宽时传 `w-[640px]` 之类的宽度类覆盖。
 * - 基类用 flex-col,消费者可让中间内容区 flex-1 overflow-y-auto 自行滚动,
 *   header / footer 钉在顶/底(参考 TransactionsPanel 的编辑抽屉)。
 * - 开/关动画在 apps/web tailwind.config.ts 注册(drawer-in/out)。
 * - variant="centered":确认框等轻量交互保留传统居中小弹窗(淡入淡出),
 *   不做抽屉 —— 参考 ConfirmDialog。
 */
const DialogContent = forwardRef<
  ElementRef<typeof DialogPrimitive.Content>,
  ComponentPropsWithoutRef<typeof DialogPrimitive.Content> & {
    showCloseButton?: boolean
    variant?: 'drawer' | 'centered'
  }
>(({ className, children, showCloseButton = true, variant = 'drawer', ...props }, ref) => {
  const shapeClassName =
    variant === 'centered'
      ? cn(
          'fixed left-1/2 top-1/2 z-50 grid w-[92vw] max-w-lg -translate-x-1/2 -translate-y-1/2 gap-4 rounded-xl border border-border bg-card p-6 text-card-foreground shadow-soft',
          'data-[state=open]:animate-fade-in data-[state=closed]:animate-fade-out'
        )
      : cn(
          'fixed inset-y-0 right-0 z-50 flex h-dvh w-[440px] max-w-[92vw] flex-col gap-4 overflow-y-auto rounded-l-2xl border-l border-border bg-card p-6 text-card-foreground shadow-soft',
          'data-[state=open]:animate-drawer-in data-[state=closed]:animate-drawer-out'
        )
  return (
    <DialogPortal>
      <DialogOverlay />
      <DialogPrimitive.Content
        ref={ref}
        className={cn(shapeClassName, className)}
        {...props}
      >
        {children}
        {showCloseButton ? (
          <DialogPrimitive.Close className="absolute right-4 top-4 rounded-sm opacity-70 transition-opacity hover:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring">
            <X className="h-4 w-4" />
            <span className="sr-only">Close</span>
          </DialogPrimitive.Close>
        ) : null}
      </DialogPrimitive.Content>
    </DialogPortal>
  )
})
DialogContent.displayName = DialogPrimitive.Content.displayName

function DialogHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('flex flex-col space-y-1.5 text-left', className)} {...props} />
}

function DialogFooter({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('flex items-center justify-end gap-2', className)} {...props} />
}

const DialogTitle = forwardRef<
  ElementRef<typeof DialogPrimitive.Title>,
  ComponentPropsWithoutRef<typeof DialogPrimitive.Title>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Title
    ref={ref}
    className={cn('text-base font-semibold', className)}
    {...props}
  />
))
DialogTitle.displayName = DialogPrimitive.Title.displayName

const DialogDescription = forwardRef<
  ElementRef<typeof DialogPrimitive.Description>,
  ComponentPropsWithoutRef<typeof DialogPrimitive.Description>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Description
    ref={ref}
    className={cn('text-sm text-muted-foreground', className)}
    {...props}
  />
))
DialogDescription.displayName = DialogPrimitive.Description.displayName

export {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogOverlay,
  DialogPortal,
  DialogTitle,
  DialogTrigger
}
