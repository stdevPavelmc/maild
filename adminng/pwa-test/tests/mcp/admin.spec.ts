import { expect, test, type Page } from '@playwright/test'

import { adminCode, adminCodeCount, adminEmail, adminReset, expungeServiceMail, restoreAdmin, snapshotAdmin } from '../../lib/mcp'

/**
 * MailD MCP admin panel (/adminmcp, proposal §7.2, P3) against the live dev stack. Sign-in with
 * the real ALTCHA widget and the code mailed to the admin; the groups' Update/Restore cards; the
 * domains dual list; master tokens and their tabs; the service-email Test transcript; the logs
 * viewer. The admin row, the settings and the domain policy are snapshotted and restored.
 */

const PASSWORD = `e2e-admin-${Date.now()}`
let email = ''

test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  snapshotAdmin()
  adminReset(PASSWORD)
  email = adminEmail()
})

test.afterAll(() => {
  restoreAdmin()
  expungeServiceMail(email)
})

async function signIn(page: Page) {
  await page.goto('/adminmcp')
  await page.getByLabel('Username').fill('admin')
  await page.getByLabel('Password').fill(PASSWORD)
  await page.locator('altcha-widget').getByText("I'm not a robot").click()
  await expect(page.getByTestId('admin-login-submit')).toBeEnabled({ timeout: 30_000 })
  const before = adminCodeCount(email)
  await page.getByTestId('admin-login-submit').click()
  await expect(page.getByText('A 6-digit code was mailed to')).toBeVisible()
  await page.getByLabel('Code').fill(await adminCode(email, before))
  await page.getByTestId('admin-code-submit').click()
  // the sign-in screens carry the same heading: wait for a panel-only element
  await expect(page.getByTestId('admin-user-card')).toBeVisible()
}

test('admin sign-in needs the mailed code, and the session survives a reload', async ({ page }) => {
  await signIn(page)
  await page.reload()
  await expect(page.getByTestId('admin-user-card')).toContainText(email)
})

test('domains dual list: move with the arrow buttons, Restore, Update', async ({ page }) => {
  await signIn(page)
  const allowed = page.getByTestId('domains-allowed')
  const denied = page.getByTestId('domains-denied')
  const pick = denied.getByRole('option').first()
  const name = (await pick.innerText()).split('\n')[0]
  await pick.click()
  await page.getByRole('button', { name: 'Allow the selected domain' }).click()
  await expect(allowed).toContainText(name)
  await page.getByTestId('domains-card').locator('..').getByRole('button', { name: 'Restore' }).click()
  await expect(denied).toContainText(name)
  await denied.getByRole('option', { name }).dblclick()   // double-click moves too
  await expect(allowed).toContainText(name)
  await page.getByTestId('domains-update').click()
  await page.reload()
  await expect(page.getByTestId('domains-allowed')).toContainText(name)
})

test('settings cards: dirty badge, Restore, Update; logging switches', async ({ page }) => {
  await signIn(page)
  const card = page.getByTestId('logging-card')
  await card.getByLabel('Mail actions').uncheck()
  await expect(page.getByTestId('logging-card-dirty')).toBeVisible()
  await page.getByTestId('logging-card-restore').click()
  await expect(card.getByLabel('Mail actions')).toBeChecked()
  await page.getByTestId('policy-card').getByLabel('Users may turn send confirmation off').check()
  await page.getByTestId('policy-card-update').click()
  await expect(page.getByTestId('policy-card').getByText('Saved.')).toBeVisible()
  await page.reload()
  await expect(page.getByTestId('policy-card').getByLabel('Users may turn send confirmation off')).toBeChecked()
})

test('master tokens: shown once, listed in the Active tab, revoked into the Revoked tab', async ({ page }) => {
  await signIn(page)
  const form = page.getByTestId('master-form')
  await form.getByLabel('Token name').fill('e2e-master')
  await form.getByRole('button', { name: 'Create the master token' }).click()
  await expect(page.getByTestId('master-value')).toHaveText(/^mdmcp_mst_[A-Za-z0-9]{43}$/)
  const list = page.getByTestId('master-list')
  await expect(list).toContainText('e2e-master')
  await list.locator('li', { hasText: 'e2e-master' }).getByRole('button', { name: 'Revoke' }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Revoke' }).click()
  await page.getByRole('tab', { name: /Revoked/ }).click()
  await expect(page.getByTestId('master-list')).toContainText('e2e-master')
})

test('service email: the internal Test reports a transcript; the logs viewer lists the test', async ({ page }) => {
  await signIn(page)
  await page.getByTestId('service-test').click()
  const result = page.getByTestId('service-test-result')
  await expect(result).toContainText('The test message was accepted.', { timeout: 60_000 })
  await expect(result).toContainText('internal, amavis')
  await page.getByLabel('Filter').fill('service_email.test')
  await expect(page.getByTestId('logs-list')).toContainText('service_email.test')
})
