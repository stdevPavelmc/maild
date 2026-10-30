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
| P1 | User login (IMAP), accounts/addresses/magic links, PATs, read tools, audit logs | done | 2026-10-29 | 2026-10-30 | |
| P1b | amavis `10026` + ACLs on both ports + IP watchdog; cron jobs to `10026` (D13) | done | 2026-10-30 | 2026-10-30 | |
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

Status: done (clean-stack verification pending)

Checklist
- [x] User login via IMAP LOGIN (STARTTLS) + ALTCHA + lockout; domain allow-list (catalogue, deny by default)
- [x] Accounts, main address, MCP master switch
- [x] Secondary addresses: magic link (24 h), resend backoff 2^n from 1 min, disable/remove + notices, global uniqueness + "Already in use" + postmaster notice (throttled), owner-wins on pending
- [x] PATs: create/list/enable/disable/revoke, forever warning, 30-day idle disable + re-enable from UI only
- [x] Web session (short JWT + rotating refresh cookie, 24 h)
- [x] MCP endpoint `/api/v1/mcp` (SDK v2, stateless), per-request authorization chain (§8.2), scopes
- [x] Read tools: `list_accounts`, `list_folders`, `check_new_mail`, `search_emails`, `get_email` (mark read default), `get_thread`, `get_attachment`, `get_quota`
- [x] IMAP pool per mailbox (≤ 3), cert verification against `mail.crt` (leaf pin)
- [x] Audit/access/error logs (date-named files, JSON lines)
- [x] User SPA (React, EN/ES, mobile), `i18n:check`
- [x] Tests: `test.sh` (login, token auth 401/403, read tools on fixtures, search does not set `\Seen`, `get_email` sets it, idle-disable), pytest, `pwa-test` user flows — K1–K22, 14 pytest units, 6 `run.sh mcp` flows
- [x] Full `./test.sh` green — 127 passed / 0 failed / 0 skipped, 4m56s
- [x] Manual check by Pavel: Claude Code reads a fixture mailbox (exit criterion, manual half)

Log

