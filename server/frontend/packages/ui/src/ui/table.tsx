import type { HTMLAttributes, TableHTMLAttributes, TdHTMLAttributes, ThHTMLAttributes } from 'react'

import { cn } from '../lib/cn'

export function Table({ className, ...props }: TableHTMLAttributes<HTMLTableElement>) {
  return <table className={cn('w-full caption-bottom text-sm border-collapse text-left', className)} {...props} />
}

export function TableHeader({ className, ...props }: HTMLAttributes<HTMLTableSectionElement>) {
  return (
    <thead
      className={cn(
        'bg-muted/40 text-xs text-muted-foreground border-b border-border/80 sticky top-0 z-10 backdrop-blur-xs',
        className
      )}
      {...props}
    />
  )
}

export function TableBody({ className, ...props }: HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody className={cn('divide-y divide-border/40 [&_tr:last-child]:border-0', className)} {...props} />
}

export function TableRow({ className, ...props }: HTMLAttributes<HTMLTableRowElement>) {
  return (
    <tr
      className={cn(
        'border-b border-border/50 transition-colors duration-150 hover:bg-primary/[0.03] dark:hover:bg-primary/[0.06] data-[state=selected]:bg-primary/[0.08]',
        className
      )}
      {...props}
    />
  )
}

export function TableHead({ className, ...props }: ThHTMLAttributes<HTMLTableCellElement>) {
  return (
    <th
      className={cn(
        'h-11 px-3.5 py-3 text-left align-middle font-semibold text-xs tracking-wider text-muted-foreground select-none whitespace-nowrap',
        className
      )}
      {...props}
    />
  )
}

export function TableCell({ className, ...props }: TdHTMLAttributes<HTMLTableCellElement>) {
  return <td className={cn('px-3.5 py-3 align-middle text-sm', className)} {...props} />
}

