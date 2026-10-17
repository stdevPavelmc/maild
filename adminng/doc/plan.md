# AdminNG — Implementation Plan

**Companion of [technical-draft.md](technical-draft.md).** Phases are small,
mergeable units with explicit acceptance criteria ("Done when"). The plan
covers the whole lifecycle from scaffolding to the PostfixAdmin-deprecation
decision point.

## Working conventions (every phase)

- Local work uses `docker-compose-dev.yml` only; **every** compose command
  carries `--env-file env.dev`.
- The acceptance suite is `./test.sh`; fixtures come from `./bootstrap-dev.sh`
  (passwords in `test.creds`, git-ignored).
- Compose chain rule: any compose change lands in `docker-compose-dev.yml` →
  `docker-compose.yml` → `compose-github.yml` + `compose-gitlab.yml` **in the
  same commit** (only `image:` lines differ; GitLab uses
  `IMG_API`/`IMG_ADMINNG` + `${TAG}`).
- Doc rule: the matching `.agents/` files, `env.sample`, `Changelog.md` and
  this plan's checkboxes are updated **in the same commit** as the change they
  describe.
- CI: the GitHub workflow `SERVICES` list and `.gitlab-ci.yml` keep covering the
  new services from Phase 0 on — a phase is not done until CI is green.

## Progress tracking

Status legend: **initiated** (started, incomplete) · **partial** (mostly done,
blocked or pending validation) · **finished** (implemented, not yet verified by
running it) · **validated** (verified by running the acceptance checks).

| Phase | Status | Evidence / notes |
|---|---|---|
| 0 — Scaffolding & wiring | **validated** (CI pending remote run) | per-task table below |
| 1 — Core catalogue API | not started | |
| 2 — Security model | not started | |
| 3 — PWA frontend | not started | |
| 4 — APK pipeline | not started | |
| 5 — Hardening & decision | not started | |

### Phase 0 — task status

| # | Task | Status | Evidence |
|---|---|---|---|
| 1 | `adminng/api/` skeleton — FastAPI, `GET /health`, migration runner, `adminng.py`, Dockerfile | **validated** | image built; `/health` → 200 `{"database":"up"}`; `migrations applied: 001_adminng_core.sql`; 5 tables in the `adminng` DB; CLI list/approve/revoke/totp-reset exercised |
| 2 | `adminng/pwa/` skeleton — Vite+React+TS+Tailwind+shadcn-style UI, i18n en/es, nginx, multi-stage Dockerfile | **validated** | `tsc --noEmit && vite build` inside the image; shell served 200; `manifest.webmanifest`, `sw.js` and hashed assets present; EN/ES switch shipped |
| 3 | `db/Dockerfile` + `ensure_databases.sh`: create `ADMINNG_DB` | **validated** | db log: `db: created database 'adminng'`; deviation: own `ADMINNG_DB` var instead of a `POSTGRES_EXTRA_DB` list (mua contacts DSN) |
| 4 | Four compose files: `adminng` (8083 / Traefik) + `api` (internal) | **validated** | `compose config -q` passes on all four; both containers healthy; `8083:80` in dev, no port in production |
| 5 | `env.sample` — `ADMINNG_*` catalogue + `ADMINNG_DB` | **finished** | documented; not runtime-testable by nature |
| 6 | CI — `SERVICES`, `IMG_API`/`IMG_ADMINNG`, build/release jobs | **finished** | GitHub workflow + `.gitlab-ci.yml` updated; pending the first remote pipeline run to call it validated |
| 7 | Docs — `.agents/*`, `Changelog.md`, `AGENTS.md`, `adminng/README.md`, `db_upgrade.md` | **finished** | updated in the same commit, per the doc rule |

**Phase 0 deviations found while implementing**

- `ADMINNG_DB` instead of `POSTGRES_EXTRA_DB=contacts,adminng`: `mua/config-setup.php`
  consumes `POSTGRES_EXTRA_DB` as a **single** DB name (SnappyMail contacts), so a
  comma list there would silently break the webmail address book.
