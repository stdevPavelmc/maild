/**
 * Visual capture for UI/UX review (plan.md Phase 3, "development with agents").
 *
 * Writes PNGs under `<artifacts>/screens` for every screen, at the desktop
 * (1440x900) and mobile (390x844) breakpoints, in English and Spanish, plus the
 * login/pending screens, the search modal and an editor. It asserts nothing about
 * looks: it produces the material a human or an agent reviews after a change.
 *
 * Run with `./adminng/pwa-test/run.sh visual`.
 */

import { mkdirSync } from 'node:fs'
import { join } from 'node:path'

import { expect, test, type Page } from '@playwright/test'

import { approveThisDevice, login, loginSuperadmin } from '../lib/login'
import { ARTIFACTS } from '../lib/env'

const OUT = join(ARTIFACTS, 'screens')
const DESKTOP = { width: 1440, height: 900 }
const MOBILE = { width: 390, height: 844 }

const screens: { path: string; name: string }[] = [
  { path: '/domains', name: 'domains' },
  { path: '/mailboxes', name: 'mailboxes' },
  { path: '/aliases', name: 'aliases' },
  { path: '/admins', name: 'admins' },
  { path: '/logs', name: 'logs' },
  { path: '/settings', name: 'settings' },
]

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: join(OUT, `${name}.png`), fullPage: true })
}

test('capture every screen for review', async ({ page, browser }) => {
  mkdirSync(OUT, { recursive: true })
  test.setTimeout(300_000)

  await page.setViewportSize(DESKTOP)
  await page.goto('/')
  await shot(page, 'desktop-pending')
  await page.setViewportSize(MOBILE)
  await shot(page, 'mobile-pending')

  const deviceId = await approveThisDevice(page)
  expect(deviceId).toBeTruthy()

  await page.setViewportSize(DESKTOP)
  await shot(page, 'desktop-login')
  await page.setViewportSize(MOBILE)
  await shot(page, 'mobile-login')

  await page.setViewportSize(DESKTOP)
  await login(page, 'alice@example.net')

  for (const screen of screens) {
    await page.goto(screen.path)
    await expect(page.getByRole('main')).toBeVisible()
    await page.waitForTimeout(400)
    await shot(page, `desktop-${screen.name}`)
  }

  await test.step('overlays', async () => {
    await page.goto('/mailboxes')
    await expect(page.getByRole('button', { name: 'New account' })).toBeVisible()
    await page.keyboard.press('Control+k')
    await expect(page.getByPlaceholder(/Search users, aliases or domains/)).toBeVisible()
    await page.keyboard.type('alice')
    await page.waitForTimeout(600)
    await shot(page, 'desktop-search')
    await page.keyboard.press('Escape')

    await page.getByRole('button', { name: 'New account' }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await shot(page, 'desktop-mailbox-editor')
    await page.getByRole('dialog').getByRole('button', { name: 'close' }).click()

    const row = page.getByRole('row', { name: /bob@example\.net/ })
    await row.getByRole('button', { name: 'Delete' }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await shot(page, 'desktop-confirm-delete')
    await page.getByRole('button', { name: 'Cancel' }).click()
  })

  await test.step('mobile layout', async () => {
    await page.setViewportSize(MOBILE)
    for (const screen of [screens[0], screens[1], screens[5]]) {
      await page.goto(screen.path)
      await page.waitForTimeout(400)
      await shot(page, `mobile-${screen.name}`)
    }

    await page.goto('/mailboxes')
    await page.getByRole('button', { name: 'New account' }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await shot(page, 'mobile-mailbox-editor')
    await page.getByRole('dialog').getByRole('button', { name: 'close' }).click()
  })

  await test.step('spanish', async () => {
    await page.setViewportSize(DESKTOP)
    await page.goto('/settings')
    await page.getByRole('button', { name: 'Español' }).click()
    await expect(page.getByRole('link', { name: /Dominios/ }).first()).toBeVisible()
    for (const screen of [screens[0], screens[1], screens[4]]) {
      await page.goto(screen.path)
      await page.waitForTimeout(400)
      await shot(page, `es-${screen.name}`)
    }
    await page.goto('/settings')
    await page.getByRole('button', { name: 'English' }).click()
  })

  await test.step('superadmin devices panel', async () => {
    const adminContext = await browser.newContext({ viewport: DESKTOP })
    const adminPage = await adminContext.newPage()
    await approveThisDevice(adminPage)
    await loginSuperadmin(adminPage)
    await adminPage.goto('/devices')
    await adminPage.waitForTimeout(400)
    await shot(adminPage, 'desktop-devices')
    await adminContext.close()
  })
})
