# AdminNG — Consolidated Technical Draft

**Status:** draft for review · **Version:** 0.1 · **Date:** 2026-10-16
**Sources:** consolidates and enriches the original Spanish drafts
(`especificacion-tecnica-uiux-mailserver.md`, `guia-complementaria-api-pwa(1).md`),
grounded in the MailD codebase rules (`AGENTS.md`, `.agents/services/*.md`,
`admin/seed.sh`, `cron/scripts/backup_db.sh`).

AdminNG is the next-generation administration interface for MailD: a modern,
simpler, PWA-first replacement for the PostfixAdmin UI — usable from any browser
and installable as an Android app — that manages the PostfixAdmin catalogue
(domains, users/mailboxes, aliases, administrators) with a zero-trust device
model, two-step authentication and a full audit trail.

**Companion documents:** [plan.md](plan.md) (phased roadmap) ·
[../README.md](../README.md) (device authorization how-to). The PostfixAdmin
`admin` service **stays** as the fallback UI and the first-boot provisioning
leader (schema via `public/upgrade.php`, sentinel + fixtures via `seed.sh`);
AdminNG deprecates it only later, by explicit decision (plan.md, Phase 5).

## 1. Overview & design goals

1. **Simpler, modern UI** — the everyday tasks (create a user, edit a quota,
   flip an alias, suspend an account) in seconds, on desktop and on phone.
2. **PWA-first, Android-capable** — installable, offline-safe (read-only),
   shipped as a signed APK artifact of every release.
3. **Zero-trust devices** — every client carries an `X-Device-ID` plus a
   client-minted `X-Device-Secret`; the API is unreachable until the *browser*
   is explicitly approved **server-side**. (Implementation note: since
   `008_device_trust.sql` approval is device-scoped — `device.state` — so one
   approval authorizes the browser for every admin; the per-`(browser, admin)`
   grant below is retained as the activity log + trust window. This document
   keeps the original per-grant wording in §4 as the design history.)
4. **Two-step auth** — password + TOTP (mandatory for superadmins), with a
   proper enrollment flow on first login.
5. **Full audit trail** — every mutation logged, with domain-scoped visibility.
6. **Compatible by construction** — writes rows exactly like PostfixAdmin /
   `admin/seed.sh` do today: no DDL on the catalogue, the same Argon2id password
   scheme (md5crypt accepted as legacy until 2027-02-01, §3.1), same
   `maildir`/quota formats — so Postfix, Dovecot and Amavis keep working
   unchanged. PostfixAdmin remains a dev-only fallback (it cannot verify
   Argon2id).
7. **i18n from day one** — English source language with a complete Spanish
   translation, auto-detected, user-overridable.

## 2. Architecture in MailD

### 2.1 Services & containers

Two new services join the stack (hostnames fixed from day one, per the
never-rename rule):

| Service | Image | Build dir | Exposure |
|---|---|---|---|
| `adminng` | `pavelmc/maild-adminng:<tag>` | `adminng/pwa/` | dev port **8083**; prod Traefik `adminng.${DEFAULT_DOMAIN}` |
| `api` | `pavelmc/maild-api:<tag>` | `adminng/api/` | **none** — internal compose network only |

- **`adminng`** serves the built PWA static bundle from the web root and
  reverse-proxies `/api/v1/` to `api:8080`. It owns the exterior-facing
  **access log** (the record of every interaction with the outside world) and
  the standard nginx hygiene: gzip, immutable asset caching, no directory
  listing, security headers.
- **`api`** is FastAPI (Uvicorn) on `python:3.14-slim-trixie`; it talks
  to `db`, applies its own migrations to the `adminng` database at boot, mounts
  `ldata/vmail` **read-only** (quota usage, §7), and never publishes a port.
- Same-origin API: web/PWA clients need no base-URL configuration; only the
  **Android APK** asks for the server URL on first run (§6.3).

**Naming note:** the exposed service is simply `adminng` (it *is* the AdminNG
frontend) and the internal one is `api` (short, unique on the maild network —
no other service claims that hostname). Both names are **fixed from day one**
per the never-rename rule, and the images follow the `maild-<svc>` rule:
`maild-adminng` / `maild-api`.

### 2.2 Network & ports

- Dev: `adminng` publishes `8083:80` on the `maild-dev` network;
  `api` publishes nothing — reachable only as `api` on the
  compose network.
- Production: `adminng` carries the Traefik labels
  (`adminng.${DEFAULT_DOMAIN}`, entrypoint `websecure`, backend port 80)
  exactly like `admin`/`mua`; TLS is terminated by the operator's ingress
  proxy — the stack itself terminates no TLS. `api` gets no Traefik
  labels at all.

### 2.3 Folder layout & build contexts

One umbrella project, two build contexts — each image is still built from its
own service directory, per the MailD convention:

```
adminng/                  the umbrella project
  ├── doc/                all documentation: this spec, plan.md and the
  │                       original Spanish source drafts
  ├── api/                FastAPI app + Dockerfile → maild-api
  │     app/, migrations/, adminng.py (CLI)
  │                       (service `api`, internal only)
  ├── pwa/                PWA app + Dockerfile → maild-adminng
  │     src/, i18n/ (en+es), nginx/ (proxy conf),
  │     Dockerfile (multi-stage: node build → nginx serving dist/ and
  │     proxying /api/v1/), app-generate.sh (APK build)
  └── README.md           integrations & details (device authorization)
```

