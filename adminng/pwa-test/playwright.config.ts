import { defineConfig, devices } from '@playwright/test'

import { ARTIFACTS, BASE_URL } from './lib/env'

/**
 * AdminNG browser suite.
 *
 * It runs against a live dev stack, served by the `adminng` nginx on
 * `http://localhost:8083`. Inside the `pwa-test` container the entrypoint tunnels
 * that origin to `http://adminng:80` so the tests keep a secure context (service
 * worker, installability, offline boot) and the same URL as a host run.
 *
 * The suite approves its own device through the API container CLI, so it needs
 * the docker socket (container) or the docker CLI (host) — see lib/env.ts.
 *
 * `visual.spec.ts` and `a11y.spec.ts` are opt-in (entrypoint sets PWA_TEST_ALL=1)
 * because they produce artifacts rather than pass/fail assertions on every run.
 */
const INCLUDE_TOOLING_SPECS = process.env.PWA_TEST_ALL === '1'

export default defineConfig({
  testDir: './tests',
  timeout: 90_000,
  expect: { timeout: 15_000 },
  workers: 1,
  retries: 0,
  fullyParallel: false,
  testIgnore: INCLUDE_TOOLING_SPECS ? [] : ['**/visual.spec.ts', '**/a11y.spec.ts'],
  outputDir: `${ARTIFACTS}/results`,
  reporter: [
    ['list'],
    ['html', { open: 'never', outputFolder: `${ARTIFACTS}/report` }],
  ],
  use: {
    baseURL: BASE_URL,
    locale: 'en-US',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    // A blocked click must fail loudly instead of consuming the whole test timeout.
    actionTimeout: 20_000,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})

