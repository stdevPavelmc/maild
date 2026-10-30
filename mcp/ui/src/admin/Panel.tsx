import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { adminCall, type AdminMe, type DomainRow, type MasterToken } from './api'
import { Row, SettingsCard, inputCls } from './SettingsCard'
import { formatDate } from '../lib/utils'
import { Alert, Button, Card, Field, Modal, StatusBadge } from '../components/ui'
import { errorText } from '../pages/Login'

type Notice = { kind: 'error' | 'success' | 'info'; text: string } | null

// ------------------------------------------------------------- admin user ---
function AdminUserCard({ me, onChange }: { me: AdminMe; onChange: (m: AdminMe) => void }) {
  const { t } = useTranslation()
  const [newEmail, setNewEmail] = useState('')
  const [emailFlow, setEmailFlow] = useState<{ group: string; old: string; new: string } | null>(null)
  const [codeOld, setCodeOld] = useState('')
  const [codeNew, setCodeNew] = useState('')
  const [cur, setCur] = useState('')
  const [pw, setPw] = useState('')
  const [pw2, setPw2] = useState('')
  const [pwFlow, setPwFlow] = useState<{ id: string; to: string } | null>(null)
  const [pwCode, setPwCode] = useState('')
  const [notice, setNotice] = useState<Notice>(null)

  async function run(fn: () => Promise<void>) {
    setNotice(null)
    try {
      await fn()
    } catch (err) {
      setNotice({ kind: 'error', text: errorText(t, err) })
    }
  }

  return (
    <Card title={t('admin.user.title')}>
      <div className="flex flex-col gap-4" data-testid="admin-user-card">
        <p className="text-sm text-slate-300">
          {t('admin.user.signedIn', { user: me.username, email: me.email })}
        </p>
        {!emailFlow ? (
          <form
            className="flex flex-col gap-2 sm:flex-row sm:items-end"
            onSubmit={(e: FormEvent) => {
              e.preventDefault()
              void run(async () => setEmailFlow(await adminCall('POST', '/email/start', { new_email: newEmail })))
            }}
          >
            <div className="flex-1">
              <Field label={t('admin.user.newEmail')} type="email" required value={newEmail} onChange={(e) => setNewEmail(e.target.value)} />
            </div>
            <Button type="submit">{t('admin.user.sendCodes')}</Button>
          </form>
        ) : (
          <form
            className="flex flex-col gap-2"
            onSubmit={(e: FormEvent) => {
              e.preventDefault()
              void run(async () => {
                onChange(await adminCall('POST', '/email/confirm', { group: emailFlow.group, code_old: codeOld, code_new: codeNew }))
                setEmailFlow(null)
                setCodeOld('')
                setCodeNew('')
                setNotice({ kind: 'success', text: t('admin.user.emailChanged') })
              })
            }}
          >
            <Field label={t('admin.user.codeOld', { to: emailFlow.old })} inputMode="numeric" maxLength={6} required value={codeOld}
                   onChange={(e) => setCodeOld(e.target.value)} />
            <Field label={t('admin.user.codeNew', { to: emailFlow.new })} inputMode="numeric" maxLength={6} required value={codeNew}
                   onChange={(e) => setCodeNew(e.target.value)} />
            <div className="flex gap-2">
              <Button type="submit">{t('admin.user.confirmEmail')}</Button>
              <Button type="button" variant="secondary" onClick={() => setEmailFlow(null)}>
                {t('common.cancel')}
              </Button>
            </div>
          </form>
        )}
        {!pwFlow ? (
          <form
            className="flex flex-col gap-2"
            onSubmit={(e: FormEvent) => {
              e.preventDefault()
              if (pw !== pw2) {
                setNotice({ kind: 'error', text: t('admin.password.mismatch') })
                return
              }
              void run(async () => {
                const r = await adminCall<{ challenge_id: string; sent_to: string }>('POST', '/password/start', { current: cur, new: pw })
                setPwFlow({ id: r.challenge_id, to: r.sent_to })
              })
            }}
          >
            <Field label={t('admin.password.current')} type="password" autoComplete="current-password" required value={cur}
                   onChange={(e) => setCur(e.target.value)} />
            <Field label={t('admin.password.new')} type="password" autoComplete="new-password" minLength={12} required value={pw}
                   onChange={(e) => setPw(e.target.value)} hint={t('admin.password.rules')} />
            <Field label={t('admin.password.again')} type="password" autoComplete="new-password" required value={pw2}
                   onChange={(e) => setPw2(e.target.value)} />
            <div>
              <Button type="submit">{t('admin.password.change')}</Button>
            </div>
          </form>
        ) : (
          <form
            className="flex flex-col gap-2 sm:flex-row sm:items-end"
            onSubmit={(e: FormEvent) => {
              e.preventDefault()
              void run(async () => {
                await adminCall('POST', '/password/confirm', { challenge_id: pwFlow.id, code: pwCode })
                setPwFlow(null)
                setCur('')
                setPw('')
                setPw2('')
                setPwCode('')
                setNotice({ kind: 'success', text: t('admin.password.changed') })
              })
            }}
          >
            <div className="flex-1">
              <Field label={t('admin.password.code', { to: pwFlow.to })} inputMode="numeric" maxLength={6} required value={pwCode}
                     onChange={(e) => setPwCode(e.target.value)} />
            </div>
            <Button type="submit">{t('admin.password.confirm')}</Button>
          </form>
        )}
        {notice && <Alert kind={notice.kind}>{notice.text}</Alert>}
      </div>
    </Card>
  )
}