Two build contexts ↔ two containers, each with its own Dockerfile, ENV
defaults and entrypoint; the documentation and the README live one level up,
beside them, in the same organizational folder.


### 2.4 Environment chain (MailD rules, applied)

Every tunable defaults **inside each image** (`ENV` in the Dockerfiles); the
operator file (`env.dev` dev / `.env` prod) always wins over the image default;
`POSTGRES_PASSWORD` is mandatory and never baked; debug switches are never
baked (the operator sets them).

**`api` image ENV defaults (overridable):**

| Variable | Default | Meaning |
|---|---|---|
| `POSTGRES_HOST` | `db` | catalogue + adminng DB host |
| `POSTGRES_DB` | `mailddb` | PostfixAdmin catalogue (RW, **zero DDL**) |
| `POSTGRES_USER` | `maild` | catalogue role |
| `ADMINNG_DB` | `adminng` | own database (devices, sessions, TOTP, audit) |
| `ADMINNG_API_PORT` | `8080` | internal listen port (nginx proxies to it) |
| `ADMINNG_API_DOCS` | `no` | `yes` = serve the OpenAPI contract + Swagger UI (`/api/v1/openapi.json`, `/api/v1/docs`); dev-only convenience, keep it off in production (2026-10 audit F-04) |
| `ADMINNG_ACCESS_TTL` | `600` | access-token lifetime, seconds |
| `ADMINNG_REFRESH_IDLE_TTL` | `900` | refresh-token inactivity purge (the 15-min rule) |
| `ADMINNG_REAUTH_TTL` | `30` | destructive-action validation token lifetime, seconds |
| `ADMINNG_AUTO_APPROVE_FIRST` | `no` | `yes` = first superadmin login auto-approves its device (unattended first boot; off by default — see §4.2) |
| `ADMINNG_TOTP_REQUIRED` | `superadmin` | `all` \| `superadmin` \| `none` — who must enroll TOTP |
| `ADMINNG_SEARCH_LIMIT` | `20` | rapid-search result cap per entity type |
| `ADMINNG_QUOTA_CACHE_TTL` | `300` | quota-usage cache lifetime, seconds (§7) |

Operator-file mandatory: `POSTGRES_PASSWORD` (compose `${POSTGRES_PASSWORD:?}`
guard). Operator-file optional: every knob above, documented as commented lines
in `env.sample`. `ADMINNG_DEBUG` follows the debug-switch convention (never
baked; the operator sets it).

**`adminng`** bakes nothing and gets **no `env_file`** — it is stateless
static + proxy (same variable-separation logic as `clamav`).

### 2.5 Databases

Two databases on the same server, two very different contracts:

1. **`mailddb` (the PostfixAdmin catalogue) — read/write, ZERO DDL.** The API
   reads and writes `domain`, `mailbox`, `alias`, `admin`, `domain_admins`
   exactly as PostfixAdmin does (§3.1). Schema creation/upgrade stays with the
   `admin` container (`public/upgrade.php`); AdminNG never creates, alters or
   drops a catalogue table.
2. **`adminng` (own database) — full owner.** Created by
   `db/ensure_databases.sh` on **every** boot from its own `ADMINNG_DB`
   variable (default `adminng`), which both the db and api images bake. It is
   deliberately **not** an entry of `POSTGRES_EXTRA_DB`: `mua/config-setup.php`
   reads that variable as a single database name for the SnappyMail contacts
   DSN, so appending `adminng` to the list would silently break webmail
   contacts. All AdminNG state lives here: devices, sessions, TOTP
   credentials, audit events (§3.2).

### 2.6 Migration strategy

- `adminng/api/migrations/NNN_*.sql` — idempotent DDL (`CREATE TABLE IF NOT
  EXISTS`, guarded `ALTER`s), applied by the **api entrypoint at every
  boot** to the `adminng` DB only, tracked in a `schema_version` table. This
  follows the `db/migrations/001_maild_provision.sql` style — but the slot is
  the api container, because `db/migrate.sh` stays catalogue-only and
  `ensure_databases.sh` is for *creating* databases, never altering them.
- Data migrations (seed/repair) are optional one-shot Python scripts under
  `adminng/api/migrations/`, run by the same entrypoint after the DDL.

## 3. Data model

### 3.1 The legacy catalogue — write-compatibility rules (non-negotiable)

Everything here is what `admin/seed.sh`, `POSTFIXADMIN_ENCRYPT=md5crypt` and the
Dovecot/Postfix/Amavis SQL consumers already rely on. A row written by AdminNG
must be indistinguishable from a row written by PostfixAdmin:

