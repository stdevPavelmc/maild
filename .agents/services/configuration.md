# Service Configuration Patterns

## The environment chain (new schema)

```
env.dev (dev, fake secrets)  /  .env (prod, real secrets)    ← the ONLY operator file
        │  --env-file → compose interpolation (domainname, Traefik labels, guards)
        │  env_file: → injected into the 8 DB-consumer containers
        ▼
container env  ⊕  image ENV defaults (per service, baked in each Dockerfile)
        │      runtime env always wins over the image default
        ▼
docker-entrypoint.sh  →  config templates (_${VAR}_)
```

Deploying needs ONE env file: the mandatory values (`DEFAULT_DOMAIN`,
`MAIL_ADMIN_USER`, `POSTGRES_PASSWORD`), the secrets, and any value that deviates
from a default. Every tunable defaults INSIDE each service image (`ENV` in the
Dockerfiles, per service — only the variables that service's own
entrypoint/scripts consume); a same-named variable in the operator file (or a
compose `environment:` entry / `docker run -e`) always overrides the image
default. Secrets are never baked into images.

Two distinct mechanisms — do not mix them up:

1. **Compose interpolation** (`${VAR}` in the compose files) only reads the
   `--env-file` (`env.dev` in dev; `.env` by default in production) and never
   reads `env_file:` contents. The compose files use it for `domainname:`, the
   Traefik labels, `MAILADMIN` and the `${POSTGRES_PASSWORD:?}` /
   `${DEFAULT_DOMAIN:?}` fail-fast guards.
2. **Container env** — the operator file is injected via `env_file:` into the
   **8 DB-consumer services** (db, admin, api, mua, mda, mta, amavis, cron) and wins
   over the image `ENV` defaults. **clamav gets no `env_file`** (it needs no
   catalogue access: variable separation); its two knobs are explicit
   `environment:` entries with `${VAR:-}` — an empty value behaves exactly
   like unset for both (the entrypoint tests them with `if [ "$VAR" ]`).

**Never leave a variable empty** in the operator file (`FOO=` overrides the
image default with an empty string): comment the line out instead. The toggles
are audited to treat empty as "off/unset", but a blanked value is never what
you want.

`env.sample` is the operator template (mandatory values + the commented optional
override catalogue) — copy to `.env`, edit, deploy. `env.sample_gitlab` is the
CI variant: `.gitlab-ci.yml` crafts `.env` from it plus the CI/CD variables.
`vars/*.env` is **gone**: its defaults moved into the Dockerfiles; its
forwarding hacks (`AUTO_PROVISION=${AUTO_PROVISION:-yes}`) and hardcoded
inter-service hostnames (`AMAVIS=amavis`, `MTA=mta`, `CTDB=contacts`) are image
`ENV` now. Dead vars dropped with it: `CTDB` (unused — the mua reads
`POSTGRES_EXTRA_DB`) and `AMAVIS_MTA` (unused — the amavis entrypoint reads `MTA`).

### PWA build-time variables (not container env)

`adminng/pwa` is a static bundle: its variables are read by Vite at **build** time and baked
into the JS, so they are not part of the compose/`env_file` chain and must be passed to
`docker build`/`npm run build`:

| Variable | Default | Effect |
|---|---|---|
| `VITE_API_BASE` | empty (same origin) | Absolute API base baked into the bundle. The web deployment leaves it empty: `adminng`'s nginx proxies `/api/v1/`. |
| `VITE_REQUIRE_SERVER_URL` | unset | `1` marks a bundled-asset build (own assets, e.g. a Capacitor-style APK) whose first run must ask for the server address (`ServerScreen`). The TWA pipeline (`app-generate.sh`) loads `APP_URL`, so it is same-origin and leaves this unset. |

The **APK pipeline** (`adminng/pwa/app-generate.sh`) is not Vite: `APP_URL` must be `https://`
(a TWA needs a secure origin) and `APP_CA_CERT` (optional) is the CA certificate the build should
trust for a private-CA LAN origin (`ldata/certs/adminng-ca.crt`). The bundle stays root-relative,
so the same `dist/` is valid behind 8083 (HTTP) and 8084 (HTTPS).

