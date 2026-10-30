import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Route, Routes } from 'react-router-dom'
import { logout, refresh, setSessionExpiredHandler, type Account as AccountT } from './lib/api'
import Account from './pages/Account'
import Confirm from './pages/Confirm'
import Login from './pages/Login'

/** `/` = login or the account page; `/confirm#<token>` = magic-link landing (no session needed). */
export default function App() {
  const { t, i18n } = useTranslation()
  const [account, setAccount] = useState<AccountT | null>(null)
  const [ready, setReady] = useState(false)

  useEffect(() => {
    document.documentElement.lang = i18n.language.startsWith('es') ? 'es' : 'en'
  }, [i18n.language])

  useEffect(() => {
    setSessionExpiredHandler(() => setAccount(null))
    // a page reload keeps the session through the refresh cookie (the access JWT is memory-only)
    refresh()
      .then((a) => setAccount(a))
      .finally(() => setReady(true))
  }, [])

  const home = !ready ? (
    <p className="p-6 text-sm text-slate-400" role="status">
      {t('common.loading')}
    </p>
  ) : account ? (
    <Account
      account={account}
      onChange={setAccount}
      onLogout={() => {
        void logout().finally(() => setAccount(null))
      }}
    />
  ) : (
    <Login onLogin={setAccount} />
  )

  return (
    <Routes>
      <Route path="/confirm" element={<Confirm />} />
      <Route path="*" element={home} />
    </Routes>
  )
}
