import { useState } from 'react'
import { QRCodeSVG } from 'qrcode.react'
import { useTranslation } from 'react-i18next'
import { deviceId, loadRememberPreference, loadUsername, saveRememberPreference, saveUsername } from '../lib/api'
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
            : code === 'biometric'
              ? t('login.biometricFailed')
            : t('login.network')
  return <ErrorBanner message={text} />
}

export function LoginPage() {
  const { t } = useTranslation()
  const { phase, login, loginBiometric, submitCode, enroll, enrollment, loginError, busy } = useAuth()
  const [username, setUsername] = useState(loadUsername() ?? '')
  const [password, setPassword] = useState('')
  const [code, setCode] = useState('')
  const [remember, setRemember] = useState(loadRememberPreference)
  const [copied, setCopied] = useState(false)
  const device = deviceId()

  const submitPassword = (event: React.FormEvent): void => {
    event.preventDefault()
    saveUsername(username)
    void login(username, password, remember)
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
            <label className="flex items-center gap-2 text-sm text-slate-300">
              <input
                type="checkbox"
                checked={remember}
                onChange={(event) => {
                  const checked = event.target.checked
                  setRemember(checked)
                  saveRememberPreference(checked)
                }}
                className="h-4 w-4 accent-blue-600"
              />
              {t('login.remember')}
            </label>
            <Button type="submit" className="w-full" disabled={busy}>
              {t('login.submit')}
            </Button>
            {username.trim().length >= 3 && typeof PublicKeyCredential !== 'undefined' && (
              <Button
                type="button"
                variant="outline"
                className="w-full"
                disabled={busy}
                onClick={() => {
                  saveUsername(username)
                  void loginBiometric(username, remember)
                }}
              >
                {t('login.biometric')}
              </Button>
            )}
          </form>
        )}

        {phase === 'login' && (
          <details className="rounded-lg border border-slate-800 bg-slate-900/40 p-3 text-xs text-slate-400">
            <summary className="cursor-pointer select-none">{t('device.identityTitle')}</summary>
            <p className="mt-2">{t('device.identityBody')}</p>
            <div className="mt-2 flex items-center gap-2">
              <code className="flex-1 truncate rounded bg-slate-800 px-2 py-1">{device}</code>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => {
                  void navigator.clipboard.writeText(device)
                  setCopied(true)
                  window.setTimeout(() => setCopied(false), 1500)
                }}
              >
                {copied ? '✓' : t('device.copy')}
              </Button>
            </div>
          </details>
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
