/**
 * Environment helpers for the AdminNG browser suite.
 *
 * Everything is read from the repository itself: `test.creds` (written by
 * `bootstrap-dev.sh`) for the fixture passwords, and the API container's
 * `adminng.py` CLI for the device approval the UI cannot perform by design.
 *
 * Two run modes share this file:
 *   - container (`adminng/pwa-test`, the normal path): MAILD_ROOT=/repo is the
 *     read-only mount of test.creds and ADMINNG_API_CONTAINER names the api
 *     container, so `docker exec` reaches the CLI through the mounted socket;
 *   - host (`npm run verify` inside this folder): the compose CLI is used, the
 *     same way the original suite did it.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

/** Repository root (…/maild); override with MAILD_ROOT when running elsewhere. */
export const ROOT = process.env.MAILD_ROOT ?? join(HERE, '..', '..', '..')

/** Where the suite talks to the frontend (the container tunnels this to nginx). */
export const BASE_URL = process.env.ADMINNG_URL ?? 'http://localhost:8083'

/** Reports, traces, screenshots and the Lighthouse output. */
export const ARTIFACTS = resolve(process.env.E2E_ARTIFACTS ?? join(ROOT, 'ldata', 'e2e'))

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

/**
 * Run a command inside the api container.
 *
 * In the harness container the Compose CLI is unavailable, so the call goes
 * straight to `docker exec` against the named container; `run.sh` mounts the
 * socket for exactly this purpose. On the host the documented compose command
 * is used instead.
 */
function apiExec(binary: string, args: string[]): string {
  const container = process.env.ADMINNG_API_CONTAINER
  const argv = container
    ? ['exec', container, binary, ...args]
    : [
        'compose',
        '--env-file',
        'env.dev',
        '-f',
        'docker-compose-dev.yml',
        'exec',
        '-T',
        'api',
        binary,
        ...args,
      ]

  try {
    return execFileSync('docker', argv, { cwd: ROOT, encoding: 'utf8' })
  } catch (error) {
    const hint = container
      ? `is the docker socket mounted and the '${container}' container running?`
      : 'is the dev stack up (./bootstrap-dev.sh)?'
    throw new Error(`${binary} ${args.join(' ')} failed — ${hint}\n${String(error)}`)
  }
}

/** Run `adminng.py …` inside the api container (device approval). */
export function adminngCli(...args: string[]): string {
  return apiExec('adminng.py', args)
}

/**
 * The current TOTP code for an enrolled admin, read from the stored (encrypted)
 * seed by `tests/totp_code.py` — the same helper test.sh uses. Nothing is
 * reset, so an authenticator enrolled by a human keeps working. `next` asks for
 * the following 30-second step (the API accepts ±1), which covers a step already
 * consumed by another login.
 */
export function totpCode(user: string, next = false): string {
  const args = ['tests/totp_code.py', user, ...(next ? ['--next'] : [])]
  return apiExec('python', args).trim()
}