// ---------------------------------------------------------------- domains ---
function DomainsCard() {
  const { t } = useTranslation()
  const [rows, setRows] = useState<DomainRow[]>([])
  const [allowed, setAllowed] = useState<string[]>([])
  const [picked, setPicked] = useState<string>('')
  const [notice, setNotice] = useState<Notice>(null)

  const load = useCallback(async () => {
    const r = await adminCall<{ domains: DomainRow[] }>('GET', '/domains')
    setRows(r.domains)
    setAllowed(r.domains.filter((d) => d.allowed).map((d) => d.domain))
  }, [])
  useEffect(() => {
    void load().catch((err) => setNotice({ kind: 'error', text: errorText(t, err) }))
  }, [load, t])

  const server = rows.filter((d) => d.allowed).map((d) => d.domain).sort()
  const dirty = JSON.stringify([...allowed].sort()) !== JSON.stringify(server)
  const toggle = (d: string) => setAllowed((a) => (a.includes(d) ? a.filter((x) => x !== d) : [...a, d]))
  const inactive = new Set(rows.filter((r) => !r.catalogue_active).map((r) => r.domain))

  function List({ title, items, testId }: { title: string; items: string[]; testId: string }) {
    return (
      <div className="flex-1">
        <p className="mb-1 text-sm text-slate-300">{title}</p>
        <ul className="min-h-[8rem] rounded-md border border-slate-700 p-1" data-testid={testId} role="listbox" aria-label={title}>
          {items.map((d) => (
            <li key={d}>
              <button
                type="button"
                role="option"
                aria-selected={picked === d}
                onClick={() => setPicked(d)}
                onDoubleClick={() => toggle(d)}
                className={`flex min-h-[40px] w-full items-center justify-between rounded px-2 text-left text-sm ${picked === d ? 'bg-slate-700' : 'hover:bg-slate-800'}`}
              >
                <span>{d}</span>
                {inactive.has(d) && <span className="text-xs text-amber-300">{t('admin.domains.inactive')}</span>}
              </button>
            </li>
          ))}
        </ul>
      </div>
    )
  }

  const all = rows.map((r) => r.domain)
  return (
    <Card
      title={t('admin.domains.title')}
      actions={dirty ? <span className="rounded-full border border-amber-600 px-2 py-0.5 text-xs text-amber-200">✎ {t('prefs.unsaved')}</span> : undefined}
    >
      <p className="mb-3 text-xs text-slate-400">{t('admin.domains.hint')}</p>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center" data-testid="domains-card">
        <List title={t('admin.domains.allowed')} items={allowed.slice().sort()} testId="domains-allowed" />
        <div className="flex flex-row justify-center gap-2 sm:flex-col">
          <Button variant="secondary" aria-label={t('admin.domains.deny')} disabled={!allowed.includes(picked)} onClick={() => toggle(picked)}>
            →
          </Button>
          <Button variant="secondary" aria-label={t('admin.domains.allow')} disabled={!picked || allowed.includes(picked)} onClick={() => toggle(picked)}>
            ←
          </Button>
        </div>
        <List title={t('admin.domains.denied')} items={all.filter((d) => !allowed.includes(d)).sort()} testId="domains-denied" />
      </div>
      {notice && <div className="mt-3"><Alert kind={notice.kind}>{notice.text}</Alert></div>}
      <div className="mt-3 flex gap-2">
        <Button
          disabled={!dirty}
          data-testid="domains-update"
          onClick={async () => {
            try {
              const r = await adminCall<{ domains: DomainRow[] }>('PUT', '/domains', { allowed })
              setRows(r.domains)
              setNotice({ kind: 'success', text: t('admin.saved') })
            } catch (err) {
              setNotice({ kind: 'error', text: errorText(t, err) })
            }
          }}
        >
          {t('prefs.update')}
        </Button>
        <Button variant="secondary" disabled={!dirty} onClick={() => setAllowed(server)}>
          {t('prefs.restore')}
        </Button>
      </div>
    </Card>
  )
}

