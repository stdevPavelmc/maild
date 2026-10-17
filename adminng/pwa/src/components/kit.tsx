import {
  useEffect,
  useId,
  useRef,
  useState,
  type ButtonHTMLAttributes,
  type InputHTMLAttributes,
  type ReactNode,
  type Ref,
  type SelectHTMLAttributes,
} from 'react'
import { useTranslation } from 'react-i18next'
import { cn } from '../lib/utils'
import { QUOTA_UNITS, quotaToBytes, quotaValueFromBytes, type QuotaUnit } from '../lib/format'
import { Button } from './ui/button'

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block text-slate-400">{label}</span>
      {children}
    </label>
  )
}

export function Input(
  props: InputHTMLAttributes<HTMLInputElement> & { inputRef?: Ref<HTMLInputElement> },
) {
  const { inputRef, ...rest } = props
  return (
    <input
      {...rest}
      ref={inputRef}
      className={cn(
        'h-10 w-full rounded-md border border-slate-700 bg-slate-900 px-3 text-slate-100',
        'placeholder:text-slate-400 focus:border-blue-500 focus:outline-none disabled:opacity-50',
        props.className,
      )}
    />
  )
}

export function Select(props: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select
      {...props}
      className={cn(
        'h-10 w-full rounded-md border border-slate-700 bg-slate-900 px-3 text-slate-100',
        'focus:border-blue-500 focus:outline-none disabled:opacity-50',
        props.className,
      )}
    />
  )
}

export function Toggle({
  checked,
  onChange,
  label,
  disabled,
}: {
  checked: boolean
  onChange: (value: boolean) => void
  label: string
  disabled?: boolean
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className="flex items-center gap-3 text-sm text-slate-200 disabled:opacity-50"
    >
      <span
        className={cn(
          'relative h-6 w-11 rounded-full transition-colors',
          checked ? 'bg-blue-600' : 'bg-slate-700',
        )}
      >
        <span
          className={cn(
            'absolute top-0.5 h-5 w-5 rounded-full bg-white transition-all',
            checked ? 'left-[22px]' : 'left-0.5',
          )}
        />
      </span>
      {label}
    </button>
  )
}

export function Badge({ tone = 'slate', children }: { tone?: 'slate' | 'green' | 'amber' | 'red' | 'blue'; children: ReactNode }) {
  const tones: Record<string, string> = {
    slate: 'bg-slate-800 text-slate-300',
    green: 'bg-emerald-900/60 text-emerald-300',
    amber: 'bg-amber-900/60 text-amber-300',
    red: 'bg-red-900/60 text-red-300',
    blue: 'bg-blue-900/60 text-blue-300',
  }
  return <span className={cn('rounded px-2 py-0.5 text-xs font-medium', tones[tone])}>{children}</span>
}

export function QuotaBar({ used, limit }: { used: number; limit: number }) {
  if (limit <= 0) return <span className="text-xs text-slate-400">∞</span>
  const pct = Math.min(100, Math.round((used * 100) / limit))
  const tone = pct >= 90 ? 'bg-red-500' : pct >= 70 ? 'bg-orange-500' : 'bg-blue-500'
  return (
    <div className="flex items-center gap-2">
      <div className="h-1.5 w-24 overflow-hidden rounded bg-slate-800">
        <div className={cn('h-full', tone)} style={{ width: `${pct}%` }} />
      </div>
      <span className="text-xs text-slate-400">{pct}%</span>
    </div>
  )
}

export function Modal({
  open,
  title,
  onClose,
  children,
  footer,
}: {
  open: boolean
  title: string
  onClose: () => void
  children: ReactNode
  footer?: ReactNode
}) {
  if (!open) return null
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={title}
      className="fixed inset-0 z-40 flex items-end justify-center bg-black/50 sm:items-center"
    >
      <div className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-t-2xl bg-slate-900 p-5 shadow-xl sm:rounded-2xl">
        <div className="mb-4 flex items-center justify-between gap-4">
          <h2 className="text-lg font-semibold">{title}</h2>
          <Button variant="outline" size="sm" onClick={onClose} aria-label="close">
            ✕
          </Button>
        </div>
        <div className="space-y-3">{children}</div>
        {footer && <div className="mt-5 flex justify-end gap-2">{footer}</div>}
      </div>
    </div>
  )
}

