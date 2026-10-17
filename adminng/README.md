# MailD AdminNG — next-generation admin interface (PWA + Android)

AdminNG is the modern, PWA-first administration interface for MailD's PostfixAdmin
catalogue (domains, users/mailboxes, aliases, administrators, security logs) —
usable from any browser and installable as an Android app.

**Status: design phase.** The consolidated specification is
[doc/technical-draft.md](doc/technical-draft.md) and the phased roadmap is
[doc/plan.md](doc/plan.md). The original Spanish drafts that seeded this design
are kept in `doc/` as source material.

## Project layout

One umbrella project — two buildable services, the documentation beside them:

```
adminng/
  ├── doc/      docs, plans, tech docs, drafts (this design)
  ├── api/      FastAPI app + Dockerfile   → service `api`    (internal only)
  ├── pwa/      PWA app + Dockerfile       → service `adminng` (exposed)
  │      └── app-generate.sh (APK build, in Docker)
  ├── pwa-test/ browser suite + Dockerfile → service `pwa-test` (dev only)
  └── README.md
```

| Path | Content |
|------|---------|
| `adminng/doc/` | Documentation: [technical-draft.md](doc/technical-draft.md), [plan.md](doc/plan.md), the original Spanish source drafts |
| `adminng/api/` | FastAPI backend app + Dockerfile → image `maild-api` (service `api`, **internal only**, no published port) |
| `adminng/pwa/` | Vite + React PWA app + Dockerfile → image `maild-adminng` (service `adminng`, **exposed**: dev port 8083, prod `adminng.${DEFAULT_DOMAIN}` via Traefik) + `app-generate.sh` |
| `adminng/pwa-test/` | Playwright + Lighthouse harness + Dockerfile → image `maild-pwa-test` (service `pwa-test`, **dev only**, one-shot) |


`adminng` serves the built PWA static bundle and reverse-proxies
`/api/v1/` to `api` — and keeps the exterior-facing access logs.

## Development quick start (Phase 0)

```bash
./bootstrap-dev.sh                      # builds+starts the stack, including api + adminng
curl -sf localhost:8083/api/v1/health   # API, through the nginx proxy
curl -sI localhost:8083/ | head -1      # the PWA shell (HTTP 200)
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f adminng api
```

Only the two AdminNG services:

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml build api adminng
docker compose --env-file env.dev -f docker-compose-dev.yml up -d db api adminng
```

`api` applies its own migrations to the `adminng` database at boot (created by the
`db` container from `ADMINNG_DB`, default `adminng`). `adminng` has no environment
of its own: it is a static bundle plus the `/api/v1/` proxy.

### Frontend checks (Phase 3)

The browser gates run in the dev-only `pwa-test` container (Playwright + Chromium and
Lighthouse are baked into the image, so the host needs nothing but Docker):

```bash
cd adminng/pwa && npm run i18n:check      # en/es key + placeholder parity (part of `npm run build`)
cd adminng/pwa && npm run build           # i18n gate -> tsc --noEmit -> Vite

./adminng/pwa-test/run.sh verify          # flows + installability + Lighthouse budget
./adminng/pwa-test/run.sh superadmin      # TOTP enrollment + devices panel
./adminng/pwa-test/run.sh visual          # ldata/e2e/screens/*.png (desktop/mobile, EN/ES)
./adminng/pwa-test/run.sh a11y            # axe-core WCAG 2.1 A/AA
./adminng/pwa-test/run.sh shell           # interactive shell in the harness image
```

- `adminng/pwa-test` drives a real Chromium against `http://localhost:8083`. The entrypoint
  tunnels that origin to `http://adminng:80` inside the Compose network: `localhost` is a
  secure context, so the service worker, installability and offline assertions are real.
- It approves its own device through `adminng.py --approve-device` in the api container (the
  UI cannot approve itself by design); `run.sh superadmin` covers the UI path (devices panel,
  re-auth + 5 s armed authorize). `flows.spec.ts` covers login, account create/delete, the
  sidebar domain scope, the language switch and the offline write lockdown.
- `tests/installable.spec.ts` asserts the manifest fields, an active service worker controlling
  the page and the app booting from the cache with the network down.
