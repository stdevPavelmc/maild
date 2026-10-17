/**
 * Installability and offline shell (plan.md Phase 3 task 5): a valid manifest, an
 * active service worker controlling the page, and the app booting from the cache
 * with the network down.
 *
 * The pending-device state is irrelevant here: the assertions are about the
 * shell, not about an authenticated session.
 */

import { expect, test } from '@playwright/test'

test('manifest, service worker and offline boot', async ({ page, request }) => {
  const manifest = await request.get('/manifest.webmanifest')
  expect(manifest.ok()).toBe(true)

  const body = (await manifest.json()) as {
    name?: string
    short_name?: string
    display?: string
    start_url?: string
    icons?: { src: string; sizes?: string }[]
  }
  expect(body.name).toBeTruthy()
  expect(body.short_name).toBeTruthy()
  expect(body.display).toBe('standalone')
  expect(body.start_url).toBe('/')
  expect(body.icons?.length ?? 0).toBeGreaterThan(0)

  await page.goto('/')
  await expect(page).toHaveTitle(/AdminNG/)

  // Wait for the worker to activate, then reload so it controls the page.
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready
  })
  await page.reload()
  await expect
    .poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)))
    .toBe(true)

  await page.context().setOffline(true)
  await page.reload()
  await expect(page.getByRole('heading', { name: 'MailD AdminNG', exact: true })).toBeVisible()
  await page.context().setOffline(false)
})
