# Service Configuration Patterns

## The environment chain

```
env.dev (dev, fake secrets)  /  .env (prod, real secrets)      ← compose interpolation
        │  (--env-file env.dev -f docker-compose-dev.yml …)
        ▼
vars/<service>.env  +  vars/ssl.env + vars/db.env + env.sample  ← env_file: lists
        │
        ▼
container environment  →  docker-entrypoint.sh  →  config templates (_${VAR}_)
```

Two distinct mechanisms — do not mix them up:

1. **Compose interpolation** (`${POSTGRES_PASSWORD}` in the compose file) only reads the
   `--env-file` (or `.env` by default). It does **not** read `env_file:` contents. That is
   why `docker-compose-dev.yml` passes `POSTGRES_PASSWORD`, `POSTFIXADMIN_SETUP_PASSWORD`,
   `DEFAULT_DOMAIN`, `AV_ENABLED`… as explicit `environment:` entries — production parity.
2. **Container env** (`env_file:` lists) inject `vars/*.env` + `env.sample` straight into
   the container; the entrypoint consumes them (and substitutes `_${VAR}_` in templates).

`env.sample` is the documented catalogue of every variable and is loaded by **every** dev
container; production loads `.env` instead. `DEFAULT_DOMAIN` / `MAIL_ADMIN_USER` must stay
in sync between `env.dev` and `env.sample` (containers read their own copy from env.sample).

## Compose files & the chain rule

Production and its variants are kept in lock-step. The dependency chain is:

```
docker-compose-dev.yml   (dev source; dozzle lives only here)
        │  mirror perdurable changes up
        ▼
docker-compose.yml       (production source of truth, derived from -dev)
        │  strict copy: only the image: lines change
        ├──▶ compose-github.yml   image: ghcr.io/stdevpavelmc/maild-<svc>:latest
        └──▶ compose-gitlab.yml   image: ${IMG_<SVC>}:${TAG}  (see .gitlab-ci.yml)
```

- `docker-compose-dev.yml` → binds `./ldata/*`, `env.sample`, tag `develop`, JSON logs, dozzle.
- `docker-compose.yml` → named volumes, `.env`, tag `latest`, syslog, image
  `pavelmc/maild-<svc>:latest`, external `maild` network, **Traefik labels** on `admin`
  (`mailadmin.${DEFAULT_DOMAIN}`) and `mua` (`webmail.${DEFAULT_DOMAIN}`).
- `compose-github.yml` / `compose-gitlab.yml` are **strict copies** — regenerate them from
  `docker-compose.yml` whenever it changes (only the `image:` lines differ).
  `compose-dockerhub.yml` was removed: `docker-compose.yml` *is* the Docker Hub file.

Images are always named `maild-<svc>:<tag>`. `.gitlab-ci.yml` sets
`COMPOSE_FILE=compose-gitlab.yml` and the `IMG_*` vars to `$CI_REGISTRY_IMAGE/maild-<svc>`.

Production exposes **no** TLS for the web UIs: the operator must run an ingress controller
(Traefik, Nginx, …) that terminates TLS and joins the external `maild` network; the Traefik
labels above are only the routing hints.

## vars/ anatomy

Each `vars/<service>.env` has two sections, separated by the
`##### Do not edit below this line ##############` marker: tunable defaults above,
forwarded names (`VAR=${VAR}`) and hardcoded inter-service hostnames below
(e.g. `vars/mta.env` → `AMAVIS=amavis`, `MDA=mda`; `vars/amavis.env` → `CLAMAV=clamav`,
`MTA=mta`, `CRON=cron`; `vars/mua.env` → `CTDB=contacts`).

Special cases: `vars/ssl.env` (cert subject fields for self-signed certs, consumed by mda
and mta) and `vars/db.env` (shared by db, admin, mua, mda, mta, amavis, cron — the catalogue
coordinates plus `POSTGRES_EXTRA_DB`).

## Adding a new configuration option

1. Document + default it in **`env.sample`** (with a comment block explaining behaviour).
2. If a container needs it: add `NEW_VAR=
${NEW_VAR}` to the relevant **`vars/<service>.env`**.
3. Reference it in the service's config template with the `_${NEW_VAR}_` placeholder
   (templates live beside each service's config, e.g. `mta/postfix/`, `mda/dovecot/`,
   `amavis/amavis/` — there is no shared `conf/` directory).
4. Make sure the service's `docker-entrypoint.sh` actually substitutes it into the template.
5. Rebuild and test the single service:
   `docker compose --env-file env.dev -f docker-compose-dev.yml build <svc> && … up -d <svc>`.
6. Update `env.sample` comments and the matching `.agents/` file in the same commit.

Debug switches follow the same pattern (`MTA_DEBUG`, `MDA_DEBUG_*`, `MUA_DEBUG`,
`CLAMAV_DEBUG`, `AMAVIS_DEBUG`) — comment them out to disable.

## First-boot provisioning variables

`AUTO_PROVISION`, `MAIL_ADMIN_PASSWORD`, `PROVISION_VERSION`, `PROVISION_WAIT_TIMEOUT` and
`PROVISION_FORCE` are documented in `env.sample` and forwarded through the relevant
`vars/*.env` (admin: all of them; amavis/mua/mta: the gate subset). The `admin` entrypoint is
the seeder (leader): after `upgrade.php` it runs `admin/seed.sh`, which seeds the default
domain + superadmin + aliases and writes the `maild_provision` sentinel row. `amavis`, `mua`
and `mta` wait on that sentinel before their DB-dependent config stage. Full details:
`.agents/services/provisioning.md`.

## Entrypoint pattern

- Every service ships `docker-entrypoint.sh` (db wraps it with
  `docker-entrypoint-wrapper.sh` + `ensure_databases.sh`).
- Entrypoints are idempotent per boot: render templates, seed volumes (SpamAssassin config,
  DKIM keys), wait/fail bounded, then `exec` the server process.
- Keep entrypoint scripts executable and POSIX-ish bash; log with clear prefixes
  (`db: INFO - …`, `mta: …`) — the test suite and bootstrap grep these.
- Amavis needs the cron container's IP at start (and the mta needs the mda's); that is why
  bootstrap-dev.sh starts `cron` with the rest and restarts peers when IPs change.

## Database schema changes

1. Never `ALTER` the PostfixAdmin core tables casually — write a migration script under
   `db/` and run it from the db entrypoint chain (the `ensure_databases.sh` slot is for
   *new* databases only).
2. Test against a disposable dev stack: `down` → `rm -rf ldata/` → bootstrap → verify.
3. Remember both consumers: PostfixAdmin (admin UI) and the services' SQL lookups
   (Dovecot/Postfix/Amavis queries).
4. Bump/document in `Changelog.md`.