- **Passwords: Argon2id with legacy md5crypt coexistence (2026-10 audit
  F-18).** New hashes are `{ARGON2ID}$argon2id$v=19$m=65536,t=4,p=1$…` (the
  `{SCHEME}` prefix is mandatory for Dovecot's SQL passdb; the parameters are
  self-encoded in the hash, so any writer's output verifies). Legacy raw
  `$1$<8-char-salt>$<22-char-checksum>` (md5crypt) hashes remain legal and may
  mix freely in the same column: Dovecot verifies them through
  `default_password_scheme = MD5-CRYPT` (enabled by `auth_allow_weak_schemes`).
  The writers (`admin/seed.sh`, this API's `app/passwords.py`, the webmail
  change-password driver) follow `PASSWORD_SCHEME` (`argon2id` default,
  `md5crypt` escape hatch). **Weak-scheme support is removed on 2027-02-01**:
  from that date the API refuses `PASSWORD_SCHEME=md5crypt`, the mda sets
  `auth_allow_weak_schemes = no`, and legacy `$1$` rows stop authenticating
  (rehash-on-login and password changes migrate them before then;
  `adminng.py --legacy-hashes` lists the stragglers). PostfixAdmin cannot
  verify Argon2id — it is a deprecated, dev-only fallback, accepted by design.
- **`mailbox` row:** `username` (full email, PK), `password` (Argon2id, or
  legacy md5crypt during the window), `name`,
  `maildir = '<domain>/<local_part>/'` (**trailing slash**), `quota` in
  **bytes, 0 = unlimited** (Dovecot's userdb SQL returns the column raw), plus
  `local_part`, `domain`, `active`, `created`/`modified`.
- **`domain` row:** `domain`, `description`, the counters
  `aliases`/`mailboxes`/`maxquota` (0 = unlimited), `quota`,
  `transport='virtual'`, `backupmx=false`, `active`.
- **`alias` row:** `address`, `goto` (comma-separated recipients), `domain`,
  `active`. A user's own forwarding aliases are simply alias rows whose
  `goto` includes the mailbox address (the UI's "tags in the user editor",
  §6.3, edits these rows in place).
- **`admin` row:** `username` (full email), `password` (Argon2id/legacy md5crypt
  per the scheme above — same value as the matching `mailbox` row where it
  exists; that is the MailD convention from `seed.sh`), `superadmin`, `active`;
  per-domain scope via `domain_admins` (`username`, `domain`, `active`).
- **Dovecot auth-cache caveat, carried over:** after a password change,
  Dovecot's auth cache (`auth_cache_ttl`, 1 minute in MailD) may still accept
  the old password for up to a minute — the same note the SnappyMail
  change-password driver documents.
- **Delete discipline:** mirror PostfixAdmin's cascades (delete a domain ⇒
  its mailboxes, aliases, `domain_admins` rows in one transaction); never
  touch unrelated rows.
- **Zero DDL:** AdminNG never `CREATE`/`ALTER`/`DROP`s anything on `mailddb`.

### 3.2 The `adminng` database — DDL draft

Migrations under `adminng/api/migrations/`, applied in numeric order by the api
entrypoint (each file idempotent). The shape below is the early one
(`001_adminng_core.sql` … `008_device_trust.sql`); since 008 `device.state` is
the authoritative approval and `device_grant.trusted_until` carries the 24h
"skip the code" window:

```sql
CREATE TABLE IF NOT EXISTS schema_version (
  version    int PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS device (
  device_id       uuid PRIMARY KEY,
  client_type     text NOT NULL DEFAULT 'web',   -- 'web' | 'android_pwa' | ...
  device_name     text,
  secret_hash     text,                          -- sha256(client-minted secret); NULL until first login
  first_seen      timestamptz NOT NULL DEFAULT now(),
  last_seen       timestamptz NOT NULL DEFAULT now(),
  last_ip         text
);

-- Authorization is per (browser, administrator): the device row above is the
-- browser identity, this is the approval (migration 007, audit F-11).
CREATE TABLE IF NOT EXISTS device_grant (
  device_id   uuid NOT NULL REFERENCES device(device_id) ON DELETE CASCADE,
  username    text NOT NULL,
  state       text NOT NULL DEFAULT 'PENDING'
              CHECK (state IN ('PENDING','APPROVED','REVOKED')),
  first_seen  timestamptz NOT NULL DEFAULT now(),
  last_seen   timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  approved_by text,                              -- username | 'cli' | 'auto-first'
  last_ip     text,
  PRIMARY KEY (device_id, username)
);

CREATE TABLE IF NOT EXISTS session (
  jti          text PRIMARY KEY,          -- refresh-token id (rotated)
  username     text NOT NULL,
  device_id    uuid NOT NULL REFERENCES device(device_id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);

CREATE TABLE IF NOT EXISTS totp_credential (
  username    text PRIMARY KEY,
  secret      text NOT NULL,             -- encrypted at rest (ADMINNG_SECRET_KEY)
  confirmed   boolean NOT NULL DEFAULT false,
  enrolled_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_event (
  id          bigserial PRIMARY KEY,
  ts          timestamptz NOT NULL DEFAULT now(),
  actor       text NOT NULL,             -- username | 'cli' | 'system'
  device_id   uuid,
  action      text NOT NULL,            -- LOGIN_OK, LOGIN_FAIL, TOTP_FAIL,
                                        -- LOCKOUT, DEVICE_APPROVE, ...
  entity_type text,                     -- 'mailbox'|'domain'|'alias'|'admin'|'device'
  entity_id   text,
  domain      text,                     -- tenant tag (NULL = global)
  ip          text,
  endpoint    text,
  result      text NOT NULL,             -- 'ok' | 'denied' | 'error'
  details     jsonb
);

CREATE INDEX IF NOT EXISTS audit_event_ts_idx    ON audit_event (ts DESC);
CREATE INDEX IF NOT EXISTS audit_event_actor_idx ON audit_event (actor);
CREATE INDEX IF NOT EXISTS audit_event_domain_idx ON audit_event (domain);
CREATE INDEX IF NOT EXISTS session_device_idx ON session (device_id);
```

Notes: TOTP secrets and any future WebAuthn credentials are encrypted at rest
with a key from the operator file (`ADMINNG_SECRET_KEY`, mandatory once Phase 2
lands — never baked); the audit indexes serve the Logs UI filters
(actor/domain/action + newest-first cursor pagination).

## 4. Security model

### 4.1 Device trust (zero-trust)

- Every client generates a UUID v4 (`crypto.randomUUID()`) **and a secret**
  (32 random bytes, `crypto.getRandomValues`) on first run and sends them as
  `X-Device-ID` / `X-Device-Secret` on **every** request except
  `GET /api/v1/health`. The id is a public identifier (shown on the lock
  screen); the secret is a possession factor the server stores only as
  `sha256`, so a leaked id alone can neither be polled nor reused from another
  host (audit F-11).
- **Registration is not anonymous.** There is no handshake endpoint: a `device`
  row (and its `device_grant` for the admin) is created *inside* a
  `POST /auth/login-step1` whose password verified. Random callers cannot mint
  rows.
- The gate rejects any request whose device is missing, whose secret does not
  match, or whose `(device, user)` grant is missing/`PENDING`. `PENDING` allows
  exactly two things: `POST /auth/login-step1` (verify creds, link the grant)
  and `GET /device/status?username=` (the pending-screen poll, secret required).
  A mismatched secret or a foreign device id answers the same `404/403` as an
  unknown device — no enumeration oracle.
- State transitions (per grant):
  - `PENDING → APPROVED`: by a superadmin via the devices panel, or by the CLI
    (§4.2). Recorded in `device_grant.approved_by`.
  - `APPROVED → REVOKED`: superadmin/CLI; **immediately destroys every
    `session` row bound to that `(device, user)`** — the revoked client wipes
    its cached credentials on the next failed call and drops back to the lock
    screen. Revoking the whole browser (`--revoke-device`) revokes all grants.
  - Stale `PENDING` grants are purged after `ADMINNG_PENDING_TTL_DAYS`
    (default 3) at boot and hourly.
- The nginx access log is the transport-level corroboration of who talked to
  the exterior; `audit_event` is the application-level record.

### 4.2 First-device bootstrap — CLI, not silent auto-approval

There is **no** in-app first-device auto-approval: on a fresh deployment,
whoever reaches the server first never gets in automatically. The first
administrator is approved from the **server side** — access to the container
is root authority:

```bash
docker compose exec api adminng.py --list-devices
docker compose exec api adminng.py --approve-device '<uuid>'
docker compose exec api adminng.py --revoke-device '<uuid>'          # whole browser
docker compose exec api adminng.py --revoke-grant '<uuid>' --user '<admin>'
docker compose exec api adminng.py --purge-pending                   # stale PENDING
docker compose exec api adminng.py --totp-reset '<username>'   # lost authenticator
```

The client's lock screen shows the device ID with a copy button (and, once
registered, a short **fingerprint** derived from the secret), so the admin can
relay it over a trusted channel; the operator verifies the requester's identity
before approving. Each grant carries the approving admin's name in
`device_grant.approved_by`.

