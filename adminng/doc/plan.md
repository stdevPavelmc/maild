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
| 2 — Security model | **validated** | per-task table below; full suite 67 passed / 0 failed |
| 3 — PWA frontend | **validated** | implemented and built; served at :8083; containerized browser suite (`pwa-test`) 3/3 flows + Lighthouse 97/100/96 + axe clean (see notes) |
| 4 — APK pipeline | **partial → validated (pipeline)** | first real signed APK built locally with a throwaway keystore: apksigner v2/v3, `cu.maild.adminng` 0.1.0, minSdk 24; only the operator-keystore CI run and the on-device install remain |
| 5 — Hardening & decision | **partial** | headers/CSP + docs; full `test.sh` 67/67 green, containerized browser + a11y gates, per-feature PostfixAdmin table recorded; WebAuthn deferred, fresh-cycle run and APK CI run still open |

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
| 6 | Rate limiting + lockout | **validated** | I16 (5 failures → 429), I17 (`--reset-ratelimit` clears it) and `tests/test_ratelimit.py`; state is persisted in the `adminng` DB (migration 004) |
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
- **Lockout is persisted** in the `adminng` database (`rate_limit`, migration 004), keyed by
  username+IP — it survives api restarts, is shared by replicas, another user behind the same
  NAT is unaffected, and `adminng.py --reset-ratelimit <user>` clears it from another process.
- **Backup credentials:** `~/.pgpass` needs one line per database; the script now writes both
  (catalogue + adminng) — the first attempt failed with `fe_sendauth: no password supplied`.
- **WebAuthn/passkeys** remain Phase 5; TOTP is the enforced second factor for now.

### Phase 3 — task status

| # | Task | Status | Evidence |
|---|---|---|---|
| 1 | Shell layouts (sidebar / bottom tabs / FAB) | **validated** | `components/Shell.tsx`; responsive at the 640 px breakpoint; the FAB only appears on creatable screens and is disabled offline |
| 2 | Screens & flows (login, 2FA, enrollment QR, pending lock, editors, armed confirm, devices, logs) | **validated** | pages under `src/pages/`; `pwa-test` covers approval → login → create → delete (re-auth + 5 s armed button) and, in `superadmin.spec.ts`, TOTP login (enrolling only on first run) + devices-panel authorize/revoke through the UI |
| 3 | Onboarding "server URL" — APK only | **validated** | runtime base (`getBaseUrl`/`setBaseUrl`), first-run `ServerScreen` when built with `VITE_REQUIRE_SERVER_URL=1`, Settings → "Change server"; the TWA APK is same-origin by construction (`APP_URL`) |
| 4 | Rapid search (Ctrl/⌘K) | **validated** | modal calls `GET /search`; `?q=` is reactive (`lib/useUrlState.ts`), so a hit re-filters an already-mounted screen; `flows.spec.ts` opens it with the real shortcut and asserts the `example.net` hit |
| 5 | Offline rules | **validated** | `vite-plugin-pwa` (CacheFirst shell / NetworkOnly API), `OnlineProvider` disables every write control, Dexie log cache; browser suite asserts banner + disabled FAB + offline boot |
| 6 | Backgrounding (2 min shield / 15 min purge) | **validated** | `store/AuthContext.tsx` (visibilitychange + activity timers) |
| 7 | Virtualized lists | **validated** (deviation) | `@tanstack/react-virtual` in the logs screen; catalogue tables stay cursor-paginated (bounded DOM) — see notes |
| 8 | i18n en + es | **validated** | JSON catalogues + `npm run i18n:check` inside `npm run build`: 128 keys, placeholder parity, no empty values |
| 9 | Settings (language, device, server, about) | **validated** | `pages/Settings.tsx` |

**Phase 3 notes**

- `npm run build` is the gate: i18n completeness → `tsc --noEmit` → Vite. It runs inside the
  image, so a missing Spanish key fails the image build.
- Browser suite: **`adminng/pwa-test`** — a dev-only one-shot container (service `pwa-test`)
  with Playwright 1.64.1 + Chromium and Lighthouse 12.8.2 baked in. `./adminng/pwa-test/run.sh
  verify` runs `flows`, `installable`, `superadmin` and the Lighthouse budget; no host Node or
  `npx playwright install` is involved. **3/3 passing.**
