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
                        └── admin :8080 / mua :8081 / db :5432 ┴─── bayes db (ldata/spamassassin)
```

- **Inbound:** Postfix → amavis (content filter, port 10024) → back to Postfix → LMTP to
  the mda → Maildir. The mta writes the mda's IP into `main.cf` at start
  (`virtual_transport = lmtp:inet:<ip>:24`) — if the mda is recreated with a new IP the mta
  must be restarted or it delivers to a dead address while reporting unhealthy.
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
| `amavis` | `pavelmc/maild-amavis:develop` | content filter (spam/AV/DKIM) | 10024 | db |
| `mda` | `pavelmc/maild-mda:develop` | Dovecot IMAP/POP3/Sieve | 110, 143, 993, 995, 4190, 12345 | db |
| `mta` | `pavelmc/maild-mta:develop` | Postfix SMTP | 25, 465, 587 | db, mda, amavis, clamav |
| `admin` | `pavelmc/maild-admin:develop` | PostfixAdmin UI | 8080 | db |
| `mua` | `pavelmc/maild-mua:develop` | SnappyMail webmail | 8081 | mda |
| `cron` | `pavelmc/maild-cron:develop` | maintenance jobs | — | db |
| `dozzle` | `amir20/dozzle:latest` | live log viewer (dev only) | 8082 | — |

- Service names are the DNS aliases on the network; in dev the containers are also named
  `maild-dev-<svc>` (production: `maild-<svc>`, external network `maild`).
- `depends_on` is a **start order**, not a readiness wait — `bootstrap-dev.sh` does the
  real bounded waiting (Postgres, PostfixAdmin schema, web UIs, ClamAV signatures).

## Startup order

1. `db` — everything talks to the catalogue (`pg_isready` is the readiness signal).
2. `clamav` — first boot downloads ~230 MB of signatures; amavis defers all mail until
   clamd answers, so mail does not flow on a cold volume before that finishes.
3. `amavis` (needs db; effectively needs clamav too).
4. `mda` (needs db).
5. `mta` (needs mda + amavis + clamav) — last, it hard-depends on its peers.
6. `admin`, `mua`, `cron` — after db; the admin container creates the PostfixAdmin schema
   on boot, which is why bootstrap waits for it.

First-boot provisioning rides on this order: the `db` entrypoint applies the `maild_provision`
sentinel migration, the `admin` entrypoint seeds the default domain + superadmin + aliases and
writes the sentinel, and `amavis` / `mua` / `mta` block (bounded) on that sentinel **before**
their DB-dependent config stage (`AUTO_PROVISION`, default on). See
`.agents/services/provisioning.md`.

## Data layout on the host (dev bind mounts)

| Host path | Container path | Used by |
|-----------|----------------|---------|
| `ldata/db` | `/var/lib/postgresql/data` | db |
| `ldata/vmail` | `/home/vmail` | mda, mta, cron |
| `ldata/spool` | `/var/spool/` | mda, mta, amavis |
| `ldata/certs` | `/certs` | mda, mta |
| `ldata/clamav` | `/var/lib/clamav` | clamav |
| `ldata/amavis` | `/var/lib/amavis` | clamav, amavis (quarantine in `virusmails/`) |
| `ldata/spamassassin` | `/var/lib/spamassassin` | amavis (bayes db), cron (learning) |
| `ldata/mua_web` | `/var/www/html/data` | mua (only the writable `data/` dir!) |
| `ldata/logs` | `/var/log` | cron (empty in dev — JSON logging, see DEV-SETUP.md) |
| `ldata/backups` | `/backups` | cron (db dumps) |
| `ldata/dozzle` | `/data` | dozzle |

`ldata/` is git-ignored and disposable in dev: `down` → `rm -rf ldata/` → re-run bootstrap.

## Entrypoints & healthchecks

| Service | ENTRYPOINT → CMD | HEALTHCHECK |
|---------|------------------|-------------|
| db | `docker-entrypoint-wrapper.sh` → `ensure_databases.sh` → stock postgres entrypoint; `CMD postgres` | `pg_isready -U $POSTGRES_USER` |
| clamav | `/docker-entrypoint.sh` (foreground) | `/check.sh` |
| amavis | `/docker-entrypoint.sh` → `amavisd` (`CMD amavis`) | `/check.sh` |
| mda | `/docker-entrypoint.sh` → `dovecot` | `/check.sh` |
| mta | `/docker-entrypoint.sh` → `postfix` | `/check.sh` |
| admin | `/docker-entrypoint.sh` → `apache2-foreground` | `curl -f http://localhost/` |
| mua | `/docker-entrypoint.sh` → apache (base image default) | `curl -f http://localhost/` |
| cron | `/docker-entrypoint.sh` → `cron -f -L 2` | none |

The `amavis`, `mua` and `mta` entrypoints additionally gate on the `maild_provision` sentinel
before their DB-dependent config stage; the `admin` entrypoint runs `admin/seed.sh` after its
schema step to create the sentinel. See `.agents/services/provisioning.md`.

## Cron schedule (cron/crontab, UTC)

| Time | Script | Job |
|------|--------|-----|
| hourly | `date` | heartbeat |
| 01:10 | `resume.sh` | daily traffic resume (needs syslog — see env.sample) |
| 02:13 monthly | `check_maildirs.sh` | stale/orphan maildir report |
| 03:00 | `purge_junk.sh` | delete Junk older than `JUNK_RETENTION_DAYS` |
| 03:30 | `learn_from_folders.sh` | Bayes learning from Junk + INBOX samples |
| 08:00 | `backup_db.sh` | catalogue dump to `/backups/db` |

SpamAssassin rule updates run on the amavis container (`amavis/sa-update-loop.sh`), not cron.

## Critical constraints

- Hostnames, schema, env var names and volume mount points are immutable — see
  `AGENTS.md → Core principles` and `.agents/services/configuration.md`.
- The admin container emits an OTP setup password on every boot
  (`POSTFIXADMIN_SETUP_PASSWORD` from env is ignored by the dev entrypoint).
- SnappyMail is baked into the mua image at `/var/www/html`; only `/var/www/html/data`
  may be bind-mounted (mounting over the app dir hides it: Apache 403 and the entrypoint
  waits forever for `admin_password.txt`).