The runtime value the user enters is stored in `localStorage` (`adminng.baseUrl`) and wins over
`VITE_API_BASE`; changing it from Settings clears the token pair, the device UUID and the Dexie
log cache before reloading.

## The variable matrix

Per service: what the image bakes (defaults), what the operator file must
carry (mandatory), what it may override. Debug switches are **never** baked:
unset by default, the operator sets them. `POSTGRES_PASSWORD` is mandatory for
every DB consumer and is never baked.

| Service | Image ENV defaults (overridable) | Mandatory from the operator file | Optional overrides (documented in env.sample) |
|---------|----------------------------------|----------------------------------|-----------------------------------------------|
| db | `POSTGRES_HOST=db` `POSTGRES_DB=mailddb` `POSTGRES_USER=maild` `POSTGRES_EXTRA_DB=contacts` `ADMINNG_DB=adminng` | `POSTGRES_PASSWORD` | `POSTGRES_HOST/DB/USER/EXTRA_DB`, `ADMINNG_DB` (advanced; `ADMINNG_DB` must match the api's) |
| admin | `POSTGRES_HOST/DB/USER` `POSTFIXADMIN_DB_TYPE=pgsql` `POSTFIXADMIN_SMTP_SERVER=mta` `POSTFIXADMIN_SMTP_PORT=25` `POSTFIXADMIN_ENCRYPT=md5crypt` `AUTO_PROVISION=yes` `PROVISION_VERSION=1` `PROVISION_WAIT_TIMEOUT=180` `PROVISION_FORCE=no` | `DEFAULT_DOMAIN` `MAIL_ADMIN_USER` `POSTGRES_PASSWORD` | `MAIL_ADMIN_PASSWORD` (empty ⇒ OTP), `PROVISION_*`, `POSTFIXADMIN_*` |
| api | `POSTGRES_HOST=db` `POSTGRES_DB=mailddb` `POSTGRES_USER=maild` `ADMINNG_DB=adminng` `ADMINNG_API_PORT=8080` `ADMINNG_ACCESS_TTL=600` `ADMINNG_REFRESH_IDLE_TTL=900` `ADMINNG_REMEMBER_TTL=86400` `ADMINNG_REAUTH_TTL=30` `ADMINNG_FLOW_TTL=300` `ADMINNG_ENROLL_TTL=600` `ADMINNG_AUTO_APPROVE_FIRST=no` `ADMINNG_TOTP_REQUIRED=superadmin` `ADMINNG_TOTP_ISSUER=MailD AdminNG` `ADMINNG_LOGIN_MAX_FAILURES=5` `ADMINNG_LOCKOUT_SECONDS=900` `ADMINNG_SEARCH_LIMIT=20` `ADMINNG_QUOTA_CACHE_TTL=300` `VMAIL_ROOT=/home/vmail` | `POSTGRES_PASSWORD` `ADMINNG_SECRET_KEY` (JWT signing + TOTP encryption) | every `ADMINNG_*` knob |
| adminng | (none — static PWA + nginx proxy) | — | — (no `env_file`); dev publishes 8083 (HTTP) and 8084 (HTTPS, local CA) |
| mua | `BANNER_TITLE=Webmail` `MTA=mta` `MDA=mda` `POSTGRES_HOST/DB/USER` `POSTGRES_EXTRA_DB=contacts` `MUA_ADMIN_USER=maild` `MUA_CONFIG_WAIT_TIMEOUT=120` `MUA_PLUGINS=add-x-originating-ip-header,change-password,two-factor-auth` `AUTO_PROVISION=yes` `PROVISION_VERSION=1` `PROVISION_WAIT_TIMEOUT=180` | `POSTGRES_PASSWORD` | `MUA_ADMIN_PASSWORD` (empty ⇒ generated + logged), `BANNER_TITLE`, `MUA_PLUGINS`, `MUA_CONFIG_WAIT_TIMEOUT` |
| mda | `POSTGRES_HOST/DB/USER` `DEFAULT_MAILBOX_SIZE=200M` `QUOTA_REPORT_HOUR=0` `QUOTA_REPORT_MINUTE=1` `COUNTRY=JM` `STATE=Kingston` `CITY=Kingston` `ORG=MailD` `OU=MailD` | `DEFAULT_DOMAIN` `MAIL_ADMIN_USER` `POSTGRES_PASSWORD` | `DEFAULT_MAILBOX_SIZE`, `QUOTA_REPORT_*`, cert subject (`COUNTRY/STATE/CITY/ORG/OU`) |
| mta | `POSTGRES_HOST/DB/USER` `MAX_MESSAGESIZE=34865152` `SPF_ENABLE=True` `DNSBL_ENABLE=true` `DNSBL_LIST=zen.spamhaus.org=…` `PEER_WAIT_TIMEOUT=120` `PEER_WATCH_INTERVAL=30` `AMAVIS=amavis` `MDA=mda` `MUA=MUA` `ADMIN=admin` `AUTO_PROVISION=yes` `PROVISION_VERSION=1` `PROVISION_WAIT_TIMEOUT=180` | `DEFAULT_DOMAIN` `MAIL_ADMIN_USER` `POSTGRES_PASSWORD` | `RELAY`, `ALWAYS_BCC`, `POSTMASTER_ABUSE_SETUP` (unset ⇒ off), `MAX_MESSAGESIZE`, `SPF_ENABLE`, `DNSBL_*`, `PEER_*` |
| amavis | `POSTGRES_HOST/DB/USER` `MTA=mta` `CLAMAV=clamav` `CRON=cron` `SPAM_FILTER_ENABLED=yes` `AV_ENABLED=yes` `DKIM_SIGNING=yes` `SA_AUTOLEARN_NONSPAM=0.1` `SA_AUTOLEARN_SPAM=10` `JUNK_RETENTION_DAYS=7` `SA_HAM_SAMPLE_PER_USER=25` `SA_HAM_SAMPLE_MAX=400` `AUTO_PROVISION=yes` `PROVISION_VERSION=1` `PROVISION_WAIT_TIMEOUT=180` | `POSTGRES_PASSWORD` | `AV_ENABLED`, `SPAM_FILTER_ENABLED`, `DKIM_SIGNING`, `SA_*`, `JUNK_RETENTION_DAYS` |
| cron | `POSTGRES_HOST/DB/USER` `MTA=mta` `JUNK_RETENTION_DAYS=7` `SA_HAM_SAMPLE_PER_USER=25` `SA_HAM_SAMPLE_MAX=400` | `DEFAULT_DOMAIN` `MAIL_ADMIN_USER` `POSTGRES_PASSWORD` | `JUNK_RETENTION_DAYS`, `SA_HAM_SAMPLE_*` (the entrypoint dumps the env into `/etc/environment`, from where the cron jobs source it) |
| clamav | (none — both knobs unset by design) | — | `ALTERNATE_MIRROR`, `CLAMAV_DEBUG` (passed by the compose files as explicit entries) |

AdminNG's login checkbox opts this browser/device into `ADMINNG_REMEMBER_TTL`
(default 86400 seconds): both the access token and that session's refresh idle
window use this value. The ordinary access and refresh idle TTLs remain
`ADMINNG_ACCESS_TTL` and `ADMINNG_REFRESH_IDLE_TTL`. The preference is stored
locally per device, and destructive operations still require password
re-authentication and the armed confirmation.

Debug switches (all off by default, never baked): `DEBUG` (mta alias-file
dump), `MTA_DEBUG`, `MDA_DEBUG_INIT/AUTH/AUTH_PASSWORD/MAIL/SSL`, `MUA_DEBUG`,
`CLAMAV_DEBUG`, `AMAVIS_DEBUG`.

## Compose files & the chain rule

Production and its variants are kept in lock-step. The dependency chain is:

```
docker-compose-dev.yml   (dev source; dozzle + pwa-test live only here; env_file: env.dev)
        │  mirror perdurable changes up
        ▼
docker-compose.yml       (production source of truth, derived from -dev; env_file: .env)
        │  strict copy: only the image: lines change
        ├──▶ compose-github.yml   image: ghcr.io/stdevpavelmc/maild-<svc>:latest
        └──▶ compose-gitlab.yml   image: ${IMG_<SVC>}:${TAG}  (see .gitlab-ci.yml)
```

- `docker-compose-dev.yml` → binds `./ldata/*`, `env.dev` (interpolation AND
  `env_file:`), tag `develop`, JSON logs, dozzle, extra debug ports.
- `docker-compose.yml` → named volumes, `.env` (interpolation AND `env_file:`),
  tag `latest`, syslog, image `pavelmc/maild-<svc>:latest`, external `maild`
  network, **Traefik labels** on `admin` (`mailadmin.${DEFAULT_DOMAIN}`),
  `mua` (`webmail.${DEFAULT_DOMAIN}`) and `adminng`
  (`adminng.${DEFAULT_DOMAIN}`).
- `compose-github.yml` / `compose-gitlab.yml` are **strict copies** — regenerate
  them from `docker-compose.yml` whenever it changes (only the `image:` lines
  differ).

Production exposes **no** TLS for the web UIs: the operator must run an ingress
controller (Traefik, Nginx, …) that terminates TLS and joins the external `maild`
network; the Traefik labels are only the routing hints.

## Adding a new configuration option

1. Bake the default in the **service's Dockerfile** `ENV` block (the
   "MailD default configuration (new env schema)" section) — only if that
   service consumes it.
