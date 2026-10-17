/**
 * Environment helpers for the AdminNG browser suite.
 *
 * Everything is read from the repository itself: `test.creds` (written by
 * `bootstrap-dev.sh`) for mailbox passwords and the compose CLI for the device
 * approval that the UI cannot perform by design.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

/** Repository root (…/maild); override with MAILD_ROOT when running elsewhere. */
export const ROOT = process.env.MAILD_ROOT ?? join(HERE, '..', '..', '..')

export const BASE_URL = process.env.ADMINNG_URL ?? 'http://localhost:8083'

/** Password for a fixture mailbox, from the git-ignored `test.creds`. */
export function password(user: string): string {
  const file = join(ROOT, 'test.creds')
  for (const raw of readFileSync(file, 'utf8').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#') || !line.includes('=')) continue
    const index = line.indexOf('=')
    if (line.slice(0, index).toLowerCase() === user.toLowerCase()) return line.slice(index + 1)
  }
  throw new Error(`${user} is not in ${file} — run ./bootstrap-dev.sh first`)
}

/** Run `adminng.py ...` inside the api container (device approval, resets). */
export function adminngCli(...args: string[]): string {
  return execFileSync(
    'docker',
    [
      'compose',
      '--env-file',
      'env.dev',
      '-f',
      'docker-compose-dev.yml',
      'exec',
      '-T',
      'api',
      'adminng.py',
      ...args,
    ],
    { cwd: ROOT, encoding: 'utf8' },
  )
}
