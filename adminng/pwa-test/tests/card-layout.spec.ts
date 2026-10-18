import { expect, test } from '@playwright/test'

import { approveThisDevice, loginSuperadmin } from '../lib/login'

test('catalogue cards stay wide on desktop and full-width on phones', async ({ page }) => {
  await approveThisDevice(page)
  await loginSuperadmin(page)

  const screens = ['/domains', '/mailboxes', '/aliases', '/admins', '/devices']

  await page.setViewportSize({ width: 1440, height: 900 })
  for (const screen of screens) {
    await page.goto(screen)
    const grids = page.locator('main [role="list"]')
    await expect(grids.first()).toBeVisible()
    for (let index = 0; index < (await grids.count()); index += 1) {
      const columns = await grids.nth(index).evaluate((element) =>
        getComputedStyle(element).gridTemplateColumns.trim().split(/\s+/).length,
      )
      expect(columns, `${screen} grid ${index} desktop columns`).toBe(2)
    }
  }

  await page.setViewportSize({ width: 390, height: 844 })
  for (const screen of screens) {
    await page.goto(screen)
    const grids = page.locator('main [role="list"]')
    await expect(grids.first()).toBeVisible()
    for (let index = 0; index < (await grids.count()); index += 1) {
      const columns = await grids.nth(index).evaluate((element) =>
        getComputedStyle(element).gridTemplateColumns.trim().split(/\s+/).length,
      )
      expect(columns, `${screen} grid ${index} mobile columns`).toBe(1)
    }
  }
})