/** Destructive action button with the mandated 5-second arming delay. */
export function ArmedButton({
  label,
  onConfirm,
  disabled,
  seconds = 5,
  className,
}: {
  label: string
  onConfirm: () => void
  disabled?: boolean
  seconds?: number
  className?: string
}) {
  const [armed, setArmed] = useState(false)
  const [left, setLeft] = useState(seconds)

  useEffect(() => {
    if (!armed) return
    if (left <= 0) return
    const timer = window.setTimeout(() => setLeft((value) => value - 1), 1000)
    return () => window.clearTimeout(timer)
  }, [armed, left])

  useEffect(() => {
    if (!armed) setLeft(seconds)
  }, [armed, seconds])

  return (
    <Button
      className={cn('bg-red-600 hover:bg-red-500', className)}
      disabled={disabled || (armed && left > 0)}
      onClick={() => {
        if (!armed) {
          setArmed(true)
          return
        }
        if (left <= 0) onConfirm()
      }}
    >
      {!armed ? label : left > 0 ? `${label} (${left}s)` : label}
    </Button>
  )
}

export function Empty({ text }: { text: string }) {
  return <p className="py-8 text-center text-sm text-slate-400">{text}</p>
}

export function ErrorBanner({ message }: { message: string | null }) {
  if (!message) return null
  return (
    <div className="rounded-md border border-red-900 bg-red-950/60 px-3 py-2 text-sm text-red-300">
      {message}
    </div>
  )
}

export function SectionHeader({ title, action }: { title: string; action?: ReactNode }) {
  return (
    <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
      <h2 className="text-lg font-semibold">{title}</h2>
      {action}
    </div>
  )
}

export function Btn(props: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'default' | 'outline'; size?: 'default' | 'sm' }) {
  return <Button {...props} />
}

/**
 * Quota editor: a numeric input plus a unit multiplier (MB default, GB and TB
 * selectable). The value is bytes end to end — the unit never leaks into the
 * page. Commits on blur of the number (the screens' established UX) and when
 * the unit changes; 0 means unlimited, and the hint says so (linked with
 * aria-describedby for screen readers).
 */
export function QuotaInput({
  bytes,
  onCommit,
  disabled,
}: {
  bytes: number
  onCommit: (bytes: number) => void
  disabled?: boolean
}) {
  const { t } = useTranslation()
  const hintId = useId()
  const initial = quotaValueFromBytes(bytes)
  const [number, setNumber] = useState(String(initial.number))
  const [unit, setUnit] = useState<QuotaUnit>(initial.unit)
  const committed = useRef(bytes)

  const commit = (raw: string, chosen: QuotaUnit): void => {
    const next = quotaToBytes(Math.max(0, Math.round(Number(raw) || 0)), chosen)
    if (next === committed.current) return
    committed.current = next
    onCommit(next)
  }

  return (
    <div>
      <div className="flex gap-2">
        <Input
          inputMode="numeric"
          aria-label={t('mailboxes.quota')}
          aria-describedby={hintId}
          disabled={disabled}
          value={number}
          onChange={(event) => setNumber(event.target.value.replace(/[^0-9]/g, ''))}
          onBlur={() => commit(number, unit)}
        />
        <Select
          aria-label={t('mailboxes.quotaUnit')}
          className="w-24"
          disabled={disabled}
          value={unit}
          onChange={(event) => {
            const chosen = event.target.value as QuotaUnit
            setUnit(chosen)
            commit(number, chosen)
          }}
        >
          {QUOTA_UNITS.map((option) => (
            <option key={option} value={option}>{option}</option>
          ))}
        </Select>
      </div>
      <p id={hintId} className="mt-1 text-xs text-slate-400">{t('mailboxes.quotaHint')}</p>
    </div>
  )
}
