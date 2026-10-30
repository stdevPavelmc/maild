/**
 * Fixture helpers for the MailD MCP user page flows (tests/mcp, entrypoint mode `mcp`).
 *
 * Like the AdminNG flows they reach the dev containers through `docker exec` (the harness
 * mounts the socket): the mcp CLI for the domain allow-list, psql for cleanup and doveadm to
 * read the magic link out of the fixture mailbox. Container names are the dev compose ones.
 */

import { execFileSync } from 'node:child_process'

const MCP = process.env.MCP_CONTAINER ?? 'maild-dev-mcp'
const DB = process.env.DB_CONTAINER ?? 'maild-dev-db'
const MDA = process.env.MDA_CONTAINER ?? 'maild-dev-mda'

function dockerExec(container: string, args: string[]): string {
  return execFileSync('docker', ['exec', container, ...args], { encoding: 'utf8' })
}

function mcpSql(sql: string): string {
  return dockerExec(DB, ['psql', '-U', 'maild', '-d', 'mcp', '-tAc', sql]).trim()
}

/** Current policy row for a domain: 't', 'f' or '' (no row). */
export function domainPolicy(domain: string): string {
  return mcpSql(`SELECT allowed FROM domain_policy WHERE domain='${domain}'`)
}

export function allowDomain(domain: string): void {
  dockerExec(MCP, ['python', 'manage.py', 'mcp_domains', 'allow', domain])
}

export function restoreDomain(domain: string, before: string): void {
  if (before === 't') mcpSql(`UPDATE domain_policy SET allowed=true WHERE domain='${domain}'`)
  else if (before === 'f') mcpSql(`UPDATE domain_policy SET allowed=false WHERE domain='${domain}'`)
  else mcpSql(`DELETE FROM domain_policy WHERE domain='${domain}'`)
}

/** Delete the MCP accounts of a fixture domain (children first: no ON DELETE CASCADE in SQL). */
export function dropAccounts(domain: string): void {
  const ids = `(SELECT id FROM account WHERE main_email LIKE '%@${domain}')`
  mcpSql(
    `DELETE FROM web_session WHERE kind='user' AND subject_id IN ${ids}; ` +
      `DELETE FROM token WHERE account_id IN ${ids}; ` +
      `DELETE FROM account_address WHERE account_id IN ${ids}; ` +
      `DELETE FROM account WHERE main_email LIKE '%@${domain}'; ` +
      `DELETE FROM login_failure WHERE key LIKE '%@${domain}';`,
  )
}

/** Expunge the service mail ("From: MailD MCP") the flows caused in a fixture mailbox. */
export function expungeServiceMail(address: string): void {
  try {
    dockerExec(MDA, ['doveadm', 'expunge', '-u', address, 'mailbox', 'INBOX', 'header', 'From', 'MailD MCP'])
  } catch {
    // nothing to expunge
  }
}

/** The newest magic-link token mailed to `address`, polling up to `seconds`. */
export async function magicToken(address: string, seconds = 60): Promise<string> {
  const deadline = Date.now() + seconds * 1000
  while (Date.now() < deadline) {
    const found = dockerExec(MDA, ['doveadm', 'search', '-u', address, 'mailbox', 'INBOX', 'subject', `Confirm ${address}`]).trim()
    const uids = found
      .split('\n')
      .map((line) => Number(line.trim().split(/\s+/)[1]))
      .filter((n) => Number.isFinite(n) && n > 0)
    if (uids.length) {
      const raw = dockerExec(MDA, ['doveadm', 'fetch', '-u', address, 'body', 'mailbox', 'INBOX', 'uid', String(Math.max(...uids))])
      // quoted-printable: undo soft line breaks before matching
      const body = raw.replace(/=\r?\n/g, '')
      const match = body.match(/confirm#(mdmcp_ml_[A-Za-z0-9]+)/)
      if (match) return match[1]
    }
    await new Promise((r) => setTimeout(r, 2000))
  }
  throw new Error(`no magic link reached ${address} within ${seconds}s`)
}
