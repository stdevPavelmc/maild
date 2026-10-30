/**
 * Admin web API client (mcp/app/webapi/admin.py): same scheme as the user client — access JWT in
 * memory, refresh cookie scoped to /webapi/admin, one silent refresh on 401.
 */
import { ApiError } from '../lib/api'

export interface AdminMe {
  username: string
  email: string
  last_login_at: string | null
  service_mailbox: { address: string; active: boolean | null }
  master_token_max_hours: number
}

export interface DomainRow {
  domain: string
  catalogue_active: boolean
  allowed: boolean
  effective: boolean
}

export interface MasterToken {
  id: number
  name: string
  display: string
  scopes: string[]
  status: 'active' | 'disabled' | 'revoked'
  disabled_reason: string
  created_at: string
  expires_at: string | null
  last_used_at: string | null
  last_used_ip: string
  allowed_cidrs: string[]
  admin: string
}

let accessToken = ''
let onExpired: () => void = () => {}

export function setAdminExpiredHandler(fn: () => void) {
  onExpired = fn
}

async function raw(method: string, path: string, body?: unknown, auth = true): Promise<Response> {
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  if (auth && accessToken) headers.Authorization = `Bearer ${accessToken}`
  return fetch(`/webapi/admin${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'same-origin',
  })
}

async function parse<T>(resp: Response): Promise<T> {
  const data = await resp.json().catch(() => ({}))
  if (!resp.ok) throw new ApiError(resp.status, data.error ?? 'error', data.message ?? resp.statusText, data.retry_after)
  return data as T
}

export async function adminRefresh(): Promise<AdminMe | null> {
  const resp = await raw('POST', '/refresh', undefined, false)
  if (!resp.ok) {
    accessToken = ''
    return null
  }
  const data = await resp.json()
  accessToken = data.access_token
  return data.admin as AdminMe
}

export async function adminCall<T>(method: string, path: string, body?: unknown): Promise<T> {
  let resp = await raw(method, path, body)
  if (resp.status === 401 && accessToken) {
    if (await adminRefresh()) resp = await raw(method, path, body)
    else onExpired()
  }
  return parse<T>(resp)
}

export async function adminPublic<T>(method: string, path: string, body?: unknown): Promise<T> {
  return parse<T>(await raw(method, path, body, false))
}

export async function adminVerify(challengeId: string, code: string): Promise<AdminMe> {
  const data = await parse<{ access_token: string; admin: AdminMe }>(
    await raw('POST', '/login/verify', { challenge_id: challengeId, code }, false),
  )
  accessToken = data.access_token
  return data.admin
}

export async function adminLogout(): Promise<void> {
  try {
    await adminCall('POST', '/logout')
  } finally {
    accessToken = ''
  }
}