- The container tunnels `http://localhost:8083` to `http://adminng:80`: `localhost` is a secure
  context, so the service worker / installability / offline assertions behave exactly as on the
  host or behind the production ingress. (Verified the hard way: `http://adminng` makes
  `crypto.randomUUID` unavailable and the app cannot even generate its device id.)
- Device approval stays out of band. `flows`/`visual`/`a11y` read the pending UUID and run the
  documented `adminng.py --approve-device` in the `api` container through the docker socket
  (dev-only service, absent from every production compose file). `superadmin.spec.ts` covers the
  other documented path: TOTP enrollment, then authorize/revoke from the devices panel with
  re-auth + the 5 s armed button.
- Lighthouse 12: performance 97, accessibility 100, best-practices 96; SEO is reported only (63)
  because `public/robots.txt` disallows crawling a private admin panel on purpose.
- `visual.spec.ts` (desktop 1440×900 + mobile 390×844, EN/ES, 21 PNGs in `ldata/e2e/screens/`)
  and `a11y.spec.ts` (axe-core WCAG 2.1 A/AA, JSON per screen in `ldata/e2e/a11y/`) are the
  review tools for UI/UX work; the first audit run drove three fixes below.
- Accessibility fixes found by the audits: secondary text moved from `slate-500` to `slate-400`
  (3.97:1 → ~7:1), modals expose `role="dialog"`/`aria-modal`, and the virtualized log list is now
  a keyboard-focusable `role="region"` (`scrollable-region-focusable` was the only serious axe
  finding).
- Pagination gaps found by the same review: the **devices** panel and the **admins** table used
  `usePaged` without passing the cursor or rendering "Load more", so only the first page was ever
  reachable. Both now paginate like domains/accounts/aliases.
- **Deviation (task 7):** only the logs view is virtualized. The catalogue tables are
  cursor-paginated (25 rows per page, user-driven), so the DOM stays bounded; virtualizing them
  would add complexity without changing the node count.
- The APK pipeline builds a **TWA** that loads `APP_URL`, so the app is same-origin and needs no
  runtime server address. The runtime setting exists for bundled-asset builds
  (`VITE_REQUIRE_SERVER_URL=1`) and to repoint a build from Settings; it clears the session and
  the device identity on change.
- Session storage is `localStorage` (device id + token pair); the PKCE/WebAuthn upgrade is the
  Phase-5 credential work.
- Artifacts are host-owned: the harness runs as root (docker socket, Chromium sandbox off) and
  `entrypoint.sh` chowns `ldata/e2e` back to the invoking uid/gid on exit.


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

**Status:** validated (30 unit tests; full `test.sh` 67 passed / 0 failed).

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

**Status:** validated — implemented, built, and exercised in the `pwa-test` container by three
Playwright specs (flows, installability, superadmin) plus the Lighthouse budget and an axe audit
(see the task table at the top of this document and the verification block below).

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

**Verification (how each "done when" is demonstrated today):**

```bash
# i18n gate: key/placeholder parity, no empty values (also part of the image build)
cd adminng/pwa && npm run i18n:check

# Browser flows + installability + Lighthouse, in the dev-only pwa-test container
# (self-contained: Playwright 1.64.1 + Chromium and Lighthouse are baked in)
./adminng/pwa-test/run.sh verify
#   -> flows: pending device -> CLI approval -> login -> Ctrl/⌘K search palette ->
#      create/delete an account (re-auth + 5 s armed confirm) -> domain scope ->
#      ES/EN switch -> offline lockdown
#   -> installable: manifest fields, active service worker, boot with the network down
#   -> superadmin: TOTP enrollment + devices panel authorize/revoke through the UI
#   -> Lighthouse: performance >= 0.85, accessibility >= 0.9, best-practices >= 0.9

# Review tools (artifacts under ldata/e2e/)
./adminng/pwa-test/run.sh visual    # 21 PNGs: desktop 1440x900 + mobile 390x844, EN/ES
./adminng/pwa-test/run.sh a11y      # axe WCAG 2.1 A/AA per screen (fails on serious/critical)
./adminng/pwa-test/run.sh shell     # interactive shell inside the harness image

# CI: .github/workflows/pwa-e2e.yml (manual dispatch: builds the stack, runs verify + a11y)
```

