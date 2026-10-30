import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { call, type Token } from '../lib/api'
import { formatDate } from '../lib/utils'
import { Alert, Button, Card, Field, Modal, StatusBadge } from '../components/ui'
import { errorText } from './Login'

const SCOPES = ['mail.read', 'mail.modify', 'mail.trash', 'mail.send'] as const
const LIFETIMES = ['default', '7d', '90d', '365d', 'forever'] as const

export default function Tokens({ addresses, onError }: { addresses: string[]; onError: (text: string) => void }) {
  const { t, i18n } = useTranslation()
  const [tokens, setTokens] = useState<Token[]>([])
  const [name, setName] = useState('')
  const [lifetime, setLifetime] = useState<(typeof LIFETIMES)[number]>('default')
  const [scopes, setScopes] = useState<string[]>(['mail.read'])
  const [limitAddresses, setLimitAddresses] = useState(false)
  const [chosen, setChosen] = useState<string[]>([])
  const [foreverWarning, setForeverWarning] = useState(false)
  const [created, setCreated] = useState<string>('')
  const [revoking, setRevoking] = useState<Token | null>(null)
  const [copied, setCopied] = useState(false)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    try {
      setTokens((await call<{ tokens: Token[] }>('GET', '/user/tokens')).tokens)
    } catch (err) {
      onError(errorText(t, err))
    }
  }, [onError, t])

  useEffect(() => {
    void load()
  }, [load])

  async function create() {
    setBusy(true)
    try {
      const res = await call<Token & { token: string }>('POST', '/user/tokens', {
        name,
        lifetime,
        scopes,
        addresses: limitAddresses ? chosen : null,
      })
      setCreated(res.token)
      setCopied(false)
      setName('')
      await load()
    } catch (err) {
      onError(errorText(t, err))
    } finally {
      setBusy(false)
    }
  }

  function submit(e: FormEvent) {
    e.preventDefault()
    if (lifetime === 'forever') setForeverWarning(true)
    else void create()
  }

  async function act(tok: Token, action: 'enable' | 'disable' | 'revoke') {
    setBusy(true)
    try {
      await call('POST', `/user/tokens/${tok.id}/${action}`)
      await load()
    } catch (err) {
      onError(errorText(t, err))
    } finally {
      setBusy(false)
    }
  }

  function toggle(list: string[], value: string): string[] {
    return list.includes(value) ? list.filter((v) => v !== value) : [...list, value]
  }

  const statusLabel = (tok: Token) =>
    tok.status === 'disabled' && tok.disabled_reason === 'idle' ? t('tokens.status.idle') : t(`tokens.status.${tok.status}`)

  return (
    <Card title={t('tokens.title')}>
      <form onSubmit={submit} className="flex flex-col gap-3 rounded-md border border-slate-800 p-3" data-testid="token-form">
        <Field label={t('tokens.name')} value={name} onChange={(e) => setName(e.target.value)} maxLength={100} required placeholder="Claude Desktop" />
        <div className="flex flex-col gap-1">
          <label htmlFor="lifetime" className="text-sm text-slate-300">
            {t('tokens.lifetime')}
          </label>
          <select
            id="lifetime"
            value={lifetime}
            onChange={(e) => setLifetime(e.target.value as (typeof LIFETIMES)[number])}
            className="min-h-[44px] rounded-md border border-slate-700 bg-slate-900 px-2 text-sm"
          >
            {LIFETIMES.map((l) => (
              <option key={l} value={l}>
                {t(`tokens.lifetimes.${l}`)}
              </option>
            ))}
          </select>
        </div>
        <fieldset className="flex flex-col gap-1">
          <legend className="text-sm text-slate-300">{t('tokens.scopes')}</legend>
          <div className="flex flex-wrap gap-3">
            {SCOPES.map((s) => (
              <label key={s} className="inline-flex min-h-[44px] items-center gap-2 text-sm">
                <input type="checkbox" checked={scopes.includes(s)} onChange={() => setScopes(toggle(scopes, s))} />
                <span>
                  <code>{t(`tokens.scope.${s}`)}</code> <span className="text-slate-400">— {t(`tokens.scopeHint.${s}`)}</span>
                </span>
              </label>
            ))}
          </div>
        </fieldset>
        <fieldset className="flex flex-col gap-1">
          <label className="inline-flex min-h-[44px] items-center gap-2 text-sm">
            <input type="checkbox" checked={limitAddresses} onChange={() => setLimitAddresses(!limitAddresses)} />
            {t('tokens.limitAddresses')}
          </label>
          {limitAddresses && (
            <div className="flex flex-wrap gap-3 pl-6">
              {addresses.map((a) => (
                <label key={a} className="inline-flex min-h-[44px] items-center gap-2 text-sm">
                  <input type="checkbox" checked={chosen.includes(a)} onChange={() => setChosen(toggle(chosen, a))} />
                  {a}
                </label>
              ))}
            </div>
          )}
        </fieldset>
        <div>
          <Button type="submit" disabled={busy || !name.trim() || scopes.length === 0 || (limitAddresses && chosen.length === 0)}>
            {t('tokens.create')}
          </Button>
        </div>
      </form>

      {created && (
        <div className="mt-3 flex flex-col gap-2" data-testid="token-created">
          <Alert kind="warning">{t('tokens.showOnce')}</Alert>
          <div className="flex flex-col gap-2 sm:flex-row">
            <code className="flex-1 break-all rounded-md border border-slate-700 bg-slate-950 p-3 text-xs" data-testid="token-value">
              {created}
            </code>
            <Button
              variant="secondary"
              onClick={() => {
                void navigator.clipboard?.writeText(created).then(() => setCopied(true))
              }}
            >
              {copied ? t('tokens.copied') : t('tokens.copy')}
            </Button>
          </div>
          <Button variant="ghost" onClick={() => setCreated('')}>
            {t('tokens.dismiss')}
          </Button>
        </div>
      )}

      <ul className="mt-4 divide-y divide-slate-800" data-testid="token-list">
        {tokens.length === 0 && <li className="py-3 text-sm text-slate-400">{t('tokens.none')}</li>}
        {tokens.map((tok) => (
          <li key={tok.id} className={`flex flex-col gap-2 py-3 ${tok.status === 'revoked' ? 'opacity-60' : ''}`}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="min-w-0">
                <p className="text-sm font-medium">
                  {tok.name}{' '}
                  {tok.kind === 'oauth_refresh' ? (
                    <span className="text-xs text-slate-400">({t('tokens.oauthApp')})</span>
                  ) : (
                    <code className="text-xs text-slate-400">{tok.display}</code>
                  )}
                </p>
                <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-slate-400">
                  <StatusBadge status={tok.status} label={statusLabel(tok)} />
                  <span>{tok.scopes.join(', ')}</span>
                  <span>{tok.addresses ? tok.addresses.join(', ') : t('tokens.allAddresses')}</span>
                </div>
              </div>
              {tok.status !== 'revoked' && (
                <div className="flex flex-wrap gap-2">
                  {tok.kind === 'oauth_refresh' ? null : tok.status === 'active' ? (
                    <Button variant="secondary" disabled={busy} onClick={() => act(tok, 'disable')}>
                      {t('tokens.disable')}
                    </Button>
                  ) : (
                    <Button variant="secondary" disabled={busy} onClick={() => act(tok, 'enable')}>
                      {tok.disabled_reason === 'idle' ? t('tokens.reenable') : t('tokens.enable')}
                    </Button>
                  )}
                  <Button variant="danger" disabled={busy} onClick={() => setRevoking(tok)}>
                    {t('tokens.revoke')}
                  </Button>
                </div>
              )}
            </div>
            <dl className="grid grid-cols-1 gap-x-4 gap-y-1 text-xs text-slate-400 sm:grid-cols-3">
              <div>
                <dt className="inline">{t('tokens.created')}: </dt>
                <dd className="inline">{formatDate(tok.created_at, i18n.language)}</dd>
              </div>
              <div>
                <dt className="inline">{t('tokens.expires')}: </dt>
                <dd className="inline">{tok.expires_at ? formatDate(tok.expires_at, i18n.language) : t('tokens.never')}</dd>
              </div>
              <div>
                <dt className="inline">{t('tokens.lastUsed')}: </dt>
                <dd className="inline">
                  {tok.last_used_at ? `${formatDate(tok.last_used_at, i18n.language)} · ${tok.last_used_ip}` : t('tokens.neverUsed')}
                </dd>
              </div>
            </dl>
          </li>
        ))}
      </ul>

      {foreverWarning && (
        <Modal title={t('tokens.foreverTitle')} onClose={() => setForeverWarning(false)}>
          <Alert kind="warning">{t('tokens.foreverBody')}</Alert>
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={() => setForeverWarning(false)}>
              {t('common.cancel')}
            </Button>
            <Button
              onClick={() => {
                setForeverWarning(false)
                void create()
              }}
              data-testid="forever-confirm"
            >
              {t('tokens.foreverConfirm')}
            </Button>
          </div>
        </Modal>
      )}

      {revoking && (
        <Modal title={t('tokens.revokeTitle')} onClose={() => setRevoking(null)}>
          <p className="text-sm text-slate-300">{t('tokens.revokeBody', { name: revoking.name })}</p>
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={() => setRevoking(null)}>
              {t('common.cancel')}
            </Button>
            <Button
              variant="danger"
              onClick={() => {
                const tok = revoking
                setRevoking(null)
                void act(tok, 'revoke')
              }}
            >
              {t('tokens.revoke')}
            </Button>
          </div>
        </Modal>
      )}
    </Card>
  )
}
