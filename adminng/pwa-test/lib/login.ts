/**
 * Shared browser flows for the AdminNG suite.
 *
 * The device approval is out of band on purpose (a pending device cannot
 * authorize itself), so the helpers drive the documented CLI in the api
 * container. The superadmin helper also enrolls a fresh TOTP credential, which
 * is what a real superadmin does on first login.
 */

import { expect, type Page } from '@playwright/test'

import { adminngCli, password } from './env'
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

/** Open the app, read the pending device id and approve it through the CLI. */
export async function approveThisDevice(page: Page): Promise<string> {
  await page.goto('/')
  const pending = page.getByRole('heading', { name: /Waiting for approval/ })
  const id = await pendingDeviceId(page)
  adminngCli('--approve-device', id)
  await page.getByRole('button', { name: 'Check approval' }).click()
  await expect(pending).toHaveCount(0)
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
 * Superadmin login: reset any previous credential (deterministic runs), enroll
 * the authenticator shown by the UI and complete the 2FA step. The same code is
 * reused for the immediate login — the API deliberately leaves the enrollment
 * step usable once so the follow-up login inside the same 30 s window works.
 */
export async function loginSuperadmin(page: Page): Promise<void> {
  adminngCli('--totp-reset', SYSADMIN)
  await submitCredentials(page, SYSADMIN)

  const body = page.getByText(/Superadmins must enroll an authenticator/)
  await expect(body).toBeVisible()
  const secret = (await page.locator('p.font-mono').first().innerText()).trim()
  const code = totp(secret)

  await page.locator('input[inputmode="numeric"]').fill(code)
  await page.getByRole('button', { name: 'Confirm' }).click()

  const verify = page.getByRole('button', { name: 'Verify' })
  await expect(verify).toBeVisible()
  await page.locator('input[inputmode="numeric"]').fill(code)
  await verify.click()

  await expect(page.getByRole('link', { name: /Domains/ }).first()).toBeVisible()
}
