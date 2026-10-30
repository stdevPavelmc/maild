# MailD MCP — Progress

Tracks the delivery plan of `mcp/technical-proposal.md` §13.

## Status legend

| Status | Meaning |
|--------|---------|
| — | Not started |
| Initiated | Baseline recorded (or inherited), work on the phase has started |
| testing | Changes in place, running the test/fix loop |
| done | New checks + full `test.sh` pass on the dev stack |
| verified | Re-checked from a clean dev stack (`down` → `rm -rf ldata/` → `./bootstrap-dev.sh` → full `./test.sh` + phase-specific harness runs) and reviewed against the proposal |

## Procedure (every phase)

0. **Baseline.** `./test.sh` passes on the dev stack before touching anything. Omitted when the previous phase ended with a full pass (its final run is the baseline).
1. **Work.** Write the tests for the new feature first (new `test.sh` checks, pytest, `pwa-test` flows), make the changes, fix problems.
2. **Test.** Run the new checks and the full `./test.sh`. Fail → back to step 1. Pass → phase `done`, next phase.

Rules:
- Dev stack only: `docker compose --env-file env.dev -f docker-compose-dev.yml …`. Never the production compose locally.
- Scratch/test data in `/tmp/maild-mcp-<phase>/`, mounted into the test container; removed at the end of the phase.
- Web UI checks through the `adminng/pwa-test` harness (Playwright + Lighthouse).
- Every change to services/ports/env/entrypoints updates the matching `.agents/` file in the same commit (`AGENTS.md` doc rule).
- Each decision or action gets a dated line in the phase log.

## Phase board

| Phase | Scope (proposal §13) | Status | Started | Done | Verified |
|-------|----------------------|--------|---------|------|----------|
| P0 | mda master user + rehash fix; `MCP_DB` + `ensure_roles.sh` + migration 003; compose chain; empty `mcp` container with `/healthz` + service mailbox | verified | 2026-10-29 | 2026-10-29 | 2026-10-29 |
| P1 | User login (IMAP), accounts/addresses/magic links, PATs, read tools, audit logs | — | | | |
| P1b | amavis `10026` + ACLs on both ports + IP watchdog; cron jobs to `10026` (D13) | — | | | |
| P2 | Modify/trash/spam tools, send/reply/forward via `amavis:10026`, confirmations, rate limit | — | | | |
| P3 | Admin panel (all groups), master tokens, external SMTP + test | — | | | |
| P4 | OAuth 2.1 AS (CIMD + DCR), consent UI | — | | | |
| P5 | REST mirror, OpenAPI, SKILL.md, docs | — | | | |
| Final | All phases `verified` + goal review against `Idea.md` and the proposal | — | | | |

---

## P0 — Foundations

Status: verified

Checklist
- [x] Baseline `./test.sh` green (record count/duration) — 93 passed / 0 failed / 0 skipped, 2m44s
- [x] mda: `MCP_DOVECOT_MASTER_USER/PASSWORD`, `master-users` file rendered only when set, master passdb (`auth_master_user_separator = *`), IMAP only
- [x] mda: `rehash-password.sh` skips master logins (§5.4)
- [x] db: `MCP_DB` in `ensure_databases.sh`
- [x] db: `003_mcp_service_mailbox.sql` (`SECURITY DEFINER` function)
- [x] db: `ensure_roles.sh` (role `maild_mcp`, DB owner, column grants, EXECUTE grant), wired after `migrate.sh`
- [x] cron: `backup_db.sh` third archive `maild_mcp_*.sql.gz`
- [x] `mcp/` image skeleton (Python 3.14 + Django + uvicorn, non-root, read-only rootfs), `/healthz`, sentinel wait, Django migrate, admin seed, service mailbox creation + OTP banner
- [x] Compose chain: dev → prod → github → gitlab (same commit — nothing committed yet), env.sample, `.agents/` docs
- [x] New `test.sh` checks: master login OK (active), KO (inactive), KO over POP3, `$1$` hash unchanged after master login; `maild_mcp` cannot read `mailbox.password`, cannot UPDATE catalogue, can EXECUTE the function; service mailbox created once, untouched on restart; `/healthz` 200 — J1–J11 + G4c
- [x] Full `./test.sh` green — 105 passed / 0 failed / 0 skipped, 3m13s

