import { useTranslation } from 'react-i18next'
import { useAuth } from '../store/AuthContext'
import { SectionHeader } from '../components/kit'
import { Button } from '../components/ui/button'

export function SettingsPage() {
  const { t, i18n } = useTranslation()
  const { user, device, logout } = useAuth()

  return (
    <div className="max-w-xl space-y-6">
      <SectionHeader title={t('nav.settings')} />

      <section className="space-y-2 rounded-lg border border-slate-800 p-4">
        <p className="text-xs uppercase tracking-wide text-slate-500">{t('language')}</p>
        <div className="flex gap-2">
          <Button variant={i18n.language.startsWith('en') ? 'default' : 'outline'} size="sm" onClick={() => void i18n.changeLanguage('en')}>English</Button>
          <Button variant={i18n.language.startsWith('es') ? 'default' : 'outline'} size="sm" onClick={() => void i18n.changeLanguage('es')}>Español</Button>
        </div>
      </section>

      <section className="space-y-1 rounded-lg border border-slate-800 p-4 text-sm">
        <p className="text-xs uppercase tracking-wide text-slate-500">{t('login.username')}</p>
        <p>{user?.username} {user?.superadmin ? '(superadmin)' : ''}</p>
        <p className="text-xs uppercase tracking-wide text-slate-500">{t('device.id')}</p>
        <p className="break-all font-mono text-xs text-slate-400">{device}</p>
      </section>

      <section className="space-y-2 rounded-lg border border-slate-800 p-4 text-sm text-slate-400">
        <p>MailD AdminNG · v0.1.0</p>
        <p>{t('app.subtitle')}</p>
      </section>

      <Button variant="outline" onClick={() => void logout()}>{t('login.logout')}</Button>
    </div>
  )
}
