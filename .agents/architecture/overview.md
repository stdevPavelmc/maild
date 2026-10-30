# Architecture Overview

## What MailD is

A complete mail server built from Docker containers. The user/domain catalogue lives in
PostgreSQL (no LDAP). Every service is one container with a stable hostname on a dedicated
compose network.

## Mail flow

```
                ┌─────────────────────────── dev network: maild-dev ───────────────────────────┐
 internet ──▶ mta :25/:465/:587 ──▶ amavis :10024 (spam + AV + DKIM) ──▶ mta ──▶ LMTP ──▶ mda
                        ▲                                     │                               │
                        │                              clamav :3310                    Maildir /home/vmail
                        │                                     ▲                               │
                        └── adminng :8083 / mua :8081 / db :5432 ┴─── bayes db (ldata/spamassassin)
```

- **Inbound:** Postfix → amavis (content filter, port 10024) → back to Postfix → LMTP to
  the mda → Maildir. The mta writes the mda's IP into `main.cf` at start
  (`virtual_transport = lmtp:inet:<ip>:24`) — if the mda is recreated with a new IP the mta
  must be restarted or it delivers to a dead address while reporting unhealthy.
- **Alias domains:** Postfix checks the PostfixAdmin `alias_domain` table. An active
  `user@alias-domain` is rewritten to `user@target-domain` before mailbox delivery; inactive
  alias-domain rows are not eligible recipients. AdminNG requires both domains to exist and
  the caller to manage both of them.
- **Internal submitters:** cron's report mails and the MCP's service mail go straight to
  amavis:10026 (bank INTERNAL, DKIM-signed, then mta:10025); amavis admits only the mta on 10024
  and only cron/mcp on 10026, by source address, following moved peers with its watchdog.
- **Outbound:** submission on :587 (auth) → SPF/DNSBL checks → amavis (DKIM signing,
  `DKIM_SIGNING=yes`) → internet. `RELAY` and `ALWAYS_BCC` are optional mta knobs.
- **Content filter:** EICAR and banned attachments (`$banned_filename_re`, e.g. `.exe`)
  are discarded (`D_DISCARD`) and quarantined under `ldata/amavis/virusmails/`; GTUBE is
  scored ~999 by SpamAssassin and quarantined as `spam-*` (delivery policy is `D_PASS`).
- **SpamAssassin lifecycle (automatic):** `sa-update` daily ~02:50 with amavisd reload;
  shared config volume (`saconf`) on amavis/cron/mda with the MailD tuning in
  `/etc/spamassassin/maild.cf`; Bayes learning from the Junk folders (instant via
  imapsieve on the mda, daily batch on cron at 03:30) + autolearn; Junk purge daily 03:00
  (`JUNK_RETENTION_DAYS`, default 7).

## Service map

| Service | Image | Role | Ports (dev) | `depends_on` |
|---------|-------|------|-------------|--------------|
| `db` | `pavelmc/maild-db:develop` | PostgreSQL catalogue | 5432 | — |
| `clamav` | `pavelmc/maild-clamav:develop` | clamd antivirus | 3310 | — |
| `amavis` | `pavelmc/maild-amavis:develop` | content filter (spam/AV/DKIM); 10024 ← mta, 10026 ← cron/mcp | — (internal) | db |
| `mda` | `pavelmc/maild-mda:develop` | Dovecot IMAP/POP3/Sieve | 110, 143, 993, 995, 4190, 12345 | db |
| `mta` | `pavelmc/maild-mta:develop` | Postfix SMTP | 25, 465, 587 | db, mda, amavis, clamav |
| `adminng` | `pavelmc/maild-adminng:develop` | AdminNG PWA + `/api/v1/` proxy | 8083 (HTTP), 8084 (HTTPS, dev) | api |
| `api` | `pavelmc/maild-api:develop` | AdminNG API + first-boot seeder | — (internal) | db |
| `mua` | `pavelmc/maild-mua:develop` | SnappyMail webmail | 8081 | mda |
| `cron` | `pavelmc/maild-cron:develop` | maintenance jobs | — | db |
| `mcp` | `pavelmc/maild-mcp:develop` | MailD MCP: AI-assistant access to the mailboxes (IMAP master user, user page, read tools; service mail via amavis:10026) | 8085 | db, mda, amavis |
| `dozzle` | `amir20/dozzle:latest` | live log viewer (dev only) | 8082 | — |
| `pwa-test` | `pavelmc/maild-pwa-test:develop` | Playwright + Lighthouse harness (dev only, one-shot) | — | api, adminng |

