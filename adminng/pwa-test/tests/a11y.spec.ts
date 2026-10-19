/**
 * Accessibility audit (plan.md Phase 5, task 2) with axe-core.
 *
 * Runs the WCAG 2.1 A/AA rules on every screen, writes one JSON report per screen
 * under `<artifacts>/a11y` and fails on `serious`/`critical` findings. The source
 * is evaluated through Playwright (not injected as a <script>), so the strict
 * `script-src 'self'` CSP of the adminng nginx does not block it.
 *
 * Run with `./adminng/pwa-test/run.sh a11y`.
 */

import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

import { expect, test, type Page } from '@playwright/test'

import { adminngCli, ARTIFACTS } from '../lib/env'
import { approveThisDevice, login, loginSuperadmin, registerDevice, ALICE, SYSADMIN } from '../lib/login'

const require = createRequire(import.meta.url)
const AXE_SOURCE = readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8')
const OUT = join(ARTIFACTS, 'a11y')

type AxeNode = { target: string[]; failureSummary?: string }
type AxeViolation = {
  id: string
  impact: 'minor' | 'moderate' | 'serious' | 'critical' | null
  help: string
  nodes: AxeNode[]
}
type AxeResult = { violations: AxeViolation[] }

async function audit(page: Page, name: string): Promise<AxeViolation[]> {
  await page.waitForLoadState('networkidle')
  await page.evaluate(AXE_SOURCE)
  const result = await page.evaluate(async (): Promise<AxeResult> => {
    const axe = (window as unknown as { axe: { run: (options: unknown) => Promise<AxeResult> } }).axe
    return axe.run({
      runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] },
    })
  })

  mkdirSync(OUT, { recursive: true })
  writeFileSync(join(OUT, `${name}.json`), JSON.stringify(result, null, 2))

  for (const violation of result.violations) {
    console.log(
      `a11y ${name}: ${violation.impact} ${violation.id} (${violation.nodes.length} node(s)) — ${violation.help}`,
    )
  }
  if (result.violations.length === 0) console.log(`a11y ${name}: clean`)

  return result.violations.filter(
    (violation) => violation.impact === 'serious' || violation.impact === 'critical',
  )
}

test('every screen passes the WCAG 2.1 A/AA audit (serious/critical)', async ({ page, browser }) => {
  test.setTimeout(180_000)
  await page.setViewportSize({ width: 1440, height: 900 })

  await page.goto('/')
  const loginFailures = await audit(page, 'login')

  // Registration happens inside a real sign-in now (audit F-11), so the pending
  // screen is captured after submitting credentials.
  const id = await registerDevice(page, ALICE)
  const pendingFailures = await audit(page, 'pending')
  adminngCli('--approve-device', id, '--user', ALICE)
  await page.getByRole('button', { name: 'Check approval' }).click()

  await login(page, ALICE)
  const failures: AxeViolation[] = [...pendingFailures, ...loginFailures]

  for (const screen of ['domains', 'mailboxes', 'aliases', 'admins', 'logs', 'settings']) {
    await page.goto(`/${screen}`)
    failures.push(...(await audit(page, screen)))
  }

  const adminContext = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  const adminPage = await adminContext.newPage()
  await approveThisDevice(adminPage, SYSADMIN)
  await loginSuperadmin(adminPage)
  await adminPage.goto('/devices')
  failures.push(...(await audit(adminPage, 'devices')))
  await adminContext.close()

  expect(failures, JSON.stringify(failures.map((item) => item.id))).toEqual([])
})
