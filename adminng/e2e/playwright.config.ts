import { defineConfig, devices } from '@playwright/test'

/**
 * AdminNG browser suite.
 *
 * It runs against a live dev stack (`./bootstrap-dev.sh` + `docker compose ...
 * up -d`), served by the `adminng` nginx at http://localhost:8083. The suite
 * approves its own device through the API container CLI, so it needs the docker
 * CLI and the compose file (see lib/env.ts).
 */
export default defineConfig({
  testDir: './tests',
  timeout: 90_000,
  expect: { timeout: 15_000 },
  workers: 1,
  retries: 0,
  reporter: [
    ['list'],
    ['html', { open: 'never', outputFolder: '../../ldata/e2e/report' }],
  ],
  use: {
    baseURL: process.env.ADMINNG_URL ?? 'http://localhost:8083',
    locale: 'en-US',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})