- Service names are the DNS aliases on the network; in dev the containers are also named
  `maild-dev-<svc>` (production: `maild-<svc>`, external network `maild`).
- `depends_on` is a **start order**, not a readiness wait — `bootstrap-dev.sh` does the
  real bounded waiting (Postgres, the catalogue schema, Dovecot's auth socket, the web UIs,
  the ClamAV signatures).
- Production images are `pavelmc/maild-<svc>:latest` (Docker Hub), `ghcr.io/stdevpavelmc/maild-<svc>:latest`
  (GitHub) or `${IMG_<SVC>}:${TAG}` (GitLab). The web UIs (`mua`, `adminng`, `mcp`) are exposed via
  Traefik labels and fronted by an external ingress that terminates TLS — the stack ships none.

## Startup order

1. `db` — everything talks to the catalogue (`pg_isready` is the readiness signal).
2. `clamav` — first boot downloads ~230 MB of signatures; amavis defers all mail until
   clamd answers, so mail does not flow on a cold volume before that finishes.
3. `amavis` (needs db; effectively needs clamav too).
4. `mda` (needs db).
5. `mta` (needs mda + amavis + clamav) — last, it hard-depends on its peers.
6. `api`, `adminng`, `mua`, `cron` — after db; the `api` container seeds the catalogue on
   boot (and `db` creates its schema), which is why bootstrap waits for the schema first.
7. `mcp` — gates (bounded) on the `maild_provision` sentinel, migrates its own DB, seeds its
   admin and ensures its service mailbox before uvicorn starts. The `db` must have run
   `ensure_roles.sh` (the `maild_mcp` role) — until then mcp keeps waiting.

First-boot provisioning rides on this order: the `db` entrypoint applies
`db/migrations/001_maild_provision.sql` (the sentinel table) and
`002_postfixadmin_catalogue.sql` (the catalogue schema), the `api` seeder then writes the
default domain + superadmin + aliases and the sentinel row, and `amavis` / `mua` / `mta`
block (bounded) on that sentinel **before** their DB-dependent config stage
(`AUTO_PROVISION`, default on). See `.agents/services/provisioning.md`.

## Data layout on the host (dev bind mounts)

