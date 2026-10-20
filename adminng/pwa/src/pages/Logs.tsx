import { useCallback, useEffect, useRef, useState } from 'react'
import { useVirtualizer } from '@tanstack/react-virtual'
import { useTranslation } from 'react-i18next'
import { api, type AuditEvent, type Domain } from '../lib/api'
import { cacheLogs, cachedLogs, db } from '../lib/cache'
import { useSelectedDomain } from '../lib/selectedDomain'
import { Badge, ErrorBanner, SectionHeader, Select } from '../components/kit'
import { Button } from '../components/ui/button'

/** Sentinel for the "Nobody" actor option (must match the API's NOBODY_ACTOR). */
export const NOBODY_ACTOR = '__none__'

export function LogsPage() {
  const { t } = useTranslation()
  const scope = useSelectedDomain()
  const [actor, setActor] = useState('')
  const [domain, setDomain] = useState('')
  const [action, setAction] = useState('')
  const [domains, setDomains] = useState<string[]>([])
  const [actors, setActors] = useState<string[]>([])
  const [actions, setActions] = useState<string[]>([])
  const [items, setItems] = useState<AuditEvent[]>([])
  const [cursor, setCursor] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [offline, setOffline] = useState(false)
  const parentRef = useRef<HTMLDivElement>(null)

  // Adopt the global shell domain scope once (local override wins after that).
  const scoped = useRef(false)
  useEffect(() => {
    if (!scoped.current && scope) {
      scoped.current = true
      setDomain(scope)
    }
  }, [scope])


  const load = useCallback(
    async (reset: boolean, next?: string) => {
      setError(null)
      try {
        const page = await api.logs({
          actor: actor || undefined,
          domain: domain || undefined,
          action: action || undefined,
          cursor: next,
        })
        setItems((current) => (reset ? page.items : [...current, ...page.items]))
        setCursor(page.next_cursor)
        await cacheLogs(page.items)
        setOffline(false)
      } catch {
        const cached = await cachedLogs(100)
        if (reset) setItems(cached)
        setOffline(true)
        setError(cached.length ? null : t('login.network'))
      }
    },
    [actor, domain, action, t],
  )

  useEffect(() => {
    void load(true)
  }, [load])

  // Domain options: every domain the logged-in admin can view/edit (the
  // catalogue endpoint is already tenant-scoped). Offline: domains seen in
  // the local log cache.
  useEffect(() => {
    let cancelled = false
    const collect = async (): Promise<void> => {
      try {
        const all: Domain[] = await api.listAllDomains()
        if (!cancelled) setDomains(all.map((entry) => entry.domain))
      } catch {
        try {
          const rows = await db.logs.orderBy('domain').uniqueKeys()
          const seen = [...new Set(rows.filter((key): key is string => typeof key === 'string'))].sort()
          if (!cancelled) setDomains(seen)
        } catch {
          /* keep previous options */
        }
      }
    }
    void collect()
    return () => {
      cancelled = true
    }
  }, [])

  // Actor/Action options: distinct values in the tenant-visible logs, scoped
  // by the selected domain (actors) and domain+actor (actions). Offline:
  // distinct values from the local log cache under the same scope.
  useEffect(() => {
    let cancelled = false
    const collect = async (): Promise<void> => {
      try {
        const facets = await api.logFacets({
          domain: domain || undefined,
          actor: actor || undefined,
        })
        if (cancelled) return
        setActors(facets.actors)
        setActions(facets.actions)
        if (actor && actor !== NOBODY_ACTOR && !facets.actors.includes(actor)) setActor('')
        setAction((current) => (current && !facets.actions.includes(current) ? '' : current))
      } catch {
        try {
          const rows = await db.logs.toArray()
          const inScope = rows.filter(
            (row) =>
              (!domain || row.domain === domain) &&
              (!actor || (actor === NOBODY_ACTOR ? false : row.actor === actor)),
          )
          const actorScope = rows.filter((row) => !domain || row.domain === domain)
          if (cancelled) return
          setActors([...new Set(actorScope.map((row) => row.actor))].sort())
          setActions([...new Set(inScope.map((row) => row.action))].sort())
        } catch {
          /* keep previous options */
        }
      }
    }
    void collect()
    return () => {
      cancelled = true
    }
  }, [domain, actor])

  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 68,
    overscan: 8,
  })

  return (
    <div className="space-y-4">
      <SectionHeader title={t('logs.title')} />
      {offline && <div className="rounded border border-amber-800 bg-amber-950/50 p-2 text-xs text-amber-200">{t('offline')}</div>}
      <ErrorBanner message={error} />
      <div className="grid gap-2 sm:grid-cols-3">
        <label className="block text-sm">
          <span className="mb-1 block text-slate-400">{t('logs.domain')}</span>
          <Select aria-label={t('logs.domain')} value={domain} onChange={(event) => setDomain(event.target.value)}>
            <option value="">{t('logs.allDomains')}</option>
            {domains.map((entry) => (
              <option key={entry} value={entry}>{entry}</option>
            ))}
          </Select>
        </label>
        <label className="block text-sm">
          <span className="mb-1 block text-slate-400">{t('logs.actor')}</span>
          <Select aria-label={t('logs.actor')} value={actor} onChange={(event) => setActor(event.target.value)}>
            <option value="">{t('logs.allActors')}</option>
            <option value={NOBODY_ACTOR}>{t('logs.nobody')}</option>
            {actors.map((entry) => (
              <option key={entry} value={entry}>{entry}</option>
            ))}
          </Select>
        </label>
        <label className="block text-sm">
          <span className="mb-1 block text-slate-400">{t('logs.action')}</span>
          <Select aria-label={t('logs.action')} value={action} onChange={(event) => setAction(event.target.value)}>
            <option value="">{t('logs.anyAction')}</option>
            {actions.map((entry) => (
              <option key={entry} value={entry}>{entry}</option>
            ))}
          </Select>
        </label>
      </div>

      <div
        ref={parentRef}
        tabIndex={0}
        role="region"
        aria-label={t('logs.title')}
        className="h-[60vh] overflow-y-auto rounded-lg border border-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
      >
        <div style={{ height: `${virtualizer.getTotalSize()}px`, position: 'relative' }}>
          {virtualizer.getVirtualItems().map((virtualRow) => {
            const event = items[virtualRow.index]
            return (
              <div
                key={event.id}
                className="absolute left-0 top-0 w-full border-b border-slate-800 px-3 py-2 text-sm"
                style={{ height: `${virtualRow.size}px`, transform: `translateY(${virtualRow.start}px)` }}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate font-medium">
                    {event.action}{' '}
                    {event.entity_id && <span className="font-mono text-xs text-slate-400">{event.entity_id}</span>}
                  </span>
                  <Badge tone={event.result === 'ok' ? 'green' : event.result === 'denied' ? 'amber' : 'red'}>
                    {event.result}
                  </Badge>
                </div>
                <p className="truncate text-xs text-slate-400">
                  {new Date(event.ts).toLocaleString()} · {event.actor}
                  {event.domain ? ` · ${event.domain}` : ''}
                  {event.ip ? ` · ${event.ip}` : ''}
                </p>
              </div>
            )
          })}
        </div>
        {items.length === 0 && <p className="py-8 text-center text-sm text-slate-400">{t('logs.empty')}</p>}
      </div>
      {cursor && (
        <Button variant="outline" onClick={() => void load(false, cursor ?? undefined)}>
          {t('common.page')}
        </Button>
      )}
    </div>
  )
}