Installability is asserted twice: structurally in `tests/installable.spec.ts` (manifest fields,
active service worker controlling the page, app boot with the network down) and by Lighthouse's
performance/accessibility/best-practices budget. The install prompt itself is a browser UI and is
verified on the device at release time.


## Phase 4 — Android APK pipeline

**Status:** validated (pipeline) — the first real signed APK was produced on 2026-10-17 from
this tree with a throwaway keystore: `dist/android/cu.maild.adminng-0.1.0.apk`, `apksigner
verify` OK (v2 + v3), package `cu.maild.adminng`, versionName `0.1.0`, minSdk 24, target 36.
The remaining legs are the release-keystore run in CI and the install on a physical phone.

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

**Status:** partial — hardening done; the browser E2E/Lighthouse and accessibility gates are
containerized (`pwa-test`) and green, the full `./test.sh` suite passes (67/67), and the
per-feature PostfixAdmin decision table is recorded below. Open: WebAuthn (deliberately
deferred), the fresh `down` → `rm -rf ldata/` → `bootstrap-dev.sh` cycle, and the first APK
build with the operator keystore.

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
| 1 | `app-generate.sh` (dockerized PWA → signed APK) | **validated** | built `dist/android/cu.maild.adminng-0.1.0.apk` (~0.96 MB) from the live dev stack; `apksigner verify` v2+v3 with the throwaway cert `CN=MailD Test`; `aapt dump badging`: `cu.maild.adminng`, 0.1.0 (1), minSdk 24, target 36 |
| 2 | GitHub Actions release artifact | **finished** | `.github/workflows/android-apk.yml` (workflow_dispatch + release; keystore from secrets; artifact + release attach); the script it calls is now the one proven above |
| 3 | Keystore decision + rotation runbook | **partial** | dev/test generation documented and scripted (`adminng/pwa/keystore-generate.sh`, validated by rebuilding the APK: the new certificate digest matched); the operator still decides Play Store vs sideload and must supply/back up the release key as the `KEYSTORE_BASE64`/`KEY_ALIAS`/`KEY_PASSWORD`/`STORE_PASSWORD` secrets |
| 4 | APK first-run flow | **validated (PWA side)** | the TWA loads `APP_URL`, so the PWA's existing handshake → approval → enrollment/2FA flow is what runs on the phone; the LAN HTTPS build (`APP_URL=https://192.168.1.163:8084` + `APP_CA_CERT`) is validated end-to-end, on-phone install still needs a device |

**Phase 4 notes — what the first real run found (all fixed in the script/image):**

- **Bubblewrap `init` is interactive even with `--manifest`** (domain, URL path, name, package,
  colors, signing key), so it cannot run unattended. The script now writes `twa-manifest.json`
  itself and drives the deterministic `update` + `build` pair.
- **`build` must run from inside the project directory**: it invokes `./gradlew` from the
  current working directory, not from `--directory`. The manifest and checksum must sit beside
  it; the script copies the manifest into `android-project/` and `cd`s there.
- **Signing passwords** go through Bubblewrap's documented
  `BUBBLEWRAP_KEYSTORE_PASSWORD` / `BUBBLEWRAP_KEY_PASSWORD` variables (the 1.27 prompt order
  is not the one the old pipe assumed, and it only asks for two passwords).
- **Bubblewrap needs `$ANDROID_HOME/bin`** (its SDK validation) while the modern command-line
  tools only ship `cmdline-tools/latest/bin`. A symlink breaks the `sdkmanager` launcher
  (`ClassNotFoundException`); the image installs a one-line wrapper script instead.
- **`minSdkVersion 24`**: `com.google.androidbrowserhelper:androidbrowserhelper:2.7.4` refuses
  to merge with 21.
- **Bubblewrap's JDK/SDK prompts** are avoided by pre-seeding `/root/.bubblewrap/config.json`
  with the paths baked into the image.
- **Network deviation on this host:** the IPv4 route to `dl.google.com` answers 404 (the IPv6
  route works), so the SDK repo, Maven artifacts and the Gradle distribution could not be
  fetched by the JVM. The script exposes `DOCKER_NETWORK=host` and passes
  `JAVA_TOOL_OPTIONS` through; the documented invocation here is
  `DOCKER_NETWORK=host JAVA_TOOL_OPTIONS=-Djava.net.preferIPv6Addresses=true ./app-generate.sh`.
  This is an environment quirk, not a build requirement: healthy networks use the defaults.