// ---------------------------------------------------------------- logging ---
type Logging = { enabled: boolean; categories: Record<string, boolean>; rotation: 'day' | 'week' | 'month'; retention: number }
const CATS = ['web_login', 'bearer_access', 'mail_actions', 'token_lifecycle', 'admin_changes', 'errors', 'security']

function LoggingCard() {
  const { t } = useTranslation()
  return (
    <SettingsCard<Logging> title={t('admin.logging.title')} group="logging" testId="logging-card">
      {(v, set) => (
        <>
          <label className="inline-flex min-h-[44px] items-center gap-2 text-sm">
            <input type="checkbox" checked={v.enabled} onChange={(e) => set({ enabled: e.target.checked })} />
            {t('admin.logging.enabled')}
          </label>
          {v.enabled && (
            <fieldset className="grid grid-cols-1 gap-1 pl-6 sm:grid-cols-2">
              {CATS.map((c) => (
                <label key={c} className="inline-flex min-h-[40px] items-center gap-2 text-sm">
                  <input type="checkbox" checked={v.categories[c] ?? true}
                         onChange={(e) => set({ categories: { ...v.categories, [c]: e.target.checked } })} />
                  {t(`admin.logging.cat.${c}`)}
                </label>
              ))}
            </fieldset>
          )}
          <p className="text-xs text-slate-400">{t('admin.logging.masterAlways')}</p>
          <div className="grid gap-3 sm:grid-cols-2">
            <Row label={t('admin.logging.rotation')}>
              <select className={inputCls} value={v.rotation} onChange={(e) => set({ rotation: e.target.value as Logging['rotation'] })}>
                {(['day', 'week', 'month'] as const).map((r) => (
                  <option key={r} value={r}>
                    {t(`admin.logging.rotations.${r}`)}
                  </option>
                ))}
              </select>
            </Row>
            <Row label={t('admin.logging.retention')} hint={t('admin.logging.retentionHint')}>
              <input className={inputCls} type="number" min={1} max={3650} value={v.retention}
                     onChange={(e) => set({ retention: Number(e.target.value) })} />
            </Row>
          </div>
        </>
      )}
    </SettingsCard>
  )
}