Log

| Date | Type | Entry |
|------|------|-------|
| 2026-10-29 | action | Session now runs on the operator's workstation (local Docker 29.9.2), so the global-log blocker no longer applies. Scratch dir `/tmp/maild-mcp-p0/` created (bootstrap + test logs). |
| 2026-10-29 | action | `./bootstrap-dev.sh` on the existing `ldata/` (stack was down): OK in 24 s, fixtures intact. |
| 2026-10-29 | action | Baseline `./test.sh` (full): **93 passed / 0 failed / 0 skipped, 2m44s**. P0 → Initiated. |
| 2026-10-29 | finding | §5.4 confirmed on the live stack: with the master passdb enabled and the guard removed, a master login to a `$1$` probe mailbox rewrote its hash to `Argon2id(master password)`. With the guard the hash is unchanged; the user's own login still migrates it. |
| 2026-10-29 | decision | Dovecot 2.4.2 exposes `%{master_user}` in userdb fields: added `master_user = %{master_user}` next to `plain_pass` (`auth-sql.conf.ext`); `rehash-password.sh` exits early when `MASTER_USER` is non-empty (proposal §5.4, variable name verified). |
| 2026-10-29 | decision | Master passdb inside `protocol imap { passdb mcp_master { driver = passwd-file; master = yes; result_success = continue } }`; template `conf.d/auth-master.conf.ext.in`, copied/removed by the mda entrypoint on **every** boot (rotation/removal = edit env + recreate), included via `!include_try`. Hash via `doveadm pw -s ARGON2ID` with the password on stdin. Verified: IMAP OK; POP3, SMTP AUTH (587) and ManageSieve refused; inactive/non-existent mailboxes refused. Source-IP restriction not added (container IPs are dynamic; proposal says "if possible"). |
| 2026-10-29 | finding | Dovecot's default login line does not show the master name (proposal §5.3/§11 rely on it). `%{master_user}` is not a login-process variable; `%{auth_user}` is (master name on master logins, = user otherwise). Added `auth_user=<%{auth_user}>` to `login_log_format_elements` (`10-logging.conf`); nothing in the repo parses that line. |
| 2026-10-29 | decision | Migration 003 guards beyond the proposal sketch: address regex, `{ARGON2ID}$argon2id$` hash prefix required (a compromised mcp cannot plant a weak/plain credential), refuses an address that is already an alias, advisory xact lock per address, `search_path = public, pg_temp`. |
| 2026-10-29 | decision | `ensure_roles.sh` is declarative: role created or `ALTER`ed (NOSUPERUSER/NOCREATEDB/NOCREATEROLE, password re-asserted) and catalogue grants revoked + re-granted on every boot; `REVOKE ALL ON DATABASE mcp FROM PUBLIC`. Password passed with `psql -v` on stdin, statements built with `format(%I, %L)` + `\gexec`. |
| 2026-10-29 | finding | Dev-only bug in `bootstrap-dev.sh`: `mkdir -p` created `ldata/vmail/<domain>` as root and only the leaf homes were chowned, so Dovecot could not create the home of any *new* mailbox in a fixture domain (it would have broken `mcp@maild.cu`). Fixed (chown the domain dirs too). Production unaffected. |
| 2026-10-29 | decision | `backup_db.sh`: the MCP archive is SKIPPED (not FAILED) when the database is missing or has no table yet (empty until mcp has migrated). P0 archive is ~1.2 KB (2 tables), above the 1024-byte floor; it grows with P1+. |
| 2026-10-29 | decision | mcp image bakes only the variables P0 consumes (AGENTS env rule); SMTP/rate/session-TTL vars arrive with the phases that read them. Note for P1b/P2: §9.5 lists `MCP_SMTP_PORT=10024`, but D2/D13 make it `10026` — bake `10026` when sending lands. |
| 2026-10-29 | decision | P0 has no Starlette dependency: `asgi.py` is a plain ASGI function delegating to Django; the `/api/v1/mcp` mount is added in P1 with the SDK. No SPA build stage yet (P1). Pins: Django 6.1.2, uvicorn 0.54.0, psycopg 3.3.6, argon2-cffi 25.1.0 (latest on PyPI today). `--lifespan off` (Django has no lifespan handler). |
| 2026-10-29 | decision | **Asked Pavel** (proposal contradiction: §9.4 snippet `env_file: .env` vs "mcp does not get POSTGRES_PASSWORD"). Answer: **allow-list, no `env_file` on mcp**. The three secrets use `:?` guards; optional tunables are bare map keys (`MCP_DB:`), which compose passes through when set and leaves unset otherwise, so the image default applies (verified with a throwaway compose project). Settings also treat empty as unset. |
| 2026-10-29 | action | Compose chain updated in one pass (dev → prod → github → gitlab): `mcp` service, `db` gets `MCP_DB_PASSWORD: ${…:-}`, `mda` gets `MCP_DOVECOT_MASTER_PASSWORD: ${…:-}`, `mcp_logs` volume, Traefik labels (nested `${MCP_HOSTNAME:-mcp.${DEFAULT_DOMAIN}}` resolves to `mcp.maild.cu`). All four validate with `compose config -q`; the resolved mcp env carries no `POSTGRES_PASSWORD`. CI wiring: `IMG_MCP` + `build_mcp`/`release_mcp`/deploy need in `.gitlab-ci.yml` (env crafting copies `MCP_*`), `SERVICES`/`IMG_MCP` in `.github/workflows/docker-image.yml`. |
| 2026-10-29 | finding | Pre-existing chain drift, **not touched**: `compose-github.yml` routes the AdminNG UI as `admin.${DEFAULT_DOMAIN}` (router `admin`) while `docker-compose.yml`/`compose-gitlab.yml` use `adminng.${DEFAULT_DOMAIN}`. Needs Pavel's call. |
| 2026-10-29 | action | mcp boot verified on dev: sentinel → migrate (`0001_initial`) → admin seeded (generated password banner) → `mcp@maild.cu` created (banner), IMAP login with it works; restart: "admin already present", "service mailbox present and active", row unchanged; `/healthz` 200 `{db, catalogue, imap}`; container `healthy`. |
| 2026-10-29 | action | New checks: `test.sh` J1–J11 (master login OK/trail/inactive KO/IMAP-only/`$1$` untouched + own-login control/role column grants/no writes/function EXECUTE + weak-hash refusal/service mailbox once + untouched on restart/healthz) and G4c (MCP archive). Throwaway mailboxes `mcp-{legacy,inactive}-probe@example.net` removed by `cleanup()`. Fast subset (`--skip-content --skip-quota`): 96 passed / 0 failed / 2 skipped. |
| 2026-10-29 | action | Docs: `env.sample` (+ `env.sample_gitlab`), `.agents/services/catalog.md` (db, mda, cron, new mcp section), `.agents/services/configuration.md` (matrix + chain), `.agents/architecture/overview.md`, `.agents/devops/{environment-setup,workflows,base-images}.md`, `AGENTS.md`, `db/`, `mda/`, `cron/` READMEs, new `mcp/README.md`, `Changelog.md` (Unreleased). |
| 2026-10-29 | finding | Adding the MCP vars to `env.dev` changes the config hash of every service with `env_file: env.dev`, so the next `up` recreates `api`, `mta`, `mua`, `amavis` (new IPs). Two services cache peer IPs at start and went stale: `adminng`'s nginx → `api` (all `/api/v1` calls 502, 24 `I*` failures) and `amavis` ("MTA IP has changed, need to reboot", unhealthy). First full run: 80 passed / 25 failed — none in MCP code. Fixed by restarting `adminng` + `amavis`. Pre-existing fragility (same class as the IP-handling TODO and proposal §9.6 option A); operators will hit it when they add the MCP secrets to `.env` — the upgrade note should say "recreate the whole stack". Not changed in P0. |
| 2026-10-29 | finding | `bootstrap-dev.sh` starts an explicit service list: `mcp` would never start on a clean stack. Added it to the `up -d` list plus a non-fatal `/healthz` wait at the end (after the catalogue exists), and a summary line. Re-run: green, idempotent. |
| 2026-10-29 | action | Full `./test.sh` after restarting the stale services: **105 passed / 0 failed / 0 skipped, 3m13s** (93 baseline + J1–J11 + G4c). P0 → **done**. Not verified yet (clean-stack run pending); nothing committed. Scratch dir `/tmp/maild-mcp-p0/` kept until P0 is verified. |
| 2026-10-29 | action | Verification from a clean stack: `down` → `ldata/` wiped (from a throwaway container: it holds root-owned files) → old `test.creds` moved aside → `./bootstrap-dev.sh`: OK in 57 s, mcp healthy (cold boot exercised the sentinel wait: "sentinel not written yet" → provisioned → admin + `mcp@maild.cu` created). |
| 2026-10-29 | finding | First `./test.sh` straight after that bootstrap: 104 passed / 1 failed — the up-front health check saw `amavis(starting)`. Cause: the bootstrap's last step restarts amavis (DKIM keys for the new domains) and Docker reports `starting` until the first probe; the suite started within seconds. Pre-existing race, not MCP-related (CI never hits it: the swaks install step sits between bootstrap and tests). Candidate fix outside P0: bootstrap waits for amavis `healthy` after that restart. |
| 2026-10-29 | action | Second full `./test.sh` on the same clean stack: **105 passed / 0 failed / 0 skipped, 3m13s** (J1–J11, G4c green). Fresh-boot checks: `master-users` `0640 root:dovecot`, `maild_mcp` not superuser/createdb/createrole and owner of `mcp`, `ldata/mcp_logs` owned 10001, domain dirs owned 5000, probe mailboxes cleaned. |
| 2026-10-29 | review | Against the proposal: §5.4 fix + test ✓; §9.1 items 1–5 ✓ (source-IP restriction skipped, logged); §9.2 items 1–6 ✓ (extra guards logged); §9.4 ✓ except `env_file` (deviation decided by Pavel); §9.5 partially baked by design (only P0 consumers; `MCP_TRUSTED_PROXIES`, SMTP, rate and TTL vars come with P1/P1b/P2); §12 ✓ except the SPA build stage and the hourly jobs (P1+); §7.2 seed ✓; §7.4 service mailbox ✓ (the admin-panel warning for an inactive mailbox is P3); §4 `/healthz` ✓. P0 → **verified**. |
| 2026-10-29 | action | Scratch dir `/tmp/maild-mcp-p0/` removed (bootstrap/test logs, compose-validation copies, the pre-verify `test.creds` copy). |
| 2026-10-29 | action | P0 committed on branch `mcp` (one commit: code, compose chain, CI, docs, planning docs). Left out on purpose: `.env-prod`, `SECURITY-AUDIT.md` (not part of this work). |

