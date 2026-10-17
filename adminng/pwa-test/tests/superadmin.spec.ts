/**
 * Superadmin path: TOTP enrollment and the devices panel (plan.md Phase 3 §6.3).
 *
 * This covers what the alice-based flow cannot: a superadmin must present an
 * authenticator (the helper enrolls one only when the API asks for it and
 * otherwise reuses the enrolled seed), and the pending-device queue is only
 * reachable with that role. The approval goes through the **UI** here (re-auth +
 * the armed confirm), while flows.spec.ts covers the CLI path — both are
 * documented ways to authorize a device.
 */

import { expect, test } from '@playwright/test'

import { approveThisDevice, loginSuperadmin, pendingDeviceId, SYSADMIN } from '../lib/login'
import { password } from '../lib/env'

test('the superadmin signs in with TOTP (enrolling on first run) and authorizes a device from the panel', async ({
  page,
  browser,
}) => {
  const phone = await browser.newContext()
  const phonePage = await phone.newPage()

  await test.step('a second device registers itself and waits', async () => {
    await phonePage.goto('/')
    const id = await pendingDeviceId(phonePage)
    expect(id).toBeTruthy()
  })

  await test.step('the superadmin signs in with TOTP and opens the devices panel', async () => {
    await approveThisDevice(page)
    await loginSuperadmin(page)
    await page.getByRole('link', { name: /Devices/ }).first().click()
    await expect(page.getByRole('heading', { name: 'Devices', exact: true })).toBeVisible()
  })

  const phoneId = (await phonePage.locator('code').first().innerText()).trim()

  await test.step('the pending device is authorized through the UI', async () => {
    const row = page.getByRole('listitem').filter({ hasText: phoneId })
    await expect(row).toBeVisible()
    await row.getByRole('button', { name: 'Authorize' }).click()

    const dialog = page.getByRole('dialog')
    await dialog.getByLabel('Administrator password').fill(password(SYSADMIN))
    const armed = dialog.getByRole('button', { name: /^Authorize/ })
    await armed.click()
    await expect(armed).toHaveText(/\(\d+s\)/)
    await expect(armed).toBeEnabled({ timeout: 10_000 })
    await armed.click()

    await expect(page.getByRole('listitem').filter({ hasText: phoneId })).toBeVisible()
  })

  await test.step('the newly authorized device leaves the pending screen', async () => {
    await phonePage.getByRole('button', { name: 'Check approval' }).click()
    await expect(phonePage.getByRole('heading', { name: /Waiting for approval/ })).toHaveCount(0)
    await expect(phonePage.locator('input[autocomplete="username"]')).toBeVisible()
  })

  await test.step('revoking it removes the device from the active list', async () => {
    const row = page.getByRole('listitem').filter({ hasText: phoneId })
    await row.getByRole('button', { name: 'Revoke' }).click()

    const dialog = page.getByRole('dialog')
    await dialog.getByLabel('Administrator password').fill(password(SYSADMIN))
    const armed = dialog.getByRole('button', { name: /^Revoke/ })
    await armed.click()
    await expect(armed).toBeEnabled({ timeout: 10_000 })
    await armed.click()

    await expect(page.getByRole('listitem').filter({ hasText: phoneId })).toHaveCount(0)
  })

  await phone.close()
})