// ----------------------------------------------------------------- policy ---
type Policy = Record<string, number | boolean>
const NUMBERS: [string, number, number][] = [
  ['max_tokens', 1, 100], ['pat_default_days', 1, 3650], ['pat_idle_days', 1, 30], ['send_rate_recipients', 1, 100000],
  ['send_rate_window', 60, 604800], ['max_message_size', 1024, 2147483647], ['max_attachment_bytes', 0, 104857600],
  ['magic_link_hours', 1, 168], ['resend_base_seconds', 10, 3600], ['max_secondary', 0, 100],
]
const SWITCHES = ['pat_forever_allowed', 'allow_external', 'force_confirm', 'allow_no_confirm', 'master_notify_user']

function PolicyCard() {
  const { t } = useTranslation()
  return (
    <SettingsCard<Policy> title={t('admin.policy.title')} group="user_policy" testId="policy-card">
      {(v, set) => (
        <>
          <div className="grid gap-3 sm:grid-cols-2">
            {NUMBERS.map(([k, lo, hi]) => (
              <Row key={k} label={t(`admin.policy.${k}`)}>
                <input className={inputCls} type="number" min={lo} max={hi} value={Number(v[k])}
                       onChange={(e) => set({ [k]: Number(e.target.value) })} />
              </Row>
            ))}
          </div>
          {SWITCHES.map((k) => (
            <label key={k} className="inline-flex min-h-[40px] items-center gap-2 text-sm">
              <input type="checkbox" checked={Boolean(v[k])} onChange={(e) => set({ [k]: e.target.checked })} />
              {t(`admin.policy.${k}`)}
            </label>
          ))}
        </>
      )}
    </SettingsCard>
  )
}

// ---------------------------------------------------------- service email ---
type ServiceEmail = { transport: 'internal' | 'external'; host: string; port: number; tls: 'none' | 'starttls' | 'implicit';
  verify_tls: boolean; user: string; password?: string; password_set?: boolean; sender?: string }
type TestResult = { ok: boolean; transport: string; steps: { step: string; ok: boolean; detail: string }[]; error: string }

