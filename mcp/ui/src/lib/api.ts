/**
 * Web API client (mcp/app/webapi/api.py). The access JWT lives in memory only; the refresh
 * token is an HttpOnly cookie scoped to /webapi that the browser sends to /refresh and /logout.
 * A 401 triggers one silent refresh and a retry; a failed refresh ends the session.
 */

export type AddressStatus = 'pending' | 'active' | 'disabled'

export interface Address {
  id: number
  email: string
  main: boolean
  status: AddressStatus
  confirmed_at: string | null
  magic_expires_at: string | null
  next_resend_at: string | null
  resend_count: number
}

export interface Account {
  id: number
  main_email: string
  mcp_enabled: boolean
  lang: 'en' | 'es'
  addresses: Address[]
  mcp_url: string
  login_email?: string
}

export interface Token {
  id: number
  public_id: string
  kind: string
  name: string
  display: string
  scopes: string[]
  addresses: string[] | null
  status: 'active' | 'disabled' | 'revoked'
  disabled_reason: string
  created_at: string
  expires_at: string | null
  last_used_at: string | null
  last_used_ip: string
  last_used_client: string
}

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public retryAfter?: number,
  ) {
    super(message)
  }
}

let accessToken = ''
let onExpired: () => void = () => {}

export function setSessionExpiredHandler(fn: () => void) {
  onExpired = fn
}

async function raw(method: string, path: string, body?: unknown, auth = true): Promise<Response> {
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  if (auth && accessToken) headers.Authorization = `Bearer ${accessToken}`
  return fetch(`/webapi${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'same-origin',
  })
}

async function parse<T>(resp: Response): Promise<T> {
  const data = await resp.json().catch(() => ({}))
  if (!resp.ok) {
    throw new ApiError(resp.status, data.error ?? 'error', data.message ?? resp.statusText, data.retry_after)
  }
  return data as T
}

export async function refresh(): Promise<Account | null> {
  const resp = await raw('POST', '/user/refresh', undefined, false)
  if (!resp.ok) {
    accessToken = ''
    return null
  }
  const data = await resp.json()
  accessToken = data.access_token
  return data.account as Account
}

export async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
  let resp = await raw(method, path, body)
  if (resp.status === 401 && accessToken) {
    if (await refresh()) {
      resp = await raw(method, path, body)
    } else {
      onExpired()
    }
  }
  return parse<T>(resp)
}

export async function login(email: string, password: string, altcha: string): Promise<Account> {
  const data = await parse<{ access_token: string; account: Account }>(
    await raw('POST', '/user/login', { email, password, altcha }, false),
  )
  accessToken = data.access_token
  return data.account
}

export async function logout(): Promise<void> {
  try {
    await call('POST', '/user/logout')
  } finally {
    accessToken = ''
  }
}

export async function confirmLink(token: string): Promise<{ address: string; account: string }> {
  return parse(await raw('POST', '/confirm', { token }, false))
}
