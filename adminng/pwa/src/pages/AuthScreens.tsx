import { useState } from 'react'
import { QRCodeSVG } from 'qrcode.react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../store/AuthContext'
import { Button } from '../components/ui/button'
import { ErrorBanner, Field, Input } from '../components/kit'

function ErrorText({ code }: { code: string | null }) {
  const { t } = useTranslation()
  if (!code) return null
  const text =
    code === 'wrong'
      ? t('login.wrong')
      : code === 'badCode'
        ? t('login.badCode')
        : code === 'RATE_LIMITED'
          ? t('login.rateLimited')
          : code === 'revoked'
            ? t('device.revoked')
            : t('login.network')
  return <ErrorBanner message={text} />
}

export function LoginPage() {
  const { t } = useTranslation()
  const { phase, login, submitCode, enroll, enrollment, loginError, busy } = useAuth()
  const [username, setUsername] = useState(localStorage.getItem('adminng.username') ?? '')
  const [password, setPassword] = useState('')
  const [code, setCode] = useState('')

  const submitPassword = (event: React.FormEvent): void => {
    event.preventDefault()
    localStorage.setItem('adminng.username', username)
    void login(username, password)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-950 p-6">
      <div className="w-full max-w-sm space-y-5 rounded-2xl border border-slate-800 bg-slate-900/60 p-6">
        <header>
          <h1 className="text-xl font-semibold">{t('app.title')}</h1>
          <p className="text-xs text-slate-400">{t('app.subtitle')}</p>
        </header>
        <ErrorText code={loginError} />

        {phase === 'login' && (
          <form className="space-y-3" onSubmit={submitPassword}>
            <Field label={t('login.username')}>
              <Input
                value={username}
                onChange={(event) => setUsername(event.target.value)}
                autoComplete="username"
              />
            </Field>
            <Field label={t('login.password')}>
              <Input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete="current-password"
              />
            </Field>
            <Button type="submit" className="w-full" disabled={busy}>
              {t('login.submit')}
            </Button>
          </form>
        )}

        {phase === 'twofa' && (
          <form
            className="space-y-3"
            onSubmit={(event) => {
              event.preventDefault()
              void submitCode(code)
            }}
          >
            <Field label={t('login.code')}>
              <Input
                inputMode="numeric"
                maxLength={8}
                value={code}
                onChange={(event) => setCode(event.target.value)}
              />
            </Field>
            <Button type="submit" className="w-full" disabled={busy}>
              {t('login.verify')}
            </Button>
          </form>
        )}

        {phase === 'enroll' && enrollment && (
          <form
            className="space-y-3"
            onSubmit={(event) => {
              event.preventDefault()
              void enroll(code)
            }}
          >
            <p className="text-sm text-slate-300">{t('enroll.body')}</p>
            <div className="flex justify-center rounded-lg bg-white p-3">
              <QRCodeSVG value={enrollment.otpauth_uri} size={168} />
            </div>
            <p className="break-all text-center font-mono text-xs text-slate-400">
              {enrollment.secret}
            </p>
            <Field label={t('enroll.code')}>
              <Input
                inputMode="numeric"
                maxLength={8}
                value={code}
                onChange={(event) => setCode(event.target.value)}
              />
            </Field>
            <Button type="submit" className="w-full" disabled={busy}>
              {t('enroll.confirm')}
            </Button>
          </form>
        )}
      </div>
    </div>
  )
}
