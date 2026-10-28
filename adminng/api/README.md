# AdminNG API Backend (`api`) for MailD

The `api` container runs the FastAPI backend for AdminNG. It provides RESTful management
over the MailD mail catalogue (domains, mailboxes, aliases, admins), enforces zero-trust
device authorization, TOTP and WebAuthn multi-factor authentication, and acts as the
first-boot provisioning leader for the entire stack.

## Overview

- **Engine:** FastAPI / Uvicorn running on Python 3.14 (`python:3.14-slim-trixie`).
- **Network isolation:** Runs internally on the compose network (`maild`/`maild-dev`) with
  no published ports. The `adminng` nginx frontend reverse-proxies `/api/v1/` requests to `api:8080`.
- **First-boot provisioning leader (`app/provision.py`):**
  - Runs on container startup before Uvicorn starts.
  - Takes an advisory lock on PostgreSQL and seeds `DEFAULT_DOMAIN`, the superadmin account
    (`MAIL_ADMIN_USER@DEFAULT_DOMAIN`), its mailbox, and default aliases (`postmaster`, `abuse`,
    `hostmaster`, `webmaster`).
  - Writes the `maild_provision` sentinel row when complete, unblocking dependent services
    (`amavis`, `mda`, `mta`, `mua`).
- **Databases:**
  - `POSTGRES_DB` (`mailddb`): PostfixAdmin-compatible mail catalogue (domains, mailboxes, aliases).
  - `ADMINNG_DB` (`adminng`): AdminNG-specific schema (devices, grants, refresh tokens, TOTP secrets, WebAuthn credentials, audit logs). Migrated automatically at boot from `migrations/`.
- **Security model:**
  - Client requests carry `X-Device-ID` and `X-Device-Secret`.
  - Browsers register on first login in `PENDING` state and must be approved by a superadmin.
  - TOTP (RFC 6238) enforced for superadmins. TOTP seeds encrypted with `ADMINNG_SECRET_KEY`.
  - Destructive operations require password/biometric re-authentication minting a 30-second `X-Security-Validation-Token`.
  - Passwords hashed using Argon2id by default (`PASSWORD_SCHEME=argon2id`).
- **Read-only quota inspection:** Mounts `/home/vmail` read-only under uid/gid `5000:5000` to inspect Maildir++ `.maildirsize` files directly without modifying mail storage.
- **CLI management:** Contains `adminng.py` for device approvals, revocations, and administrative tasks.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8080 | HTTP     | Internal API listener (proxied by `adminng` container) |

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/home/vmail`  | `ldata/vmail` | Maildir volume (mounted **read-only**) to read `.maildirsize` |

## Variables

Every tunable defaults inside the image (`adminng/api/Dockerfile`). The operator file
(`.env` in production, `env.dev` in development) overrides any value.

### Mandatory deployment variables
- `ADMINNG_SECRET_KEY`: 32-byte hex secret (`openssl rand -hex 32`) for JWT signing and TOTP encryption.
- `DEFAULT_DOMAIN`: Primary domain served by this MailD instance.
- `MAIL_ADMIN_USER`: Superadmin username (e.g. `sysadmin`).
- `POSTGRES_PASSWORD`: PostgreSQL catalogue password.

### Image defaults (overridable)
- `POSTGRES_HOST=db`: Database hostname.
- `POSTGRES_PORT=5432`: Database port.
- `POSTGRES_DB=mailddb`: Primary catalogue database name.
- `POSTGRES_USER=maild`: Database user.
- `ADMINNG_DB=adminng`: AdminNG database name.
- `PASSWORD_SCHEME=argon2id`: Password hashing algorithm (`argon2id` default, `md5crypt` legacy).
- `AUTO_PROVISION=yes`: Run first-boot database seeding (`no` to disable).
- `PROVISION_VERSION=1`: Sentinel schema version.
- `PROVISION_WAIT_TIMEOUT=180`: Timeout in seconds waiting for database readiness.
- `PROVISION_FORCE=no`: Set to `yes` to force-reset admin password on boot.
- `ADMINNG_API_PORT=8080`: Internal HTTP listener port.
- `ADMINNG_API_DOCS=no`: Enable OpenAPI interactive docs at `/api/v1/docs` (`yes` in dev).
- `ADMINNG_ACCESS_TTL=600`: Access token lifetime in seconds (10 minutes).
- `ADMINNG_REFRESH_IDLE_TTL=900`: Refresh token idle expiration window (15 minutes).
- `ADMINNG_REMEMBER_TTL=86400`: Trust window for remembered devices (24 hours).
- `ADMINNG_REAUTH_TTL=30`: Validation token lifespan for destructive actions (30 seconds).
- `ADMINNG_AUTO_APPROVE_FIRST=no`: Auto-approve the first superadmin browser on initial login.
- `ADMINNG_PENDING_TTL_DAYS=3`: Days before purging stale pending device registrations.
- `ADMINNG_TOTP_REQUIRED=superadmin`: TOTP policy (`superadmin`, `all`, or `none`).
- `ADMINNG_WEBAUTHN_RP_ID=localhost`: Relying Party ID for WebAuthn passkeys (set to your domain in production).
- `ADMINNG_WEBAUTHN_ORIGINS=http://localhost:8083,https://localhost:8084`: Allowed WebAuthn origins (comma-separated HTTPS URLs in production).
- `ADMINNG_WEBAUTHN_CHALLENGE_TTL=300`: WebAuthn challenge lifetime in seconds.
- `ADMINNG_SEARCH_LIMIT=20`: Maximum results per category in rapid search.
- `ADMINNG_QUOTA_CACHE_TTL=300`: Mailbox quota cache TTL in seconds.
- `VMAIL_ROOT=/home/vmail`: Base path for Maildir storage.

### Optional overrides
- `MAIL_ADMIN_PASSWORD`: Superadmin password. If commented out or empty, generated at first boot and logged.

## Operational commands

```bash
# Approve a pending browser device
docker compose exec api adminng.py --approve-device '<DEVICE-UUID>'

# List all registered devices and approval states
docker compose exec api adminng.py --list-devices

# Revoke a device
docker compose exec api adminng.py --revoke-device '<DEVICE-UUID>'

# Reset TOTP for an administrator who lost their authenticator
docker compose exec api adminng.py --totp-reset '<admin@domain.tld>'

# View catalogue password hashes still using legacy md5crypt
docker compose exec api adminng.py --legacy-hashes

# Run the API test suite
docker compose exec api python -m unittest discover -s tests -v
```