2. Reference it in the service's config template with the `_${NEW_VAR}_`
   placeholder (templates live beside each service's config, e.g. `mta/postfix/`,
   `mda/dovecot/`, `amavis/amavis/` — there is no shared `conf/` directory).
3. Make sure the service's `docker-entrypoint.sh` actually substitutes it into
   the template (the `CFILE` echo blocks enumerate what gets rendered).
4. Add a commented line to **`env.sample`** (documented override) when it makes
   sense as an operator knob.
5. Rebuild and test the single service:
   `docker compose --env-file env.dev -f docker-compose-dev.yml build <svc> && … up -d <svc>`.
6. Update `env.sample` comments, the matrix above and the matching `.agents/`
   file in the same commit.

Debug switches follow the same pattern (`MTA_DEBUG`, `MDA_DEBUG_*`, `MUA_DEBUG`,
`CLAMAV_DEBUG`, `AMAVIS_DEBUG`) — but they are never baked as `ENV`: set them
in the operator file to enable.

## First-boot provisioning variables

`AUTO_PROVISION`, `MAIL_ADMIN_PASSWORD`, `PROVISION_VERSION`, `PROVISION_WAIT_TIMEOUT`
and `PROVISION_FORCE` are documented in `env.sample`; their defaults are baked
in the admin/amavis/mua/mta images (see the matrix). The `admin` entrypoint is
the seeder (leader): after `upgrade.php` it runs `admin/seed.sh`, which seeds
the default domain + superadmin + aliases and writes the `maild_provision`
sentinel row. `amavis`, `mua` and `mta` wait on that sentinel before their
DB-dependent config stage. Full details: `.agents/services/provisioning.md`.

