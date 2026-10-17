#!/usr/bin/env node
/**
 * Lighthouse budget for the AdminNG PWA (plan.md Phase 3 verification).
 *
 * Runs Lighthouse with the Chromium that Playwright installed (no second browser
 * download), keeps the JSON+HTML reports under the artifacts directory and fails
 * the build when accessibility / best-practices / performance drop below the
 * budget. Installability and the offline shell are asserted by
 * `tests/installable.spec.ts`, which is version-stable across Lighthouse releases
 * (the PWA category was removed in v12).
 *
 * Inside the `pwa-test` container the URL is http://localhost:8083 served by the
 * entrypoint's tunnel to the `adminng` nginx (a secure context, so the PWA
 * scoring matches a real deployment behind the ingress).
 */

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const URL = process.env.ADMINNG_URL ?? 'http://localhost:8083'
const OUT = resolve(process.env.E2E_ARTIFACTS ?? join(HERE, '..', '..', 'ldata', 'e2e'))
/**
 * Gated metrics. SEO is reported but not gated: this is a private admin panel and
 * `public/robots.txt` disallows crawling on purpose, which makes Lighthouse's
 * `is-crawlable` audit fail by design. Performance is gated at 0.85 because
 * Lighthouse timings are noisy on shared CI runners.
 */
const BUDGET = { performance: 0.85, accessibility: 0.9, 'best-practices': 0.9 }
const REPORT_ONLY = ['seo']
const CATEGORIES = ['performance', 'accessibility', 'best-practices', 'seo']

mkdirSync(OUT, { recursive: true })

function chromePath() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH
  return execFileSync(
    process.execPath,
    ['-e', "import('playwright').then((p) => console.log(p.chromium.executablePath()))"],
    { cwd: HERE, encoding: 'utf8' },
  ).trim()
}

const report = join(OUT, 'lighthouse.json')
console.log(`lighthouse: auditing ${URL} (reports in ${OUT})`)

// Prefer the installed binary: `npx --yes` would hit the registry on every run
// (and fail in an air-gapped runner), the local one is pinned by the lockfile.
const local = join(HERE, 'node_modules', '.bin', 'lighthouse')
const binary = existsSync(local) ? local : 'npx'
const prefix = existsSync(local) ? [] : ['--yes', 'lighthouse']

execFileSync(
  binary,
  [
    ...prefix,
    URL,
    '--quiet',
    '--output=json',
    '--output=html',
    `--output-path=${join(OUT, 'lighthouse')}`,
    '--only-categories=' + CATEGORIES.join(','),
    '--chrome-flags=--headless=new --no-sandbox --disable-dev-shm-usage',
  ],
  { stdio: 'inherit', cwd: HERE, env: { ...process.env, CHROME_PATH: chromePath() } },
)

// With two output formats Lighthouse writes `<path>.report.json`.
const json = JSON.parse(readFileSync(join(OUT, 'lighthouse.report.json'), 'utf8'))
const scores = Object.fromEntries(
  Object.entries(json.categories).map(([key, value]) => [key, value.score]),
)
for (const [category, score] of Object.entries(scores)) {
  const tag = REPORT_ONLY.includes(category) ? ' (reported, not gated)' : ''
  console.log(`lighthouse: ${category}: ${Math.round((score ?? 0) * 100)}${tag}`)
}

const failures = Object.entries(BUDGET)
  .filter(([category, minimum]) => (scores[category] ?? 0) < minimum)
  .map(([category, minimum]) => `${category} ${scores[category]} < ${minimum}`)

if (failures.length > 0) {
  console.error(`lighthouse: below budget: ${failures.join(', ')}`)
  process.exit(1)
}
console.log('lighthouse: within budget')

