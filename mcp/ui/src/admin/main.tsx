import { StrictMode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import '../i18n'
import '../index.css'
import { adminLogout, adminRefresh, setAdminExpiredHandler, type AdminMe } from './api'
import { AdminLogin, AdminRecover, AdminReset } from './AuthScreens'
import Panel from './Panel'

/** /adminmcp — its own bundle entry: none of this code is shipped to the user page. */
function AdminApp() {
  const { t } = useTranslation()
  const [me, setMe] = useState<AdminMe | null>(null)
  const [ready, setReady] = useState(false)
  useEffect(() => {
    setAdminExpiredHandler(() => setMe(null))
    adminRefresh().then(setMe).finally(() => setReady(true))
  }, [])
  const home = !ready ? (
    <p className="p-6 text-sm text-slate-400" role="status">{t('common.loading')}</p>
  ) : me ? (
    <Panel me={me} onChange={setMe} onLogout={() => void adminLogout().finally(() => setMe(null))} />
  ) : (
    <AdminLogin onLogin={setMe} />
  )
  return (
    <Routes>
      <Route path="/recover" element={<AdminRecover />} />
      <Route path="/reset" element={<AdminReset />} />
      <Route path="*" element={home} />
    </Routes>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter basename="/adminmcp">
      <AdminApp />
    </BrowserRouter>
  </StrictMode>,
)