| Date | Type | Entry |
|------|------|-------|
| 2026-10-29 | action | Baseline inherited from P0's verification run (clean stack, 105 passed / 0 failed / 0 skipped). P1 → Initiated. |
| 2026-10-29 | decision | **Asked Pavel** — service mail before P1b exists: submit to **`amavis:10024`** now (`MCP_SMTP_PORT` tunable); P1b switches the default to `10026`. |
| 2026-10-29 | decision | **Asked Pavel** — domain allow-list before the P3 panel: **CLI** `manage.py mcp_domains list\|allow\|deny <domain>`, audited, kept afterwards as the fallback beside the UI. |
| 2026-10-29 | decision | **Asked Pavel** — exit criterion check: **scripted** SDK-client test in `test.sh` (PAT against `http://mcp:8080/api/v1/mcp`) **plus a manual** MCP Inspector / Claude Code check by Pavel with commands I provide; his Claude Code config is not touched. |
| 2026-10-29 | decision | Library pins checked today: `mcp` 2.3.0, django-ninja 1.7.3, imapclient 4.1.0, altcha 2.3.0, PyJWT 2.15.1, html2text 2025.4.15, nh3 0.3.7, cryptography 50.0.2, pytest 9.2.0, pytest-django 4.14.0. SPA reuses the AdminNG PWA stack (React 18, Vite 5, Tailwind 3, i18next, react-router 6). |
| 2026-10-29 | decision | **Asked Pavel** — absolute links: new variable **`MCP_PUBLIC_URL`** (default `https://<MCP_HOSTNAME>`, env.dev `http://localhost:8085`); never derived from request headers. |
| 2026-10-29 | decision | **Asked Pavel** — a secondary that is **disabled** in account A and logs in with its own password: **login refused** ("disabled in another account") until A re-enables or removes it. (Active secondary → lands on A; pending → owner wins, as in §7.3.) |
| 2026-10-29 | decision | **Asked Pavel** — MCP master switch default for a new account: **on**. |
| 2026-10-29 | decision | mda TLS: the mcp **pins** the leaf certificate (byte-identical to the first cert in `MCP_IMAP_CA_FILE`) instead of chain + hostname checks: the dev cert is self-signed `CN=maild.cu` without SAN/extensions, and in production `/certs/mail.crt` is issued for the public mail host, never `mda` (proposal §5.3 allows "or pins it"). |
| 2026-10-29 | decision | ALTCHA protocol **v1** (SHA-256 PoW, `create/verify/solve_challenge_v1`): every widget version accepts it; solutions single-use via the `altcha_used` table. |
| 2026-10-29 | decision | Duration variables use the proposal's notation (`15m`, `24h`, `7d`): `MCP_ACCESS_TTL` (15m), `MCP_USER_SESSION_TTL` (24h). User-policy defaults live in `mcpcore/policy.py` until the P3 settings table. |
| 2026-10-29 | decision | Every address of an account (the main one too, `is_main`) is an `account_address` row, so one unique column enforces D11. Refresh-token reuse detection via `web_session.prev_refresh_hash` (reuse of the last superseded token revokes the session). Tokens get `reenabled_at` so re-enabling restarts the D12 idle clock without faking `last_used_at`. |
| 2026-10-29 | decision | MCP auth is done by a bearer wrapper in `asgi.py` (not the SDK's `token_verifier`): it can answer 403 `mcp_disabled` and 403 `insufficient_scope` (reads the JSON-RPC body for `tools/call`) as §8.2 requires; the SDK only gives 401. 401 carries `WWW-Authenticate: Bearer resource_metadata=…`. Principal reaches the tools via `request.state`. Lifespan is now **on** (the SDK session manager + the hourly jobs loop). |
| 2026-10-29 | decision | SDK v2 calls tools with the alias as keyword, so `from` cannot be a parameter: the search filter is named **`sender`** (deviation from §8.3 `from?`; P2's `send_email` will use the same name). |
| 2026-10-29 | finding | Dovecot returns "No quota" without a QUOTAROOT line for an unlimited mailbox (quota 0); imapclient's `get_quota_root` crashes on it → treated as unlimited. |
| 2026-10-29 | decision | Dev `MCP_PUBLIC_URL` default (`http://localhost:8085`) is set in `docker-compose-dev.yml`, not in `env.dev`: editing env.dev recreates every service and re-triggers the stale-peer-IP problem found in P0. New passthrough keys in all four compose files: `MCP_PUBLIC_URL`, `MCP_TRUSTED_PROXIES`, `MCP_SMTP_HOST`, `MCP_SMTP_PORT`, `MCP_ACCESS_TTL`, `MCP_USER_SESSION_TTL` (gitlab still in sync). |
| 2026-10-30 | finding | Domain allow-list cache bug (found by K3–K5): caching the whole verdict for 30 s per worker kept a domain denied after `mcp_domains allow`. Now only the catalogue state is cached; the policy row is read on every call. |
| 2026-10-30 | finding | test.sh cleanup: raw `DELETE FROM account` failed on FKs (Django's CASCADE is ORM-side, not `ON DELETE`); children (token, account_address) are deleted first now. |
| 2026-10-30 | action | Section K (K1–K22) added to `test.sh`; iterated with a scratch runner (suite preamble + section K). Last run: **19 passed / 3 failed** (K15, K16, K18 — all from one test bug, see below). Full suite not run for P1 yet. |
| 2026-10-30 | action | **Session paused by Pavel.** Nothing committed for P1. |
| 2026-10-30 | action | Resumed (host rebooted; stack came back healthy on its restart policies). K15 link decoding fixed (`policy=email.policy.default` + `get_content()`), dev leftovers cleaned. Section K alone: **22 passed / 0 failed**. |
| 2026-10-30 | decision | SPA in `mcp/ui`, pinned to the **AdminNG lockfile versions** (React 18.3.1, Vite 5.4.21, Tailwind 3.4.19, i18next 23, react-router 6.30, TS 5.6.3) as D4/§7.1 ask, not today's majors (React 19, Vite 8, Tailwind 4). ALTCHA widget **2.3.0** (last 2.x, speaks the v1 protocol the server uses). `scripts/check-i18n.mjs` copied from AdminNG; `npm run build` = i18n:check + tsc + vite. Node stage `node:26-alpine` in `mcp/Dockerfile`; output split into `ui-dist/{index.html,assets/,root/}`; WhiteNoise marks Vite-hashed files immutable. Builds and lockfile generation run in containers (no host `node_modules`). |
| 2026-10-30 | decision | The magic link is a fragment (`/confirm#token`, never in logs or Referer) and confirming needs an explicit button press (a mail scanner pre-fetching the link confirms nothing); the page drops the token from the address bar. |
| 2026-10-30 | action | Browser pane check: the page renders, the widget loads under the CSP. I did not complete the ALTCHA there myself (assistants do not solve CAPTCHAs interactively); the Playwright flows exercise it instead. |
| 2026-10-30 | decision | `pwa-test` reused for the MCP page (proposal: web UI checks through that harness): new entrypoint mode **`mcp`** (tunnel `localhost:8085 → mcp:8080`, health path configurable via `E2E_HEALTH_PATH`), specs in `tests/mcp/`, ignored by the AdminNG gate (`PWA_TEST_MCP`). Fixture helpers in `lib/mcp.ts` (docker exec, like the AdminNG device CLI). `./adminng/pwa-test/run.sh mcp`: **6 passed** (login with the real widget + reload, switch, token once/masked/revoke, forever warning, magic link → confirm → disable with type-to-confirm, ES + 375 px without horizontal scroll). |
| 2026-10-30 | finding | Pre-existing (fixed later the same day, see the P1b log): AdminNG's own `run.sh flows` fails at `flows.spec.ts:115` — `getByLabel('Domain', {exact:true})` now matches two selects on the logs screen (`#domain-scope` and the logs filter), a Playwright strict-mode violation. Neither the spec nor the AdminNG UI changed in this work; needs its own fix. |
| 2026-10-30 | action | pytest units `mcp/tests/test_units.py` (handles bind/tamper/expiry, token hashing, resend backoff, IMAP criteria + binary OR tree, message ids/UIDVALIDITY, idle anchor, durations), run in a throwaway mcp-image container with `/tmp/maild-mcp-p1` as the pip target: **14 passed**. |
| 2026-10-30 | action | Docs: `env.sample` (6 new optional vars), image ENV defaults (`MCP_SMTP_*`, TTLs), `.agents/services/{catalog,configuration}.md`, `.agents/devops/workflows.md`, `AGENTS.md`, `adminng/pwa-test/README.md`, `mcp/README.md` (incl. the `claude mcp add` command), `Changelog.md`. |
| 2026-10-30 | action | Full `./test.sh` on the running dev stack: **127 passed / 0 failed / 0 skipped, 4m56s** (105 + K1–K22). P1 → **done**. Open: Pavel's manual MCP client check, then the clean-stack verification. Nothing committed. Scratch `/tmp/maild-mcp-p1/` kept until P1 is verified. |
| 2026-10-30 | finding | Pavel's first Claude Code attempt listed the 8 tools but every prompt failed with `ECONNREFUSED` + "claude.ai connectors are disabled". Cause on his workstation, not in MailD: `~/.bashrc` exported `ANTHROPIC_BASE_URL=http://127.0.0.1:8080` + `ANTHROPIC_AUTH_TOKEN` from an old local-model setup (nothing listens there), so the CLI's *model* requests were refused. The mcp access/audit logs showed every MCP request answered 200 and no tool call. |
| 2026-10-30 | action | **Manual exit-criterion check passed (Pavel)**: Claude Code CLI with a PAT checks the inbox and reads mails through `maild-dev` (`http://localhost:8085/api/v1/mcp`). P1 exit criterion met. |
| 2026-10-30 | decision | P1 clean-stack verification **deferred**: wiping `ldata/` now would delete the PAT Pavel's Claude Code uses. To be run at a convenient point (it does not block P1b, whose baseline is P1's full pass). |
| 2026-10-30 | action | P1 committed on branch `mcp`. |

### Pause notes (P1, 2026-10-30 — resolved the same day)

Done (code in the tree, uncommitted):
- Backend: `mcpcore/{policy,crypto,audit,domains,imap,mailer,webauth,accounts,tokens,authz,mail,jobs}.py`, models + migration `0002_p1_accounts_tokens`, CLIs `mcp_domains` and `mcp_jobs`, `webapi/api.py` (login/refresh/logout/me/switch/prefs/addresses/confirm/tokens), `mcpserver/server.py` (8 read tools), root router `asgi.py`, `mcp/tests/{altcha_solve,mcp_call}.py` (copied into the image), settings + requirements pinned.
- Verified by hand on the dev stack: login with ALTCHA, PAT, all read tools through the SDK client, `\Seen` semantics, cursor/watermark/thread, 401/403 statuses, SPA fallback route.
- `test.sh` section K + its cleanup.

Next steps:
1. **Fix K15's link decoding in `test.sh`** (not applied — the edit was rejected when the session stopped): in the python one-liner that extracts the magic link, parse with `policy=email.policy.default` and use `get_content()` (the plain `Message` has no `get_body`). This should also turn K16/K18 green (they depend on bob being confirmed).
2. Clean the dev mcp DB leftovers from the manual repro before re-running: alice's account with a pending `bob@example.net` and the magic-link mail in bob's INBOX (`DELETE FROM web_session; DELETE FROM token; DELETE FROM account_address; DELETE FROM account;` in db `mcp`, and `doveadm expunge -u bob@example.net mailbox INBOX header From "MailD MCP"`). `example.net` is currently **allowed** in `domain_policy` (dev).
3. User SPA (React 18 + Vite + Tailwind + i18next EN/ES, `i18n:check`): login (ALTCHA widget), account (switch, addresses with confirm dialogs, resend countdown), tokens (create with forever warning, list, enable/disable/revoke), `/confirm` page; node:26-alpine build stage in `mcp/Dockerfile` → `/app/ui-dist` (WhiteNoise already wired, CSP in `views.spa`).
4. `pwa-test` user flows; pytest (unit: handles, idle rule, criteria builder) run in a container with `/tmp/maild-mcp-p1` mounted.
5. Docs (`env.sample`: `MCP_PUBLIC_URL`, `MCP_TRUSTED_PROXIES`, `MCP_SMTP_*`, TTLs; `.agents/`, mcp README, Changelog), full `./test.sh`, then the manual MCP Inspector / Claude Code check by Pavel.
- Deferred from §7.3 to P2: the Preferences section (send confirmation etc.) except language; read rate limiting.
- Scratch dir `/tmp/maild-mcp-p1/` (scratch runner) stays until P1 ends.

---

## P1b — amavis 10024/10026 split (D13)

Status: done (clean-stack verification pending, together with P1's)

Checklist
- [x] `50-user`: `$inet_socket_port = [10024, 10026]`, bank `MTA` ACL = localhost + mta, bank `INTERNAL` ACL = localhost + cron + mcp (mcp optional)
- [x] amavis IP watchdog (`PEER_WATCH_INTERVAL`) re-renders ACLs + `amavisd reload` (verify reload re-reads `inet_acl` — verified: mcp, absent from the boot ACL, admitted after the watchdog's HUP)
- [x] `check.sh` checks both ports
- [x] cron: `AMAVIS_SUBMIT_PORT=10026` in the five scripts
- [x] Dev compose: drop or loopback-bind `10024` — dropped
- [x] Tests: cron→10026 OK, cron→10024 refused, api→10024/10026 refused, mta flows unchanged, recreate cron → accepted again within one interval — L1–L6 (+ mcp→10026 / mcp→10024 refused)
- [x] Docs (`.agents/`, env.sample, Changelog)
- [x] Full `./test.sh` green — 133 passed / 0 failed / 0 skipped, 5m20s

Log

| Date | Type | Entry |
|------|------|-------|
| 2026-10-30 | action | Baseline inherited from P1's full pass (127/0/0). P1b started after the P1 commit `0904907`. |
| 2026-10-30 | decision | ACLs in their own rendered file `conf.d/52-maild-acl` (`$policy_bank{'MTA'}{inet_acl}`, `$policy_bank{'INTERNAL'}{inet_acl}`), rewritten wholesale by the boot and by the watchdog, instead of sed-patching addresses inside the distro files. Loopback always in (check.sh). `50-user` declares `$inet_socket_port = [10024, 10026]`, both banks `originating => 1`. |
| 2026-10-30 | decision | Watchdog mirrors the mta's: same variable `PEER_WATCH_INTERVAL` (default 30 s, 0 = off — one operator setting now drives both), re-resolves mta/cron/mcp, keeps the old address when a lookup fails (never an ACL without the mta or cron), lets mcp come and go (optional, starts after amavis), re-renders + `kill -HUP` (same reload path as `sa-update-loop.sh`) and updates `/tmp/{MTA,CRON,MCP}IP` so `check.sh` stays healthy. New image defaults: `MCP=mcp`, `PEER_WATCH_INTERVAL=30`; `EXPOSE 10024 10026`. |
| 2026-10-30 | finding | Behaviour measured on the dev stack: refused clients get their connection closed after accept (`SMTPServerDisconnected` / no 220) and amavis logs `DENIED ACCESS from IP <x>, policy bank '<bank>'`. Probe matrix: mcp 10024 ✗ / 10026 ✓, cron ✗ / ✓, api ✗ / ✗. |
| 2026-10-30 | decision | cron: new image default `AMAVIS_SUBMIT_PORT=10026`, used by the five mailing scripts (`resume`, `outbound_watch`, `check_maildirs`, `backup_db`, `check_dns`). mcp: `MCP_SMTP_PORT` default → 10026. Dev compose: `10024:10024` dropped (checklist option; a host-side connection arrives from the docker gateway and would be refused by the ACL anyway). |
| 2026-10-30 | action | `test.sh` section L (L1–L6) written and run alone: **6 passed** — L6 moved cron 172.23.0.6 → 172.23.0.12 (stop, placeholder container takes a free address, start) and 10026 admitted it again after 6 s with amavis healthy. |
| 2026-10-30 | action | Docs: `.agents/services/{catalog,configuration}.md` (amavis listeners + watchdog, cron submit port, mcp port), `.agents/architecture/overview.md` (internal submitters, service map), `.agents/devops/workflows.md` (section L, 133 checks), `AGENTS.md`, `env.sample` (`PEER_WATCH_INTERVAL` scope, `AMAVIS_SUBMIT_PORT`, `MCP_SMTP_PORT`), `amavis/README.md`, `cron/README.md`, `Changelog.md`. |
| 2026-10-30 | finding | First full run: 132 passed / 0 failed / **1 skipped** — L6 could not move cron: the free-address placeholder got another IP and cron got its old one back (IPAM-dependent, flaky). Fixed: the placeholder is pinned to cron's released address (`docker run --ip`, accepted on the compose network `172.23.0.0/16`), so cron must come back elsewhere. Section L alone twice: 6/6 both (re-admitted after 32 s and 13 s, bound 2 × 30 + 15 s). |
| 2026-10-30 | action | Full `./test.sh`: **133 passed / 0 failed / 0 skipped, 5m20s** (127 + L1–L6; sections A–G prove the mta path on 10024 and the cron jobs on 10026, K the mcp service mail on 10026). P1b → **done**. Nothing committed yet. |
| 2026-10-30 | action | P1b committed on branch `mcp`. |
| 2026-10-30 | action | **AdminNG pre-existing failure fixed** (Pavel's request; outside the MCP phases, logged here because it was found here). Root cause: since `92d4af0` (2026-10-19) the Logs filter kept a private copy of the global domain scope, seeded once ("local override wins after that"), so on the Logs screen two "Domain" selects could disagree and changing the sidebar did nothing; the flows spec's `getByLabel('Domain', {exact:true})` also matched both (strict-mode violation), so that step had failed since it was written. Fix: the Logs Domain filter now reads/writes the global scope (`useSelectedDomain` + `setSelectedDomain`), the pattern the Accounts selector already used (spec §6.2, now stated in `adminng/doc/technical-draft.md`). Test: the filters are taken from `main`, plus a two-way sync step (filter → sidebar + `domain=` query, sidebar → filter) that the old code fails. AdminNG `run.sh verify`: 5/5 specs, Lighthouse within budget (perf 98, a11y 100, best practices 100); `run.sh mcp` 6/6. |
| 2026-10-30 | action | AdminNG Logs fix committed on branch `mcp`. |

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