---

## P1 — User side + read access

Status: —

Checklist
- [ ] User login via IMAP LOGIN (STARTTLS) + ALTCHA + lockout; domain allow-list (catalogue, deny by default)
- [ ] Accounts, main address, MCP master switch
- [ ] Secondary addresses: magic link (24 h), resend backoff 2^n from 1 min, disable/remove + notices, global uniqueness + "Already in use" + postmaster notice (throttled), owner-wins on pending
- [ ] PATs: create/list/enable/disable/revoke, forever warning, 30-day idle disable + re-enable from UI only
- [ ] Web session (short JWT + rotating refresh cookie, 24 h)
- [ ] MCP endpoint `/api/v1/mcp` (SDK v2, stateless), per-request authorization chain (§8.2), scopes
- [ ] Read tools: `list_accounts`, `list_folders`, `check_new_mail`, `search_emails`, `get_email` (mark read default), `get_thread`, `get_attachment`, `get_quota`
- [ ] IMAP pool per mailbox (≤ 3), cert verification against `mail.crt`
- [ ] Audit/access/error logs (date-named files, JSON lines)
- [ ] User SPA (React, EN/ES, mobile), `i18n:check`
- [ ] Tests: `test.sh` (login, token auth 401/403, read tools on fixtures, search does not set `\Seen`, `get_email` sets it, idle-disable), pytest, `pwa-test` user flows
- [ ] Full `./test.sh` green