- `adminng.py` is symlinked to `/usr/local/bin` so the documented
  `docker compose exec api adminng.py …` works (`exec` does not look in `/app`).
- The real PWA service-worker plugin package is **`vite-plugin-pwa`** (the
  original draft's `@vite-pwa/plugin` was a typo); the code and docs use the
  real name.
- Expected noise during validation: right after the db container is recreated,
  `bootstrap-dev.sh`'s IMAP verification can report one `temp_fail` for the
  sysadmin mailbox (Dovecot auth process reconnecting); a re-run verifies all
  fixtures cleanly — observed and confirmed on this stack.

## Phase 0 — Scaffolding & wiring

**Status:** validated (the CI item awaits its first remote run).

**Goal:** the stack boots with two empty-but-healthy services; every chain
(compose, env, CI, docs) already knows them.

Tasks:
1. `adminng/api/`: FastAPI project skeleton — `app/`, `GET /health`, the
   idempotent migration runner (`migrations/` + `schema_version`), `adminng.py`
   CLI stub, `Dockerfile` (python:3.14-slim-trixie, ENV defaults per §2.4 of
   the draft, HEALTHCHECK on `/health`).
2. `adminng/pwa/`: Vite + React + TS + Tailwind + shadcn/ui skeleton, i18n
   scaffold (en + es), `nginx/` proxy conf, multi-stage `Dockerfile`
   (node build → nginx serving `dist/` + `/api/v1/` proxy).
3. `db/Dockerfile` + `db/ensure_databases.sh`: create `ADMINNG_DB` (default
   `adminng`) on every boot. **Deviation from the original wording**
   (`POSTGRES_EXTRA_DB=contacts,adminng`): `mua/config-setup.php` reads
   `POSTGRES_EXTRA_DB` as **one** database name (the SnappyMail contacts DSN),
   so AdminNG gets its own variable; db and api bake the same default.
4. All four compose files gain `adminng` (dev `8083:80`; prod Traefik
   labels `adminng.${DEFAULT_DOMAIN}`, port 80) and `api`
   (no ports, `env_file: env.dev/.env`, `${POSTGRES_PASSWORD:?}` guard).
5. `env.sample`: commented `ADMINNG_*` override catalogue.
6. CI: `SERVICES` gains `api adminng`; `.gitlab-ci.yml` gains
   `IMG_API`/`IMG_ADMINNG` + validation vars.
7. Docs: `.agents/services/catalog.md` + `configuration.md` rows,
   `.agents/devops/workflows.md` commands, `Changelog.md`, `adminng/README.md`
   access points.

**Done when:** `./bootstrap-dev.sh` brings the stack up; `curl localhost:8083/`
serves the skeleton; `curl localhost:8083/api/v1/health` answers **through the
nginx proxy**; the `adminng` DB exists with its tables; all four compose files
validate; CI is green.

## Phase 1 — Core catalogue API

**Status:** not started.

**Goal:** the full CRUD surface over the legacy catalogue, correctly scoped
and paginated — but with plain bearer auth (the security model lands in
Phase 2).

Tasks:
1. Catalogue layer: read/write on `domain`, `mailbox`, `alias`, `admin`,
   `domain_admins` with the §3.1 write-compatibility rules (md5crypt,
   `maildir='domain/local_part/'`, quota in bytes/0=unlimited, PostfixAdmin's
   cascade discipline on deletes, one transaction per mutation).
2. Routes: domains / mailboxes / aliases / admins CRUD, `GET /search`,
   cursor pagination on every list route, the uniform error taxonomy.
3. Quota usage: read-only `ldata/vmail` mount, `.maildirsize` parsing with the
   du fallback + cache (`GET /mailboxes/{u}/quota`).
4. Multi-tenant scoping middleware (domain admins × `domain_admins`).
5. Restart-advisory response on domain create (§10.9 of the draft).
6. Integration tests (httpx) against the dev fixtures, including the
   **write-compat assertions**: a mailbox created through the API is
   byte-identical (columns, hash format, maildir string) to one created
   through PostfixAdmin, and it **can log into IMAP** immediately.

**Done when:** a full CRUD round-trip (create user → edit quota → add alias →
suspend → reactivate → delete) passes via curl against the dev fixtures;
the write-compat and IMAP-login assertions pass; a domain admin cannot read
or mutate a foreign domain (negative tests); `test.sh` gains the CRUD
black-box checks.

## Phase 2 — Auth, device trust, TOTP, re-auth, audit

**Status:** not started.

**Goal:** the security model of §4 lands completely; devices gate everything.

Tasks:
1. Device middleware (`X-Device-ID` on every route except `/health`),
   `PENDING`/`APPROVED`/`REVOKED` lifecycle, handshake + status endpoints.
2. `login-step1`/`step2` against the catalogue `admin` table (md5crypt
   verify), flow tokens; TOTP (RFC 6238, pyotp) with the **enrollment flow**
   (`REQUIRES_TOTP_ENROLLMENT` → QR → confirm), `ADMINNG_TOTP_REQUIRED`
   policy; access/refresh tokens bound to `(username, device_id)` with jti
   rotation and the 15-min idle purge.
3. Re-auth: `POST /auth/reauth-confirm` → 30-second scoped
   `X-Security-Validation-Token` enforced on every destructive route.
4. `adminng.py` CLI: `--list-devices`, `--approve-device`, `--revoke-device`,
   `--totp-reset` (the §4.2 bootstrap mechanism — documented in
   `adminng/README.md`).
5. Audit trail: `audit_event` rows on every login attempt, device transition
   and catalogue mutation; the `GET /logs` route with cross-filters and the
   forced domain filter for custom admins.
6. Rate limiting + lockout (§4.6).
7. `cron/scripts/backup_db.sh`: extend to **also dump the `adminng` DB**
   (second archive, same retention/validation — today it dumps only
   `POSTGRES_DB`).
8. `bootstrap-dev.sh`: self-approve the dev devices via the CLI; extend
   `test.creds`.

**Done when:** an unapproved device is rejected on every route (negatives);
login+TOTP happy path and lockout pass; a DELETE without the validation
token returns `403 OPERATION_NOT_VERIFIED`; CLI approve/revoke work; the
audit log shows every action performed in the tests; `test.sh` gains the
auth/device/re-auth/audit black-box checks; the daily backup produces both
archives.

## Phase 3 — PWA frontend

**Status:** not started.

**Goal:** the complete AdminNG experience against the finished API — the
everyday admin work is fully doable from a phone.

Tasks:
1. Shell layouts: desktop sidebar + high-density tables (quota bars
   blue→orange→red); mobile header + bottom tab bar (Admin · Accounts · Logs)
   + contextual FAB.
2. Screens & flows per §6.3: login, 2FA, TOTP enrollment (QR), device-pending
   lock screen (copyable ID + poll button), entity editors as drawers/sheets
   (user editor with in-situ alias tags; superadmin toggle locking the domain
   picker), destructive-confirmation sheet (re-auth + 5-second armed button),
   devices panel (pending queue, armed authorize, revoke with re-auth), logs
   timeline with cross-filter tags + `[🛡️ VIEW LOGS]` jump with pre-applied
   persistent filter.
3. Onboarding "server URL" screen — **APK only** (the web app is same-origin).
4. Rapid search (`CTRL/CMD+K` / mobile lupa): `GET /search`, categorized
   badges, editor drawer on select.
5. Offline rules: `vite-plugin-pwa` (CacheFirst assets / NetworkOnly API),
   read-only banner + disabled write controls on connectivity loss, cached
   log pages via Dexie.
6. Backgrounding: privacy shield after >2 min (biometric/unlock to dismiss),
   full token purge after >15 min idle.
7. Virtualized lists (TanStack Virtual or equivalent) + cursor pagination.
8. **i18n: English source strings + complete Spanish translation**, detected
   on first load (`navigator.language` → `Accept-Language`), overridable in
   Settings, persisted (i18next + detector). No hardcoded strings ship.
9. Settings screen: language, API base (APK only), about/version.

**Done when:** every API feature is reachable from the UI on desktop **and**
from an installed PWA on Android; the offline/backgrounding rules behave as
specified; switching language to Spanish translates the whole interface with
no missing keys (i18n completeness check in CI); the Lighthouse PWA check
passes installability on the dev stack.

## Phase 4 — Android APK pipeline

**Status:** not started.

**Goal:** a signed APK as an artifact of every release, reproducibly.

Tasks:
1. `adminng/pwa/app-generate.sh`: dockerized PWA→APK build (Bubblewrap/TWA
   against the manifest + a build-time `VITE_APP_BASE`), no local Android SDK
   required on the dev machine.
2. GitHub Actions: release workflow (tags, after the image builds) runs
   `app-generate.sh` with the signing keystore from repository secrets and
   attaches the signed APK as a release artifact; `.gitlab-ci.yml` equivalent
   if the GitLab pipeline stays the canonical release path.
3. Keystore management decision + rotation runbook (operator decision, §11.4
   of the draft).
4. The APK's first-run flow: server-URL onboarding → handshake → login →
   (enrollment/)2FA → possibly the device-pending lock screen.

**Done when:** a tagged release produces the APK artifact; installing it on a
phone against the dev stack reaches a working login (and the device shows up
`PENDING` until approved — proving the zero-trust gate works on mobile too).

## Phase 5 — Hardening, integration & the deprecation decision

**Status:** not started.

**Goal:** production-grade confidence and an explicit, informed decision on
PostfixAdmin's future.

Tasks:
1. WebAuthn/passkeys (Android platform authenticator as the biometric
   shortcut in login + re-auth; `python-fido2`/`py_webauthn` — the original
   draft's "Moshi" reference was an error).
2. Security audit pass: headers, CORS (none needed — same origin via nginx),
   token lifetimes, lockout policy, `ADMINNG_SECRET_KEY` handling, the
   read-only vmail mount surface, nginx hardening review.
3. `test.sh` consolidation: all AdminNG black-box checks final-shaped (device
   gate negatives incl. open relay-style "nothing without approval", CRUD,
   tenant isolation, re-auth negatives, audit rows, quota route).
4. Documentation final pass: `INSTALL.md` access points + device bootstrap
   (CLI), `README.md`, `.agents/services/catalog.md` +
   `.agents/services/configuration.md` + `.agents/devops/workflows.md`,
   `env.sample` complete, `Changelog.md`.
5. **The deprecation decision (explicit, with data):** PostfixAdmin still owns
   vacation, fetchmail, welcome/vacation templates, backup/restore UI,
   `POSTFIXADMIN_SETUP_PASSWORD` OTP flow. Decide per feature: port to AdminNG,
   declare dead, or keep PostfixAdmin as the permanent escape hatch — then
   update this plan with the Phase 6 that implements the decision.

**Done when:** the audit findings are triaged and fixed; the full `./test.sh`
suite (existing + AdminNG checks) is green on a fresh
`down` → `rm -rf ldata/` → `bootstrap-dev.sh` cycle; the deprecation decision
is recorded and its follow-up plan exists.

## Milestone summary

| Phase | Delivers | Key acceptance |
|---|---|---|
| 0 | Scaffolding + all chains wired | stack boots; health through the proxy; adminng DB exists; CI green |
| 1 | Catalogue CRUD + search + quota | write-compat + IMAP-login assertions; tenant negatives |
| 2 | Security model end-to-end | device-gate negatives; re-auth negative; CLI; audit rows; both DB backups |
| 3 | The PWA | full flows on desktop + Android PWA; i18n complete; offline rules |
| 4 | APK pipeline | signed APK release artifact; mobile zero-trust verified |
| 5 | Hardening + decision | audit triaged; test.sh green on fresh cycle; deprecation decision recorded |

**Explicitly out of scope for v1** (tracked in §11 of the draft): vacation,
fetchmail, welcome templates, backup/restore UI, scratch TOTP codes, PostfixAdmin
feature parity beyond the catalogue, a stack-wide password-scheme migration.


