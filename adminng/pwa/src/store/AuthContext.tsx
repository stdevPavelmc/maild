/**
 * Auth state machine: boot → pending → login → (enroll) → 2FA → ready, plus
 * the session-specific idle purge and the 2-minute background privacy shield.
 *
 * The browser identity is minted locally (`deviceId()` + `deviceSecret()`); the
 * server registers it lazily on the first verified login and answers PENDING
 * until a superadmin approves this admin's grant (audit F-11).
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import {
  ApiError,
  api,
  deviceId,
  loadTokens,
  loadUsername,
  saveTokens,
  saveUsername,
  type DeviceState,
  type User,
} from '../lib/api'
import { getPlatformCredential } from '../lib/webauthn'

type Phase = 'boot' | 'pending' | 'login' | 'enroll' | 'twofa' | 'ready'

type AuthContextValue = {
  phase: Phase
  user: User | null
  deviceState: DeviceState | null
  device: string
  deviceFingerprint: string | null
  pendingUser: string | null
  loginError: string | null
  busy: boolean
  shielded: boolean
  login: (username: string, password: string, remember?: boolean) => Promise<void>
  loginBiometric: (username: string, remember?: boolean) => Promise<void>
  submitCode: (code: string) => Promise<void>
  enroll: (code: string) => Promise<void>
  enrollment: { secret: string; otpauth_uri: string } | null
  deviceStatus: () => Promise<void>
  unlock: (password: string) => Promise<void>
  logout: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)
const DEFAULT_IDLE_SECONDS = 900
const SHIELD_MS = 2 * 60 * 1000
const LAST_ACTIVITY = 'adminng.lastActivity'

export function AuthProvider({ children }: { children: ReactNode }) {
  const [phase, setPhase] = useState<Phase>('boot')
  const [user, setUser] = useState<User | null>(null)
  const [deviceState, setDeviceState] = useState<DeviceState | null>(null)
  const [deviceFingerprint, setDeviceFingerprint] = useState<string | null>(null)
  const [pendingUser, setPendingUser] = useState<string | null>(null)
  const [loginError, setLoginError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [shielded, setShielded] = useState(false)
  const [enrollment, setEnrollment] = useState<{ secret: string; otpauth_uri: string } | null>(null)
  const flow = useRef<{ token: string; kind: '2fa' | 'enroll' } | null>(null)
  const credentials = useRef<{ username: string; password: string; remember: boolean } | null>(null)
  const device = deviceId()

  /** Route a device error to the right screen. Returns true when handled. */
  const guard = useCallback((error: unknown): boolean => {
    if (error instanceof ApiError) {
      if (error.code === 'DEVICE_NOT_AUTHORIZED') {
        setDeviceState('PENDING')
        setPendingUser((current) => current ?? (loadUsername() || null))
        setPhase('pending')
        return true
      }
      if (error.code === 'DEVICE_REVOKED') {
        setDeviceState('REVOKED')
        saveTokens(null)
        setPhase('login')
        return true
      }
    }
    return false
  }, [])

  const refreshUser = useCallback(async (): Promise<'ready' | 'guarded' | 'failed'> => {
    try {
      const me = await api.me()
      setUser({ username: me.username, superadmin: me.superadmin, domains: me.domains })
      setDeviceState('APPROVED')
      setPhase('ready')
      return 'ready'
    } catch (error) {
      return guard(error) ? 'guarded' : 'failed'
    }
  }, [guard])

  // Boot: resume a stored session when possible; otherwise go to login. The
  // device is not registered until the first verified login, so there is no
  // anonymous handshake here.
  useEffect(() => {
    let cancelled = false
    const boot = async () => {
      const result = loadTokens() ? await refreshUser() : 'failed'
      if (cancelled) return
      if (result === 'failed') setPhase('login')
    }
    void boot()
    return () => {
      cancelled = true
    }
  }, [refreshUser])

  // Idle purge + activity tracking follows the server's session policy.
  useEffect(() => {
    if (phase !== 'ready') return
    const touch = (): void => localStorage.setItem(LAST_ACTIVITY, String(Date.now()))
    touch()
    const events = ['pointerdown', 'keydown', 'touchstart'] as const
    events.forEach((event) => window.addEventListener(event, touch, { passive: true }))
    const timer = window.setInterval(() => {
      const last = Number(localStorage.getItem(LAST_ACTIVITY) ?? Date.now())
      const idleSeconds = loadTokens()?.idle_timeout ?? DEFAULT_IDLE_SECONDS
      if (Date.now() - last > idleSeconds * 1000) void logout()
    }, 30_000)
    return () => {
      events.forEach((event) => window.removeEventListener(event, touch))
      window.clearInterval(timer)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase])

  // Privacy shield: coming back after >2 minutes backgrounded locks the screen.
  useEffect(() => {
    let hiddenAt: number | null = null
    const onVisibility = (): void => {
      if (document.visibilityState === 'hidden') hiddenAt = Date.now()
      else if (hiddenAt && Date.now() - hiddenAt > SHIELD_MS && phase === 'ready') setShielded(true)
    }
    document.addEventListener('visibilitychange', onVisibility)
    return () => document.removeEventListener('visibilitychange', onVisibility)
  }, [phase])

  const login = useCallback(async (username: string, password: string, remember = false) => {
    setBusy(true)
    setLoginError(null)
    credentials.current = { username, password, remember }
    saveUsername(username)
    try {
      const result = await api.loginStep1(username, password, remember)
      if (result.session_state === 'REQUIRES_TOTP_ENROLLMENT') {
        const info = await api.totpEnroll(result.enrollment_token)
        flow.current = { token: result.enrollment_token, kind: 'enroll' }
        setEnrollment({ secret: info.secret, otpauth_uri: info.otpauth_uri })
        setPhase('enroll')
      } else if (result.session_state === 'REQUIRES_2FA') {
        flow.current = { token: result.flow_token, kind: '2fa' }
        setPhase('twofa')
      } else {
        saveTokens({
          access: result.access_token,
          refresh: result.refresh_token,
          remember: result.remember,
          idle_timeout: result.idle_timeout,
        })
        setUser(result.user)
        setDeviceState('APPROVED')
        setDeviceFingerprint(null)
        credentials.current = null
        setPhase('ready')
      }
    } catch (error) {
      if (error instanceof ApiError && error.code === 'DEVICE_NOT_AUTHORIZED') {
        setDeviceState('PENDING')
        setPendingUser(username)
        setPhase('pending')
      } else if (error instanceof ApiError && error.code === 'DEVICE_REVOKED') {
        setDeviceState('REVOKED')
        setLoginError('revoked')
      } else if (error instanceof ApiError && error.code === 'RATE_LIMITED') {
        setLoginError('RATE_LIMITED')
      } else if (error instanceof ApiError && error.status === 401) {
        setLoginError('wrong')
      } else {
        setLoginError('network')
      }
    } finally {
      setBusy(false)
    }
  }, [])

  const loginBiometric = useCallback(
    async (username: string, remember = false) => {
      setBusy(true)
      setLoginError(null)
      saveUsername(username)
      try {
        const options = await api.webauthnLoginOptions(username, remember)
        const credential = await getPlatformCredential(options.public_key)
        const result = await api.webauthnLoginVerify(
          username,
          options.challenge_id,
          credential,
        )
        saveTokens({
          access: result.access_token,
          refresh: result.refresh_token,
          remember: result.remember,
          idle_timeout: result.idle_timeout,
        })
        setUser(result.user)
        setDeviceState('APPROVED')
        setDeviceFingerprint(null)
        credentials.current = null
        setPhase('ready')
      } catch (error) {
        guard(error)
        if (error instanceof ApiError && error.code === 'RATE_LIMITED') {
          setLoginError('RATE_LIMITED')
        } else {
          setLoginError('biometric')
        }
      } finally {
        setBusy(false)
      }
    },
    [guard],
  )

  const submitCode = useCallback(
    async (code: string) => {
      if (!flow.current || flow.current.kind !== '2fa') return
      setBusy(true)
      setLoginError(null)
      try {
        const result = await api.loginStep2(flow.current.token, code)
        saveTokens({
          access: result.access_token,
          refresh: result.refresh_token,
          remember: result.remember,
          idle_timeout: result.idle_timeout,
        })
        setUser(result.user)
        credentials.current = null
        setPhase('ready')
      } catch (error) {
        guard(error)
        setLoginError(
          error instanceof ApiError && error.code === 'TOTP_INVALID' ? 'badCode' : 'network',
        )
      } finally {
        setBusy(false)
      }
    },
    [guard],
  )

  const enroll = useCallback(
    async (code: string) => {
      if (!flow.current || flow.current.kind !== 'enroll') return
      setBusy(true)
      setLoginError(null)
      try {
        await api.totpConfirm(flow.current.token, code)
        setEnrollment(null)
        // Continue straight into the 2FA step with the credentials we still hold,
        // so the user does not retype them (and the code they just used can be the
        // one they confirm with, thanks to the enrollment step allowance).
        const saved = credentials.current
        if (saved) await login(saved.username, saved.password, saved.remember)
        else setPhase('login')
      } catch (error) {
        setLoginError(
          error instanceof ApiError && error.code === 'TOTP_INVALID' ? 'badCode' : 'wrong',
        )
      } finally {
        setBusy(false)
      }
    },
    [login],
  )

  const deviceStatus = useCallback(async () => {
    const username = pendingUser ?? loadUsername()
    if (!username) return
    try {
      const status = await api.deviceStatus(username)
      setDeviceState(status.authorization_state)
      setDeviceFingerprint(status.fingerprint ?? null)
      setPendingUser(status.username)
      if (status.authorization_state === 'APPROVED') {
        if (loadTokens()) {
          await refreshUser()
        } else {
          setPhase('login')
        }
      }
    } catch {
      /* keep the pending screen */
    }
  }, [pendingUser, refreshUser])

  const unlock = useCallback(async (password: string) => {
    setBusy(true)
    try {
      await api.reauth(password)
      setShielded(false)
      localStorage.setItem(LAST_ACTIVITY, String(Date.now()))
    } finally {
      setBusy(false)
    }
  }, [])

  const logout = useCallback(async () => {
    const tokens = loadTokens()
    saveTokens(null)
    credentials.current = null
    setUser(null)
    setShielded(false)
    if (tokens) {
      try {
        await api.logout(tokens.refresh)
      } catch {
        /* already revoked */
      }
    }
    setPhase('login')
  }, [])

  const value = useMemo<AuthContextValue>(
    () => ({
      phase,
      user,
      deviceState,
      device,
      deviceFingerprint,
      pendingUser,
      loginError,
      busy,
      shielded,
      login,
      loginBiometric,
      submitCode,
      enroll,
      enrollment,
      deviceStatus,
      unlock,
      logout,
    }),
    [
      phase,
      user,
      deviceState,
      device,
      deviceFingerprint,
      pendingUser,
      loginError,
      busy,
      shielded,
      login,
      loginBiometric,
      submitCode,
      enroll,
      enrollment,
      deviceStatus,
      unlock,
      logout,
    ],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth outside AuthProvider')
  return context
}
