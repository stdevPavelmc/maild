/**
 * Global domain scope (spec §6.2): a Slack-style selector in the shell that
 * narrows accounts and aliases to one domain. Persisted per browser; an empty
 * value means "all domains".
 */

import { useSyncExternalStore } from 'react'

const KEY = 'adminng.domain'
let current = localStorage.getItem(KEY) ?? ''
const listeners = new Set<() => void>()

export function getSelectedDomain(): string {
  return current
}

export function setSelectedDomain(domain: string): void {
  current = domain
  if (domain) localStorage.setItem(KEY, domain)
  else localStorage.removeItem(KEY)
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function useSelectedDomain(): string {
  return useSyncExternalStore(subscribe, getSelectedDomain, getSelectedDomain)
}
