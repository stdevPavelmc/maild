import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../store/AuthContext'
import { Button } from '../components/ui/button'
import { ErrorBanner, Field, Input, Modal } from '../components/kit'

export function PendingScreen() {
  const { t } = useTranslation()
  const { device, deviceStatus, logout } = useAuth()
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    const timer = window.setInterval(() => void deviceStatus(), 10_000)
    return () => window.clearInterval(timer)
  }, [deviceStatus])

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-950 p-6">
      <div className="w-full max-w-md space-y-4 rounded-2xl border border-slate-800 bg-slate-900/60 p-6">
        <h1 className="text-lg font-semibold">🔐 {t('device.pendingTitle')}</h1>
        <p className="text-sm text-slate-400">{t('device.pendingBody')}</p>
        <p className="text-xs uppercase tracking-wide text-slate-500">{t('device.id')}</p>
        <div className="flex items-center gap-2">
          <code className="flex-1 truncate rounded bg-slate-800 px-2 py-1 text-xs">{device}</code>
          <Button
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
        <div className="flex gap-2">
          <Button onClick={() => void deviceStatus()}>{t('device.check')}</Button>
          <Button variant="outline" onClick={() => void logout()}>
            {t('login.logout')}
          </Button>
        </div>
      </div>
    </div>
  )
}

export function PrivacyShield() {
  const { t } = useTranslation()
  const { unlock, busy } = useAuth()
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)

  const run = async (): Promise<void> => {
    setError(null)
    try {
      await unlock(password)
      setPassword('')
    } catch {
      setError(t('login.wrong'))
    }
  }

  return (
    <Modal open title={t('privacy.title')} onClose={() => undefined}>
      <p className="text-sm text-slate-300">{t('privacy.body')}</p>
      <ErrorBanner message={error} />
      <Field label={t('login.password')}>
        <Input
          type="password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
        />
      </Field>
      <Button className="w-full" disabled={busy} onClick={() => void run()}>
        {t('privacy.unlock')}
      </Button>
    </Modal>
  )
}
