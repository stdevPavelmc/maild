import { useEffect, useState } from 'react'
import { NavLink, useLocation, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { api, type Domain, type SearchHit } from '../lib/api'
import { useOnline } from '../lib/online'
import { setSelectedDomain, useSelectedDomain } from '../lib/selectedDomain'
import { useAuth } from '../store/AuthContext'
import { Button } from './ui/button'
import { Modal, Select } from './kit'

const links = [
  { to: '/domains', key: 'domains', icon: '🌐' },
  { to: '/mailboxes', key: 'mailboxes', icon: '✉️' },
  { to: '/aliases', key: 'aliases', icon: '🔀' },
  { to: '/admins', key: 'admins', icon: '👤' },
  { to: '/devices', key: 'devices', icon: '💻' },
  { to: '/logs', key: 'logs', icon: '📋' },
] as const

export function Shell({ children }: { children: React.ReactNode }) {
  const { t, i18n } = useTranslation()
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()
  const [menu, setMenu] = useState(false)
  const [search, setSearch] = useState(false)
  const [query, setQuery] = useState('')
  const [hits, setHits] = useState<SearchHit[]>([])
  const [domains, setDomains] = useState<Domain[]>([])
  const online = useOnline()
  const offline = !online
  const selectedDomain = useSelectedDomain()

  // Domain scope (spec §6.2): the list feeds the sidebar selector and therefore
  // the accounts/aliases filters.
  useEffect(() => {
    if (!user) return
    let alive = true
    api
      .listDomains()
      .then((page) => {
        if (alive) setDomains(page.items)
      })
      .catch(() => {
        if (alive) setDomains([])
      })
    return () => {
      alive = false
    }
  }, [user])

  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setSearch(true)
      }
      if (event.key === 'Escape') setSearch(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  useEffect(() => {
    if (!search || query.trim().length < 2) {
      setHits([])
      return
    }
    const timer = window.setTimeout(() => {
      api
        .search(query.trim())
        .then((result) => setHits(result.results))
        .catch(() => setHits([]))
    }, 250)
    return () => window.clearTimeout(timer)
  }, [query, search])

  const current = links.find((link) => location.pathname.startsWith(link.to))
  const creatable = ['/domains', '/mailboxes', '/aliases', '/admins'].includes(current?.to ?? '')
  const go = (hit: SearchHit): void => {
    setSearch(false)
    const target = hit.type === 'user' ? '/mailboxes' : hit.type === 'alias' ? '/aliases' : '/domains'
    navigate(`${target}?q=${encodeURIComponent(hit.id)}&new=0`)
  }
  const switchLanguage = (language: string): void => {
    void i18n.changeLanguage(language)
  }

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      {offline && (
        <div className="bg-amber-900/80 px-4 py-1.5 text-center text-xs text-amber-100">{t('offline')}</div>
      )}
      <div className="mx-auto flex max-w-6xl">
        <aside className="hidden w-56 shrink-0 border-r border-slate-800 p-4 sm:block">
          <div className="mb-6">
            <h1 className="text-lg font-semibold">{t('app.title')}</h1>
            <p className="text-xs text-slate-400">{user?.username}</p>
          </div>
          <label className="mb-1 block text-[11px] uppercase tracking-wide text-slate-400" htmlFor="domain-scope">
            {t('domain.select')}
          </label>
          <Select
            id="domain-scope"
            className="mb-4 h-9 text-sm"
            value={selectedDomain}
            onChange={(event) => setSelectedDomain(event.target.value)}
          >
            <option value="">{t('domain.all')}</option>
            {domains.map((item) => (
              <option key={item.domain} value={item.domain}>{item.domain}</option>
            ))}
          </Select>
          <nav className="space-y-1">
            {links.map((link) => (
              <NavLink
                key={link.to}
                to={link.to}
                className={({ isActive }) =>
                  `flex items-center gap-2 rounded-md px-3 py-2 text-sm ${
                    isActive ? 'bg-slate-800 text-white' : 'text-slate-400 hover:bg-slate-900'
                  }`
                }
              >
                <span aria-hidden>{link.icon}</span>
                {t(`nav.${link.key}`)}
              </NavLink>
            ))}
          </nav>
          <div className="mt-8 space-y-2 text-xs text-slate-400">
            <button className="w-full text-left hover:text-slate-300" onClick={() => setSearch(true)}>
              🔎 {t('nav.search')} <span className="text-slate-400">({t('search.hint')})</span>
            </button>
            <div className="flex items-center gap-1">
              <button className="hover:text-slate-300" onClick={() => switchLanguage('en')}>EN</button>
              <span>/</span>
              <button className="hover:text-slate-300" onClick={() => switchLanguage('es')}>ES</button>
            </div>
            <button className="w-full text-left hover:text-slate-300" onClick={() => navigate('/settings')}>
              ⚙️ {t('nav.settings')}
            </button>
            <button className="w-full text-left hover:text-slate-300" onClick={() => void logout()}>
              🚪 {t('login.logout')}
            </button>
          </div>
        </aside>

        <div className="min-w-0 flex-1 pb-24 sm:pb-4">
          <header className="flex items-center justify-between gap-2 border-b border-slate-800 px-4 py-3 sm:hidden">
            <button aria-label="menu" onClick={() => setMenu(true)}>☰</button>
            <span className="truncate text-sm font-medium">
              {current ? t(`nav.${current.key}`) : t('app.title')}
            </span>
            <button aria-label="search" onClick={() => setSearch(true)}>🔎</button>
          </header>
          <main className="p-4">{children}</main>
        </div>
      </div>

      <nav className="fixed inset-x-0 bottom-0 z-30 flex justify-around border-t border-slate-800 bg-slate-950/95 py-2 sm:hidden">
        {[links[0], links[1], links[4], links[5]].map((link) => (
          <NavLink key={link.to} to={link.to} className="px-3 py-1 text-center text-[11px] text-slate-400">
            <span className="block text-lg">{link.icon}</span>
            {t(`nav.${link.key}`)}
          </NavLink>
        ))}
      </nav>
      {creatable && (
        <button
          className="fixed bottom-20 right-4 z-30 h-12 w-12 rounded-full bg-blue-600 text-2xl leading-none shadow-lg disabled:opacity-40 sm:bottom-6"
          aria-label={t('common.create')}
          title={online ? t('common.create') : t('offline')}
          disabled={!online}
          onClick={() => {
            const next = new URLSearchParams(location.search)
            next.set('new', '1')
            navigate(`${current?.to ?? '/domains'}?${next.toString()}`)
          }}
        >
          +
        </button>
      )}

      <Modal open={menu} title={t('app.title')} onClose={() => setMenu(false)}>
        <div className="space-y-2">
          <label className="block text-[11px] uppercase tracking-wide text-slate-400" htmlFor="domain-scope-mobile">
            {t('domain.select')}
          </label>
          <Select
            id="domain-scope-mobile"
            value={selectedDomain}
            onChange={(event) => setSelectedDomain(event.target.value)}
          >
            <option value="">{t('domain.all')}</option>
            {domains.map((item) => (
              <option key={item.domain} value={item.domain}>{item.domain}</option>
            ))}
          </Select>
          {links.map((link) => (
            <Button
              key={link.to}
              variant="outline"
              className="w-full justify-start"
              onClick={() => {
                setMenu(false)
                navigate(link.to)
              }}
            >
              {link.icon} {t(`nav.${link.key}`)}
            </Button>
          ))}
          <Button
            variant="outline"
            className="w-full justify-start"
            onClick={() => {
              setMenu(false)
              void logout()
            }}
          >
            🚪 {t('login.logout')}
          </Button>
        </div>
      </Modal>

      <Modal open={search} title={t('nav.search')} onClose={() => setSearch(false)}>
        <input
          autoFocus
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t('search.placeholder')}
          className="h-10 w-full rounded-md border border-slate-700 bg-slate-900 px-3 text-sm outline-none focus:border-blue-500"
        />
        <div className="max-h-64 space-y-1 overflow-y-auto">
          {hits.map((hit) => (
            <button
              key={`${hit.type}-${hit.id}`}
              className="flex w-full items-center justify-between gap-3 rounded-md px-2 py-2 text-left text-sm hover:bg-slate-800"
              onClick={() => go(hit)}
            >
              <span className="truncate">{hit.display_name}</span>
              <span className="text-xs uppercase text-slate-400">{hit.type}</span>
            </button>
          ))}
          {query.length >= 2 && hits.length === 0 && (
            <p className="py-4 text-center text-xs text-slate-400">{t('search.empty')}</p>
          )}
        </div>
      </Modal>
    </div>
  )
}