## Entrypoint pattern

- Every service ships `docker-entrypoint.sh` (db wraps it with
  `docker-entrypoint-wrapper.sh` + `ensure_databases.sh`).
- Entrypoints are idempotent per boot: render templates, seed volumes
  (SpamAssassin config, DKIM keys), wait/fail bounded, then `exec` the server.
- Keep entrypoint scripts executable and POSIX-ish bash; log with clear
  prefixes (`db: INFO - …`, `mta: …`) — the test suite and bootstrap grep these.
- Amavis needs the cron container's IP at start (and the mta needs the mda's);
  that is why bootstrap-dev.sh starts `cron` with the rest and restarts peers
  when IPs change.
- The mda renders `/etc/dovecot/config.local` only on the first boot (the
  `configured` flag in the volume): env changes that affect the dovecot config
  need a `docker compose ... up -d --force-recreate mda` after wiping the flag
  (fresh volumes are unaffected).

## Database schema changes

1. Never `ALTER` the PostfixAdmin core tables casually — write a migration
   script under `db/` and run it from the db entrypoint chain (the
   `ensure_databases.sh` slot is for *new* databases only).
2. Test against a disposable dev stack: `down` → `rm -rf ldata/` → bootstrap →
   verify.
3. Remember both consumers: PostfixAdmin (admin UI) and the services' SQL
   lookups (Dovecot/Postfix/Amavis queries).
4. Bump/document in `Changelog.md`.
