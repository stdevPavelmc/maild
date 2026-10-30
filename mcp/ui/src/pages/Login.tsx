import 'altcha'
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { ApiError, login, type Account } from '../lib/api'
import { Alert, Button, Field } from '../components/ui'

/** Error codes from mcpcore/accounts.py + webapi/api.py, translated by code (errors.*). */
export function errorText(t: (k: string, o?: Record<string, unknown>) => string, err: unknown): string {
  if (err instanceof ApiError) {
    const key = `errors.${err.code}`
    const text = t(key, { seconds: err.retryAfter ?? 0 })
    return text === key ? err.message : text
  }
  return t('errors.network')
}

export default function Login({ onLogin }: { onLogin: (a: Account) => void }) {
  const { t } = useTranslation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [captcha, setCaptcha] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [widgetKey, setWidgetKey] = useState(0)
  const widgetBox = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const el = widgetBox.current?.querySelector('altcha-widget')
    if (!el) return
    const onState = (ev: Event) => {
      const detail = (ev as CustomEvent<{ state: string; payload?: string }>).detail
      setCaptcha(detail.state === 'verified' && detail.payload ? detail.payload : '')
    }
    el.addEventListener('statechange', onState)
    return () => el.removeEventListener('statechange', onState)
  }, [widgetKey])

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError('')
    try {
      onLogin(await login(email, password, captcha))
    } catch (err) {
      setError(errorText(t, err))
      // a solved challenge is single-use: hand out a fresh widget after any failure
      setCaptcha('')
      setWidgetKey((k) => k + 1)
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center gap-6 px-4 py-10">
      <header className="text-center">
        <h1 className="text-2xl font-semibold">{t('app.title')}</h1>
        <p className="mt-1 text-sm text-slate-400">{t('login.subtitle')}</p>
      </header>
      <form onSubmit={submit} className="flex flex-col gap-4 rounded-lg border border-slate-800 bg-slate-900/70 p-5">
        <Field
          label={t('login.email')}
          type="email"
          autoComplete="username"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
        <Field
          label={t('login.password')}
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          hint={t('login.passwordHint')}
        />
        {/* re-keyed after a failed login: a solved challenge is single-use */}
        <div key={widgetKey} ref={widgetBox}>
          <altcha-widget challengeurl="/webapi/altcha/challenge" hidelogo hidefooter />
        </div>
        {error && <Alert>{error}</Alert>}
        <Button type="submit" disabled={busy || !captcha} data-testid="login-submit">
          {busy ? t('login.signingIn') : t('login.signIn')}
        </Button>
      </form>
    </main>
  )
}
