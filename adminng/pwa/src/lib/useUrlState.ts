/**
 * URL-backed screen state.
 *
 * The rapid-search modal and the FAB navigate with `?q=` / `?new=1`; because
 * React Router keeps the screen mounted when only the query changes, parsing
 * `window.location` once at mount silently ignored those navigations. These
 * hooks derive the state from `useSearchParams` so a hit, the FAB and the
 * browser back button all behave.
 */

import { useEffect } from 'react'
import { useSearchParams } from 'react-router-dom'

/** Two-way `?q=` binding for the list search box. */
export function useSearchQuery(): [string, (value: string) => void] {
  const [params, setParams] = useSearchParams()
  const value = params.get('q') ?? ''

  const setValue = (next: string): void => {
    const copy = new URLSearchParams(params)
    if (next) copy.set('q', next)
    else copy.delete('q')
    setParams(copy, { replace: true })
  }

  return [value, setValue]
}

/**
 * `?new=1` is a one-shot signal fired by the FAB: it opens the create modal and
 * is stripped from the URL right away, so pressing the FAB again from the same
 * screen (or after closing the modal) fires again.
 */
export function useNewSignal(): boolean {
  const [params, setParams] = useSearchParams()
  const signal = params.get('new') === '1'

  useEffect(() => {
    if (!signal) return
    const copy = new URLSearchParams(params)
    copy.delete('new')
    setParams(copy, { replace: true })
  }, [signal, params, setParams])

  return signal
}
