/** Local cache: offline reading of the last fetched audit pages (technical-draft §6.5). */

import Dexie, { type Table } from 'dexie'
import type { AuditEvent } from './api'

class AdminngDB extends Dexie {
  logs!: Table<AuditEvent, number>

  constructor() {
    super('adminng')
    this.version(1).stores({ logs: 'id, ts, action, actor, domain' })
  }
}

export const db = new AdminngDB()

export async function cacheLogs(items: AuditEvent[]): Promise<void> {
  try {
    await db.logs.bulkPut(items)
    const count = await db.logs.count()
    if (count > 500) {
      const keep = await db.logs.orderBy('id').reverse().limit(500).primaryKeys()
      await db.logs.where('id').noneOf(keep).delete()
    }
  } catch {
    // The cache is a convenience: never break the screen because of it.
  }
}

export async function cachedLogs(limit = 50): Promise<AuditEvent[]> {
  try {
    return await db.logs.orderBy('id').reverse().limit(limit).toArray()
  } catch {
    return []
  }
}