function ServiceEmailCard({ me }: { me: AdminMe }) {
  const { t } = useTranslation()
  const [result, setResult] = useState<TestResult | null>(null)
  const [testing, setTesting] = useState(false)
  return (
    <>
      <SettingsCard<ServiceEmail> title={t('admin.service.title')} group="service_email" testId="service-card">
        {(v, set) => (
          <>
            <p className="text-sm text-slate-300">
              {t('admin.service.sender', { address: me.service_mailbox.address })}{' '}
              <StatusBadge status={me.service_mailbox.active ? 'active' : 'disabled'}
                           label={me.service_mailbox.active ? t('addresses.status.active') : t('admin.service.inactive')} />
            </p>
            {!me.service_mailbox.active && <Alert kind="warning">{t('admin.service.inactiveHint')}</Alert>}
            <fieldset className="flex flex-wrap gap-4 text-sm">
              {(['internal', 'external'] as const).map((tr) => (
                <label key={tr} className="inline-flex min-h-[40px] items-center gap-2">
                  <input type="radio" name="transport" checked={v.transport === tr} onChange={() => set({ transport: tr })} />
                  {t(`admin.service.${tr}`)}
                </label>
              ))}
            </fieldset>
            {v.transport === 'external' && (
              <div className="grid gap-3 sm:grid-cols-2">
                <Row label={t('admin.service.host')}>
                  <input className={inputCls} value={v.host} onChange={(e) => set({ host: e.target.value })} />
                </Row>
                <Row label={t('admin.service.port')}>
                  <input className={inputCls} type="number" min={1} max={65535} value={v.port} onChange={(e) => set({ port: Number(e.target.value) })} />
                </Row>
                <Row label={t('admin.service.tls')}>
                  <select className={inputCls} value={v.tls} onChange={(e) => set({ tls: e.target.value as ServiceEmail['tls'] })}>
                    {(['none', 'starttls', 'implicit'] as const).map((m) => (
                      <option key={m} value={m}>
                        {t(`admin.service.tlsModes.${m}`)}
                      </option>
                    ))}
                  </select>
                </Row>
                {v.tls !== 'none' && (
                  <label className="inline-flex min-h-[40px] items-center gap-2 text-sm sm:col-span-2">
                    <input type="checkbox" checked={v.verify_tls} onChange={(e) => set({ verify_tls: e.target.checked })} />
                    {t('admin.service.verifyTls')}
                  </label>
                )}
                {v.tls !== 'none' && !v.verify_tls && (
                  <div className="sm:col-span-2"><Alert kind="warning">{t('admin.service.verifyOff')}</Alert></div>
                )}
                <Row label={t('admin.service.user')}>
                  <input className={inputCls} value={v.user} autoComplete="off" onChange={(e) => set({ user: e.target.value })} />
                </Row>
                <Row label={t('admin.service.password')} hint={v.password_set ? t('admin.service.passwordKept') : undefined}>
                  <input className={inputCls} type="password" autoComplete="new-password" value={v.password ?? ''}
                         onChange={(e) => set({ password: e.target.value })} />
                </Row>
              </div>
            )}
          </>
        )}
      </SettingsCard>
      <Card title={t('admin.service.testTitle')}>
        <p className="mb-3 text-sm text-slate-300">{t('admin.service.testHint', { to: me.email })}</p>
        <Button
          disabled={testing}
          data-testid="service-test"
          onClick={async () => {
            setTesting(true)
            try {
              setResult(await adminCall<TestResult>('POST', '/service-email/test'))
            } finally {
              setTesting(false)
            }
          }}
        >
          {testing ? t('admin.service.testing') : t('admin.service.test')}
        </Button>
        {result && (
          <div className="mt-3 flex flex-col gap-1" data-testid="service-test-result">
            <Alert kind={result.ok ? 'success' : 'error'}>{result.ok ? t('admin.service.testOk') : t('admin.service.testFail')}</Alert>
            <ul className="text-xs text-slate-300">
              {result.steps.map((s, i) => (
                <li key={i}>
                  <span aria-hidden="true">{s.ok ? '✓' : '✕'}</span> <code>{s.step}</code> — {s.detail}
                </li>
              ))}
            </ul>
          </div>
        )}
      </Card>
    </>
  )
}

