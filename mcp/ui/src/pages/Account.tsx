import { useEffect, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { call, type Account as AccountT, type Address } from '../lib/api'
import { formatDate } from '../lib/utils'
import { Alert, Button, Card, Field, StatusBadge, TypeToConfirm } from '../components/ui'
import { errorText } from './Login'
import Tokens from './Tokens'
import { ActivityCard, PreferencesCard } from './Preferences'

type Pending = { kind: 'disable' | 'enable' | 'remove'; address: Address } | null

function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

export default function Account({
  account,
  onChange,
  onLogout,
}: {
  account: AccountT
  onChange: (a: AccountT) => void
  onLogout: () => void
}) {
  const { t, i18n } = useTranslation()
  const now = useNow()
  const [newAddress, setNewAddress] = useState('')
  const [notice, setNotice] = useState<{ kind: 'error' | 'success' | 'info'; text: string } | null>(null)
  const [pending, setPending] = useState<Pending>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (account.lang && account.lang !== i18n.language) void i18n.changeLanguage(account.lang)
  }, [account.lang, i18n])

  async function run<T>(fn: () => Promise<T>, ok?: string): Promise<T | undefined> {
    setBusy(true)
    setNotice(null)
    try {
      const res = await fn()
      if (ok) setNotice({ kind: 'success', text: ok })
      return res
    } catch (err) {
      setNotice({ kind: 'error', text: errorText(t, err) })
      return undefined
    } finally {
      setBusy(false)
    }
  }

  async function reload() {
    const me = await call<AccountT>('GET', '/user/me')
    onChange(me)
  }

  async function toggleMcp() {
    const res = await run(() => call<AccountT>('PUT', '/user/mcp', { enabled: !account.mcp_enabled }))
    if (res) onChange(res)
  }

  async function setLang(lang: 'en' | 'es') {
    void i18n.changeLanguage(lang)
    const res = await run(() => call<AccountT>('PUT', '/user/prefs', { lang }))
    if (res) onChange(res)
  }

  async function add(e: FormEvent) {
    e.preventDefault()
    const email = newAddress.trim()
    const res = await run(() => call<Address>('POST', '/user/addresses', { email }), t('addresses.checkInbox', { address: email }))
    if (res) {
      setNewAddress('')
      await reload()
    }
  }

  async function resend(a: Address) {
    const res = await run(() => call<Address>('POST', `/user/addresses/${a.id}/resend`), t('addresses.checkInbox', { address: a.email }))
    if (res) await reload()
  }

  async function confirmPending(typed: string) {
    if (!pending) return
    const { kind, address } = pending
    setPending(null)
    const res =
      kind === 'remove'
        ? await run(() => call('POST', `/user/addresses/${address.id}/remove`, { confirm: typed }), t('addresses.removed', { address: address.email }))
        : await run(
            () => call('POST', `/user/addresses/${address.id}/status`, { enabled: kind === 'enable', confirm: typed }),
            t(kind === 'enable' ? 'addresses.enabledDone' : 'addresses.disabledDone', { address: address.email }),
          )
    if (res) await reload()
  }

  const usableForTokens = account.addresses.filter((a) => a.status !== 'pending').map((a) => a.email)

  return (
    <div className="mx-auto flex w-full max-w-4xl flex-col gap-4 px-4 py-6">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">{t('app.title')}</h1>
          <p className="text-sm text-slate-400">
            {t('account.signedInAs', { email: account.login_email ?? account.main_email })}
            {account.login_email && account.login_email !== account.main_email && (
              <> · {t('account.mainIs', { email: account.main_email })}</>
            )}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <label className="sr-only" htmlFor="lang">
            {t('account.language')}
          </label>
          <select
            id="lang"
            value={i18n.language.startsWith('es') ? 'es' : 'en'}
            onChange={(e) => setLang(e.target.value as 'en' | 'es')}
            className="min-h-[44px] rounded-md border border-slate-700 bg-slate-900 px-2 text-sm"
          >
            <option value="en">English</option>
            <option value="es">Español</option>
          </select>
          <Button variant="secondary" onClick={onLogout} data-testid="logout">
            {t('account.logout')}
          </Button>
        </div>
      </header>

      {notice && <Alert kind={notice.kind}>{notice.text}</Alert>}

      <Card title={t('account.mcpTitle')}>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="max-w-prose text-sm text-slate-300">{t('account.mcpBody')}</p>
          <button
            role="switch"
            aria-checked={account.mcp_enabled}
            onClick={toggleMcp}
            disabled={busy}
            data-testid="mcp-switch"
            className="inline-flex min-h-[44px] items-center gap-3 rounded-md border border-slate-700 px-3 text-sm"
          >
            <span
              aria-hidden="true"
              className={`relative h-6 w-11 rounded-full transition ${account.mcp_enabled ? 'bg-emerald-600' : 'bg-slate-600'}`}
            >
              <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition ${account.mcp_enabled ? 'left-5' : 'left-0.5'}`} />
            </span>
            {account.mcp_enabled ? t('account.mcpOn') : t('account.mcpOff')}
          </button>
        </div>
        <p className="mt-3 break-all text-xs text-slate-400">
          {t('account.endpoint')}: <code className="text-slate-200">{account.mcp_url}</code>
        </p>
      </Card>

      <Card title={t('addresses.title')}>
        <ul className="divide-y divide-slate-800" data-testid="address-list">
          {account.addresses.map((a) => {
            const wait = a.next_resend_at ? Math.max(0, Math.ceil((Date.parse(a.next_resend_at) - now) / 1000)) : 0
            return (
              <li key={a.id} className="flex flex-wrap items-center justify-between gap-2 py-3" data-testid={`address-${a.email}`}>
                <div className="min-w-0">
                  <p className="break-all text-sm font-medium">{a.email}</p>
                  <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-slate-400">
                    <StatusBadge status={a.status} label={t(`addresses.status.${a.status}`)} />
                    {a.main && <span>{t('addresses.main')}</span>}
                    {a.status === 'pending' && <span>{t('addresses.expires', { date: formatDate(a.magic_expires_at, i18n.language) })}</span>}
                  </div>
                </div>
                {!a.main && (
                  <div className="flex flex-wrap gap-2">
                    {a.status === 'pending' && (
                      <Button variant="secondary" disabled={busy || wait > 0} onClick={() => resend(a)}>
                        {wait > 0 ? t('addresses.resendIn', { seconds: wait }) : t('addresses.resend')}
                      </Button>
                    )}
                    {a.status === 'active' && (
                      <Button variant="secondary" disabled={busy} onClick={() => setPending({ kind: 'disable', address: a })}>
                        {t('addresses.disable')}
                      </Button>
                    )}
                    {a.status === 'disabled' && (
                      <Button variant="secondary" disabled={busy} onClick={() => setPending({ kind: 'enable', address: a })}>
                        {t('addresses.enable')}
                      </Button>
                    )}
                    <Button variant="danger" disabled={busy} onClick={() => setPending({ kind: 'remove', address: a })}>
                      {t('addresses.remove')}
                    </Button>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
        <form onSubmit={add} className="mt-3 flex flex-col gap-2 sm:flex-row sm:items-end">
          <div className="flex-1">
            <Field
              label={t('addresses.add')}
              type="email"
              placeholder="name@example.com"
              value={newAddress}
              onChange={(e) => setNewAddress(e.target.value)}
              hint={t('addresses.addHint')}
              required
            />
          </div>
          <Button type="submit" disabled={busy || !newAddress.trim()} className="sm:mb-6">
            {t('addresses.addButton')}
          </Button>
        </form>
      </Card>

      <Tokens addresses={usableForTokens} onError={(text) => setNotice({ kind: 'error', text })} />

      <PreferencesCard account={account} onChange={onChange} />

      <ActivityCard />

      {pending && (
        <TypeToConfirm
          title={t(`addresses.confirm.${pending.kind}.title`)}
          body={t(`addresses.confirm.${pending.kind}.body`, { address: pending.address.email, main: account.main_email })}
          expected={pending.address.email}
          confirmLabel={t(`addresses.${pending.kind}`)}
          danger={pending.kind !== 'enable'}
          onConfirm={confirmPending}
          onClose={() => setPending(null)}
        />
      )}
    </div>
  )
}