`ADMINNG_AUTO_APPROVE_FIRST=yes` (**off by default**) is the documented
escape hatch for unattended first boots: the **first** successful superadmin
login (password **plus completed TOTP enrollment**) auto-approves its own
device, and the window closes permanently once a device is approved. The
auto-approved row records `approved_by='auto-first'` in the audit trail.
`bootstrap-dev.sh` uses the CLI (never the escape hatch) so the dev fixtures
self-approve safely. The full how-to lives in `adminng/README.md`.

### 4.3 Authentication flow (two steps + TOTP enrollment)

1. `POST /auth/login-step1` — username + password, verified against the
   catalogue `admin` table (Argon2id, or legacy md5crypt during the window —
   `app/passwords.py`, §3.1). On the **first** verified login from a browser the
   device is registered and its secret bound; the `(device, admin)` grant opens
   `PENDING`:
   - grant `PENDING` ⇒ `403 DEVICE_NOT_AUTHORIZED` (lock screen; poll
     `GET /device/status?username=`) — the payload carries `device_id` and
     `username`;
   - grant `REVOKED` ⇒ `401 DEVICE_REVOKED`;
   - grant `APPROVED`, user has **no confirmed TOTP credential** but TOTP is
     required for this role ⇒ **enrollment flow**: `REQUIRES_TOTP_ENROLLMENT`
     + a one-time enrollment token; the client renders the QR
     (`otpauth://` URI), the user scans it, enters a code, and
     `POST /auth/totp-confirm` stores the credential as `confirmed`;
   - otherwise ⇒ `REQUIRES_2FA` + a short-lived `flow_token`.