// ---------------------------------------------------------- master tokens ---
function MasterTokensCard({ me }: { me: AdminMe }) {
  const { t, i18n } = useTranslation()
  const [tab, setTab] = useState<'active' | 'disabled' | 'revoked'>('active')
  const [items, setItems] = useState<MasterToken[]>([])
  const [name, setName] = useState('')
  const [ttl, setTtl] = useState(24)
  const [scopes, setScopes] = useState<string[]>(['mail.read'])
  const [cidrs, setCidrs] = useState('')
  const [created, setCreated] = useState('')
  const [revoking, setRevoking] = useState<MasterToken | null>(null)
  const [notice, setNotice] = useState<Notice>(null)

  const load = useCallback(async () => {
    setItems((await adminCall<{ tokens: MasterToken[] }>('GET', '/master-tokens')).tokens)
  }, [])
  useEffect(() => {
    void load()
  }, [load])

  async function act(tok: MasterToken, action: string) {
    try {
      await adminCall('POST', `/master-tokens/${tok.id}/${action}`)
      await load()
    } catch (err) {
      setNotice({ kind: 'error', text: errorText(t, err) })
    }
  }

  return (
    <Card title={t('admin.master.title')}>
      <p className="mb-3 text-xs text-slate-400">{t('admin.master.hint')}</p>
      <form
        className="flex flex-col gap-3 rounded-md border border-slate-800 p-3"
        data-testid="master-form"
        onSubmit={async (e: FormEvent) => {
          e.preventDefault()
          setNotice(null)
          try {
            const r = await adminCall<MasterToken & { token: string }>('POST', '/master-tokens', {
              name, ttl_hours: ttl, scopes,
              allowed_cidrs: cidrs.split(',').map((c) => c.trim()).filter(Boolean),
            })
            setCreated(r.token)
            setName('')
            await load()
          } catch (err) {
            setNotice({ kind: 'error', text: errorText(t, err) })
          }
        }}
      >
        <Field label={t('tokens.name')} required maxLength={100} value={name} onChange={(e) => setName(e.target.value)} />
        <Field label={t('admin.master.ttl', { max: me.master_token_max_hours })} type="number" min={1} max={me.master_token_max_hours}
               value={ttl} onChange={(e) => setTtl(Number(e.target.value))} />
        <fieldset className="flex flex-wrap gap-3">
          <legend className="text-sm text-slate-300">{t('tokens.scopes')}</legend>
          {['mail.read', 'mail.modify', 'mail.trash', 'mail.send'].map((s) => (
            <label key={s} className="inline-flex min-h-[40px] items-center gap-2 text-sm">
              <input type="checkbox" checked={scopes.includes(s)}
                     onChange={() => setScopes(scopes.includes(s) ? scopes.filter((x) => x !== s) : [...scopes, s])} />
              <code>{s}</code>
            </label>
          ))}
        </fieldset>
        <Field label={t('admin.master.cidrs')} placeholder="10.0.0.0/8, 192.0.2.10/32" value={cidrs} onChange={(e) => setCidrs(e.target.value)}
               hint={t('admin.master.cidrsHint')} />
        <div>
          <Button type="submit" disabled={!name.trim() || scopes.length === 0}>
            {t('admin.master.create')}
          </Button>
        </div>
      </form>
      {created && (
        <div className="mt-3 flex flex-col gap-2" data-testid="master-created">
          <Alert kind="warning">{t('admin.master.showOnce')}</Alert>
          <code className="break-all rounded-md border border-slate-700 bg-slate-950 p-3 text-xs" data-testid="master-value">{created}</code>
          <p className="text-xs text-slate-400">{t('admin.master.howTo')}</p>
          <Button variant="ghost" onClick={() => setCreated('')}>{t('tokens.dismiss')}</Button>
        </div>
      )}
      {notice && <div className="mt-3"><Alert kind={notice.kind}>{notice.text}</Alert></div>}
      <div className="mt-4 flex gap-1" role="tablist">
        {(['active', 'disabled', 'revoked'] as const).map((k) => (
          <button key={k} role="tab" aria-selected={tab === k} onClick={() => setTab(k)}
                  className={`min-h-[40px] rounded-t-md px-3 text-sm ${tab === k ? 'bg-slate-800 text-white' : 'text-slate-400 hover:bg-slate-900'}`}>
            {t(`tokens.status.${k}`)} ({items.filter((i) => i.status === k).length})
          </button>
        ))}
      </div>
      <ul className="divide-y divide-slate-800 border-t border-slate-800" data-testid="master-list" role="tabpanel">
        {items.filter((i) => i.status === tab).map((tok) => (
          <li key={tok.id} className={`flex flex-wrap items-center justify-between gap-2 py-3 ${tok.status === 'revoked' ? 'opacity-60' : ''}`}>
            <div className="min-w-0 text-sm">
              <p className="font-medium">{tok.name} <code className="text-xs text-slate-400">{tok.display}</code></p>
              <p className="text-xs text-slate-400">
                {tok.scopes.join(', ')} · {t('tokens.expires')}: {formatDate(tok.expires_at, i18n.language)}
                {tok.allowed_cidrs.length > 0 && ` · ${tok.allowed_cidrs.join(', ')}`}
                {tok.last_used_at && ` · ${t('tokens.lastUsed')}: ${formatDate(tok.last_used_at, i18n.language)}`}
              </p>
            </div>
            {tok.status !== 'revoked' && (
              <div className="flex gap-2">
                <Button variant="secondary" onClick={() => act(tok, tok.status === 'active' ? 'disable' : 'enable')}>
                  {tok.status === 'active' ? t('tokens.disable') : t('tokens.enable')}
                </Button>
                <Button variant="danger" onClick={() => setRevoking(tok)}>{t('tokens.revoke')}</Button>
              </div>
            )}
          </li>
        ))}
      </ul>
      {revoking && (
        <Modal title={t('tokens.revokeTitle')} onClose={() => setRevoking(null)}>
          <p className="text-sm text-slate-300">{t('tokens.revokeBody', { name: revoking.name })}</p>
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={() => setRevoking(null)}>{t('common.cancel')}</Button>
            <Button variant="danger" onClick={() => { const tok = revoking; setRevoking(null); void act(tok, 'revoke') }}>
              {t('tokens.revoke')}
            </Button>
          </div>
        </Modal>
      )}
    </Card>
  )
}