Log

| Date | Type | Entry |
|------|------|-------|

---

## P1b — amavis 10024/10026 split (D13)

Status: —

Checklist
- [ ] `50-user`: `$inet_socket_port = [10024, 10026]`, bank `MTA` ACL = localhost + mta, bank `INTERNAL` ACL = localhost + cron + mcp (mcp optional)
- [ ] amavis IP watchdog (`PEER_WATCH_INTERVAL`) re-renders ACLs + `amavisd reload` (verify reload re-reads `inet_acl`)
- [ ] `check.sh` checks both ports
- [ ] cron: `AMAVIS_SUBMIT_PORT=10026` in the five scripts
- [ ] Dev compose: drop or loopback-bind `10024`
- [ ] Tests: cron→10026 OK, cron→10024 refused, api→10024/10026 refused, mta flows unchanged, recreate cron → accepted again within one interval
- [ ] Docs (`.agents/`, env.sample, Changelog)
- [ ] Full `./test.sh` green

Log

| Date | Type | Entry |
|------|------|-------|

---

## P2 — Write access + sending

Status: —

Checklist
- [ ] `mark_emails`, `move_emails`, `create_folder`, `rename_folder`, `save_draft`
- [ ] `report_spam`, `not_spam`, `trash_emails`, `restore_from_trash`, `delete_folder` with confirm handles; no expunge path anywhere
- [ ] `send_email`, `reply_email` (default sender rule), `forward_email` via `amavis:10026`; sender ownership check; Bcc handling; Sent copy
- [ ] Send rate limiter + `maild-mcp: sent` log line; size limit
- [ ] Send confirmation per user preference (external recipients by default)
- [ ] Service mail (2FA, magic links, notices) via the same path
- [ ] Tests: DKIM-signed delivery, Sent copy present, alias sender refused, foreign sender refused, Junk move triggers Bayes learn, Trash never expunged, rate limit triggers
- [ ] Full `./test.sh` green

