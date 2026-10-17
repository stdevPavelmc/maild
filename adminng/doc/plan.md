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
| 1 — Core catalogue API | **validated** | per-task table below; full suite 59 passed / 0 failed |
| 2 — Security model | **validated** | per-task table below; full suite 66 passed / 0 failed |
| 3 — PWA frontend | **partial** | implemented and built; served at :8083; browser E2E/Lighthouse pending (see notes) |
| 4 — APK pipeline | **partial** | script + toolchain image + release workflow implemented; first CI/keystore run pending |
| 5 — Hardening & decision | **partial** | headers/CSP, docs, 66-check suite done; WebAuthn explicitly deferred (decision recorded) |

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

### Phase 1 — task status

| # | Task | Status | Evidence |
|---|---|---|---|
| 1 | Catalogue layer — md5crypt, maildir layout, quota bytes, cascade deletes, counters, admin password mirroring | **validated** | `adminng/api/tests/test_catalogue.py`: 11/11 tests (hash shape/verification, maildir `domain/probe/`, quota bytes, counters, mirroring, 409 on duplicate, cascade) |
| 2 | Routes — domains/mailboxes/aliases/admins CRUD, `GET /search`, cursor pagination, uniform errors | **validated** | curl round-trip through the nginx proxy (201/200/204/404/409, `FORBIDDEN_TENANT`), `next_cursor` present, OpenAPI at `/api/v1/docs` |
| 3 | Quota usage — read-only vmail, `.maildirsize` + `du` fallback + cache | **validated** | quota route reports `source=maildirsize` (831 B after the first IMAPS login); `du` path when no `.maildirsize` yet |
| 4 | Multi-tenant scoping (domain admins × `domain_admins`) | **validated** | unit test + HTTP: alice lists only `example.net`; foreign domain GET/POST → 403 `FORBIDDEN_TENANT`; `/admins` → 403 |
| 5 | Restart advisory on domain create | **validated** | create response carries `RESTART_REQUIRED` for amavis/mua/mta |
| 6 | Integration tests incl. write-compat + IMAP login | **validated** | self-test 11/11; `test.sh` I3 (maildir/bytes) and I4 (the API-created mailbox logs into IMAPS immediately) |
| + | `test.sh` section I (black box) | **validated** | full suite: **59 passed, 0 failed, 0 skipped** (I1–I10, suspend/reactivate included) |

**Phase 1 deviations / notes**

- **Token model:** Phase 1 issues opaque DB-backed bearer tokens (only the SHA-256 is
  stored as `session.jti`), not the JWT pair yet — Phase 2 replaces issuance with
  `login-step1/2` + device binding + jti rotation, keeping the `Principal` dependency.
- **The api process runs as uid/gid 5000** (the vmail owner) because maildirs are `0700`;
  the volume is mounted read-only, so it can read `.maildirsize`/sizes but never write mail.
- **Dovecot's auth cache** can keep a suspended account (or a superseded password) valid for
  up to a minute; `test.sh` flushes it (`doveadm auth cache flush`) before asserting, and
  the caveat is documented (it is identical under PostfixAdmin).
