/**
 * AdminNG API client (technical-draft §5).
 *
 * - generates and persists the device UUID (`X-Device-ID`) on first run;
 * - attaches the Bearer access token and, when a destructive call needs it, the
 *   `X-Security-Validation-Token`;
 * - refreshes the token pair once on `TOKEN_EXPIRED`/`SESSION_EXPIRED`;
 * - turns `{detail, message}` payloads into `ApiError` so screens can branch on
 *   stable codes (`DEVICE_NOT_AUTHORIZED`, `FORBIDDEN_TENANT`, …).
 */

const DEVICE_KEY = 'adminng.device'
const TOKENS_KEY = 'adminng.tokens'
const BASE_KEY = 'adminng.baseUrl'

/**
 * Server base URL. Empty string means "same origin as the PWA" (the normal web
 * deployment: the `adminng` nginx proxies /api/v1/). A bundled build (APK with
 * its own assets) sets `VITE_REQUIRE_SERVER_URL=1` and the user picks the server
 * at first run; the value is persisted in localStorage and wins over the
 * build-time `VITE_API_BASE` default.
 */
const BUILD_BASE = ((import.meta.env.VITE_API_BASE as string | undefined) ?? '').replace(/\/+$/, '')

export function getBaseUrl(): string {
  return localStorage.getItem(BASE_KEY) ?? BUILD_BASE
}

export function normaliseBase(url: string): string {
  const trimmed = url.trim()
  if (!trimmed || trimmed === '/') return ''
  return trimmed.replace(/\/+$/, '')
}

export function setBaseUrl(url: string): void {
  const clean = normaliseBase(url)
  if (clean) localStorage.setItem(BASE_KEY, clean)
  else localStorage.removeItem(BASE_KEY)
}

/** A bundled build with no server chosen yet must show the onboarding screen. */
export function needsServerSetup(): boolean {
  return import.meta.env.VITE_REQUIRE_SERVER_URL === '1' && getBaseUrl() === ''
}

