/**
 * Connectivity context: the API is NetworkOnly, so while offline every write is
 * pointless. Screens disable their create/save/delete controls instead of firing
 * requests that cannot succeed (technical-draft §6.5).
 */

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'

const OnlineContext = createContext(true)

export function OnlineProvider({ children }: { children: ReactNode }) {
  const [online, setOnline] = useState(() => navigator.onLine)

  useEffect(() => {
    const up = (): void => setOnline(true)
    const down = (): void => setOnline(false)
    window.addEventListener('online', up)
    window.addEventListener('offline', down)
    return () => {
      window.removeEventListener('online', up)
      window.removeEventListener('offline', down)
    }
  }, [])

  return <OnlineContext.Provider value={online}>{children}</OnlineContext.Provider>
}

export function useOnline(): boolean {
  return useContext(OnlineContext)
}
