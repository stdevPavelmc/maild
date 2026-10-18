import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../store/AuthContext'
import { ApiError, api, getBaseUrl, type WebAuthnStatus } from '../lib/api'
import { createPlatformCredential } from '../lib/webauthn'
import { ErrorBanner, Field, Input, SectionHeader } from '../components/kit'
import { Button } from '../components/ui/button'
import { ServerForm } from './ServerScreen'

export function SettingsPage() {
  const { t, i18n } = useTranslation()
  const { user, device, logout } = useAuth()
  const [biometric, setBiometric] = useState<WebAuthnStatus | null>(null)
  const [biometricLoading, setBiometricLoading] = useState(true)
  const [biometricPassword, setBiometricPassword] = useState('')
  const [biometricError, setBiometricError] = useState<string | null>(null)
  const [biometricBusy, setBiometricBusy] = useState(false)

  useEffect(() => {
    let mounted = true
    void api.webauthnStatus().then(
      (status) => {
        if (mounted) {
          setBiometric(status)
          setBiometricLoading(false)
        }
      },
      (error: unknown) => {
        if (!mounted) return
        setBiometricLoading(false)
        setBiometricError(
          error instanceof ApiError
            ? `${error.code}: ${error.message}`
            : t('settings.biometricFailure'),
        )
      },
    )
    return () => {
      mounted = false
    }
  }, [t])

  const changeBiometric = async (): Promise<void> => {
    setBiometricBusy(true)
    setBiometricError(null)
    try {
      if (biometric?.enabled) {
        const result = await api.webauthnDisable(biometricPassword)
        setBiometric((current) => current ? { ...current, enabled: result.enabled } : current)
      } else {
        const options = await api.webauthnRegistrationOptions(biometricPassword)
        const credential = await createPlatformCredential(options.public_key)
        const result = await api.webauthnRegistrationVerify(options.challenge_id, credential)
        setBiometric((current) => current ? { ...current, enabled: result.enabled } : current)
      }
      setBiometricPassword('')
    } catch (error) {
      setBiometricError(
        error instanceof ApiError
          ? `${error.code}: ${error.message}`
          : t('settings.biometricFailure'),
      )
    } finally {
      setBiometricBusy(false)
    }
  }

  return (
    <div className="max-w-xl space-y-6">
      <SectionHeader title={t('nav.settings')} />

      <section className="space-y-2 rounded-lg border border-slate-800 p-4">
        <p className="text-xs uppercase tracking-wide text-slate-400">{t('language')}</p>
        <div className="flex gap-2">
          <Button variant={i18n.language.startsWith('en') ? 'default' : 'outline'} size="sm" onClick={() => void i18n.changeLanguage('en')}>English</Button>
          <Button variant={i18n.language.startsWith('es') ? 'default' : 'outline'} size="sm" onClick={() => void i18n.changeLanguage('es')}>Español</Button>
        </div>
      </section>

      <section className="space-y-1 rounded-lg border border-slate-800 p-4 text-sm">
        <p className="text-xs uppercase tracking-wide text-slate-400">{t('login.username')}</p>
        <p>{user?.username} {user?.superadmin ? `(${t('settings.superadmin')})` : ''}</p>
        <p className="text-xs uppercase tracking-wide text-slate-400">{t('device.id')}</p>
        <p className="break-all font-mono text-xs text-slate-400">{device}</p>
      </section>

      <section className="space-y-3 rounded-lg border border-slate-800 p-4 text-sm">
        <h2 className="font-medium">{t('settings.biometricTitle')}</h2>
        <p className="text-slate-400">
          {biometricLoading
            ? t('common.loading')
            : biometric === null
              ? t('settings.biometricFailure')
            : !biometric.configured
              ? t('settings.biometricUnavailable')
              : biometric.enabled
                  ? t('settings.biometricEnabled')
                  : t('settings.biometricDisabled')}
        </p>
        <ErrorBanner message={biometricError} />
        {biometric?.configured && (
          <>
            <Field label={t('settings.biometricPassword')}>
              <Input
                type="password"
                autoComplete="current-password"
                value={biometricPassword}
                onChange={(event) => setBiometricPassword(event.target.value)}
              />
            </Field>
            <Button
              onClick={() => void changeBiometric()}
              disabled={biometricBusy || biometricPassword.length === 0}
            >
              {biometricBusy
                ? t('common.loading')
                : biometric.enabled
                  ? t('settings.biometricDisable')
                  : t('settings.biometricEnable')}
            </Button>
          </>
        )}
      </section>

      <section className="space-y-2 rounded-lg border border-slate-800 p-4 text-sm">
        <p className="text-xs uppercase tracking-wide text-slate-400">{t('server.current')}</p>
        <p className="break-all font-mono text-xs text-slate-400">
          {getBaseUrl() || t('server.sameOrigin')}
        </p>
        <ServerForm onSaved={() => window.location.reload()} submitLabel={t('server.change')} />
        <p className="text-xs text-slate-400">{t('server.warning')}</p>
      </section>

      <section className="space-y-2 rounded-lg border border-slate-800 p-4 text-sm text-slate-400">
        <p>MailD AdminNG · v0.1.0</p>
        <p>{t('app.subtitle')}</p>
      </section>

      <Button variant="outline" onClick={() => void logout()}>{t('login.logout')}</Button>
    </div>
  )
}