/** Onboarding "test connection": the health route answers without auth. */
export async function probeServer(url: string): Promise<void> {
  const base = normaliseBase(url)
  const response = await fetch(`${base}/api/v1/health`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const payload = (await response.json()) as { status?: string }
  if (payload.status !== 'ok') throw new Error('server degraded')
}

/** Drop everything bound to one server: token pair, device identity, prefs. */
export function clearSession(): void {
  localStorage.removeItem(TOKENS_KEY)
  localStorage.removeItem(DEVICE_KEY)
  localStorage.removeItem('adminng.lastActivity')
  localStorage.removeItem('adminng.domain')
}

export type Tokens = { access: string; refresh: string }
export type SessionState = 'REQUIRES_TOTP_ENROLLMENT' | 'REQUIRES_2FA' | 'AUTHENTICATED'
export type DeviceState = 'PENDING' | 'APPROVED' | 'REVOKED'
export type Page<T> = { items: T[]; next_cursor: string | null }
export type User = { username: string; superadmin: boolean; domains: string[] }

export type Domain = {
  domain: string
  description: string
  aliases: number
  mailboxes: number
  maxquota: number
  quota: number
  transport: string | null
  backupmx: boolean
  active: boolean
  created: string | null
  modified: string | null
}
export type Mailbox = {
  username: string
  name: string
  quota_bytes: number
  active: boolean
  domain: string
  local_part: string
  maildir: string
  created: string | null
  modified: string | null
}
export type Alias = {
  address: string
  goto: string
  domain: string
  active: boolean
  created: string | null
  modified: string | null
}
export type Admin = {
  username: string
  superadmin: boolean
  active: boolean
  domains: string[]
  created: string | null
  modified: string | null
}
export type Quota = {
  username: string
  quota_bytes: number
  used_bytes: number
  percentage: number | null
  unlimited: boolean
  source: string
}
export type Device = {
  device_id: string
  client_type: string
  device_name: string | null
  associated_user: string | null
  authorization_state: DeviceState
  first_seen: string
  last_seen: string
  approved_at: string | null
  approved_by: string | null
  last_ip: string | null
}
export type AuditEvent = {
  id: number
  ts: string
  actor: string
  device_id: string | null
  action: string
  entity_type: string | null
  entity_id: string | null
  domain: string | null
  ip: string | null
  endpoint: string | null
  result: string
  details: Record<string, unknown> | null
}
export type SearchHit = {
  type: 'user' | 'alias' | 'domain'
  id: string
  display_name: string
  domain: string | null
  details: Record<string, unknown>
}

export class ApiError extends Error {
  status: number
  code: string
  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

export function deviceId(): string {
  let id = localStorage.getItem(DEVICE_KEY)
  if (!id) {
    id = crypto.randomUUID()
    localStorage.setItem(DEVICE_KEY, id)
  }
  return id
}

export function loadTokens(): Tokens | null {
  const raw = localStorage.getItem(TOKENS_KEY)
  if (!raw) return null
  try {
    return JSON.parse(raw) as Tokens
  } catch {
    return null
  }
}

export function saveTokens(tokens: Tokens | null): void {
  if (tokens) localStorage.setItem(TOKENS_KEY, JSON.stringify(tokens))
  else localStorage.removeItem(TOKENS_KEY)
}

type Options = {
  method?: string
  body?: unknown
  auth?: boolean
  vtoken?: string
  retry?: boolean
}

async function parse<T>(response: Response): Promise<T> {
  const text = await response.text()
  const data = text ? (JSON.parse(text) as unknown) : null
  if (!response.ok) {
    const payload = (data ?? {}) as { detail?: string; message?: string }
    throw new ApiError(
      response.status,
      payload.detail ?? 'HTTP_ERROR',
      payload.message ?? `HTTP ${response.status}`,
    )
  }
  return data as T
}

async function refreshTokens(): Promise<boolean> {
  const tokens = loadTokens()
  if (!tokens) return false
  const response = await fetch(`${getBaseUrl()}/api/v1/auth/refresh`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-ID': deviceId() },
    body: JSON.stringify({ refresh_token: tokens.refresh }),
  })
  if (!response.ok) {
    saveTokens(null)
    return false
  }
  const data = (await response.json()) as { access_token: string; refresh_token: string }
  saveTokens({ access: data.access_token, refresh: data.refresh_token })
  return true
}

export async function request<T>(path: string, options: Options = {}): Promise<T> {
  const { method = 'GET', body, auth = true, vtoken, retry = true } = options
  const headers: Record<string, string> = { 'X-Device-ID': deviceId() }
  if (auth) {
    const tokens = loadTokens()
    if (tokens) headers.Authorization = `Bearer ${tokens.access}`
  }
  if (vtoken) headers['X-Security-Validation-Token'] = vtoken
  if (body !== undefined) headers['Content-Type'] = 'application/json'

  const response = await fetch(`${getBaseUrl()}/api/v1${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })

  if (response.status === 401 && auth && retry) {
    const code = ((await response.clone().json().catch(() => ({}))) as { detail?: string }).detail
    if (code === 'TOKEN_EXPIRED' || code === 'SESSION_EXPIRED' || code === 'UNAUTHENTICATED') {
      if (await refreshTokens()) {
        return request<T>(path, { ...options, retry: false })
      }
    }
  }
  return parse<T>(response)
}

export const qs = (params: Record<string, string | number | boolean | undefined>): string => {
  const search = new URLSearchParams()
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== '') search.set(key, String(value))
  })
  const out = search.toString()
  return out ? `?${out}` : ''
}

export const api = {
  handshake: (deviceName: string) =>
    request<Device>('/device/handshake', {
      method: 'POST',
      auth: false,
      body: { client_type: 'web', device_name: deviceName },
    }),
  deviceStatus: () =>
    request<{ device_id: string; authorization_state: DeviceState }>('/device/status', {
      auth: false,
    }),
  loginStep1: (username: string, password: string) =>
    request<
      | { session_state: 'REQUIRES_TOTP_ENROLLMENT'; enrollment_token: string }
      | { session_state: 'REQUIRES_2FA'; flow_token: string }
      | { session_state: 'AUTHENTICATED'; access_token: string; refresh_token: string; user: User }
    >('/auth/login-step1', { method: 'POST', auth: false, body: { username, password } }),
  totpEnroll: (enrollment_token: string) =>
    request<{ secret: string; otpauth_uri: string; issuer: string }>('/auth/totp-enroll', {
      method: 'POST',
      auth: false,
      body: { enrollment_token },
    }),
  totpConfirm: (enrollment_token: string, code: string) =>
    request<{ enrolled: boolean }>('/auth/totp-confirm', {
      method: 'POST',
      auth: false,
      body: { enrollment_token, code },
    }),
  loginStep2: (flow_token: string, code: string) =>
    request<{ access_token: string; refresh_token: string; user: User }>('/auth/login-step2', {
      method: 'POST',
      auth: false,
      body: { flow_token, code },
    }),
  logout: (refresh: string) =>
    request<{ status: string }>('/auth/logout', {
      method: 'POST',
      auth: false,
      body: { refresh_token: refresh },
    }),
  me: () =>
    request<{ username: string; superadmin: boolean; domains: string[]; device_id: string }>(
      '/auth/me',
    ),
  reauth: (password: string) =>
    request<{ security_validation_token: string; expires_in: number }>(
      '/auth/reauth-confirm',
      { method: 'POST', body: { password } },
    ),

  listDomains: (q?: string, cursor?: string) =>
    request<Page<Domain>>(`/domains${qs({ q, cursor })}`),
  createDomain: (body: { domain: string; description?: string }) =>
    request<Domain & { advisories: { code: string; message: string }[] }>('/domains', {
      method: 'POST',
      body,
    }),
  updateDomain: (domain: string, body: Partial<Domain>) =>
    request<Domain>(`/domains/${encodeURIComponent(domain)}`, { method: 'PUT', body }),
  deleteDomain: (domain: string, vtoken: string) =>
    request<void>(`/domains/${encodeURIComponent(domain)}`, { method: 'DELETE', vtoken }),

  listMailboxes: (params: { domain?: string; q?: string; cursor?: string }) =>
    request<Page<Mailbox>>(`/mailboxes${qs(params)}`),
  createMailbox: (body: {
    username: string
    password: string
    name?: string
    quota_bytes?: number
  }) => request<Mailbox>('/mailboxes', { method: 'POST', body }),
  updateMailbox: (
    username: string,
    body: { name?: string; password?: string; quota_bytes?: number; active?: boolean },
  ) => request<Mailbox>(`/mailboxes/${encodeURIComponent(username)}`, { method: 'PUT', body }),
  deleteMailbox: (username: string, vtoken: string) =>
    request<void>(`/mailboxes/${encodeURIComponent(username)}`, { method: 'DELETE', vtoken }),
  quota: (username: string) =>
    request<Quota>(`/mailboxes/${encodeURIComponent(username)}/quota`),

  listAliases: (params: { domain?: string; goto?: string; q?: string; cursor?: string }) =>
    request<Page<Alias>>(`/aliases${qs(params)}`),
  createAlias: (body: { address: string; goto: string }) =>
    request<Alias>('/aliases', { method: 'POST', body }),
  deleteAlias: (address: string, vtoken: string) =>
    request<void>(`/aliases/${encodeURIComponent(address)}`, { method: 'DELETE', vtoken }),

  listAdmins: () => request<Page<Admin>>('/admins'),
  createAdmin: (body: {
    username: string
    password: string
    superadmin?: boolean
    domains?: string[]
  }) => request<Admin>('/admins', { method: 'POST', body }),
  updateAdmin: (
    username: string,
    body: { password?: string; superadmin?: boolean; active?: boolean; domains?: string[] },
  ) => request<Admin>(`/admins/${encodeURIComponent(username)}`, { method: 'PUT', body }),
  deleteAdmin: (username: string, vtoken: string) =>
    request<void>(`/admins/${encodeURIComponent(username)}`, { method: 'DELETE', vtoken }),

  search: (q: string) =>
    request<{ query: string; results: SearchHit[] }>(`/search${qs({ q })}`),
  logs: (params: { actor?: string; domain?: string; action?: string; cursor?: string }) =>
    request<Page<AuditEvent>>(`/logs${qs(params)}`),
  devices: (state?: string) => request<Page<Device>>(`/admin/devices${qs({ state })}`),
  setDeviceState: (device: string, action: 'APPROVE' | 'REVOKE', vtoken: string) =>
    request<{ device_id: string; new_state: DeviceState }>(
      `/admin/devices/${device}/state`,
      { method: 'PUT', body: { action }, vtoken },
    ),
}