- The toolchain container runs as root (JDK/SDK/config under `/root`); the script reclaims
  ownership of `node_modules`, `dist`, `android-project` and the APK before and after the run,
  and `npm ci` runs as the invoking user.
- **Gradle/SDK caches:** named volumes `maild-adminng-apk-gradle` and `maild-adminng-apk-sdk`
  (`GRADLE_CACHE_VOLUME` / `ANDROID_SDK_VOLUME`) keep the wrapper/dependencies and the SDK
  between runs. The image installs `platforms;android-36` + `build-tools;36.1.0` — what
  Bubblewrap 1.27 pins and AGP 8.9 uses — so a build no longer re-downloads them (the old
  34.0.0 was never used by Bubblewrap). The SDK volume is seeded from the image on first use;
  `docker volume rm maild-adminng-apk-sdk` resets it after an image bump.
- **SDK download robustness:** Google retires the `commandlinetools-…_latest.zip` archives and
  some CDN edges 404 them (wget exit 8) — the previously pinned 11076708 is one of them. The
  image now tries the pinned file plus 13114758 / 12700392 / 12266719, each with `wget` **and**
  `curl` and three attempts, and prints the `DOCKER_NETWORK=host` hint when none works.
- `VITE_APP_BASE` was **not** reaching the PWA build container (the old `docker run` did not
  pass `APP_URL`); fixed, so the bundled-asset build really points at the deployment.
- The signed APK is picked up from `android-project/app-release-signed.apk` (the old
  `find … -name '*.apk' | head -1` could return the *unsigned* intermediate).
- **LAN access is HTTPS-only (the HTTP experiment was removed):** `ALLOW_LOCAL_HTTP=1` was
  retired after it turned out that an `http://` origin cannot log in at all — `crypto.randomUUID`
  is secure-context only, and there is no service worker either. The dev stack now serves the PWA
  over **HTTPS on 8084** with a local CA (`adminng/pwa/tls-cert-generate.sh` →
  `ldata/certs/adminng-ca.{crt,der}` + `adminng.crt`; `mail.crt` untouched), and
  `app-generate.sh` takes `APP_CA_CERT` so the manifest preflight and Bubblewrap trust it. The
  phone imports `adminng-ca.der` from `http://<lan-ip>:8083/ca.der`; the APK still opens as a
  Custom Tab on an IP origin (Digital Asset Links need a DNS name).
- **Keystore:** the missing runbook now exists — `adminng/pwa/keystore-generate.sh` creates a
  dev/test JKS (0600) plus the base64 for the CI secret, prints the exact build command, and
  falls back to Docker when no JDK is installed. Proven by rebuilding the APK with a generated
  key and matching the certificate digest. Production keys must be generated on a trusted
  machine and backed up (losing them blocks updates unless Play App Signing is used); the
  Play Store vs sideload call stays with the operator.


### Phase 5 — task status & decisions

| # | Task | Status | Decision / evidence |
|---|---|---|---|
| 1 | WebAuthn / passkeys | **deferred (decision)** | TOTP is enforced for superadmins and fully tested; passkeys need a platform-authenticator harness (browser/phone) that this environment cannot provide. Tracked as Phase 6 in the roadmap below. |
| 2 | Security pass | **finished** | CSP + Permissions-Policy added in nginx; no CORS (same origin); HttpOnly-free but short-lived JWTs + rotating refresh; lockout; secrets never baked; vmail mounted read-only; `FORBIDDEN_TENANT` everywhere; audit trail. |
| 3 | `test.sh` consolidation | **validated** | 67 checks, 31 unit/integration tests; full **67 passed / 0 failed / 0 skipped** run on 2026-10-17 against the current stack (the fresh `down` → `rm -rf ldata/` → bootstrap cycle is still open) |
| 4 | Docs final pass | **finished** | README + INSTALL AdminNG sections, `.agents/*`, `Changelog.md`, `adminng/README.md`, plan/technical draft. |
| 5 | PostfixAdmin deprecation decision | **decided** | **PostfixAdmin stays** installed as the escape hatch, but each feature now has an explicit port/dead/keep call in the table below. AdminNG is the primary UI for domains/accounts/aliases/admins/devices/logs. |

