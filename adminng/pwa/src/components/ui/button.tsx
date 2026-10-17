import type { ButtonHTMLAttributes } from 'react'
import { cn } from '../../lib/utils'

export type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'default' | 'outline'
  size?: 'default' | 'sm'
}

/**
 * Minimal shadcn/ui-style button (Phase 0). Kept dependency-free on purpose:
 * the full component set arrives with the real screens in Phase 3.
 */
export function Button({
  className,
  variant = 'default',
  size = 'default',
  type = 'button',
  ...props
}: ButtonProps) {
  return (
    <button
      type={type}
      className={cn(
        'inline-flex items-center justify-center rounded-md font-medium transition-colors',
        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500',
        'disabled:pointer-events-none disabled:opacity-50',
        variant === 'default'
          ? 'bg-blue-600 text-white hover:bg-blue-500'
          : 'border border-slate-700 text-slate-200 hover:bg-slate-800',
        // Touch first: 44px targets below lg (technical-draft §6.1), compact
        // when the pointer is a mouse.
        size === 'default' ? 'h-11 px-4 text-sm lg:h-10' : 'h-8 px-3 text-xs',
        className,
      )}
      {...props}
    />
  )
}
