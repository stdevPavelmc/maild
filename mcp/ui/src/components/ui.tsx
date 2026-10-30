import { forwardRef, useEffect, useId, useRef, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { cn } from '../lib/utils'

type Variant = 'primary' | 'secondary' | 'danger' | 'ghost'

export function Button({
  variant = 'primary',
  className,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      {...props}
      className={cn(
        'inline-flex min-h-[44px] items-center justify-center gap-2 rounded-md px-4 text-sm font-medium',
        'focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400 disabled:cursor-not-allowed disabled:opacity-50',
        variant === 'primary' && 'bg-blue-600 text-white hover:bg-blue-500',
        variant === 'secondary' && 'border border-slate-600 bg-slate-800 text-slate-100 hover:bg-slate-700',
        variant === 'danger' && 'bg-red-700 text-white hover:bg-red-600',
        variant === 'ghost' && 'text-slate-300 hover:bg-slate-800',
        className,
      )}
    />
  )
}

export const Field = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string }>(
  function Field({ label, hint, ...props }, ref) {
    const id = useId()
    return (
      <div className="flex flex-col gap-1">
        <label htmlFor={id} className="text-sm text-slate-300">
          {label}
        </label>
        <input
          id={id}
          ref={ref}
          {...props}
          className={cn(
            'min-h-[44px] w-full rounded-md border border-slate-700 bg-slate-900 px-3 text-sm text-slate-100',
            'placeholder:text-slate-500 focus:border-blue-500 focus:outline-none disabled:opacity-50',
            props.className,
          )}
        />
        {hint && <p className="text-xs text-slate-400">{hint}</p>}
      </div>
    )
  },
)

export function Card({ title, children, actions }: { title: string; children: ReactNode; actions?: ReactNode }) {
  return (
    <section className="rounded-lg border border-slate-800 bg-slate-900/70 p-4 sm:p-5" aria-label={title}>
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-base font-semibold text-slate-100">{title}</h2>
        {actions}
      </div>
      {children}
    </section>
  )
}

export function Alert({ kind = 'error', children }: { kind?: 'error' | 'info' | 'success' | 'warning'; children: ReactNode }) {
  return (
    <div
      role={kind === 'error' ? 'alert' : 'status'}
      className={cn(
        'rounded-md border px-3 py-2 text-sm',
        kind === 'error' && 'border-red-800 bg-red-950/60 text-red-200',
        kind === 'info' && 'border-blue-800 bg-blue-950/60 text-blue-100',
        kind === 'success' && 'border-emerald-800 bg-emerald-950/60 text-emerald-100',
        kind === 'warning' && 'border-amber-700 bg-amber-950/60 text-amber-100',
      )}
    >
      {children}
    </div>
  )
}

const STATUS_STYLE: Record<string, { icon: string; cls: string }> = {
  active: { icon: '●', cls: 'border-emerald-700 text-emerald-200' },
  pending: { icon: '◐', cls: 'border-amber-600 text-amber-200' },
  disabled: { icon: '○', cls: 'border-slate-500 text-slate-300' },
  revoked: { icon: '✕', cls: 'border-red-800 text-red-300' },
}

/** Status shown with an icon AND a word, never colour alone (proposal §7.3, a11y). */
export function StatusBadge({ status, label }: { status: string; label: string }) {
  const style = STATUS_STYLE[status] ?? STATUS_STYLE.disabled
  return (
    <span className={cn('inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs', style.cls)}>
      <span aria-hidden="true">{style.icon}</span>
      {label}
    </span>
  )
}

export function Modal({
  title,
  children,
  onClose,
}: {
  title: string
  children: ReactNode
  onClose: () => void
}) {
  const { t } = useTranslation()
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dlg = ref.current
    if (dlg && !dlg.open) dlg.showModal()
    return () => dlg?.close()
  }, [])
  return (
    <dialog
      ref={ref}
      onCancel={(e) => {
        e.preventDefault()
        onClose()
      }}
      className="w-[min(32rem,calc(100vw-2rem))] rounded-lg border border-slate-700 bg-slate-900 p-0 text-slate-100 backdrop:bg-black/70"
      aria-label={title}
    >
      <div className="flex items-center justify-between border-b border-slate-800 px-4 py-3">
        <h3 className="font-semibold">{title}</h3>
        <button onClick={onClose} className="min-h-[44px] min-w-[44px] text-slate-400 hover:text-white" aria-label={t('common.close')}>
          ✕
        </button>
      </div>
      <div className="flex flex-col gap-3 p-4">{children}</div>
    </dialog>
  )
}

/** "Type the address to confirm" dialog used before disabling or removing an address. */
export function TypeToConfirm({
  title,
  body,
  expected,
  confirmLabel,
  danger,
  onConfirm,
  onClose,
}: {
  title: string
  body: string
  expected: string
  confirmLabel: string
  danger?: boolean
  onConfirm: (typed: string) => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const ref = useRef<HTMLInputElement>(null)
  return (
    <Modal title={title} onClose={onClose}>
      <p className="text-sm text-slate-300">{body}</p>
      <form
        className="flex flex-col gap-3"
        onSubmit={(e) => {
          e.preventDefault()
          onConfirm(ref.current?.value ?? '')
        }}
      >
        <Field label={t('common.typeToConfirm', { value: expected })} ref={ref} autoFocus autoComplete="off" />
        <div className="flex justify-end gap-2">
          <Button type="button" variant="secondary" onClick={onClose}>
            {t('common.cancel')}
          </Button>
          <Button type="submit" variant={danger ? 'danger' : 'primary'}>
            {confirmLabel}
          </Button>
        </div>
      </form>
    </Modal>
  )
}
