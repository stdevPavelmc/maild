import { expect, test } from '@playwright/test'

import { adminngCli, password } from '../lib/env'
import { approveThisDevice, loginSuperadmin, SYSADMIN } from '../lib/login'

test('a platform credential signs in and re-authenticates through the virtual authenticator', async ({
  page,
}) => {
  const cdp = await page.context().newCDPSession(page)
  await cdp.send('WebAuthn.enable')
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  })
  const deviceId = await approveThisDevice(page, SYSADMIN)

  try {
    await loginSuperadmin(page)

    await test.step('password proof registers a platform credential', async () => {
      await page.getByRole('button', { name: /Settings/ }).click()
      await page.getByLabel('Administrator password to enable or disable').fill(password(SYSADMIN))
      await page.getByRole('button', { name: 'Enable on this device' }).click()
      await expect(page.getByText('A platform credential is enabled for this device.')).toBeVisible()
    })

    await test.step('the credential bypasses the password and TOTP login screens', async () => {
      await page.getByRole('button', { name: 'Sign out', exact: true }).click()
      await page.locator('input[autocomplete="username"]').fill(SYSADMIN)
      await page.getByRole('button', { name: 'Sign in with biometrics' }).click()
      await expect(page.getByRole('link', { name: /Domains/ }).first()).toBeVisible()
      await expect(page.locator('input[inputmode="numeric"]')).toHaveCount(0)
    })

    await test.step('biometric re-auth keeps the armed destructive-action flow', async () => {
      const address = `webauthn-${Date.now()}@example.net`
      await page.getByRole('link', { name: /Accounts/ }).first().click()
      await page.getByRole('button', { name: 'New account' }).click()

      const createDialog = page.getByRole('dialog')
      await createDialog.getByLabel('Address').fill(address)
      await createDialog.getByLabel('Password').fill('Webauthn-e2e-Account-123')
      await createDialog.getByRole('button', { name: 'Create account' }).click()

      const card = page.getByRole('listitem').filter({ hasText: address })
      await expect(card).toBeVisible()
      await card.getByRole('button', { name: 'Delete' }).click()

      const deleteDialog = page.getByRole('dialog')
      await deleteDialog.getByRole('button', { name: 'Use biometrics' }).click()
      const armed = deleteDialog.getByRole('button', { name: /^Delete/ })
      await armed.click()
      await expect(armed).toHaveText(/\(\d+s\)/)
      await expect(armed).toBeEnabled({ timeout: 10_000 })
      await armed.click()
      await expect(card).toHaveCount(0)
    })
  } finally {
    adminngCli('--revoke-device', deviceId)
    await cdp.send('WebAuthn.removeVirtualAuthenticator', { authenticatorId })
    await cdp.detach()
  }
})