Log

| Date | Type | Entry |
|------|------|-------|

---

## P3 — Admin panel

Status: —

Checklist
- [ ] Admin login + ALTCHA + lockout, 72 h session, recovery link, CLI reset
- [ ] Admin user group: email change (two codes), password change (code)
- [ ] Domains group: dual list from catalogue, logging toggles, rotation + retention
- [ ] User policy group
- [ ] Master tokens: create (≤ max TTL, never forever), Active/Disabled/Revoked tabs, `act_as`, CIDR allowlist
- [ ] Service email group: internal / external SMTP + Test button
- [ ] Logs viewer
- [ ] Tests: `pwa-test` admin flows, master token access + audit, external SMTP test against a fixture
- [ ] Full `./test.sh` green

Log

| Date | Type | Entry |
|------|------|-------|

---

## P4 — OAuth 2.1

Status: —

Checklist
- [ ] Protected resource metadata, AS metadata, `401` + `resource_metadata`
- [ ] Authorize (PKCE S256), token (form-urlencoded), refresh rotation + reuse detection, revoke
- [ ] CIMD (SSRF-safe fetch) + DCR
- [ ] Consent UI (login + scopes + address selection), loopback redirect matching, `iss` in response
- [ ] OAuth grants listed with PATs; 30-day idle on refresh families
- [ ] Tests: full flow with a scripted client (CIMD and DCR), MCP Inspector; manual connector test in Claude and ChatGPT against a public test host (requires a reachable host — note result)
- [ ] Full `./test.sh` green