**Phase 5 follow-ups (explicitly open):** WebAuthn/passkeys; APK CI first run with the operator
keystore; fresh-cycle `test.sh` run. Closed here: browser E2E + Lighthouse installability
(dev-only `pwa-test` service, `run.sh verify`), automated i18n key-completeness check (inside
`npm run build`, so the image build and CI gate it), the axe accessibility audit (`run.sh a11y`)
and the per-feature PostfixAdmin decision table (below).

## Phase 6 — follow-ups & the PostfixAdmin decision table

1. WebAuthn/passkeys for login and re-auth (data model: `webauthn_credential`, challenge store).
2. ~~Browser E2E + Lighthouse in CI~~ — done in Phase 3: `adminng/pwa-test` + `run.sh verify`,
   wired into `.github/workflows/pwa-e2e.yml`; the a11y run publishes its JSON reports.
3. Automated i18n completeness check — done: `npm run i18n:check` runs inside `npm run build`,
   which is the frontend image build (and the CI gate).
4. Per-feature PostfixAdmin decision table — **recorded below**; the remaining work is the
   Phase-7 implementation of the "port" rows.
5. WebAuthn/passkey login and re-auth (Phase 6.1) — design: `webauthn_credential` table
   (credential id, public key, sign count, transports, device binding), a challenge store in
   the `adminng` DB and `py_webauthn` on the API; the PWA calls `navigator.credentials.*` for
   login **and** the re-auth step, falling back to the password when unavailable.

### Phase 6 table — the PostfixAdmin feature decisions

Basis: the feature list in §11.2 of the technical draft, the deployment's fixtures and cron
jobs, and the fact that AdminNG already owns the catalogue. There is no usage telemetry; every
"keep" is a *provisional* call to revisit after adoption, and every "dead" is backed by an
existing replacement in this repository.

| # | PostfixAdmin feature | Where it lives today | Decision | Rationale / next step |
|---|---|---|---|---|
| 1 | Domain / account / alias / admin CRUD, quota display | `admin` (PostfixAdmin) | **AdminNG is primary; PostfixAdmin stays as escape hatch** | AdminNG has write-compatible CRUD, tenant scoping, quota usage and an audit trail. Keep `admin` running until operators have migrated; no further feature work there |
| 2 | Vacation auto-reply | `admin` (`vacation` table) + Dovecot Sieve | **Port (Phase 7)** | Add a "vacation" section to the account editor that writes a managed Sieve script (or the vacation table) and a per-user toggle. Medium effort, no architectural blocker; until then users configure it in PostfixAdmin |
| 3 | Fetchmail integration | `admin` (`fetchmail` table) + cron | **Declare dead** (revisit only on operator request) | Upstream fetchmail is maintenance-only and most providers require OAuth2; a modern replacement is a different feature, not a port. Document the decision so nobody assumes parity |
| 4 | Welcome / vacation mail templates | `admin` config keys | **Declare dead → fixed templates + docs** | AdminNG never sends welcome mail (only `bootstrap-dev.sh`/seeding creates mailboxes). Keep the templates as documentation, drop the editable UI |
| 5 | Backup / restore UI | `admin` dump/restore pages | **Declare dead** | `cron/scripts/backup_db.sh` produces validated dumps of both databases with retention, and `db_upgrade.md` documents restore. A web restore button is a destructive surface with no operational need |
| 6 | Setup OTP (`POSTFIXADMIN_SETUP_PASSWORD`) | `admin` entrypoint | **Declare dead** | The admin entrypoint generates and prints its own OTP per boot; AdminNG bootstraps devices through the audited `adminng.py` CLI. The variable is already ignored by the entrypoint |
| 7 | Password scheme (md5crypt) | catalogue (`mailbox.password`) | **Keep for v1; separate stack-wide migration** | PostfixAdmin, Dovecot and AdminNG must switch schemes together (ARGON2/BLF-CRYPT). Tracked in §11.1; out of scope for the deprecation itself |
| 8 | Alias domains | not present in this deployment's catalogue/API | **Not applicable** | No `alias_domain` usage in the schema, seeder or API; do not add it for parity's sake |

**Consequence for `admin`:** it remains in the stack as the escape hatch for rows 2–6 (with row 2
being the only one the roadmap intends to port). A future Phase 7 implements vacation in AdminNG;
after that, `admin` can be dropped from the default compose profile with a one-line change and
the docs updated.


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


