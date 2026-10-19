/**
 * Shared browser flows for the AdminNG suite.
 *
 * The device approval is out of band on purpose (a pending device cannot
 * authorize itself), so the helpers drive the documented CLI in the api
 * container. The superadmin helper reuses the enrolled authenticator (reading
 * its seed through the api container) and only enrolls when the API asks for
 * it, so a phone enrolled by a human is never invalidated by a test run.
 */

import { expect, type Page } from '@playwright/test'

import { adminngCli, password, totpCode } from './env'
import { totp } from './totp'

export const ALICE = 'alice@example.net'
export const SYSADMIN = 'sysadmin@maild.cu'

/** Read the device UUID the pending screen shows. */
export async function pendingDeviceId(page: Page): Promise<string> {
  const pending = page.getByRole('heading', { name: /Waiting for approval/ })
  await expect(pending).toBeVisible()
  const id = (await page.locator('code').first().innerText()).trim()
  expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  return id
}

/**
 * Register a *fresh* browser by signing in once and read the id it shows.
 *
 * There is no anonymous handshake anymore (audit F-11): the device row only
 * exists after a login whose password verified, so the pending screen appears as
 * the answer to a real sign-in attempt.
 */
export async function registerDevice(page: Page, user: string, secret?: string): Promise<string> {
  // A brand-new context starts blank: open the app first (callers that already
  // navigated to the sign-in form are left alone, so their state is kept).
  if ((await page.locator('input[autocomplete="username"]').count()) === 0) {
    await page.goto('/')
  }
  await submitCredentials(page, user, secret)
  return pendingDeviceId(page)
}

/**
 * Register this browser (by signing in) and approve it through the documented
 * CLI. Leaves the app on the sign-in form.
 */
export async function approveThisDevice(page: Page, user: string): Promise<string> {
  const id = await registerDevice(page, user)
  adminngCli('--approve-device', id, '--user', user)
  await page.getByRole('button', { name: 'Check approval' }).click()
  await expect(page.getByRole('heading', { name: /Waiting for approval/ })).toHaveCount(0)
  return id
}

/** Fill the password step. Leaves the caller to handle 2FA/enrollment. */
export async function submitCredentials(
  page: Page,
  user: string,
  secret: string = password(user),
): Promise<void> {
  await page.locator('input[autocomplete="username"]').fill(user)
  await page.locator('input[autocomplete="current-password"]').fill(secret)
  await page.getByRole('button', { name: 'Continue' }).click()
}

/** Password login for an admin without TOTP (the domain-admin fixtures). */
export async function login(page: Page, user: string, secret?: string): Promise<void> {
  await submitCredentials(page, user, secret)
  await expect(page.getByRole('link', { name: /Domains/ }).first()).toBeVisible()
}

/**
 * Superadmin login. Nothing is reset: an enrolled authenticator (a phone, the
 * previous run) is reused by reading its seed through the api container, the
 * same helper test.sh uses. Only when the API asks for enrollment (a fresh
 * database, or after a deliberate `adminng.py --totp-reset`) does the helper
 * enroll the secret shown on screen and reuse that code for the login.
 */
export async function loginSuperadmin(page: Page): Promise<void> {
  await submitCredentials(page, SYSADMIN)

  const enrollHint = page.getByText(/Superadmins must enroll an authenticator/)
  const codeInput = page.locator('input[inputmode="numeric"]')
  const verify = page.getByRole('button', { name: 'Verify' })
  const domains = page.getByRole('link', { name: /Domains/ }).first()

  // Wait for whichever screen the API chose (enrollment or 2FA) instead of
  // assuming one: isVisible() alone would race the render.
  await Promise.race([
    enrollHint.waitFor({ state: 'visible', timeout: 10_000 }),
    verify.waitFor({ state: 'visible', timeout: 10_000 }),
  ]).catch(() => {})

  if (await enrollHint.isVisible().catch(() => false)) {
    const secret = (await page.locator('p.font-mono').first().innerText()).trim()
    const code = totp(secret)
    await codeInput.fill(code)
    await page.getByRole('button', { name: 'Confirm' }).click()
    await expect(verify).toBeVisible()
    await codeInput.fill(code)
    await verify.click()
  } else {
    await expect(verify).toBeVisible()

    // Replay protection refuses a step at or below the last consumed one, and a
    // previous login (this suite, test.sh, a phone) may hold the current 30 s
    // window. So retry only after the window rolls over, with the then-current
    // code — guaranteed ahead of whatever was consumed. Never submit a *future*
    // (--next) code: it is accepted (±1 window) but records a step ahead of the
    // clock, and the next login inside that window finds both its natural codes
    // already consumed — the flake this loop replaces. The api container and
    // this harness share the host clock, so Date.now() is the TOTP window.
    for (let attempt = 0; attempt < 3; attempt += 1) {
      if (attempt > 0) await page.waitForTimeout(30_000 - (Date.now() % 30_000) + 500)
      await codeInput.fill(totpCode(SYSADMIN))
      await verify.click()
      const signedIn = await domains
        .waitFor({ state: 'visible', timeout: 6_000 })
        .then(() => true)
        .catch(() => false)
      if (signedIn) return
    }
  }

  await expect(domains).toBeVisible()
}