Log

| Date | Type | Entry |
|------|------|-------|

---

## P5 — REST mirror, skill, docs

Status: —

Checklist
- [ ] `/api/v1/mail/*` mirror, `/api/v1/openapi.json`, `/api/v1/skill.md`
- [ ] Connection help on the user page (Claude, ChatGPT, Claude Code, Gemini CLI, mcp-remote, REST)
- [ ] `mcp/README.md`, `.agents/` (catalog, configuration, overview), `env.sample`, `Changelog.md`, `README.md`
- [ ] Tests: REST parity with MCP tools on fixtures
- [ ] Full `./test.sh` green

Log

| Date | Type | Entry |
|------|------|-------|

---

## Final review

Status: —

- [ ] Every phase `verified` from a clean dev stack
- [ ] `Idea.md` goals, one by one:
  - [ ] Own container on the MailD network, Traefik route on a configurable host, valid TLS (operator ingress)
  - [ ] Python 3.14 + Django + dedicated API lib; Postgres with own DB/credentials from compose vars
  - [ ] `/adminmcp`, `/`, `/api/v1/` endpoints
  - [ ] Admin: seed from env (ignored once set), captcha, recovery link, 72 h JWT, settings groups with Update/Restore, responsive
  - [ ] Admin user: email change with two codes, password change with code
  - [ ] Domains: list, allow/deny dual list, logging toggles, per-action categories, rotation day/week/month
  - [ ] User policy settings
  - [ ] Master tokens: name, active/disabled/revoked, due time (default 24 h, never forever), tabs
  - [ ] Service email internal/external + test button
  - [ ] User page: IMAP login, main account, multiple addresses, captcha, 24 h JWT
  - [ ] Main account: MCP master switch, secondary addresses with magic link, 2^n resend, disable/remove with confirmation + notice
  - [ ] MCP access tokens: names, monthly default / forever with warning, enable/disable/revoke, due date shown, multiple per user (+ D12 idle rule)
  - [ ] 2FA/notifications sent through the service email
  - [ ] Mailbox access choice argued (proposal §5) and implemented
  - [ ] Sending only as owned, enabled addresses; master switch obeyed; Sent copy
  - [ ] Actions: search (no read flag), new arrivals hint, fetch marks read, mark read/unread, spam (confirm), trash never wipe (confirm), send, reply with recipient-as-sender default, extra tools
  - [ ] Compatibility: MCP spec revisions via SDK v2, Claude / ChatGPT / Gemini CLI / skill
- [ ] Proposal decisions D1–D13 implemented as written, or deviations logged with reason
- [ ] Security items: rehash fix (§5.4), role grants (D8), amavis ACLs (D13), SSRF controls, no secrets in logs
- [ ] Scratch dirs in `/tmp/maild-mcp-*` removed

Log

| Date | Type | Entry |
|------|------|-------|

---

## Global log

| Date | Type | Entry |
|------|------|-------|
| 2026-10-29 | decision | Technical proposal accepted with decisions D1–D13 (`mcp/technical-proposal.md`). |
| 2026-10-29 | action | `mcp/progress.md` created. |
| 2026-10-29 | blocker | No dev stack can run from this session yet: the linked computer exposes file transfer only (no shell), and the cloud workspace's Docker cannot pull images (`registry-1.docker.io`, `deb.debian.org`, `dl-cdn.alpinelinux.org`, `mcr.microsoft.com`, `database.clamav.net`… are refused by the egress policy). P0 baseline not taken. |
