import { expect, test, type Page } from '@playwright/test'

import { password } from '../../lib/env'
import { allowDomain, domainPolicy, dropAccounts, expungeServiceMail, magicToken, restoreDomain, patchUserPolicy, restoreUserPolicy } from '../../lib/mcp'

/**
 * MailD MCP user page (mcp/technical-proposal.md §7.3), against the live dev stack on
 * http://localhost:8085. The real ALTCHA widget solves its proof-of-work in Chromium, so the
 * strict CSP (workers from blob:) is exercised too. Self-cleaning: the example.net accounts
 * are dropped and the domain policy is restored afterwards.
 */

const DOMAIN = 'example.net'
const ALICE = `alice@${DOMAIN}`
const BOB = `bob@${DOMAIN}`
let policyBefore = ''

test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  policyBefore = domainPolicy(DOMAIN)
  dropAccounts(DOMAIN)
  allowDomain(DOMAIN)
})

test.afterAll(() => {
  dropAccounts(DOMAIN)
  restoreDomain(DOMAIN, policyBefore)
  expungeServiceMail(ALICE)
  expungeServiceMail(BOB)
})

async function signIn(page: Page, user: string) {
  await page.goto('/')
  await page.getByLabel('Email address').fill(user)
  await page.getByLabel('Password').fill(password(user))
  await page.locator('altcha-widget').getByText("I'm not a robot").click()
  await expect(page.getByTestId('login-submit')).toBeEnabled({ timeout: 30_000 })
  await page.getByTestId('login-submit').click()
  await expect(page.getByRole('heading', { name: 'MailD MCP' })).toBeVisible()
  await expect(page.getByText(`Signed in as ${user}`)).toBeVisible()
}

test('login with the ALTCHA widget, and the session survives a reload', async ({ page }) => {
  const csp: string[] = []
  page.on('console', (msg) => {
    if (msg.type() === 'error' && /Content Security Policy/i.test(msg.text())) csp.push(msg.text())
  })
  await signIn(page, ALICE)
  await page.reload()
  await expect(page.getByText(`Signed in as ${ALICE}`)).toBeVisible()
  expect(csp, 'no CSP violation while solving the captcha').toEqual([])
})

test('MCP switch toggles and says so with text, not colour only', async ({ page }) => {
  await signIn(page, ALICE)
  const sw = page.getByTestId('mcp-switch')
  await expect(sw).toHaveAttribute('aria-checked', 'true')
  await sw.click()
  await expect(sw).toHaveAttribute('aria-checked', 'false')
  await expect(sw).toContainText('Disabled')
  await sw.click()
  await expect(sw).toHaveAttribute('aria-checked', 'true')
})

