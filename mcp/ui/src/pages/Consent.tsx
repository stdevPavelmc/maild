import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { call, refresh, type Account } from '../lib/api'
import { Alert, Button, StatusBadge } from '../components/ui'
import Login, { errorText } from './Login'

interface OAuthReq {
  client_name: string
  client_id: string
  client_host: string
  registration: 'cimd' | 'dcr'
  redirect_host: string
  scopes: string[]
  mcp_enabled: boolean
  addresses: string[]
}

/**
 * OAuth consent (proposal §8.2): sign in (IMAP password + ALTCHA) if needed, then show who asks
 * (client name, where its identity comes from, where it will send you back), let the user narrow
 * the scopes and pick the addresses, Allow / Deny. The request id travels in the fragment.
 */
export default function Consent() {
  const { t } = useTranslation()
  const [requestId] = useState(() => window.location.hash.replace(/^#/, ''))
  const [account, setAccount] = useState<Account | null>(null)
  const [ready, setReady] = useState(false)
  const [req, setReq] = useState<OAuthReq | null>(null)
  const [scopes, setScopes] = useState<string[]>([])
  const [addresses, setAddresses] = useState<string[]>([])
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    refresh().then(setAccount).finally(() => setReady(true))
  }, [])

  useEffect(() => {
    if (!account || !requestId) return
    call<OAuthReq>('POST', '/user/oauth/request', { request_id: requestId })
      .then((r) => {
        setReq(r)
        setScopes(r.scopes)
        setAddresses(r.addresses)
      })
      .catch((err) => setError(errorText(t, err)))
  }, [account, requestId, t])

  async function decide(approve: boolean) {
    setBusy(true)
    setError('')
    try {
      const r = await call<{ redirect: string }>('POST', '/user/oauth/decision', {
        request_id: requestId, approve, scopes, addresses,
      })
      window.location.assign(r.redirect)
    } catch (err) {
      setError(errorText(t, err))
      setBusy(false)
    }
  }

  if (!requestId) return <main className="p-6"><Alert>{t('consent.missing')}</Alert></main>
  if (!ready) return <p className="p-6 text-sm text-slate-400" role="status">{t('common.loading')}</p>
  if (!account) return <Login onLogin={setAccount} />

  const toggle = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v])
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-lg flex-col justify-center gap-4 px-4 py-10">
      <h1 className="text-xl font-semibold">{t('consent.title')}</h1>
      {error && <Alert>{error}</Alert>}
      {req && (
        <div className="flex flex-col gap-4 rounded-lg border border-slate-800 bg-slate-900/70 p-5" data-testid="consent">
          <p className="text-base">
            <strong data-testid="consent-client">{req.client_name}</strong> {t('consent.wants', { account: account.main_email })}
          </p>
          <dl className="grid grid-cols-1 gap-1 text-xs text-slate-400 sm:grid-cols-2">
            <div><dt className="inline">{t('consent.identity')}: </dt><dd className="inline">{req.client_host || req.client_id}
              {' '}({t(`consent.registration.${req.registration}`)})</dd></div>
            <div><dt className="inline">{t('consent.returnsTo')}: </dt><dd className="inline">{req.redirect_host}</dd></div>
          </dl>
          {!req.mcp_enabled && <Alert kind="warning">{t('consent.mcpOff')}</Alert>}
          <fieldset className="flex flex-col gap-1">
            <legend className="text-sm text-slate-300">{t('tokens.scopes')}</legend>
            {req.scopes.map((s) => (
              <label key={s} className="inline-flex min-h-[44px] items-center gap-2 text-sm">
                <input type="checkbox" checked={scopes.includes(s)} onChange={() => setScopes(toggle(scopes, s))} />
                <code>{s}</code> <span className="text-slate-400">— {t(`tokens.scopeHint.${s}`)}</span>
              </label>
            ))}
          </fieldset>
          <fieldset className="flex flex-col gap-1">
            <legend className="text-sm text-slate-300">{t('consent.addresses')}</legend>
            {req.addresses.map((a) => (
              <label key={a} className="inline-flex min-h-[44px] items-center gap-2 text-sm">
                <input type="checkbox" checked={addresses.includes(a)} onChange={() => setAddresses(toggle(addresses, a))} />
                {a} <StatusBadge status="active" label={t('addresses.status.active')} />
              </label>
            ))}
          </fieldset>
          <p className="text-xs text-slate-400">{t('consent.revokeHint')}</p>
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => decide(true)} disabled={busy || scopes.length === 0 || addresses.length === 0} data-testid="consent-allow">
              {t('consent.allow')}
            </Button>
            <Button variant="secondary" onClick={() => decide(false)} disabled={busy} data-testid="consent-deny">
              {t('consent.deny')}
            </Button>
          </div>
        </div>
      )}
    </main>
  )
}