2. `POST /auth/login-step2` — `flow_token` + TOTP code (RFC 6238, ±1 time
   step accepted, replayed codes rejected): success issues the token pair
   bound to `(username, device_id)`.
3. TOTP policy (`ADMINNG_TOTP_REQUIRED`): **mandatory for superadmins**
   (default `superadmin`); a domain admin with an enrolled credential gets
   step 2 enforced, one without (and `none`/not required) authenticates at
   step 1 alone.
4. Optional WebAuthn platform credentials provide Android biometric login and
   destructive-action re-auth (implemented in AdminNG Phase 6.1). Challenges
   are single-use, RP/origin-validated, and device-scoped; password + TOTP
   remains the fallback. The `webauthn` package is used by the API; the
   original draft's "Moshi" reference was an error (Moshi is a serialization
   library).

### 4.4 Sessions & tokens

**Phase 2 (implemented):** `login-step1`/`login-step2` issue a signed access JWT
(device-bound, 10 min) plus an opaque refresh token (only its SHA-256 is stored);
`/auth/refresh` rotates the jti (a replayed token is rejected) and the idle purge
applies. Phase 1's plain bearer endpoint is gone.

- **Access token:** JWT (PyJWT), `ADMINNG_ACCESS_TTL` (default 600 s), claims:
  `username`, `device_id`, `role` (`superadmin` | `domain_admin` + assigned
  domain list), `jti`, `exp`.
- **Refresh token:** opaque `jti` stored in `session`; purged after
  `ADMINNG_REFRESH_IDLE_TTL` (900 s) of inactivity — the "15-minute session
  purge" rule — and on logout/revoke. Refreshing **rotates the jti**; reuse of
  a rotated refresh token destroys the whole session (theft detection).
- Login failures return an identical shape whether the user exists or not
  (no user-enumeration oracle).
- Every transition above writes an `audit_event` row.

### 4.5 Destructive-action re-auth (`X-Security-Validation-Token`)

Destructive routes (delete a domain/mailbox/alias/admin, revoke a device,
demote an admin) require, **on the final request**, a scoped JWT obtained
seconds before via `POST /auth/reauth-confirm` (password re-entry) or the
device-bound WebAuthn re-authentication ceremony, with `ADMINNG_REAUTH_TTL`
(30 s) lifetime, bound to the **same `device_id`** and the specific action
scope. Missing, expired, scope- or device-mismatched ⇒
`403 OPERATION_NOT_VERIFIED`. The UI pairs it with the 5-second armed
confirm button (§6.3) so no destructive click can be a reflex.

### 4.6 Rate limiting & lockout

- Per `username` + `ip`: 5 failed `login-step1`/`step2` attempts ⇒ 15-minute
  lockout (`LOGIN_LOCKOUT` audit event; the login screen says so).
- Per `ip`: global device-registration/login-spam cap; `reauth-confirm`
  rate-limited per access token. (Anonymous handshake spam is gone: a device
  row is only created by a verified login.)