// ------------------------------------------------------------------- logs ---
function LogsCard() {
  const { t } = useTranslation()
  const [kind, setKind] = useState<'audit' | 'access' | 'errors'>('audit')
  const [q, setQ] = useState('')
  const [items, setItems] = useState<Record<string, unknown>[]>([])
  const load = useCallback(async () => {
    setItems((await adminCall<{ items: Record<string, unknown>[] }>('GET', `/logs?kind=${kind}&q=${encodeURIComponent(q)}&limit=200`)).items)
  }, [kind, q])
  useEffect(() => {
    void load()
  }, [load])
  return (
    <Card title={t('admin.logs.title')}>
      <div className="mb-3 flex flex-col gap-2 sm:flex-row">
        <select aria-label={t('admin.logs.kind')} className={`${inputCls} sm:w-40`} value={kind} onChange={(e) => setKind(e.target.value as typeof kind)}>
          {(['audit', 'access', 'errors'] as const).map((k) => (
            <option key={k} value={k}>{t(`admin.logs.kinds.${k}`)}</option>
          ))}
        </select>
        <input aria-label={t('admin.logs.filter')} placeholder={t('admin.logs.filter')} className={inputCls} value={q} onChange={(e) => setQ(e.target.value)} />
        <Button variant="secondary" onClick={load}>{t('activity.refresh')}</Button>
      </div>
      <ul className="max-h-96 overflow-auto font-mono text-xs" data-testid="logs-list">
        {items.length === 0 && <li className="text-slate-400">{t('activity.none')}</li>}
        {items.map((it, i) => (
          <li key={i} className="break-all border-b border-slate-900 py-1 text-slate-300">
            {String(it.ts ?? '')} {String(it.category ?? it.method ?? '')} {String(it.event ?? it.path ?? '')}{' '}
            {String(it.result ?? it.status ?? '')} {it.ip ? `· ${String(it.ip)}` : ''}
          </li>
        ))}
      </ul>
    </Card>
  )
}

export default function Panel({ me, onChange, onLogout }: { me: AdminMe; onChange: (m: AdminMe) => void; onLogout: () => void }) {
  const { t, i18n } = useTranslation()
  return (
    <div className="mx-auto flex w-full max-w-4xl flex-col gap-4 px-4 py-6">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">{t('admin.title')}</h1>
          <p className="text-sm text-slate-400">{me.username} · {me.email}</p>
        </div>
        <div className="flex items-center gap-2">
          <select aria-label={t('account.language')} value={i18n.language.startsWith('es') ? 'es' : 'en'}
                  onChange={(e) => void i18n.changeLanguage(e.target.value)} className="min-h-[44px] rounded-md border border-slate-700 bg-slate-900 px-2 text-sm">
            <option value="en">English</option>
            <option value="es">Español</option>
          </select>
          <Button variant="secondary" onClick={onLogout} data-testid="admin-logout">{t('account.logout')}</Button>
        </div>
      </header>
      <AdminUserCard me={me} onChange={onChange} />
      <DomainsCard />
      <LoggingCard />
      <PolicyCard />
      <MasterTokensCard me={me} />
      <ServiceEmailCard me={me} />
      <LogsCard />
    </div>
  )
}
