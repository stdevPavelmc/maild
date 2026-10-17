import { useCallback, useEffect, useRef, useState } from 'react'
import { useVirtualizer } from '@tanstack/react-virtual'
import { useTranslation } from 'react-i18next'
import { api, type AuditEvent } from '../lib/api'
import { cacheLogs, cachedLogs } from '../lib/cache'
import { Badge, ErrorBanner, Input, SectionHeader } from '../components/kit'
import { Button } from '../components/ui/button'

export function LogsPage() {
  const { t } = useTranslation()
  const [actor, setActor] = useState('')
  const [domain, setDomain] = useState('')
  const [action, setAction] = useState('')
  const [items, setItems] = useState<AuditEvent[]>([])
  const [cursor, setCursor] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [offline, setOffline] = useState(false)
  const parentRef = useRef<HTMLDivElement>(null)

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
        <Input placeholder={t('logs.actor')} value={actor} onChange={(event) => setActor(event.target.value)} />
        <Input placeholder={t('logs.domain')} value={domain} onChange={(event) => setDomain(event.target.value)} />
        <Input placeholder={t('logs.action')} value={action} onChange={(event) => setAction(event.target.value)} />
      </div>

      <div ref={parentRef} className="h-[60vh] overflow-y-auto rounded-lg border border-slate-800">
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
