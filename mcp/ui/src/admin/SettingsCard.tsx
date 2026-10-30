import { useEffect, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { adminCall } from './api'
import { Alert, Button, Card } from '../components/ui'
import { errorText } from '../pages/Login'

/**
 * One settings group (proposal §7.1/§7.2): loads the server value, edits a local copy, shows a
 * dirty badge, Update = PUT, Restore = drop the local edits and reload the server value.
 */
export function SettingsCard<T extends object>({
  title,
  group,
  children,
  testId,
}: {
  title: string
  group: string
  testId: string
  children: (value: T, set: (patch: Partial<T>) => void) => ReactNode
}) {
  const { t } = useTranslation()
  const [server, setServer] = useState<T | null>(null)
  const [form, setForm] = useState<T | null>(null)
  const [notice, setNotice] = useState<{ kind: 'error' | 'success'; text: string } | null>(null)
  const [busy, setBusy] = useState(false)

  async function load() {
    const v = await adminCall<T>('GET', `/settings/${group}`)
    setServer(v)
    setForm(v)
  }

  useEffect(() => {
    void load().catch((err) => setNotice({ kind: 'error', text: errorText(t, err) }))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [group])

  const dirty = server !== null && form !== null && JSON.stringify(server) !== JSON.stringify(form)

  async function update() {
    if (!form) return
    setBusy(true)
    setNotice(null)
    try {
      const v = await adminCall<T>('PUT', `/settings/${group}`, form)
      setServer(v)
      setForm(v)
      setNotice({ kind: 'success', text: t('admin.saved') })
    } catch (err) {
      setNotice({ kind: 'error', text: errorText(t, err) })
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card
      title={title}
      actions={
        dirty ? (
          <span className="rounded-full border border-amber-600 px-2 py-0.5 text-xs text-amber-200" data-testid={`${testId}-dirty`}>
            ✎ {t('prefs.unsaved')}
          </span>
        ) : undefined
      }
    >
      <div className="flex flex-col gap-3" data-testid={testId}>
        {form ? children(form, (patch) => setForm({ ...form, ...patch })) : <p className="text-sm text-slate-400">{t('common.loading')}</p>}
        {notice && <Alert kind={notice.kind}>{notice.text}</Alert>}
        <div className="flex flex-wrap gap-2">
          <Button onClick={update} disabled={busy || !dirty} data-testid={`${testId}-update`}>
            {t('prefs.update')}
          </Button>
          <Button variant="secondary" onClick={() => server && setForm(server)} disabled={busy || !dirty} data-testid={`${testId}-restore`}>
            {t('prefs.restore')}
          </Button>
        </div>
      </div>
    </Card>
  )
}

export function Row({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <span className="text-slate-300">{label}</span>
      {children}
      {hint && <span className="text-xs text-slate-400">{hint}</span>}
    </label>
  )
}

export const inputCls =
  'min-h-[44px] w-full rounded-md border border-slate-700 bg-slate-900 px-3 text-sm text-slate-100 focus:border-blue-500 focus:outline-none'