test('a token is shown once, listed masked, and revoked through the dialog', async ({ page }) => {
  await signIn(page, ALICE)
  await page.getByLabel('Token name').fill('e2e-timed')
  await page.getByRole('button', { name: 'Create token' }).click()
  const value = page.getByTestId('token-value')
  await expect(value).toHaveText(/^mdmcp_pat_[A-Za-z0-9]{43}$/)
  const token = (await value.textContent()) ?? ''
  await page.getByRole('button', { name: 'Done' }).click()
  const list = page.getByTestId('token-list')
  await expect(list).toContainText('e2e-timed')
  await expect(list).not.toContainText(token)
  await list.locator('li', { hasText: 'e2e-timed' }).getByRole('button', { name: 'Revoke' }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Revoke' }).click()
  await expect(list.locator('li', { hasText: 'e2e-timed' })).toContainText('Revoked')
})

test('a forever token needs the blocking warning first', async ({ page }) => {
  await signIn(page, ALICE)
  await page.getByLabel('Token name').fill('e2e-forever')
  await page.getByLabel('Lifetime').selectOption('forever')
  await page.getByRole('button', { name: 'Create token' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog).toContainText('30 days without use')
  await page.getByTestId('forever-confirm').click()
  await expect(page.getByTestId('token-value')).toBeVisible()
  await expect(page.getByTestId('token-list').locator('li', { hasText: 'e2e-forever' })).toContainText('Expires: never')
})

test('the lifetime list follows the admin policy: no "never expires" when forbidden, the real default length', async ({ page }) => {
  patchUserPolicy({ pat_forever_allowed: false, pat_default_days: 14 })
  try {
    await page.waitForTimeout(2_500)   // the settings cache lives 2 s per worker
    await signIn(page, ALICE)
    const lifetime = page.getByLabel('Lifetime')
    await expect(lifetime.locator('option')).toHaveText(['14 days (default)', '7 days', '90 days', '1 year'])
  } finally {
    restoreUserPolicy()
  }
})

test('secondary address: magic link, confirm page, then disable with type-to-confirm', async ({ page }) => {
  await signIn(page, ALICE)
  await page.getByLabel('Add another address').fill(BOB)
  await page.getByRole('button', { name: 'Add', exact: true }).click()
  await expect(page.getByText(`Check the inbox of ${BOB}`)).toBeVisible()
  await expect(page.getByTestId(`address-${BOB}`)).toContainText('Pending')
  await expect(page.getByTestId(`address-${BOB}`).getByRole('button', { name: /Resend in \d+ s/ })).toBeDisabled()

  const token = await magicToken(BOB)
  await page.goto(`/confirm#${token}`)
  await expect(page).toHaveURL(/\/confirm$/) // the token leaves the address bar
  await page.getByTestId('confirm-submit').click()
  await expect(page.getByText(`${BOB} is now confirmed in the account of ${ALICE}`)).toBeVisible()

  await page.goto('/')
  const row = page.getByTestId(`address-${BOB}`)
  await expect(row).toContainText('Active')
  await row.getByRole('button', { name: 'Disable' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel(`Type ${BOB} to confirm`).fill('wrong@example.net')
  await dialog.getByRole('button', { name: 'Disable' }).click()
  await expect(page.getByText('Type the address exactly to confirm.')).toBeVisible()
  await row.getByRole('button', { name: 'Disable' }).click()
  await page.getByRole('dialog').getByLabel(`Type ${BOB} to confirm`).fill(BOB)
  await page.getByRole('dialog').getByRole('button', { name: 'Disable' }).click()
  await expect(row).toContainText('Disabled')
})

test('Spanish catalogue and a phone-width layout without horizontal scroll', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 })
  await signIn(page, ALICE)
  await page.getByLabel('Language').selectOption('es')
  await expect(page.getByRole('heading', { name: 'Tokens de acceso' })).toBeVisible()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(0)
  await page.getByLabel('Idioma').selectOption('en')
})

test('preferences: dirty badge, Restore discards, Update persists; activity lists the actions', async ({ page }) => {
  await signIn(page, ALICE)
  const card = page.getByTestId('prefs-card')
  await expect(page.getByLabel('Ask me before an agent sends mail').locator('option')).toHaveText([
    'Always',
    'Only for recipients outside this server',
  ]) // "never" is not offered before the admin setting exists (P3)

  // Restore drops local edits
  await card.getByLabel('Signature').fill('e2e signature')
  await expect(page.getByTestId('prefs-dirty')).toBeVisible()
  await page.getByTestId('prefs-restore').click()
  await expect(card.getByLabel('Signature')).toHaveValue('')
  await expect(page.getByTestId('prefs-dirty')).toHaveCount(0)

  // Update saves to the server
  await page.getByLabel('Ask me before an agent sends mail').selectOption('always')
  await card.getByLabel('Signature').fill('e2e signature')
  await card.getByLabel('Folders hidden from agents').fill('Private, Archive/Tax')
  await page.getByTestId('prefs-update').click()
  await expect(page.getByText('Preferences saved.')).toBeVisible()
  await page.reload()
  await expect(page.getByLabel('Ask me before an agent sends mail')).toHaveValue('always')
  await expect(page.getByTestId('prefs-card').getByLabel('Signature')).toHaveValue('e2e signature')
  await expect(page.getByTestId('prefs-card').getByLabel('Folders hidden from agents')).toHaveValue('Archive/Tax, Private')

  // INBOX can never be hidden
  await page.getByTestId('prefs-card').getByLabel('Folders hidden from agents').fill('INBOX')
  await page.getByTestId('prefs-update').click()
  await expect(page.getByText('INBOX cannot be hidden from agents.')).toBeVisible()

  // the activity list shows the preference change (an action, not the per-request noise)
  await page.getByRole('button', { name: 'Refresh' }).click()
  await expect(page.getByTestId('activity-list')).toContainText('prefs.updated')
})

test('connection help: copy-ready settings per client, built from the page origin', async ({ page, baseURL }) => {
  await signIn(page, ALICE)
  const card = page.getByRole('region', { name: 'Connect an assistant' })
  const snippet = card.getByTestId('connect-snippet')
  const mcpUrl = `${new URL(baseURL ?? page.url()).origin}/api/v1/mcp`
  await expect(snippet).toHaveText(mcpUrl)                                 // Claude: the connector URL
  await card.getByRole('button', { name: 'Claude Code' }).click()
  await expect(card.getByRole('button', { name: 'Claude Code' })).toHaveAttribute('aria-pressed', 'true')
  await expect(snippet).toContainText(`claude mcp add --transport http maild ${mcpUrl}`)
  await card.getByRole('button', { name: 'Gemini CLI' }).click()
  expect(JSON.parse((await snippet.textContent()) ?? '{}').mcpServers.maild.httpUrl).toBe(mcpUrl)
  await card.getByRole('button', { name: 'REST / skill' }).click()
  await expect(snippet).toContainText('/api/v1/mail/list_accounts')
  const skill = await page.request.get(await card.getByRole('link', { name: 'SKILL.md' }).getAttribute('href') ?? '')
  expect(skill.ok()).toBe(true)
  expect(await skill.text()).toContain('name: maild-mail')
  const api = await page.request.get(await card.getByRole('link', { name: 'openapi.json' }).getAttribute('href') ?? '')
  expect((await api.json()).openapi).toBe('3.1.0')
  // phone width: the snippets scroll inside their box, never the page
  await page.setViewportSize({ width: 360, height: 800 })
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})
