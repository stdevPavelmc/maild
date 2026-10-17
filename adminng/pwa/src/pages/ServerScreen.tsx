/**
 * Server URL onboarding (bundled builds, e.g. an APK that ships its own assets).
 *
 * The web deployment is same-origin and never sees this screen: `adminng`'s nginx
 * proxies /api/v1/. A build with `VITE_REQUIRE_SERVER_URL=1` starts with no base
 * URL, so the first run asks for it and probes `/api/v1/health` before saving.
 * The same form is reused from Settings to point the app at another server.
 */

import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { clearSession, probeServer, setBaseUrl } from '../lib/api'
import { db } from '../lib/cache'
import { Button } from '../components/ui/button'
import { ErrorBanner, Field, Input } from '../components/kit'

export function ServerForm({
  onSaved,
  submitLabel,
}: {
  onSaved: () => void
  submitLabel?: string
}) {
  const { t } = useTranslation()
  const [url, setUrl] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async (event: React.FormEvent): Promise<void> => {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      // Empty means "the origin this app was served from".
      await probeServer(url)
      clearSession()
      setBaseUrl(url)
      try {
        await db.delete()
      } catch {
        // The offline log cache is disposable.
      }
      onSaved()
    } catch {
      setError(t('server.fail'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form className="space-y-3" onSubmit={(event) => void submit(event)}>
      <ErrorBanner message={error} />
      <Field label={t('server.url')}>
        <Input
          type="url"
          inputMode="url"
          autoComplete="url"
          placeholder="https://admin.example.com"
          value={url}
          onChange={(event) => setUrl(event.target.value)}
        />
      </Field>
      <Button type="submit" className="w-full" disabled={busy}>
        {busy ? t('server.testing') : (submitLabel ?? t('server.test'))}
      </Button>
    </form>
  )
}

export function ServerScreen({ onSaved }: { onSaved: () => void }) {
  const { t } = useTranslation()

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-950 p-6">
      <div className="w-full max-w-md space-y-4 rounded-2xl border border-slate-800 bg-slate-900/60 p-6">
        <h1 className="text-lg font-semibold">🖥️ {t('server.title')}</h1>
        <p className="text-sm text-slate-400">{t('server.body')}</p>
        <ServerForm onSaved={onSaved} />
      </div>
    </div>
  )
}
