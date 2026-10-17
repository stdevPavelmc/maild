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
  └── README.md
```

| Path | Content |
|------|---------|
| `adminng/doc/` | Documentation: [technical-draft.md](doc/technical-draft.md), [plan.md](doc/plan.md), the original Spanish source drafts |
| `adminng/api/` | FastAPI backend app + Dockerfile → image `maild-api` (service `api`, **internal only**, no published port) |
| `adminng/pwa/` | Vite + React PWA app + Dockerfile → image `maild-adminng` (service `adminng`, **exposed**: dev port 8083, prod `adminng.${DEFAULT_DOMAIN}` via Traefik) + `app-generate.sh` |

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
```

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
  as an artifact to every GitHub release. The APK is the only client that asks
  for the server URL on first run.

## Documentation

| File | Content |
|------|---------|
| [doc/technical-draft.md](doc/technical-draft.md) | Consolidated technical specification (architecture, data model, security, API contract, frontend, packaging) |
| [doc/plan.md](doc/plan.md) | Phased implementation roadmap (Phase 0–5, acceptance criteria) |
| doc/especificacion-tecnica-uiux-mailserver.md | Original Spanish UI/UX draft (source material) |
| doc/guia-complementaria-api-pwa(1).md | Original Spanish API/PWA draft (source material) |