| Host path | Container path | Used by |
|-----------|----------------|---------|
| `ldata/db` | `/var/lib/postgresql/data` | db |
| `ldata/vmail` | `/home/vmail` | mda, mta, cron |
| `ldata/spool` | `/var/spool/` | mda, mta, amavis |
| `ldata/certs` | `/certs` | mda, mta, adminng, mcp (read-only TLS certs in dev; mcp verifies mda's STARTTLS) |
| `ldata/clamav` | `/var/lib/clamav` | clamav |
| `ldata/amavis` | `/var/lib/amavis` | clamav, amavis (quarantine in `virusmails/`); cron **read-only** (the DKIM keys `dkim/db.txt` + `dkim/*.txt` for `check_dns.sh`) |
| `ldata/spamassassin` | `/var/lib/spamassassin` | amavis (bayes db), cron (learning) |
| `ldata/mua_web` | `/var/www/html/data` | mua (only the writable `data/` dir!) |
| `ldata/logs` | `/var/log` | cron (empty in dev — JSON logging, see DEV-SETUP.md) |
| `ldata/backups` | `/backups` | cron (db dumps) |
| `ldata/mcp_logs` | `/var/log/maild-mcp` | mcp (audit/access/error logs; owner 10001, prepared by bootstrap) |
| `ldata/dozzle` | `/data` | dozzle |
| `ldata/e2e` | `/artifacts` | pwa-test (Playwright reports/traces, screenshots, axe JSON, Lighthouse) |

`ldata/` is git-ignored and disposable in dev: `down` → `rm -rf ldata/` → re-run bootstrap.

## Entrypoints & healthchecks

| Service | ENTRYPOINT → CMD | HEALTHCHECK |
|---------|------------------|-------------|
| db | `docker-entrypoint-wrapper.sh` → stock postgres entrypoint, then `ensure_databases.sh` → `migrate.sh` → `ensure_roles.sh`; `CMD postgres` | `pg_isready -U $POSTGRES_USER` |
| clamav | `/docker-entrypoint.sh` (foreground) | `/check.sh` |
| amavis | `/docker-entrypoint.sh` → `amavisd` (`CMD amavis`) | `/check.sh` |
| mda | `/docker-entrypoint.sh` → `dovecot` | `/check.sh` |
| mta | `/docker-entrypoint.sh` → `postfix` | `/check.sh` |
| api | `/app/entrypoint.sh` → `python -m app.bootstrap` → `uvicorn app.main:app` | HTTP `GET /health` |
| adminng | stock nginx entrypoint → `nginx -g daemon off` | busybox `wget -q -O /dev/null http://127.0.0.1/` |
| mua | `/docker-entrypoint.sh` → apache (base image default) | `curl -f http://localhost/` |
| cron | `/docker-entrypoint.sh` → `cron -f -L 2` | none |
| mcp | `/docker-entrypoint.sh` → `manage.py mcp_boot` → `uvicorn asgi:application` | HTTP `GET /healthz` (db + catalogue + IMAP greeting) |

The `amavis`, `mua` and `mta` entrypoints additionally gate on the `maild_provision` sentinel
before their DB-dependent config stage; the `api` bootstrap (`app/provision.py`) seeds the
catalogue and writes it. See `.agents/services/provisioning.md`.

## Cron schedule (cron/crontab, UTC)

| Time | Script | Job |
|------|--------|-----|
| hourly | `date` | heartbeat |
| 01:10 | `resume.sh` | daily traffic resume (needs syslog — see env.sample) |
| 02:13 monthly | `check_maildirs.sh` | stale/orphan maildir report |
| 03:00 | `purge_junk.sh` | delete Junk older than `JUNK_RETENTION_DAYS` |
| 03:30 | `learn_from_folders.sh` | Bayes learning from Junk + INBOX samples |
| hourly (:23) | `outbound_watch.sh` | per-user outbound volume + throttle alerts (needs syslog) |
| 04:20 | `check_dns.sh` | public-DNS health check per active domain (MX/SPF/DMARC/DKIM/PTR/blocklists) → mails only the deviations |
| 08:00 | `backup_db.sh` | catalogue + AdminNG + MCP dumps to `/backups/db` |

SpamAssassin rule updates run on the amavis container (`amavis/sa-update-loop.sh`), not cron.

`check_dns.sh` compares the published records against what this deployment intends: the
expected MX set is `MX_HOSTNAME` (comma-separated; unset = inferred from `DEFAULT_DOMAIN`'s
live MX plus a notice) and the DKIM key is the one on the amavis volume, mounted read-only
into `cron` (`amavis:/var/lib/amavis:ro`). It is silent unless a finding reaches
`DNS_CHECK_ALERT_LEVEL` (default `warning`), and `DNS_CHECK_DOMAINS=none` disables the job.

## Critical constraints

- Hostnames, schema, env var names and volume mount points are immutable — see
  `AGENTS.md → Core principles` and `.agents/services/configuration.md`.
- The `api` container is the only service that writes catalogue rows at boot (the seeder)
  and can only do so because `db` created the schema first; `MAIL_ADMIN_PASSWORD` left
  empty is generated and printed OTP-style in `docker compose logs api`.
- SnappyMail is baked into the mua image at `/var/www/html`; only `/var/www/html/data`
  may be bind-mounted (mounting over the app dir hides it: Apache 403 and the entrypoint
  waits forever for `admin_password.txt`).
