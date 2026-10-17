import { useCallback, useEffect, useState } from 'react'
import type { Page } from './api'

/** Cursor-paginated list state shared by the table screens. */
export function usePaged<T>(loader: (cursor?: string) => Promise<Page<T>>, deps: unknown[]) {
  const [items, setItems] = useState<T[]>([])
  const [cursor, setCursor] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const page = await loader()
      setItems(page.items)
      setCursor(page.next_cursor)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'request failed')
    } finally {
      setLoading(false)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)

  useEffect(() => {
    void reload()
  }, [reload])

  const more = async (): Promise<void> => {
    if (!cursor) return
    setLoading(true)
    try {
      const page = await loader(cursor)
      setItems((current) => [...current, ...page.items])
      setCursor(page.next_cursor)
    } finally {
      setLoading(false)
    }
  }

  return { items, cursor, loading, error, reload, more }
}
