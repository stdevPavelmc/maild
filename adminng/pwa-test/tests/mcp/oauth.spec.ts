import { expect, test, type APIRequestContext } from '@playwright/test'

import { password } from '../../lib/env'
import { allowDomain, domainPolicy, dropAccounts, dropOAuthClients, restoreDomain } from '../../lib/mcp'

/**
 * MailD MCP OAuth consent (mcp/technical-proposal.md §8.2, P4), against the live dev stack. A
 * DCR client sends the browser to /oauth/authorize; the user signs in on the consent page,
 * narrows the scopes and allows; the browser lands on the client's loopback redirect with
 * `code`, `state` and `iss` (the redirect target is intercepted, nothing listens there). The
 * grant then shows in the token list as an app connection with Revoke only. Self-cleaning.
 */

const DOMAIN = 'example.net'
const ALICE = `alice@${DOMAIN}`
const REDIRECT = 'http://127.0.0.1:9/callback'
const CLIENT_NAME = 'e2e OAuth client'
// a fixed PKCE pair: CHALLENGE = base64url(sha256(VERIFIER))
const VERIFIER = 'dBjftJeZ4CVP-mJ92K9mGWYmaGRVK6ac0CKTIhHVF_c'
const CHALLENGE = 'Af3SsY-BJp_V_8KoRQsjChRalfGrI_t0277cWcTpqrY'
let policyBefore = ''

test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  policyBefore = domainPolicy(DOMAIN)
  dropAccounts(DOMAIN)
  allowDomain(DOMAIN)
})

test.afterAll(() => {
  dropOAuthClients(CLIENT_NAME)
  dropAccounts(DOMAIN)
  restoreDomain(DOMAIN, policyBefore)
})

async function authorizeUrl(request: APIRequestContext, state: string): Promise<{ url: string; clientId: string }> {
  const reg = await request.post('/oauth/register', { data: { client_name: CLIENT_NAME, redirect_uris: [REDIRECT] } })
  expect(reg.status()).toBe(201)
  const { client_id } = await reg.json()
  const q = new URLSearchParams({
    response_type: 'code',
    client_id,
    redirect_uri: REDIRECT,
    state,
    code_challenge: CHALLENGE,
    code_challenge_method: 'S256',
    scope: 'mail.read mail.send',
  })
  return { url: `/oauth/authorize?${q}`, clientId: client_id }
}

test('consent: sign in, narrow the scopes, allow → redirect with code + state + iss; the grant is revocable', async ({ page }) => {
  let landed = ''
  await page.route(`${REDIRECT}**`, async (route) => {
    landed = route.request().url()
    await route.fulfill({ status: 200, contentType: 'text/plain', body: 'callback' })
  })
  const { url: start, clientId } = await authorizeUrl(page.request, 'e2e-state-1')
  await page.goto(start)
  await expect(page).toHaveURL(/\/consent#/)
  // the consent page asks for the sign-in first
  await page.getByLabel('Email address').fill(ALICE)
  await page.getByLabel('Password').fill(password(ALICE))
  await page.locator('altcha-widget').getByText("I'm not a robot").click()
  await expect(page.getByTestId('login-submit')).toBeEnabled({ timeout: 30_000 })
  await page.getByTestId('login-submit').click()

  const consent = page.getByTestId('consent')
  await expect(consent).toBeVisible()
  await expect(page.getByTestId('consent-client')).toHaveText(CLIENT_NAME)
  await expect(consent).toContainText('registered here, unverified')
  await expect(consent).toContainText('127.0.0.1')
  await consent.getByRole('checkbox', { name: /mail\.send/ }).uncheck()
  await page.getByTestId('consent-allow').click()

  await expect.poll(() => landed).not.toBe('')
  const url = new URL(landed)
  expect(url.origin + url.pathname).toBe(REDIRECT)
  expect(url.searchParams.get('code')).toMatch(/^mdmcp_oac_/)
  expect(url.searchParams.get('state')).toBe('e2e-state-1')
  expect(url.searchParams.get('iss')).toBeTruthy()

  // the client's side: exchange the code, then the grant is an app connection in the token list
  const tok = await page.request.post('/oauth/token', {
    form: { grant_type: 'authorization_code', code: url.searchParams.get('code') ?? '', client_id: clientId, redirect_uri: REDIRECT, code_verifier: VERIFIER },
  })
  expect(tok.status(), await tok.text()).toBe(200)
  expect((await tok.json()).scope).toBe('mail.read')

  await page.goto('/')
  const row = page.getByTestId('token-list').locator('li', { hasText: CLIENT_NAME })
  await expect(row).toContainText('app connection')
  await expect(row.getByRole('button', { name: 'Disable' })).toHaveCount(0)
  await row.getByRole('button', { name: 'Revoke' }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Revoke' }).click()
  await expect(page.getByTestId('token-list').locator('li', { hasText: CLIENT_NAME })).toHaveCount(0)
})

test('deny returns access_denied with the state, and the request cannot be replayed', async ({ page }) => {
  let landed = ''
  await page.route(`${REDIRECT}**`, async (route) => {
    landed = route.request().url()
    await route.fulfill({ status: 200, contentType: 'text/plain', body: 'callback' })
  })
  await page.goto('/')
  await page.getByLabel('Email address').fill(ALICE)
  await page.getByLabel('Password').fill(password(ALICE))
  await page.locator('altcha-widget').getByText("I'm not a robot").click()
  await expect(page.getByTestId('login-submit')).toBeEnabled({ timeout: 30_000 })
  await page.getByTestId('login-submit').click()
  await expect(page.getByText(`Signed in as ${ALICE}`)).toBeVisible()

  // already signed in: the consent page goes straight to the decision
  await page.goto((await authorizeUrl(page.request, 'e2e-state-2')).url)
  const consentUrl = page.url()
  await expect(page.getByTestId('consent')).toBeVisible()
  await page.getByTestId('consent-deny').click()
  await expect.poll(() => landed).not.toBe('')
  const url = new URL(landed)
  expect(url.searchParams.get('error')).toBe('access_denied')
  expect(url.searchParams.get('state')).toBe('e2e-state-2')

  await page.goto(consentUrl)
  await expect(page.getByTestId('consent')).toHaveCount(0)
})
