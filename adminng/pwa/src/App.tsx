import { useState } from 'react'
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider, useAuth } from './store/AuthContext'
import { OnlineProvider } from './lib/online'
import { getBaseUrl, needsServerSetup } from './lib/api'
import { Shell } from './components/Shell'
import { BiometricPrompt } from './components/BiometricPrompt'
import { LoginPage } from './pages/AuthScreens'
import { PendingScreen, PrivacyShield } from './pages/DeviceScreens'
import { ServerScreen } from './pages/ServerScreen'
import { DomainsPage } from './pages/Domains'
import { MailboxesPage } from './pages/Mailboxes'
import { AliasesPage } from './pages/Aliases'
import { AdminsPage } from './pages/Admins'
import { DevicesPage } from './pages/Devices'
import { LogsPage } from './pages/Logs'
import { BootstrapPage } from './pages/Bootstrap'
import { SettingsPage } from './pages/Settings'

function Gate() {
  const { phase, shielded } = useAuth()

  if (phase === 'boot') {
    return (
      <div className="flex min-h-screen items-center justify-center bg-slate-950 text-sm text-slate-400">
        MailD AdminNG…
      </div>
    )
  }
  if (phase === 'pending') return <PendingScreen />
  if (phase !== 'ready') return <LoginPage />

  return (
    <Shell>
      {shielded && <PrivacyShield />}
      <BiometricPrompt />
      <Routes>
        <Route path="/" element={<Navigate to="/domains" replace />} />
        <Route path="/domains" element={<DomainsPage password="" />} />
        <Route path="/mailboxes" element={<MailboxesPage password="" />} />
        <Route path="/aliases" element={<AliasesPage password="" />} />
        <Route path="/admins" element={<AdminsPage password="" />} />
        <Route path="/devices" element={<DevicesPage password="" />} />
        <Route path="/logs" element={<LogsPage />} />
        <Route path="/bootstrap" element={<BootstrapPage />} />
        <Route path="/settings" element={<SettingsPage />} />
        <Route path="*" element={<Navigate to="/domains" replace />} />
      </Routes>
    </Shell>
  )
}

export default function App() {
  const [base, setBase] = useState(getBaseUrl)

  if (needsServerSetup()) return <ServerScreen onSaved={() => setBase(getBaseUrl())} />

  return (
    <OnlineProvider>
      <BrowserRouter>
        <AuthProvider key={base}>
          <Gate />
        </AuthProvider>
      </BrowserRouter>
    </OnlineProvider>
  )
}
