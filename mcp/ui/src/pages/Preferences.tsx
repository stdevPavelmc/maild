import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { call, type Account, type ActivityItem, type Prefs } from '../lib/api'
import { formatDate } from '../lib/utils'
import { Alert, Button, Card } from '../components/ui'
import { errorText } from './Login'

type Editable = Omit<Prefs, 'lang'>

function pick(p: Prefs): Editable {
  const { lang: _lang, ...rest } = p
  return rest
}

/**
 * Send-related preferences (proposal §7.3.3, decision 2026-10-30). One settings card with
 * Update (save to the server) and Restore (drop local edits, reload the server values), and a
 * dirty-state badge — the proposal's §7.1 card pattern.
 */
export function PreferencesCard({ account, onChange }: { account: Account; onChange: (a: Account) => void }) {
  const { t } = useTranslation()
  const server = useMemo(() => pick(account.prefs), [account.prefs])
  const [form, setForm] = useState<Editable>(server)
  const [hiddenText, setHiddenText] = useState(server.hidden_folders.join(', '))
  const [notice, setNotice] = useState<{ kind: 'error' | 'success'; text: string } | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    setForm(server)
    setHiddenText(server.hidden_folders.join(', '))
  }, [server])

  const hidden = hiddenText
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
  const current: Editable = { ...form, hidden_folders: hidden }
  const dirty = JSON.stringify(current) !== JSON.stringify(server)
  const senders = account.addresses.filter((a) => a.status !== 'pending').map((a) => a.email)

  async function update() {
    setBusy(true)
    setNotice(null)
    try {
      onChange(await call<Account>('PUT', '/user/prefs', current))
      setNotice({ kind: 'success', text: t('prefs.saved') })
    } catch (err) {
      setNotice({ kind: 'error', text: errorText(t, err) })
    } finally {
      setBusy(false)
    }
  }

  function restore() {
    setForm(server)
    setHiddenText(server.hidden_folders.join(', '))
    setNotice(null)
  }

  return (
    <Card
      title={t('prefs.title')}
      actions={
        dirty ? (
          <span className="rounded-full border border-amber-600 px-2 py-0.5 text-xs text-amber-200" data-testid="prefs-dirty">
            ✎ {t('prefs.unsaved')}
          </span>
        ) : undefined
      }
    >
      <div className="flex flex-col gap-4" data-testid="prefs-card">
        <div className="flex flex-col gap-1">
          <label htmlFor="confirm-send" className="text-sm text-slate-300">
            {t('prefs.confirmSend')}
          </label>
          <select
            id="confirm-send"
            value={form.confirm_send}
            onChange={(e) => setForm({ ...form, confirm_send: e.target.value as Prefs['confirm_send'] })}
            className="min-h-[44px] rounded-md border border-slate-700 bg-slate-900 px-2 text-sm"
          >
            {account.confirm_modes.map((m) => (
              <option key={m} value={m}>
                {t(`prefs.confirmModes.${m}`)}
              </option>
            ))}
          </select>
          <p className="text-xs text-slate-400">{t('prefs.confirmHint')}</p>
        </div>

        <div className="flex flex-col gap-1">
          <label htmlFor="default-sender" className="text-sm text-slate-300">
            {t('prefs.defaultSender')}
          </label>
          <select
            id="default-sender"
            value={form.default_sender}
            onChange={(e) => setForm({ ...form, default_sender: e.target.value })}
            className="min-h-[44px] rounded-md border border-slate-700 bg-slate-900 px-2 text-sm"
          >
            <option value="">{t('prefs.firstAddress')}</option>
            {senders.map((a) => (
              <option key={a} value={a}>
                {a}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-1">
          <label htmlFor="signature" className="text-sm text-slate-300">
            {t('prefs.signature')}
          </label>
          <textarea
            id="signature"
            rows={3}
            maxLength={2000}
            value={form.signature}
            onChange={(e) => setForm({ ...form, signature: e.target.value })}
            className="w-full rounded-md border border-slate-700 bg-slate-900 px-3 py-2 text-sm text-slate-100 focus:border-blue-500 focus:outline-none"
          />
          <p className="text-xs text-slate-400">{t('prefs.signatureHint')}</p>
        </div>

        <div className="flex flex-col gap-1">
          <label htmlFor="hidden-folders" className="text-sm text-slate-300">
            {t('prefs.hiddenFolders')}
          </label>
          <input
            id="hidden-folders"
            value={hiddenText}
            onChange={(e) => setHiddenText(e.target.value)}
            placeholder="Private, Family/Tax"
            className="min-h-[44px] w-full rounded-md border border-slate-700 bg-slate-900 px-3 text-sm text-slate-100 focus:border-blue-500 focus:outline-none"
          />
          <p className="text-xs text-slate-400">{t('prefs.hiddenHint')}</p>
        </div>

        <label className="inline-flex min-h-[44px] items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={form.allow_attachments}
            onChange={(e) => setForm({ ...form, allow_attachments: e.target.checked })}
          />
          {t('prefs.allowAttachments')}
        </label>

        <fieldset className="flex flex-col gap-1">
          <legend className="text-sm text-slate-300">{t('prefs.notifyTitle')}</legend>
          {(['notify_new_token', 'notify_new_client', 'notify_master_access'] as const).map((k) => (
            <label key={k} className="inline-flex min-h-[40px] items-center gap-2 text-sm">
              <input type="checkbox" checked={form[k]} onChange={(e) => setForm({ ...form, [k]: e.target.checked })} />
              {t(`prefs.${k}`)}
            </label>
          ))}
        </fieldset>

        {notice && <Alert kind={notice.kind}>{notice.text}</Alert>}
        <div className="flex flex-wrap gap-2">
          <Button onClick={update} disabled={busy || !dirty} data-testid="prefs-update">
            {t('prefs.update')}
          </Button>
          <Button variant="secondary" onClick={restore} disabled={busy || !dirty} data-testid="prefs-restore">
            {t('prefs.restore')}
          </Button>
        </div>
      </div>
    </Card>
  )
}

export function ActivityCard() {
  const { t, i18n } = useTranslation()
  const [items, setItems] = useState<ActivityItem[] | null>(null)
  const [error, setError] = useState('')

  async function load() {
    setError('')
    try {
      setItems((await call<{ items: ActivityItem[] }>('GET', '/user/activity')).items)
    } catch (err) {
      setError(errorText(t, err))
    }
  }

  useEffect(() => {
    void load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <Card
      title={t('activity.title')}
      actions={
        <Button variant="ghost" onClick={load}>
          {t('activity.refresh')}
        </Button>
      }
    >
      {error && <Alert>{error}</Alert>}
      {items && items.length === 0 && <p className="text-sm text-slate-400">{t('activity.none')}</p>}
      <ul className="divide-y divide-slate-800" data-testid="activity-list">
        {(items ?? []).map((item, i) => (
          <li key={i} className="flex flex-wrap items-baseline justify-between gap-2 py-2 text-sm">
            <span>
              <code className="text-slate-200">{item.event}</code>
              {item.result !== 'ok' && <span className="ml-2 text-xs text-amber-300">{item.result}</span>}
              {item.target && <span className="ml-2 text-xs text-slate-400">{item.target}</span>}
            </span>
            <span className="text-xs text-slate-400">
              {formatDate(item.ts, i18n.language)}
              {item.ip && ` · ${item.ip}`}
              {item.token && ` · ${t('activity.token')} ${item.token.slice(0, 6)}…`}
            </span>
          </li>
        ))}
      </ul>
    </Card>
  )
}
