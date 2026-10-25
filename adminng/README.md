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
- It approves its own browser through `adminng.py --approve-device <id>` in the api container
  (the UI cannot approve itself by design); `run.sh superadmin` covers the
  UI path (devices panel, re-auth + 5 s armed authorize). `flows.spec.ts` covers
  registration-on-first-login, account create/delete, the sidebar domain scope, the language
  switch and the offline write lockdown.
- `tests/installable.spec.ts` asserts the manifest fields, an active service worker controlling
  the page and the app booting from the cache with the network down.
- `lighthouse.mjs` gates performance ≥ 0.85, accessibility ≥ 0.9 and best-practices ≥ 0.9;
  SEO is reported only (the panel's `robots.txt` disallows crawling on purpose). Reports land in
  `ldata/e2e/`.
- CI: `.github/workflows/pwa-e2e.yml` (manual dispatch) builds the stack and runs the gate.


## Android APK (Phase 4)

`adminng/pwa/app-generate.sh` builds the PWA and wraps it in a signed Android APK (Trusted Web
Activity, Bubblewrap) entirely in Docker — no local Android SDK:

### Signing keystore

The APK must be signed with a **keystore you keep**: losing it means you can no longer update
an already published app (Play App Signing can mitigate that, but it is an operator decision).
For development/testing, generate a throwaway one:

```bash
cd adminng/pwa
./keystore-generate.sh          # -> ./android.keystore (0600) + ./android.keystore.b64
```

It uses `keytool` from your JDK, or falls back to Docker (`maild-adminng-apk:local`, or
`eclipse-temurin:17-jdk-jammy`) when no JDK is installed. It generates a random password when
you do not set `STORE_PASSWORD`, prints the exact build command, and writes the base64 file for
the CI secret. Optional overrides: `OUT`, `KEY_ALIAS` (default `maild-apk`), `KEY_PASSWORD`,
`DNAME`, `VALIDITY` (default 3650 days), `FORCE=1` to overwrite.

For a **production** release, run the same command on a trusted machine with your own
`DNAME`/passwords, back up both files, and set the repository secrets used by
`.github/workflows/android-apk.yml`:

| Secret | Value |
|---|---|
| `KEYSTORE_BASE64` | the contents of `android.keystore.b64` |
| `KEY_ALIAS` | the alias (`maild-apk` unless changed) |
| `KEY_PASSWORD` | the key password |
| `STORE_PASSWORD` | the keystore password |

(The workflow variable `ADMINNG_APP_URL` is the public https URL of the frontend.)

```bash
cd adminng/pwa
APP_URL=https://adminng.example.com APP_PKG=cu.maild.adminng \
KEYSTORE=/path/to/android.keystore KEY_ALIAS=maild-apk \
KEY_PASSWORD=… STORE_PASSWORD=… ./app-generate.sh
# -> dist/android/cu.maild.adminng-<version>.apk
```

- The APK loads `APP_URL`, so it is same-origin with the API and needs no runtime server
  address; the PWA's register-on-login → pending → approval → enrollment/2FA flow is what runs
  on the phone. `APP_URL` must be **https** (a TWA needs a secure origin for the service worker, the
  install prompt and the digital-asset-links check); `app-generate.sh` rejects `http://`. For a
  LAN device, run `adminng/pwa/tls-cert-generate.sh` (`bootstrap-dev.sh` does it), use the 8084
  listener that `docker-compose-dev.yml` mounts, install `ldata/certs/adminng-ca.der` on the
  phone, and pass `APP_CA_CERT=ldata/certs/adminng-ca.crt` to the build — see
  [`pwa/README.md`](pwa/README.md) §2.1.
- On networks whose IPv4 route to `dl.google.com` answers 404 (the SDK/Maven/Gradle downloads
  fail), run it as
  `DOCKER_NETWORK=host JAVA_TOOL_OPTIONS=-Djava.net.preferIPv6Addresses=true ... ./app-generate.sh`.
- The toolchain image `Dockerfile.android` tries the pinned command-line-tools archive first,
  retries with `wget` **and** `curl`, then falls back through known-good versions (Google
  rotates those "latest" files). A first build dying at
  `wget … commandlinetools…` with exit 8 is that case: update `CMDLINE_TOOLS` in the Dockerfile
  or use `DOCKER_NETWORK=host`.
- The toolchain image is `Dockerfile.android` (JDK 17 + Android SDK + Bubblewrap); the Gradle
  and SDK caches live in the `maild-adminng-apk-gradle` / `maild-adminng-apk-sdk` volumes
  (`GRADLE_CACHE_VOLUME` / `ANDROID_SDK_VOLUME` override them). The SDK volume is seeded from
  the image on first use; `docker volume rm maild-adminng-apk-sdk` resets it after an image bump.
- CI: `.github/workflows/android-apk.yml` runs the same script on a tag/release with the
  keystore from repository secrets and attaches the APK.

**Full runbook (keystore generation/preservation, the network/IPv6 workaround, troubleshooting):
[`pwa/README.md`](pwa/README.md).**

## API (Phase 2: device-bound, two-step auth)

Every request except `GET /health` carries `X-Device-ID` (a UUID the client
generates once and stores) **and `X-Device-Secret`** (32 random bytes, also
client-minted). The id is a public identifier; the secret is the possession
factor that makes it non-transferable — a leaked id alone is useless (audit
F-11). A device is **registered by the first login whose password verifies**
(there is no anonymous registration endpoint), and authorization is
**device-scoped**: a superadmin approves the *browser* once — from the CLI
(`adminng.py --approve-device <id>`) or the devices panel — after which any
admin whose password verifies may sign in from it. Then:

```
POST /api/v1/auth/login-step1            # password → REQUIRES_TOTP_ENROLLMENT | REQUIRES_2FA | AUTHENTICATED | 403 (PENDING)
POST /api/v1/auth/totp-enroll|confirm    # QR/otpauth + code (superadmins must enroll)
POST /api/v1/auth/login-step2            # TOTP code → access JWT (10 min) + refresh token
POST /api/v1/auth/refresh                # rotate the refresh jti
POST /api/v1/auth/reauth-confirm         # password → X-Security-Validation-Token (30 s)
GET  /api/v1/device/status?username=…    # this browser's state (needs the secret)
```

Ticking **“Trust this device for 24 hours”** on the password step arms a fixed
`ADMINNG_REMEMBER_TTL` window for that `(browser, admin)`: the TOTP code is asked
once, and the next logins on that browser answer `AUTHENTICATED` directly until
the window lapses. The window is armed by a TOTP (or biometric) success and is
not extended by later password-only logins; a logout or a password/device change
should be treated as a reason to re-verify.

Catalogue routes (`/domains`, `/mailboxes` + `/{u}/quota`, `/aliases`,
`/admins`, `/search`) require the Bearer access token; **deletes additionally
require the `X-Security-Validation-Token`** header (else
`403 OPERATION_NOT_VERIFIED`). `GET /logs` reads the audit trail. Interactive
docs: `/api/v1/docs`.

Dev fixtures: `bootstrap-dev.sh` pre-approves the browser
`00000000-0000-4000-8000-0000000000d1` and writes both `adminng.device=` and
`adminng.secret=` to `test.creds`; the first superadmin login must enroll TOTP
(the `sysadmin` credential persists across test runs).

The catalogue self-test runs inside the container:

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml \
  exec -T api python -m unittest discover -s tests -v
```




## Authorizing the first device (server side) — READ THIS FIRST

AdminNG uses a zero-trust device model: every client (browser or Android app)
mints an `X-Device-ID` **and** an `X-Device-Secret`, and **nothing operational
works until that browser is explicitly approved**. Approval is **device-scoped**:
once a browser is approved, any admin whose password verifies may sign in from
it. On a fresh deployment **no browser is pre-approved**: there is no silent
in-app auto-approval, so whoever reaches a fresh install first never gets in
automatically.

A browser is registered the moment someone signs in with a valid password, and
its state starts `PENDING` (there is no anonymous registration endpoint — that
was the F-11 finding). The first browser must then be approved **from the server
side** — access to the container is root authority:

```bash
# List devices (id + state + admins seen + fingerprint)
docker compose exec api adminng.py --list-devices

# Authorize a browser (any admin may then use it; --user only records the requester)
docker compose exec api adminng.py --approve-device 'DE793C1A-4F82-411B-9A74-5F1180210A88'

# Revoke a browser: every admin is locked out and its sessions are destroyed
docker compose exec api adminng.py --revoke-device 'DE793C1A-4F82-411B-9A74-5F1180210A88'

# Revoke one admin on a shared browser (deny-list + kill that admin's sessions)
docker compose exec api adminng.py --revoke-grant 'DE793C1A-…' --user 'admin@example.com'

# Drop stale PENDING browsers (age: ADMINNG_PENDING_TTL_DAYS, default 3)
docker compose exec api adminng.py --purge-pending

# Unlock an administrator that lost its TOTP authenticator
docker compose exec api adminng.py --totp-reset 'admin@example.com'

# Clear a login lockout (5 failed attempts) — testing/ops aid
docker compose exec api adminng.py --reset-ratelimit 'admin@example.com'
```

The browser id is shown on the client's lock screen (with a copy button) while
it waits for authorization, and the sign-in form carries a collapsible panel with
the same id so an admin can pre-authorize before the first attempt. Once the
browser is registered, the pending screen also shows a short **fingerprint**
derived from the secret; the superadmin sees the same code in the devices panel
and should compare it out-of-band before approving — always verify the identity
of the requester first.

> **Device approval is browser-wide.** `--approve-device <id>` authorizes the
> browser for every admin, matching the personal-device deployment model (admin
> workstations are not treated as shared kiosks). `--user <admin>` is optional
> and only records who asked for it; use `--revoke-grant <id> --user <admin>` to
> offboard one admin from a browser you no longer want them to use.
> `--secret <s>` is only for dev fixtures that must pre-bind a known secret (see
> `bootstrap-dev.sh`); a real browser binds its own secret on first login.

> Optional escape hatch for unattended first boots:
> `ADMINNG_AUTO_APPROVE_FIRST=yes` (off by default) makes the **first**
> successful superadmin login (password + completed TOTP enrollment)
> auto-approve its browser; the window closes permanently after the first
> approval. Only use it if you accept that risk. `bootstrap-dev.sh` uses the
> CLI instead, so the dev fixtures self-approve safely.

## Access points

- **Dev:** `http://localhost:8083` (`adminng`; it proxies `/api/v1/` to
  `api` — the web app is same-origin, no configuration needed).
- **Production:** `https://adminng.${DEFAULT_DOMAIN}` through the operator's
  Traefik/ingress (TLS terminated by your proxy, like `webmail.`; the stack
  itself terminates no TLS).
- **Android:** signed APK produced by `adminng/pwa/app-generate.sh` and attached
  as an artifact to every GitHub release. It is a Trusted Web Activity: the APK
  loads `APP_URL`, so it is same-origin and needs no in-app server setting.
  Builds that ship their own assets (`VITE_REQUIRE_SERVER_URL=1`) show the
  server-address screen on first run; the same form lives in Settings → *Change
  server* and clears the session, the browser identity (UUID + secret) and the
  log cache.

## Documentation

| File | Content |
|------|---------|
| [doc/technical-draft.md](doc/technical-draft.md) | Consolidated technical specification (architecture, data model, security, API contract, frontend, packaging) |
| [doc/plan.md](doc/plan.md) | Phased implementation roadmap (Phase 0–5, acceptance criteria) |
| doc/especificacion-tecnica-uiux-mailserver.md | Original Spanish UI/UX draft (source material) |
| doc/guia-complementaria-api-pwa(1).md | Original Spanish API/PWA draft (source material) |