- Implemented in-process (MailD's single-replica deployment shape); every
  decision is auditable in the logs.

## 5. API contract (`/api/v1`)

**Conventions.**

- Every route except `GET /health` requires `X-Device-ID` and `X-Device-Secret`;
  authenticated routes also require `Authorization: Bearer <access token>`.
- Errors are uniform: `{"detail": "<CODE>", "message": "...", ...}` with the
  fitting status: `401 UNAUTHENTICATED`, `401 DEVICE_REVOKED`,
  `403 DEVICE_NOT_AUTHORIZED`, `403 OPERATION_NOT_VERIFIED`,
  `403 FORBIDDEN_TENANT` (entity outside the caller's domains),
  `404 DEVICE_UNKNOWN` (status poll: unknown device / wrong secret / no grant),
  `404 NOT_FOUND`, `409 CONFLICT` (duplicate entity), `422 VALIDATION`,
  `429 RATE_LIMITED` (+ `Retry-After`).
- Destructive routes additionally require `X-Security-Validation-Token` (§4.5).
- List routes are **cursor-paginated**: `?limit=&cursor=` →
  `{"items": [...], "next_cursor": "..." | null}` — one page feeds the
  virtualized lists (§6.6); no unbounded arrays.
- Multi-tenant scoping: a domain admin sees/edits only rows whose `domain` ∈
  its `domain_admins` set; the devices panel and the admins CRUD are
  superadmin-only.
- Full request/response schemas are generated from the Pydantic models at
  FastAPI's built-in `/docs` once Phase 1 lands; the JSON examples in the
  original Spanish drafts remain the contract of record where they still apply
  (login-step1, device status, device state change, search); the retired
  handshake example is superseded by §4.1/§4.3.

**Route table:**

| Method & path | Auth | Notes |
|---|---|---|
| `GET /health` | none | liveness (healthcheck + the onboarding "test connection") |
| `GET /device/status?username=` | device + secret | `{device_id, username, authorization_state, fingerprint}` — the pending-screen poll; the secret must match or `404 DEVICE_UNKNOWN` |
| `POST /auth/login-step1` | device + secret | §4.3; registers the browser on the first verified login; `REQUIRES_2FA` + `flow_token`, `REQUIRES_TOTP_ENROLLMENT` + enroll token, or `403 DEVICE_NOT_AUTHORIZED` |
| `POST /auth/totp-enroll` | device + enroll token | `{secret_uri}` (the `otpauth://` QR payload) |
| `POST /auth/totp-confirm` | device + enroll token | `{code}` → credential `confirmed` |
| `POST /auth/login-step2` | device + flow token | `{code}` → `{access_token, refresh_token, expires_in, user{...}}` |
| `POST /auth/refresh` | refresh token | rotated jti; reuse ⇒ session destroyed |
| `POST /auth/logout` | access | destroys the session |
| `POST /auth/reauth-confirm` | access | `{password}` → `{security_validation_token}` (30 s, scoped) |
| `GET /auth/webauthn/status` | access | reports whether WebAuthn is configured and enabled on this device |
| `POST /auth/webauthn/register/options` · `POST /auth/webauthn/register/verify` | access (+ password proof to start) | enroll a platform credential for this device |
| `DELETE /auth/webauthn/credential` | access + password proof | remove this device's platform credential |
| `POST /auth/webauthn/login/options` · `POST /auth/webauthn/login/verify` | device | device-bound biometric login; options may request a remembered session |
| `POST /auth/webauthn/reauth/options` · `POST /auth/webauthn/reauth/verify` | access | mint the existing short-lived destructive-action validation token |
| `GET /admin/devices` | superadmin | cursor list of `(browser, admin)` grants; `?state=PENDING` is the pending queue (drives the UI alert) |
| `PUT /admin/devices/{device_id}/state` | superadmin + reauth | `{action:"APPROVE"\|"REVOKE", username}` → `{device_id, username, new_state, authorized_by}` |
| `GET /search?q=` | access | mixed user/alias/domain results, tenant-scoped, `ADMINNG_SEARCH_LIMIT` per type |
| `GET /domains` · `POST /domains` | access | create returns the restart advisory (§10.9) |
| `GET /domains/{d}` · `PUT /domains/{d}` · `DELETE /domains/{d}` | access (+ reauth on DELETE) | DELETE cascades per §3.1 |
| `GET /mailboxes?domain=&q=` · `POST /mailboxes` | access | create writes the §3.1-compatible row |
| `GET /mailboxes/{u}` · `PUT /mailboxes/{u}` · `DELETE /mailboxes/{u}` | access (+ reauth on DELETE) | `{u}` = URL-encoded full email |
| `GET /mailboxes/{u}/quota` | access | `{quota_bytes, used_bytes, percentage}` from `.maildirsize` (§7) |
| `GET /aliases?domain=&goto=&q=` · `POST /aliases` | access | `?goto=<mailbox>` backs the user editor's alias tags |
| `PUT /aliases/{id}` · `DELETE /aliases/{id}` | access (+ reauth on DELETE) | alias CRUD |
| `GET /admins` · `POST /admins` | superadmin | create = `admin` + `domain_admins` rows |
| `PUT /admins/{u}` · `DELETE /admins/{u}` | superadmin (+ reauth on DELETE) | superadmin flag / domain assignments |
| `GET /logs?actor=&domain=&action=&entity=&cursor=` | access | audit events; for domain admins the domain filter is **forced on** (their own domains only) |

**Example — the rapid search response** (tenant-scoped, capped):

```json
{
  "query": "carlos",
  "results": [
    {"type": "user",  "id": "carlos@empresa.com", "display_name": "Carlos Mendoza",
     "domain": "empresa.com", "details": {"quota_bytes": 10737418240,
                                          "quota_used_bytes": 5800816640, "active": true}},
    {"type": "alias", "id": "carlos-ventas@empresa.com", "display_name": "Alias de Ventas Carlos",
     "domain": "empresa.com", "details": {"goto": "info@empresa.com", "active": true}}
  ]
}
```

## 6. Frontend architecture (the PWA)

### 6.1 Stack & i18n

- **Vite + React + TypeScript** (chosen over SolidJS: ecosystem size, shadcn/ui
  compatibility, onboarding reality); **Tailwind CSS + shadcn/ui**;
  **Dexie.js** over IndexedDB (settings, cached log pages, last-known lists);
  **`vite-plugin-pwa`** for the service worker + web manifest.
- **i18n is a day-one requirement, not an afterthought:** `i18next` + browser
  language detector — English source strings with a complete **Spanish**
  translation; first load detects `navigator.language` (fallback
  `Accept-Language`), the user can override in Settings and the choice
  persists in localStorage. No hardcoded strings ship; CI checks that every
  source key has an `es` translation.
- PWA manifest: `display: standalone`, theme colors, icons, `start_url` —
  installable on Android/desktop even without the APK.
- Zero-zoom, 44 px touch targets, `touch-action` tuned — no accidental mobile
  zoom, zero perceived touch delay.

### 6.2 Shell layouts (adaptive)

- **Desktop:** fixed left sidebar — logo, the global **domain selector**
  (Slack-space style), Domains / Users / Admins / Devices / Logs; central
  high-density tables with linear quota bars (blue → orange → red).
- **Mobile / standalone PWA:** fixed header (hamburger, active-domain context,
  notification bell — pending device requests surface there), bottom sticky
  tab bar (`[⚙️ Admin]` `[✉️ Accounts]` `[📋 Logs]` — Admin includes devices),
  and a contextual **FAB (+)** for the create-action of the current section.
- Same routes, same components — the shell collapses/expands by form factor.

### 6.3 Screens & flows (from the UI/UX draft, refined)

- **Onboarding "server URL" screen — APK only** (the web app is same-origin):
  base URL input → `[⚙️ TEST CONNECTION]` → `GET /health` → the browser mints its
  UUID (`crypto.randomUUID()`) and secret (`crypto.getRandomValues`). On the web
  the mint happens silently on first visit; the browser registers on the first
  successful login (§4.1).
- **Login:** password first; on mobile the biometric (passkey) shortcut once
  enrolled; desktop adds the clean second 2FA screen.
- **TOTP enrollment:** QR + code confirmation, once per admin (per §4.3).
- **Device-pending lock screen:** valid credentials but an unapproved grant —
  the copyable device ID, the fingerprint derived from the secret, an
  explanation, and `[🔄 CHECK APPROVAL]` (re-polls
  `GET /device/status?username=` without re-entering credentials).
- **Privacy shield:** returning to the app after >2 min backgrounded covers
  the screen until a biometric/unlock; >15 min idle ⇒ tokens purged ⇒ full
  re-login.
- **Entity editors as drawers/bottom sheets** (background intact): the user
  editor embeds its forwarding aliases as dismissible tags (alias rows edited
  in place); the superadmin toggle locks the domain picker with the "global
  access" texture; the admin editor's domain multiselection only enables for
  custom admins.
- **Destructive confirmation sheet:** the guard UI — biometric/password
  re-auth (→ `reauth-confirm`), the 5-second **armed** confirm button, then
  the final request carrying `X-Security-Validation-Token`.
- **Devices panel (superadmin):** pending queue with armed `[🟢 AUTHORIZE]`,
  active list with `[🔴 REVOKE]` (re-auth); no in-app auto-approval exists.
- **Logs timeline:** colored severity rows, cross-filter tags
  (`[👤 carlos@empresa.com (x)]`), `[🛡️ VIEW LOGS]` jump from a user's editor
  with the pre-applied persistent filter tag; tapping a row opens a bottom
  sheet with the IP, event ID, authorizing `device_id` and endpoint.

### 6.4 Rapid search

Global `CTRL/CMD+K` (desktop) / lupa icon (mobile, full-width bar): one
`GET /search?q=` call, categorized badges (User / Alias / Domain), selecting
an item opens the entity's editor drawer without losing context.

### 6.5 Offline & backgrounding rules

- Service worker: `CacheFirst` for the static shell, **`NetworkOnly` for every
  `/api/v1/` call — no offline mutations, ever**; on connectivity loss all
  write controls disable and the read-only banner appears.
- Already-fetched log pages and lists stay readable from the Dexie cache.
- Backgrounding rules as in §6.3 (privacy shield / token purge).

### 6.6 Virtualized lists

Users/logs lists render only the viewport (~15–20 rows) via a virtualization
component (e.g. TanStack Virtual) fed by the cursor pagination — smooth
scrolling on mid-range Android; never "fetch all, render all".

## 7. Quota usage (the `.maildirsize` source)

Dovecot's `quota-status` service speaks the Postfix policy protocol and
answers only pass/reject (`DUNNO`/REJECT-style strings) — **no usage
numbers** — so it is rejected as a data source, and this design needs **no
Dovecot master-admin secret sharing** (a big attack surface for numbers we
can get for free). Instead `api` mounts `ldata/vmail` **read-only**
and:

1. parses the Maildir++ **`.maildirsize`** file Dovecot already maintains next
   to each mailbox — the exact accounting MailD uses
   (`.agents/services/catalog.md`, `90-quota.conf`);
2. falls back to a cached `du`-style walk when the file does not exist yet
   (a mailbox that never received mail);
3. caches results (`ADMINNG_QUOTA_CACHE_TTL`, default 300 s) behind
   `GET /mailboxes/{u}/quota`.

`mailbox.quota` (bytes, 0 = unlimited) remains the limit's source of truth;
the route is read-only and tenant-scoped like everything else.

## 8. PWA & Android packaging

- `adminng/pwa/Dockerfile` is multi-stage: a Node stage builds the static
  bundle; the nginx stage serves it (conf from `adminng/pwa/nginx/`) and
  proxies `/api/v1/` to `api:8080`.
- `adminng/pwa/app-generate.sh` wraps the **PWA → APK** build in Docker
  (Bubblewrap/TWA against the release manifest URL and a build-time
  `VITE_APP_BASE`): a deterministic, reproducible `.apk` without a local
  Android SDK on the dev machine.
- GitHub Actions: the release workflow (on tags, after the image builds) runs
  `app-generate.sh` with the **signing keystore from repository secrets** and
  attaches the signed APK as a release artifact; a `.gitlab-ci.yml` equivalent
  is added if GitLab stays a canonical release path.
- The APK is the only client needing the onboarding "server URL" screen; the
  base URL stays editable in Settings afterwards.

## 9. Observability & logging

- `adminng` access log → stdout (the docker JSON logging driver in dev,
  the operator's log pipeline in prod): the **exterior interaction record** —
  every request that crossed the boundary, with status and timing.
- `api` structured JSON logs (uvicorn + app loggers, clear
  `api:` prefixes, matching the MailD logging style): auth events,
  device transitions, migrations applied at boot, slow queries.
- The audit trail (`audit_event`, §3.2) is the **functional** record the Logs
  UI reads (who did what, on which entity, from which device/IP); the nginx
  log is the **transport** record. They complement each other, never replace.

## 10. Deployment, testing & documentation obligations

Every phase must respect these MailD core principles:

1. **Compose chain in the same commit:** `docker-compose-dev.yml` →
   `docker-compose.yml` → `compose-github.yml` + `compose-gitlab.yml`
   (strict copies; only `image:` lines differ — GitLab uses
   `IMG_API`/`IMG_ADMINNG` + `${TAG}`).
2. **Env chain:** defaults baked in each image's `ENV` block, overridden by the
   operator file; new knobs documented as commented lines in `env.sample`;
   `env_file:` injection only where consumed (`api`; the nginx image
   gets none); `${POSTGRES_PASSWORD:?}` guard in compose; never leave an
   operator-file var empty.
3. **db image:** `ADMINNG_DB` (default `adminng`) is created on every boot by
   `db/ensure_databases.sh`; keep the same value baked in the api image. Do
   **not** append it to `POSTGRES_EXTRA_DB` — the mua reads that one as a
   single contacts database name.
4. **CI:** the GitHub workflow `SERVICES` list gains `api
   adminng`; `.gitlab-ci.yml` gains `IMG_API`/`IMG_ADMINNG`
   and validates the four compose files.
5. **cron/backup_db.sh:** it dumps **only `POSTGRES_DB`** today — extend it to
   also dump the `adminng` DB (a second archive with the same retention and
   validation) so devices, TOTP credentials and the audit trail survive a
   restore.
6. **bootstrap-dev.sh:** start the two services, self-approve the dev devices
   **via the CLI** (never the auto-approval hatch), extend `test.creds` with
   the AdminNG test credentials.
7. **test.sh black-box additions:** health through the nginx proxy; device-gate
   negatives (an unapproved device is rejected everywhere); login+TOTP happy
   path + lockout; CRUD round-trip on the fixtures; tenant-isolation
   negatives; re-auth negative (DELETE without the validation token ⇒
   `403 OPERATION_NOT_VERIFIED`); audit rows exist for the actions performed;
   quota route sanity.
8. **Doc rule (same commit):** `.agents/services/catalog.md` (two new service
   sections), `.agents/services/configuration.md` (matrix rows),
   `.agents/devops/workflows.md` (commands), `env.sample`, `INSTALL.md` /
   `README.md` access points, `Changelog.md`, this draft and `plan.md`.
9. **The boot-cache caveat, made visible:** a domain created at runtime is
   invisible to the boot-time domain-cachers (`amavis` DKIM keys, `mua`
   SnappyMail per-domain config, `mta` virtual aliases) until
   `docker compose ... restart amavis mua mta` — the same inherent caveat
   PostfixAdmin has (`.agents/services/provisioning.md`). The API returns an
   `advisories` field on domain create and the UI shows the "restart needed"
   badge, so the operator is never surprised.

## 11. Risks & open questions (for the review)

1. **Password scheme — addressed (2026-10 audit F-18).** Argon2id is now the
   default writer scheme across `seed.sh`, the API and the webmail driver, with
   legacy md5crypt `$1$` coexistence (Dovecot `default_password_scheme` +
   `auth_allow_weak_schemes`) and rehash-on-login. The weak-scheme window is
   enforced and ends **2027-02-01**; see §3.1. Remaining open point: PostfixAdmin
   (deprecated dev-only fallback) cannot verify Argon2id — accepted by design.
2. **Feature gap vs PostfixAdmin:** vacation, fetchmail, welcome/vacation
   templates, backup/restore UI and the setup-OTP flow are **not** in AdminNG
   v1; PostfixAdmin stays as fallback. The Phase 5 decision must scope them in
   or declare them dead before deprecating the old UI.
3. **`.maildirsize` drift:** Dovecot recalculates it, so it can lag reality;
   the du fallback + cache mitigates; a manual "recount" action is a cheap
   future addition.
4. **APK signing keystore lifecycle** (rotation, Play Store vs sideload
   policy) needs an operator decision before Phase 4 lands.
5. **Single-replica assumptions:** the in-process rate limiter assumes one
   api replica (MailD's deployment shape); the session/device store in
   the DB is already multi-replica safe — revisit only if swarm replicas land.
6. **TOTP recovery:** a second enrolled device or the CLI `--totp-reset` are
   the recovery paths; scratch codes were deliberately left out of v1 to keep
   the surface small.
7. **`python:3.14-slim-trixie` tag** and the Bubblewrap/TWA version pin are to
   be verified at Phase 0 build time — adjust the Dockerfile if the tags
   drifted.

---

*End of the consolidated draft. Companion: [plan.md](plan.md) (implementation
roadmap) · [../README.md](../README.md) (device authorization).*





