import 'altcha'
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { adminPublic, adminVerify, type AdminMe } from './api'
import { Alert, Button, Field } from '../components/ui'
import { errorText } from '../pages/Login'

/** The ALTCHA widget; `reset` changes its key after a failure (a solution is single-use). */
function Captcha({ onSolved, resetKey }: { onSolved: (p: string) => void; resetKey: number }) {
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = box.current?.querySelector('altcha-widget')
    if (!el) return
    const onState = (ev: Event) => {
      const d = (ev as CustomEvent<{ state: string; payload?: string }>).detail
      onSolved(d.state === 'verified' && d.payload ? d.payload : '')
    }
    el.addEventListener('statechange', onState)
    return () => el.removeEventListener('statechange', onState)
  }, [resetKey, onSolved])
  return (
    <div key={resetKey} ref={box}>
      <altcha-widget challengeurl="/webapi/altcha/challenge" hidelogo hidefooter />
    </div>
  )
}

function Frame({ title, children }: { title: string; children: React.ReactNode }) {
  const { t } = useTranslation()
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center gap-6 px-4 py-10">
      <header className="text-center">
        <h1 className="text-2xl font-semibold">{t('admin.title')}</h1>
        <p className="mt-1 text-sm text-slate-400">{title}</p>
      </header>
      <div className="flex flex-col gap-4 rounded-lg border border-slate-800 bg-slate-900/70 p-5">{children}</div>
    </main>
  )
}

export function AdminLogin({ onLogin }: { onLogin: (me: AdminMe) => void }) {
  const { t } = useTranslation()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [captcha, setCaptcha] = useState('')
  const [captchaKey, setCaptchaKey] = useState(0)
  const [challenge, setChallenge] = useState<{ id: string; to: string } | null>(null)
  const [code, setCode] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function step1(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError('')
    try {
      const r = await adminPublic<{ challenge_id: string; sent_to: string }>('POST', '/login', { username, password, altcha: captcha })
      setChallenge({ id: r.challenge_id, to: r.sent_to })
    } catch (err) {
      setError(errorText(t, err))
      setCaptcha('')
      setCaptchaKey((k) => k + 1)
    } finally {
      setBusy(false)
    }
  }

  async function step2(e: FormEvent) {
    e.preventDefault()
    if (!challenge) return
    setBusy(true)
    setError('')
    try {
      onLogin(await adminVerify(challenge.id, code))
    } catch (err) {
      setError(errorText(t, err))
    } finally {
      setBusy(false)
    }
  }

  if (challenge) {
    return (
      <Frame title={t('admin.login.codeTitle')}>
        <form onSubmit={step2} className="flex flex-col gap-4">
          <p className="text-sm text-slate-300">{t('admin.login.codeSent', { to: challenge.to })}</p>
          <Field label={t('admin.login.code')} inputMode="numeric" autoComplete="one-time-code" maxLength={6} required
                 value={code} onChange={(e) => setCode(e.target.value)} />
          {error && <Alert>{error}</Alert>}
          <Button type="submit" disabled={busy || code.length !== 6} data-testid="admin-code-submit">
            {t('admin.login.verify')}
          </Button>
        </form>
      </Frame>
    )
  }
  return (
    <Frame title={t('admin.login.subtitle')}>
      <form onSubmit={step1} className="flex flex-col gap-4">
        <Field label={t('admin.login.username')} autoComplete="username" required value={username} onChange={(e) => setUsername(e.target.value)} />
        <Field label={t('login.password')} type="password" autoComplete="current-password" required value={password}
               onChange={(e) => setPassword(e.target.value)} />
        <Captcha onSolved={setCaptcha} resetKey={captchaKey} />
        {error && <Alert>{error}</Alert>}
        <Button type="submit" disabled={busy || !captcha} data-testid="admin-login-submit">
          {t('login.signIn')}
        </Button>
        <Link to="/recover" className="text-center text-sm text-blue-300 underline">
          {t('admin.login.forgot')}
        </Link>
      </form>
    </Frame>
  )
}

export function AdminRecover() {
  const { t } = useTranslation()
  const [email, setEmail] = useState('')
  const [captcha, setCaptcha] = useState('')
  const [captchaKey, setCaptchaKey] = useState(0)
  const [done, setDone] = useState(false)
  const [error, setError] = useState('')

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError('')
    try {
      await adminPublic('POST', '/recover', { email, altcha: captcha })
      setDone(true)
    } catch (err) {
      setError(errorText(t, err))
      setCaptchaKey((k) => k + 1)
    }
  }

  return (
    <Frame title={t('admin.recover.title')}>
      {done ? (
        <Alert kind="info">{t('admin.recover.sent')}</Alert>
      ) : (
        <form onSubmit={submit} className="flex flex-col gap-4">
          <Field label={t('admin.recover.email')} type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          <Captcha onSolved={setCaptcha} resetKey={captchaKey} />
          {error && <Alert>{error}</Alert>}
          <Button type="submit" disabled={!captcha}>
            {t('admin.recover.send')}
          </Button>
        </form>
      )}
      <Link to="/" className="text-center text-sm text-blue-300 underline">
        {t('admin.recover.back')}
      </Link>
    </Frame>
  )
}

export function AdminReset() {
  const { t } = useTranslation()
  const [token] = useState(() => window.location.hash.replace(/^#/, ''))
  const [password, setPassword] = useState('')
  const [again, setAgain] = useState('')
  const [captcha, setCaptcha] = useState('')
  const [captchaKey, setCaptchaKey] = useState(0)
  const [done, setDone] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (window.location.hash) history.replaceState(null, '', window.location.pathname)
  }, [])

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError('')
    if (password !== again) {
      setError(t('admin.password.mismatch'))
      return
    }
    try {
      await adminPublic('POST', '/reset', { token, password, altcha: captcha })
      setDone(true)
    } catch (err) {
      setError(errorText(t, err))
      setCaptchaKey((k) => k + 1)
    }
  }

  return (
    <Frame title={t('admin.reset.title')}>
      {done ? (
        <Alert kind="success">{t('admin.reset.done')}</Alert>
      ) : (
        <form onSubmit={submit} className="flex flex-col gap-4">
          <Field label={t('admin.password.new')} type="password" autoComplete="new-password" minLength={12} required
                 value={password} onChange={(e) => setPassword(e.target.value)} hint={t('admin.password.rules')} />
          <Field label={t('admin.password.again')} type="password" autoComplete="new-password" required value={again}
                 onChange={(e) => setAgain(e.target.value)} />
          <Captcha onSolved={setCaptcha} resetKey={captchaKey} />
          {error && <Alert>{error}</Alert>}
          <Button type="submit" disabled={!captcha || !token}>
            {t('admin.reset.submit')}
          </Button>
        </form>
      )}
      <Link to="/" className="text-center text-sm text-blue-300 underline">
        {t('admin.recover.back')}
      </Link>
    </Frame>
  )
}
