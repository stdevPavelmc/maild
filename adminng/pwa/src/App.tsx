import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from './components/ui/button'

type Health = {
  status: string
  service: string
  version: string
  database: string
}

/**
 * Phase 0 shell: proves the chain end to end — the PWA is served by the
 * `adminng` nginx container, which proxies /api/v1/ to the `api` (FastAPI)
 * service, which in turn reaches Postgres and the migrated adminng database.
 * The real shells/screens land in Phase 3.
 */
export default function App() {
  const { t, i18n } = useTranslation()
  const [health, setHealth] = useState<Health | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    fetch('/api/v1/health')
      .then(async (response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return (await response.json()) as Health
      })
      .then(setHealth)
      .catch(() => setFailed(true))
  }, [])

  const changeLanguage = (language: string) => {
    void i18n.changeLanguage(language)
  }

  return (
    <main className="min-h-screen bg-slate-950 text-slate-100">
      <div className="mx-auto flex max-w-3xl flex-col gap-8 px-6 py-16">
        <header className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">{t('app.title')}</h1>
            <p className="mt-2 text-slate-400">{t('app.subtitle')}</p>
          </div>
          <div className="flex items-center gap-2" aria-label={t('language')}>
            <Button variant={i18n.language.startsWith('es') ? 'default' : 'outline'} size="sm" onClick={() => changeLanguage('es')}>
              ES
            </Button>
            <Button variant={i18n.language.startsWith('en') ? 'default' : 'outline'} size="sm" onClick={() => changeLanguage('en')}>
              EN
            </Button>
          </div>
        </header>

        <section className="rounded-xl border border-slate-800 bg-slate-900/60 p-6">
          <h2 className="text-sm font-medium uppercase tracking-wide text-slate-400">API</h2>
          <p className="mt-3 text-lg">
            {health ? t('health.ok') : failed ? t('health.fail') : t('health.checking')}
          </p>
          {health && (
            <dl className="mt-4 grid grid-cols-2 gap-2 text-sm text-slate-300">
              <dt>{t('health.database')}</dt>
              <dd className="font-mono">{health.database}</dd>
              <dt>service</dt>
              <dd className="font-mono">{health.service}</dd>
              <dt>version</dt>
              <dd className="font-mono">{health.version}</dd>
            </dl>
          )}
        </section>

        <p className="text-sm text-slate-500">{t('phase0')}</p>
      </div>
    </main>
  )
}
