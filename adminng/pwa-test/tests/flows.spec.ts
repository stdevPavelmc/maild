/**
 * End-to-end flows (plan.md Phase 3 tasks 2/4/5): device approval, login, CRUD,
 * domain scoping, i18n and the offline write lockdown.
 *
 * One test, one browser context: the whole point is the continuous session a real
 * admin has. Steps are reported individually in the Playwright report.
 *
 * The device approval is deliberately out of band: the UI cannot approve its own
 * device, so the test reads the identifier from the pending screen and runs the
 * documented CLI.
 */

import { expect, test } from '@playwright/test'
import { adminngCli, password } from '../lib/env'

const ALICE = 'alice@example.net'
const ALICE_PASSWORD = password(ALICE)

test('the full admin flow works in a real browser', async ({ page }) => {
  const account = `e2e-${Date.now()}@example.net`

  await test.step('a fresh browser registers on first login and the CLI approves it', async () => {
    await page.goto('/')
    await page.locator('input[autocomplete="username"]').fill(ALICE)
    await page.locator('input[autocomplete="current-password"]').fill(ALICE_PASSWORD)
    await page.getByRole('button', { name: 'Continue' }).click()
    // Valid credentials, but the browser is not approved yet: the login is what
    // registers it, and it waits for approval.
    await expect(page.getByRole('heading', { name: /Waiting for approval/ })).toBeVisible()

    const deviceId = (await page.locator('code').first().innerText()).trim()
    expect(deviceId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
    adminngCli('--approve-device', deviceId)

    await page.getByRole('button', { name: 'Check approval' }).click()
    // Approved now; there are no tokens yet, so we return to the sign-in form.
    await expect(page.locator('input[autocomplete="username"]')).toBeVisible()
  })

  await test.step('alice signs in and lands on the domains list', async () => {
    await page.locator('input[autocomplete="username"]').fill(ALICE)
    await page.locator('input[autocomplete="current-password"]').fill(ALICE_PASSWORD)
    await page.getByRole('button', { name: 'Continue' }).click()

    await expect(page.getByRole('link', { name: /Domains/ }).first()).toBeVisible()
    await expect(page.getByRole('listitem').filter({ hasText: 'example.net' })).toBeVisible()
  })

  await test.step('the keyboard shortcut opens the search palette', async () => {
    await page.goto('/domains')
    // The Shell (and its window listener) mounts after the boot/login.
    await expect(page.getByRole('link', { name: /Domains/ }).first()).toBeVisible()
    await page.keyboard.press('Control+k')
    await expect(page.getByPlaceholder(/Search users, aliases or domains/)).toBeVisible()
    await page.getByPlaceholder(/Search users, aliases or domains/).fill('example')
    await expect(page.getByRole('dialog').getByText('example.net').first()).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page.getByPlaceholder(/Search users, aliases or domains/)).toHaveCount(0)
  })

  await test.step('an account is created through the UI', async () => {
    await page.getByRole('link', { name: /Accounts/ }).first().click()
    await page.getByRole('button', { name: 'New account' }).click()

    const dialog = page.getByRole('dialog')
    await dialog.getByLabel('Address').fill(account)
    await dialog.getByLabel('Password').fill('E2e-password-123')
    // 5 with the GB multiplier: the card must show the converted quota.
    await dialog.getByLabel('Quota', { exact: true }).fill('5')
    await dialog.getByLabel('Quota unit').selectOption('GB')
    await dialog.getByRole('button', { name: 'Create account' }).click()

    const card = page.getByRole('listitem').filter({ hasText: new RegExp(account) })
    await expect(card).toBeVisible()
    await expect(card.getByText('5 GB')).toBeVisible()
  })

  await test.step('the account is deleted with the 5-second armed confirm', async () => {
    const card = page.getByRole('listitem').filter({ hasText: new RegExp(account) })
    await card.getByRole('button', { name: 'Delete' }).click()

    const dialog = page.getByRole('dialog')
    await dialog.getByLabel('Administrator password').fill(ALICE_PASSWORD)
    const armed = dialog.getByRole('button', { name: /^Delete/ })
    await armed.click() // arms the countdown
    await expect(armed).toHaveText(/\(\d+s\)/)
    await expect(armed).toBeEnabled({ timeout: 10_000 })
    await armed.click() // performs the deletion

    await expect(page.getByRole('listitem').filter({ hasText: new RegExp(account) })).toHaveCount(0)
  })

  await test.step('the sidebar domain selector scopes the accounts request', async () => {
    const calls: string[] = []
    page.on('request', (request) => {
      if (request.url().includes('/api/v1/mailboxes')) calls.push(request.url())
    })

    await page.getByRole('link', { name: /Accounts/ }).first().click()
    const scope = page.getByLabel('Domain').first()

    await scope.selectOption('example.net')
    await expect.poll(() => calls.some((url) => url.includes('domain=example.net'))).toBe(true)

    await scope.selectOption('')
    await expect.poll(() => calls.some((url) => !url.includes('domain='))).toBe(true)
  })

  await test.step('switching the language translates the navigation', async () => {
    await page.getByRole('button', { name: /Settings/ }).click()
    await page.getByRole('button', { name: 'Español' }).click()
    await expect(page.getByRole('link', { name: /Dominios/ }).first()).toBeVisible()

    await page.getByRole('button', { name: 'English' }).click()
    await expect(page.getByRole('link', { name: /Domains/ }).first()).toBeVisible()
  })

  await test.step('offline disables writes and shows the banner', async () => {
    await page.getByRole('link', { name: /Domains/ }).first().click()

    await page.context().setOffline(true)
    await expect(page.getByText(/No connection to the server/)).toBeVisible()
    await expect(page.getByRole('button', { name: 'Create' })).toBeDisabled()

    await page.context().setOffline(false)
    await expect(page.getByText(/No connection to the server/)).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Create' })).toBeEnabled()
  })

  await test.step('changing the server address clears the session and starts over', async () => {
    await page.getByRole('button', { name: /Settings/ }).click()
    await page.getByLabel('Server URL').fill('http://localhost:8083')
    await page.getByRole('button', { name: 'Change server' }).click()

    // The form probes /api/v1/health, wipes tokens + device id + secret + the log
    // cache and reloads: a brand-new browser starts at the sign-in form.
    await expect(page.locator('input[autocomplete="username"]')).toBeVisible()
  })
})