- **Maildirs survive mailbox deletion** (PostfixAdmin's default): the API removes the rows
  and revokes sessions, but does not `rm -rf` mail. Recreating the address keeps its mail.
- The self-test is copied into the api image (small) so
  `docker compose exec api python tests/test_catalogue.py` runs anywhere;
  `adminng/api/.dockerignore` no longer excludes `tests/`.

### Phase 2 — task status

| # | Task | Status | Evidence |
|---|---|---|---|
| 1 | Device middleware, lifecycle, handshake/status | **validated** | `test.sh` I1/I2/I15 (PENDING refusal → CLI approve → revoke kills sessions); `tests/test_devices.py` 5 tests |
| 2 | Two-step login, TOTP enrollment, token pair, jti rotation, idle purge | **validated** | I3/I4/I13; `tests/test_totp.py` (RFC 6238 vectors + replay), `tests/test_tokens.py`, `tests/test_crypto.py` |
| 3 | Re-auth token + enforcement on destructive routes | **validated** | I10 (403 `OPERATION_NOT_VERIFIED` without the header) and I12 (204 with it) |
| 4 | `adminng.py` CLI (`--add-device`, `--approve-device`, `--revoke-device`, `--totp-reset`) | **validated** | I2 + `bootstrap-dev.sh` pre-approves the dev device |
| 5 | Audit trail + `GET /logs` (tenant-scoped) | **validated** | I14 (LOGIN_OK, MAILBOX_CREATE, DOMAIN_DELETE); logs include device id and IP |
| 6 | Rate limiting + lockout | **validated** | I16 (5 failures → 429) and `tests/test_ratelimit.py` |
| 7 | `backup_db.sh` also dumps the `adminng` DB | **validated** | G3/G4/G4b: two archives, gzip/trailer/schema checked, same retention |
| 8 | `bootstrap-dev.sh` self-approval + `test.creds` | **validated** | the dev device is added/approved by the CLI and written as `adminng.device=` |

**Phase 2 deviations / notes**

- **`ADMINNG_SECRET_KEY` is now mandatory** (compose `${ADMINNG_SECRET_KEY:?}` guard, all four
  files). It signs the JWTs and encrypts the TOTP seeds; rotating it invalidates sessions and
  enrolled seeds. Existing deployments must add it before `up`.
- **Migration `003_phase2.sql` retires Phase-1 sessions** (`device_id IS NULL`): the previous
  plain bearer tokens die with the deploy.
- **TOTP policy:** superadmins must enroll (`ADMINNG_TOTP_REQUIRED=superadmin`); a custom admin
  without an enrolled credential authenticates in step 1 alone. Replay protection refuses a
  used time step, so the test helper prints the *next* step right after enrollment.
- **Lockout is in-process** (single replica, MailD's deployment shape), keyed by
  username+IP — another user behind the same NAT is unaffected.
- **Backup credentials:** `~/.pgpass` needs one line per database; the script now writes both
  (catalogue + adminng) — the first attempt failed with `fe_sendauth: no password supplied`.
- **WebAuthn/passkeys** remain Phase 5; TOTP is the enforced second factor for now.

### Phase 3 — task status

| # | Task | Status | Evidence |
|---|---|---|---|
| 1 | Shell layouts (sidebar / bottom tabs / FAB) | **finished** | `components/Shell.tsx`; responsive at the 640 px breakpoint |
| 2 | Screens & flows (login, 2FA, enrollment QR, pending lock, editors, armed confirm, devices, logs) | **finished** | pages under `src/pages/`; destructive flows use the password re-auth + 5 s armed button |
| 3 | Onboarding "server URL" — APK only | **finished** | the web build is same-origin (`VITE_API_BASE` hook exists for the APK build) |
| 4 | Rapid search (Ctrl/⌘K) | **validated** (API) | modal calls `GET /search`; navigation prefills the list query |
| 5 | Offline rules | **finished** | `vite-plugin-pwa` (CacheFirst shell / NetworkOnly API), offline banner + disabled writes, Dexie log cache |
| 6 | Backgrounding (2 min shield / 15 min purge) | **finished** | `store/AuthContext.tsx` (visibilitychange + activity timers) |
| 7 | Virtualized lists | **finished** | `@tanstack/react-virtual` in the logs screen; tables are cursor-paginated |
| 8 | i18n en + es | **partial** | full EN/ES catalogues; the automated key-completeness check is still pending (CI step) |
| 9 | Settings (language, device, about) | **finished** | `pages/Settings.tsx` |

**Phase 3 notes**

- `npm run build` (`tsc --noEmit` + Vite) passes inside the image; the served shell,
  deep links (`/domains`, `/logs`) and the manifest were verified through the nginx proxy.
- Browser end-to-end (Playwright/Lighthouse) is **not** available in this environment:
  installability and the visual flows must be checked on a real browser before release.
- The automated i18n completeness check is a Phase-5 CI item (extract keys to JSON or a
  scripted comparison); both catalogues are complete by review today.
- Session storage is `localStorage` (device id + token pair); the PKCE/WebAuthn upgrade is
  the Phase-5 credential work.

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

**Status:** validated (self-test 11/11; full `test.sh` 59 passed / 0 failed).

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

**Status:** validated (30 unit tests; full `test.sh` 66 passed / 0 failed).

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

**Status:** partial — implemented and building; browser E2E/Lighthouse pending.

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

**Status:** partial — implemented, not executed here (needs Android SDK, network and the signing
keystore; the first CI run is the validation).

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

**Status:** partial — hardening done, WebAuthn explicitly deferred (decision below), browser
E2E/Lighthouse outstanding.

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

### Phase 4 — task status

| # | Task | Status | Evidence |
|---|---|---|---|
| 1 | `app-generate.sh` (dockerized PWA → signed APK) | **finished** | `adminng/pwa/app-generate.sh` + `Dockerfile.android` (JDK 17, Android SDK 34, Bubblewrap); `bash -n` clean |
| 2 | GitHub Actions release artifact | **finished** | `.github/workflows/android-apk.yml` (workflow_dispatch + release; keystore from secrets; artifact + release attach) |
| 3 | Keystore decision + rotation runbook | **partial** | decision: operator-owned keystore stored as repo secret `KEYSTORE_BASE64`; Play Store vs sideload still an operator call |
| 4 | APK first-run flow | **finished** | the PWA already handles handshake → approval → enrollment/2FA; the APK only adds the server-URL hook (`VITE_APP_BASE`) |

**Phase 4 notes:** the script pipes the keystore answers into Bubblewrap (documented order) —
re-check against the pinned CLI on the first real run. No APK could be produced here: the
sandbox has no Android SDK download/keystore, so this phase is deliberately `partial`.

### Phase 5 — task status & decisions

| # | Task | Status | Decision / evidence |
|---|---|---|---|
| 1 | WebAuthn / passkeys | **deferred (decision)** | TOTP is enforced for superadmins and fully tested; passkeys need a platform-authenticator harness (browser/phone) that this environment cannot provide. Tracked as Phase 6 in the roadmap below. |
| 2 | Security pass | **finished** | CSP + Permissions-Policy added in nginx; no CORS (same origin); HttpOnly-free but short-lived JWTs + rotating refresh; lockout; secrets never baked; vmail mounted read-only; `FORBIDDEN_TENANT` everywhere; audit trail. |
| 3 | `test.sh` consolidation | **validated** | 66 checks, 30 unit/integration tests; two full green runs. |
| 4 | Docs final pass | **finished** | README + INSTALL AdminNG sections, `.agents/*`, `Changelog.md`, `adminng/README.md`, plan/technical draft. |
| 5 | PostfixAdmin deprecation decision | **decided** | **PostfixAdmin stays** as the fallback for v1 (vacation, fetchmail, welcome templates, backup/restore UI, setup OTP are not ported). AdminNG becomes the primary UI for domains/accounts/aliases/admins/devices/logs. Revisit after adoption with the per-feature table from §11 of the draft; a future Phase 6 ports or retires them. |

**Phase 5 follow-ups (explicitly open):** browser E2E (Playwright) + Lighthouse installability on
a real browser; automated i18n key-completeness check in CI; WebAuthn/passkeys; APK CI first run.

## Phase 6 — follow-ups (stub, from the Phase 5 decisions)

1. WebAuthn/passkeys for login and re-auth (data model: `webauthn_credential`, challenge store).
2. Browser E2E + Lighthouse in CI (PWA installability gate).
3. Automated i18n completeness check (extract keys, fail on missing `es`).
4. Per-feature PostfixAdmin decision table (port / declare dead / keep), then retire or keep
   `admin` formally.

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


