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
      `DELETE FROM oauth_code WHERE account_id IN ${ids}; ` +
      `DELETE FROM confirm_handle WHERE token_id IN (SELECT id FROM token WHERE account_id IN ${ids}); ` +
      `DELETE FROM token WHERE account_id IN ${ids}; ` +
      `DELETE FROM account_address WHERE account_id IN ${ids}; ` +
      `DELETE FROM account WHERE main_email LIKE '%@${domain}'; ` +
      `DELETE FROM login_failure WHERE key LIKE '%@${domain}' OR key = '*';`,
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

// ------------------------------------------------------------- admin (P3) ---
function mcpExec(args: string[]): string {
  return dockerExec(MCP, args)
}

/** Snapshot the admin row (password hash + email) and the settings, to restore after the flow. */
export function snapshotAdmin(): void {
  mcpSql('DROP TABLE IF EXISTS e2e_bak_admin, e2e_bak_setting, e2e_bak_policy; ' +
    'CREATE TABLE e2e_bak_admin AS SELECT * FROM admin_user; CREATE TABLE e2e_bak_setting AS SELECT * FROM setting; ' +
    'CREATE TABLE e2e_bak_policy AS SELECT * FROM domain_policy;')
}

export function restoreAdmin(): void {
  mcpSql("DELETE FROM token WHERE kind='master' AND name LIKE 'e2e-%'; DELETE FROM otp_challenge; " +
    "DELETE FROM web_session WHERE kind='admin'; " +
    'UPDATE admin_user a SET password_hash=b.password_hash, email=b.email FROM e2e_bak_admin b WHERE a.id=b.id; ' +
    'DELETE FROM setting; INSERT INTO setting SELECT * FROM e2e_bak_setting; ' +
    'DELETE FROM domain_policy; INSERT INTO domain_policy SELECT * FROM e2e_bak_policy; ' +
    'DROP TABLE IF EXISTS e2e_bak_admin, e2e_bak_setting, e2e_bak_policy;')
}

export function adminReset(password: string): void {
  mcpExec(['python', 'manage.py', 'mcp_admin_reset', '--password', password])
}

export function adminEmail(): string {
  return mcpSql('SELECT email FROM admin_user ORDER BY id LIMIT 1')
}

function codeSubjects(address: string): number[] {
  const found = dockerExec(MDA, ['doveadm', 'search', '-u', address, 'mailbox', 'INBOX', 'subject', 'MailD MCP admin code']).trim()
  return found.split('\n').map((l) => Number(l.trim().split(/\s+/)[1])).filter((n) => Number.isFinite(n) && n > 0)
}

export function adminCodeCount(address: string): number {
  return codeSubjects(address).length
}

/** The newest admin code mailed to `address` after `before` codes were already there. */
export async function adminCode(address: string, before: number, seconds = 60): Promise<string> {
  const deadline = Date.now() + seconds * 1000
  while (Date.now() < deadline) {
    const uids = codeSubjects(address)
    if (uids.length > before) {
      const hdr = dockerExec(MDA, ['doveadm', 'fetch', '-u', address, 'hdr', 'mailbox', 'INBOX', 'uid', String(Math.max(...uids))])
      const m = hdr.match(/^Subject: MailD MCP admin code: (\d{6})/m)
      if (m) return m[1]
    }
    await new Promise((r) => setTimeout(r, 2000))
  }
  throw new Error(`no admin code reached ${address} within ${seconds}s`)
}

// ------------------------------------------------------------- OAuth (P4) ---
/** Drop the OAuth clients a flow registered, with their pending requests and codes. */
export function dropOAuthClients(name: string): void {
  const ids = `(SELECT client_id FROM oauth_client WHERE metadata->>'client_name' = '${name}')`
  mcpSql(
    `DELETE FROM oauth_request WHERE client_id IN ${ids}; DELETE FROM oauth_code WHERE client_id IN ${ids}; ` +
      `DELETE FROM token WHERE kind IN ('oauth_access', 'oauth_refresh') AND client_id IN ${ids}; ` +
      `DELETE FROM oauth_client WHERE metadata->>'client_name' = '${name}';`,
  )
}

/** Merge `patch` into the admin's user-policy settings group; restoreUserPolicy() puts the row back. */
export function patchUserPolicy(patch: Record<string, unknown>): void {
  const json = JSON.stringify(patch).replace(/'/g, "''")
  mcpSql('DROP TABLE IF EXISTS e2e_bak_upolicy; ' +
    "CREATE TABLE e2e_bak_upolicy AS SELECT * FROM setting WHERE key='user_policy'; " +
    `INSERT INTO setting (key, value, updated_by, updated_at) VALUES ('user_policy', '${json}'::jsonb, 'e2e', now()) ` +
    'ON CONFLICT (key) DO UPDATE SET value = setting.value::jsonb || EXCLUDED.value::jsonb;')
}

export function restoreUserPolicy(): void {
  mcpSql("DELETE FROM setting WHERE key='user_policy'; INSERT INTO setting SELECT * FROM e2e_bak_upolicy; " +
    'DROP TABLE IF EXISTS e2e_bak_upolicy;')
}