- `lighthouse.mjs` gates performance ≥ 0.85, accessibility ≥ 0.9 and best-practices ≥ 0.9;
  SEO is reported only (the panel's `robots.txt` disallows crawling on purpose). Reports land in
  `ldata/e2e/`.
- CI: `.github/workflows/pwa-e2e.yml` (manual dispatch) builds the stack and runs the gate.


## Android APK (Phase 4)

`adminng/pwa/app-generate.sh` builds the PWA and wraps it in a signed Android APK (Trusted Web
Activity, Bubblewrap) entirely in Docker — no local Android SDK:

```bash
cd adminng/pwa
APP_URL=https://adminng.example.com APP_PKG=cu.maild.adminng \
KEYSTORE=/path/to/android.keystore KEY_ALIAS=maild-apk \
KEY_PASSWORD=… STORE_PASSWORD=… ./app-generate.sh
# -> dist/android/cu.maild.adminng-<version>.apk
```

- The APK loads `APP_URL`, so it is same-origin with the API and needs no runtime server
  address; the PWA's handshake → pending → approval → enrollment/2FA flow is what runs on the
  phone.
- On networks whose IPv4 route to `dl.google.com` answers 404 (the SDK/Maven/Gradle downloads
  fail), run it as
  `DOCKER_NETWORK=host JAVA_TOOL_OPTIONS=-Djava.net.preferIPv6Addresses=true ... ./app-generate.sh`.
- The toolchain image is `Dockerfile.android` (JDK 17 + Android SDK + Bubblewrap); the Gradle
  cache lives in the `maild-adminng-apk-gradle` volume (`GRADLE_CACHE_VOLUME` overrides it).
- CI: `.github/workflows/android-apk.yml` runs the same script on a tag/release with the
  keystore from repository secrets and attaches the APK.

## API (Phase 2: device-bound, two-step auth)

Every request except `GET /health` carries `X-Device-ID` (a UUID the client
generates once and stores). A fresh device is `PENDING` and only a superadmin
can approve it — from the CLI (`adminng.py --approve-device`) or the devices
panel. Then:

```
POST /api/v1/device/handshake            # register (PENDING)
POST /api/v1/auth/login-step1            # password → REQUIRES_TOTP_ENROLLMENT | REQUIRES_2FA
POST /api/v1/auth/totp-enroll|confirm    # QR/otpauth + code (superadmins must enroll)
POST /api/v1/auth/login-step2            # TOTP code → access JWT (10 min) + refresh token
POST /api/v1/auth/refresh                # rotate the refresh jti
POST /api/v1/auth/reauth-confirm         # password → X-Security-Validation-Token (30 s)
```

Catalogue routes (`/domains`, `/mailboxes` + `/{u}/quota`, `/aliases`,
`/admins`, `/search`) require the Bearer access token; **deletes additionally
require the `X-Security-Validation-Token`** header (else
`403 OPERATION_NOT_VERIFIED`). `GET /logs` reads the audit trail. Interactive
docs: `/api/v1/docs`.

Dev fixtures: `bootstrap-dev.sh` pre-approves the device
`00000000-0000-4000-8000-0000000000d1` and writes it to `test.creds` as
`adminng.device=<uuid>`; the first superadmin login must enroll TOTP (the
`sysadmin` credential persists across test runs).

The catalogue self-test runs inside the container:

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml \
  exec -T api python -m unittest discover -s tests -v
```




## Authorizing the first device (server side) — READ THIS FIRST

AdminNG uses a zero-trust device model: every client (browser or Android app)
carries an `X-Device-ID`, and **nothing works until that device is explicitly
APPROVED**. On a fresh deployment **no device is pre-approved**: there is no
silent in-app auto-approval, so whoever reaches a fresh install first never
gets in automatically.

The first administrator must be approved **from the server side** — access to
the container is root authority:

```bash
# List devices (enrolled, state PENDING/APPROVED/REVOKED)
docker compose exec api adminng.py --list-devices

# Authorize a specific device
docker compose exec api adminng.py --approve-device 'DE793C1A-4F82-411B-9A74-5F1180210A88'

# Revoke immediately (destroys every session/token bound to the device)
docker compose exec api adminng.py --revoke-device 'DE793C1A-4F82-411B-9A74-5F1180210A88'

# Unlock an administrator that lost its TOTP authenticator
docker compose exec api adminng.py --totp-reset 'admin@example.com'

# Clear a login lockout (5 failed attempts) — testing/ops aid
docker compose exec api adminng.py --reset-ratelimit 'admin@example.com'
```

> **`--add-device` does not authorize anything:** it only *registers* a row in the
> `PENDING` state (used by `bootstrap-dev.sh` for its well-known dev device). The
> browser/phone generates **its own UUID** and shows it on the lock screen — copy
> that ID and run `--approve-device <id>` (or use the devices panel once another
> superadmin device is approved).

The device ID is shown on the client's lock screen (with a copy button) while
it waits for authorization, so the admin can read it to you over a trusted
channel — always verify the identity of the requester before approving.

> Optional escape hatch for unattended first boots:
> `ADMINNG_AUTO_APPROVE_FIRST=yes` (off by default) makes the **first**
> successful superadmin login (password + completed TOTP enrollment)
> auto-approve its own device; the window closes permanently after the first
> approval. Only use it if you accept that risk. `bootstrap-dev.sh` uses the
> CLI instead, so the dev fixtures self-approve safely.

## Access points

- **Dev:** `http://localhost:8083` (`adminng`; it proxies `/api/v1/` to
  `api` — the web app is same-origin, no configuration needed).
- **Production:** `https://adminng.${DEFAULT_DOMAIN}` through the operator's
  Traefik/ingress (TLS terminated by your proxy, like `mailadmin.` and
  `webmail.`; the stack itself terminates no TLS).
- **Android:** signed APK produced by `adminng/pwa/app-generate.sh` and attached
  as an artifact to every GitHub release. It is a Trusted Web Activity: the APK
  loads `APP_URL`, so it is same-origin and needs no in-app server setting.
  Builds that ship their own assets (`VITE_REQUIRE_SERVER_URL=1`) show the
  server-address screen on first run; the same form lives in Settings → *Change
  server* and clears the session, the device identity and the log cache.

## Documentation

| File | Content |
|------|---------|
| [doc/technical-draft.md](doc/technical-draft.md) | Consolidated technical specification (architecture, data model, security, API contract, frontend, packaging) |
| [doc/plan.md](doc/plan.md) | Phased implementation roadmap (Phase 0–5, acceptance criteria) |
| doc/especificacion-tecnica-uiux-mailserver.md | Original Spanish UI/UX draft (source material) |
| doc/guia-complementaria-api-pwa(1).md | Original Spanish API/PWA draft (source material) |
