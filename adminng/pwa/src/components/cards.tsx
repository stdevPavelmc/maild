/**
 * Card primitives for the catalogue screens (domains, accounts, aliases,
 * administrators, devices). Replaces the table listings: one card per entity,
 * responsive columns, an identity block, stat chips and 44px touch-safe action
 * buttons (technical-draft §6.1; the compact size only applies from `lg:` up,
 * where a mouse — not a thumb — is the pointer).
 */

import { type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { cn } from '../lib/utils'

/** The responsive card list: 1 column on phones, 2/3/4 on wider screens. */
export function CardGrid({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <ul
      role="list"
      className={cn(
        'grid grid-cols-1 gap-3',
        'sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4',
        className,
      )}
    >
      {children}
    </ul>
  )
}

const ACCENTS = {
  active: 'bg-emerald-500',
  inactive: 'bg-red-500',
  pending: 'bg-amber-500',
  neutral: 'bg-slate-600',
} as const

/**
 * One entity card: the 3px status accent bar (emerald active / red suspended /
 * amber pending), a hover lift and a tinted shadow. `<li>` inside `CardGrid`'s
 * `role="list"`, so cards are list items for assistive tech and the test suite.
 */
export function EntityCard({
  children,
  status = 'active',
  className,
}: {
  children: ReactNode
  status?: keyof typeof ACCENTS
  className?: string
}) {
  return (
    <li
      className={cn(
        'relative min-w-0 rounded-xl border border-slate-800 bg-slate-900/60 p-3.5',
        'transition-colors hover:border-slate-600 hover:bg-slate-900/80',
        status === 'inactive' && 'opacity-60 hover:opacity-100',
        className,
      )}
    >
      <span
        aria-hidden="true"
        className={cn('absolute bottom-3 left-0 top-3 w-[3px] rounded-full', ACCENTS[status])}
      />
      {children}
    </li>
  )
}

/** Identity block (left) vs actions (right) on the card's first line. */
export function CardHead({ children }: { children: ReactNode }) {
  return <div className="flex items-start justify-between gap-2">{children}</div>
}

/** Active/suspended mark: emoji glyph + the localized word for screen readers. */
export function StatusMark({ active }: { active: boolean }) {
  const { t } = useTranslation()
  const label = active ? t('common.active') : t('common.inactive')
  return (
    <span title={label} className="inline-flex shrink-0 items-center text-xl leading-none lg:text-base">
      <span aria-hidden="true">{active ? '✅' : '🚫'}</span>
      <span className="sr-only">{label}</span>
    </span>
  )
}

/**
 * A domain/mailbox name. ≤ 24 characters render in full (`break-all`, up to two
 * lines); longer multi-label names keep the first label (identity) and the last
 * two (registrable + TLD) and collapse the middle (`verylong…uni.example.com`);
 * the full name is always in the `title` tooltip.
 */
export function TruncatedName({ name, className }: { name: string; className?: string }) {
  const labels = name.split('.')
  const shown =
    name.length <= 24
      ? name
      : labels.length >= 3
        ? `${labels[0]}…${labels.slice(-2).join('.')}`
        : name
  return (
    <span
      title={name}
      className={cn(
        'min-w-0 break-all font-semibold leading-snug text-slate-100 line-clamp-2',
        className,
      )}
    >
      {shown}
    </span>
  )
}

/**
 * An email address in two tones: the local part carries the identity (bold,
 * slate-100), the domain reads as context (slate-400). Wraps (never truncates
 * silently) and carries the full address in the `title` tooltip.
 */
export function Address({ address, className }: { address: string; className?: string }) {
  const at = address.lastIndexOf('@')
  const local = at > 0 ? address.slice(0, at) : address
  const domain = at > 0 ? address.slice(at) : ''
  return (
    <span
      title={address}
      className={cn(
        'min-w-0 break-all font-semibold leading-snug text-slate-100 line-clamp-2',
        className,
      )}
    >
      {local}
      {domain && <span className="font-normal text-slate-400">{domain}</span>}
    </span>
  )
}

/** Icon + value stat chip (counts, quota, roles). */
export function MetaChip({
  icon,
  title,
  children,
  className,
}: {
  icon: string
  title?: string
  children: ReactNode
  className?: string
}) {
  return (
    <span
      title={title}
      className={cn(
        'inline-flex items-center gap-1.5 rounded-md bg-slate-800/60 px-2 py-1 text-xs text-slate-300',
        className,
      )}
    >
      <span aria-hidden="true">{icon}</span>
      <span className="tabular-nums">{children}</span>
    </span>
  )
}

/** The row of stat chips under the identity. */
export function MetaRow({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn('mt-2 flex flex-wrap items-center gap-1.5', className)}>{children}</div>
}

/**
 * Emoji action button. Touch first: 44×44px with a 24px-class glyph on every
 * screen below `lg:` (WCAG 2.5.5 / Apple HIG / technical-draft §6.1); ≥ `lg:`
 * — where the pointer is a mouse — it shrinks to 36×36px. The glyph is
 * `aria-hidden`; the accessible name is the localized action label.
 */
export function ActionButton({
  glyph,
  label,
  tone = 'default',
  disabled,
  onClick,
  className,
}: {
  glyph: string
  label: string
  tone?: 'default' | 'danger'
  disabled?: boolean
  onClick?: () => void
  className?: string
}) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={onClick}
      aria-label={label}
      title={label}
      className={cn(
        'inline-flex select-none items-center justify-center rounded-lg leading-none',
        'h-11 w-11 text-2xl transition duration-75',
        'hover:bg-slate-800 active:scale-95 active:bg-slate-800',
        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500',
        'disabled:pointer-events-none disabled:opacity-50',
        'lg:h-9 lg:w-9 lg:text-base',
        tone === 'danger' ? 'text-red-300 hover:bg-red-950/60' : 'text-slate-300',
        className,
      )}
    >
      <span aria-hidden="true">{glyph}</span>
    </button>
  )
}

/** The card's action cluster: 8px guard space between the 44px targets. */
export function ActionRow({ children, label }: { children: ReactNode; label: string }) {
  return (
    <div role="group" aria-label={label} className="flex shrink-0 items-center gap-2">
      {children}
    </div>
  )
}

