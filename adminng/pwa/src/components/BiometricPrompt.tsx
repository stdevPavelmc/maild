import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ApiError,
  api,
  type WebAuthnStatus,
} from '../lib/api'
import { createPlatformCredential } from '../lib/webauthn'
import { ErrorBanner, Field, Input } from '../components/kit'
import { Button } from '../components/ui/button'

/**
 * One-time offer to enable biometric sign-in on this device, shown right after
 * the first successful login. WebAuthn registration is password-gated (the same
 * proof Settings asks for), so the banner keeps an inline password field and can
 * be dismissed for good. Settings keeps the same control at any time.
 */

const DISMISS_KEY = 'adminng.biometricPromptDismissed'

export function BiometricPrompt() {
  const { t } = useTranslation()
  const [status, setStatus] = useState<WebAuthnStatus | null>(null)
  const [dismissed, setDismissed] = useState(
    () => localStorage.getItem(DISMISS_KEY) === 'true',
  )
  const [open, setOpen] = useState(false)
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (dismissed || typeof PublicKeyCredential === 'undefined') return
    let alive = true
    void api.webauthnStatus().then(
      (result) => {
        if (alive) setStatus(result)
      },
      () => {
        if (alive) setStatus(null)
      },
    )
    return () => {
      alive = false
    }
  }, [dismissed])

  const candidate =
    !dismissed && typeof PublicKeyCredential !== 'undefined' && status?.configured === true
  const needsEnrollment = candidate && status?.enabled === false

  const dismiss = (): void => {
    localStorage.setItem(DISMISS_KEY, 'true')
    setDismissed(true)
  }

  const enable = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    try {
      const options = await api.webauthnRegistrationOptions(password)
      const credential = await createPlatformCredential(options.public_key)
      await api.webauthnRegistrationVerify(options.challenge_id, credential)
      setStatus((current) => (current ? { ...current, enabled: true } : current))
      setPassword('')
      setOpen(false)
      dismiss()
    } catch (err) {
      setError(
        err instanceof ApiError ? `${err.code}: ${err.message}` : t('settings.biometricFailure'),
      )
    } finally {
      setBusy(false)
    }
  }

  if (!needsEnrollment) return null

  return (
    <section className="mb-4 rounded-lg border border-slate-700 bg-slate-900/60 p-3 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <p className="font-medium">🔒 {t('biometricPrompt.title')}</p>
          <p className="text-xs text-slate-400">{t('biometricPrompt.body')}</p>
        </div>
        <div className="flex shrink-0 gap-2">
          <Button size="sm" onClick={() => setOpen((current) => !current)} disabled={busy}>
            {t('biometricPrompt.enable')}
          </Button>
          <Button variant="outline" size="sm" onClick={dismiss} disabled={busy}>
            {t('biometricPrompt.later')}
          </Button>
        </div>
      </div>
      {open && (
        <div className="mt-3 max-w-sm space-y-2">
          <ErrorBanner message={error} />
          <Field label={t('login.password')}>
            <Input
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
          </Field>
          <Button
            size="sm"
            className="w-full"
            onClick={() => void enable()}
            disabled={busy || password.length === 0}
          >
            {busy ? t('common.loading') : t('biometricPrompt.confirm')}
          </Button>
        </div>
      )}
    </section>
  )
}
