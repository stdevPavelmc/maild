# PostgreSQL Catalogue (db) — Database for MailD

The `db` container runs PostgreSQL 18 and acts as the central datastore for the MailD catalogue:
domains, mailboxes, aliases, quotas, contacts, and AdminNG administration state (device authorizations,
sessions, TOTP seeds, audit logs).

## Overview

- **Engine:** PostgreSQL 18 (`postgres:18-trixie`).
- **Data storage:** Uses `PGDATA=/var/lib/postgresql/data` pinned in `db/Dockerfile`.
- **Boot process:** `db/docker-entrypoint-wrapper.sh` wraps the upstream PostgreSQL entrypoint:
  1. Boots the server and waits for socket readiness.
  2. Runs `db/ensure_databases.sh` to create any missing databases (`POSTGRES_DB`, `POSTGRES_EXTRA_DB`, and `ADMINNG_DB`).
  3. Executes `db/migrate.sh` to apply pending SQL migrations in `db/migrations/` (`001_maild_provision.sql`, `002_postfixadmin_catalogue.sql`).
- **Idempotency:** Never alters existing data or schema destructively on restart.
- **Consumer services:** Postfix (`mta`), Dovecot (`mda`), Amavis (`amavis`), AdminNG API (`api`), Webmail (`mua`), and maintenance jobs (`cron`) all connect to this container.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 5432 | PostgreSQL | Database listener (published to localhost in dev; internal only in production) |

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/var/lib/postgresql/data` | `ldata/db` | Persistent PostgreSQL database cluster files |

## Variables

Every tunable defaults inside the image (`db/Dockerfile`). The operator file (`.env` in
production, `env.dev` in development) overrides any value.

### Mandatory deployment variables
- `POSTGRES_PASSWORD`: Superuser and application database password.

### Image defaults (overridable)
- `POSTGRES_HOST=db`: Database service hostname.
- `POSTGRES_DB=mailddb`: Primary mail catalogue database.
- `POSTGRES_USER=maild`: Primary database user.
- `POSTGRES_EXTRA_DB=contacts`: Extra databases created at boot (used by SnappyMail for contacts DSN).
- `ADMINNG_DB=adminng`: AdminNG database for device approvals, audit trails, and 2FA credentials.

## Major version upgrades

PostgreSQL data directories are incompatible across major versions (e.g. 15 to 18).
Major upgrades require a dump and restore procedure into a newly initialized volume.
For detailed instructions, see [`db_upgrade.md`](../db_upgrade.md).

## Operational commands

Every compose command needs the invocation that carries the operator env file — `env.dev` in
development, `.env` in production — otherwise the `POSTGRES_PASSWORD` guard fails at parse time:

```bash
# development (this repository)
DC="docker compose --env-file env.dev -f docker-compose-dev.yml"
# production (operator deployment)
DC="docker compose --env-file .env -f docker-compose.yml"

# Connect with psql CLI
$DC exec db psql -U maild -d mailddb

# List databases
$DC exec db psql -U maild -d mailddb -c "\l"

# Check schema migration state
$DC exec db psql -U maild -d mailddb -c "SELECT * FROM maild_provision;"

# Inspect mailboxes in catalogue
$DC exec db psql -U maild -d mailddb -c "SELECT username, domain, active FROM mailbox;"
```

> [!NOTE]
> The snippets below assume the default `POSTGRES_USER=maild` (`db/Dockerfile`) — substitute your
> operator value if you changed it. Inside the `db` container `psql`/`pg_dump*` reach the server
> over the local socket (`local all all trust`), so no password is needed; from `cron` the same
> tools connect over TCP (`-h db`) and read the password from `~/.pgpass`
> (see `cron/scripts/backup_db.sh`).

> [!WARNING]
> Never change the container hostname from `db` — all other services rely on `db:5432` to connect to PostgreSQL.

## Full backup and restore (service level, every database)

A **service-level** backup is the whole PostgreSQL cluster, not a single database: the mail
catalogue (`POSTGRES_DB`), SnappyMail's contacts database (`POSTGRES_EXTRA_DB`), AdminNG's own
state (`ADMINNG_DB`) and the cluster **globals** (roles, tablespaces). `pg_dumpall` is the tool
for that; the per-database `pg_dump` archives are produced as well because they restore a single
database surgically and match the shape of the daily cron archives.

> [!NOTE]
> The database is only *part* of a complete MailD backup. **Not in PostgreSQL:** the mail itself
> (Maildir on the `vmail` volume), DKIM private keys (`amavis`), TLS certificates (`certs`),
> SnappyMail's web data (`mua_web`) and the Postfix spool. Back those volumes up separately if
> you need a full recovery point.

### Backup

```bash
# pick the compose invocation once
DC="docker compose --env-file env.dev -f docker-compose-dev.yml"   # prod: --env-file .env -f docker-compose.yml

# 1. destination on the HOST, never inside the container:
#    dev  ldata/backups/full   (git-ignored)
#    prod /var/backups/maild/full  (host side of the `db_backups` volume)
mkdir -p ldata/backups/full && cd ldata/backups/full

# 2. cluster globals: roles (with their password hashes) and tablespaces — kept for the record
$DC exec -T db pg_dumpall -U maild --globals-only > globals.sql

# 3. EVERY database + globals, compressed: the full, self-contained backup.
#    --clean --if-exists makes it restorable over an already-populated cluster (and drops
#    template1/postgres too, which MailD leaves empty); drop the flag for a smaller dump that
#    expects a cluster without those databases
$DC exec -T db pg_dumpall -U maild --clean --if-exists | gzip > full-all-databases.sql.gz

# 4. per-database custom-format dumps (surgical restore path: -Fc is compressed and lets
#    pg_restore pick individual objects). Add one line per extra database you created
$DC exec -T db pg_dump -U maild -Fc -d mailddb  > mailddb.dump     # catalogue
$DC exec -T db pg_dump -U maild -Fc -d adminng  > adminng.dump     # AdminNG state
$DC exec -T db pg_dump -U maild -Fc -d contacts > contacts.dump    # SnappyMail address book

# 5. verify BEFORE trusting the files — an unverified dump is not a backup
ls -lh
gzip -t full-all-databases.sql.gz && echo "gzip OK"
zcat full-all-databases.sql.gz | grep -c 'CREATE DATABASE'   # 5 with --clean (3 without it: mailddb, contacts, adminng)
zcat full-all-databases.sql.gz | grep -c 'CREATE TABLE'      # sanity: must be > 0
zcat full-all-databases.sql.gz | tail -3                     # must end with "PostgreSQL database cluster dump complete"
$DC exec -T db pg_restore -l < mailddb.dump | wc -l          # catalogue object count

# 6. restrict and copy OFF the stack (another disk/host): the dumps carry password hashes
chmod 0600 globals.sql ./*.gz ./*.dump
```

`-T` (no TTY) is required on `exec` because the dumps are redirected into files on the host.

Two notes on scope:

* The globals file carries the `maild` role **and its password hash**, but a restore does not
  need it: on a fresh cluster the image recreates the role from `POSTGRES_PASSWORD`. Keep it for
  the record — and treat it as a secret.
* The **daily cron job** (`cron/scripts/backup_db.sh`, 08:00 UTC) already writes
  `maild_backup_*.sql.gz` (catalogue) and `maild_adminng_*.sql.gz` (AdminNG) into `/backups/db` —
  dev `ldata/backups/db`, production the `db_backups` volume, 15-day retention, integrity-checked.
  It does **not** cover `contacts` nor the globals, so use it as a fallback source rather than as
  the service-level backup.

### Restore

> [!WARNING]
> A restore **overwrites** data. Stop every writer first and take a fresh backup of the current
> state before you start. Never run `down -v` — it deletes the named volumes (and with them the
> cluster you are about to restore).

```bash
# pick the compose invocation once
DC="docker compose --env-file env.dev -f docker-compose-dev.yml"   # prod: --env-file .env -f docker-compose.yml

# 0. stop the writers: mta, mda, api, adminng, mua, amavis and cron all hold connections to db
$DC stop
```

#### A. Whole cluster — new host, bare cluster or disaster recovery

```bash
# The cluster must be empty of the dumped databases, or the dump must carry --clean --if-exists
# (step 3 above), which drops and recreates them as part of the restore.
#   dev  : mv ldata/db ldata/db-old        (a fresh cluster is initialised on the next boot)
#   prod : point the db service at a NEW volume and keep the old one — see db_upgrade.md §3.4
$DC up -d db
$DC logs -f db          # wait for "db: INFO - all requested databases exist"

zcat full-all-databases.sql.gz | $DC exec -T db psql -U maild -d postgres

# Expected and harmless — the two errors about the role you are connected as:
#   ERROR: current user cannot be dropped   (DROP ROLE maild)
#   ERROR: role "maild" already exists      (CREATE ROLE maild, recreated by the image)
# Any other error is a real problem: read it. Without --clean you also get one
# "database ... already exists" plus "relation ... already exists" per object created by
# ensure_databases.sh/migrate.sh on boot; the data still restores, the log is just noisy.
```

#### B. One database — surgical restore

```bash
# custom format (-Fc): pg_restore drops and recreates the objects it restores
$DC exec -T db pg_restore -U maild -d mailddb --clean --if-exists --no-owner < mailddb.dump

# plain archive (.sql.gz — the shape of the daily cron archives in /backups/db):
# recreate the database first so the restore starts empty and reports no "already exists" errors
$DC exec -T db dropdb -U maild mailddb
$DC exec -T db createdb -U maild mailddb
zcat maild_backup_YYYYMMDD_HHMMSS.sql.gz | $DC exec -T db psql -U maild -d mailddb
```

#### C. Bring the stack back and verify

```bash
$DC up -d

# the catalogue is back, the sentinel is present and the mailboxes are listed
$DC exec -T db psql -U maild -d mailddb -c "SELECT count(*) AS domains FROM domain"
$DC exec -T db psql -U maild -d mailddb -c "SELECT count(*) AS mailboxes FROM mailbox"
$DC exec -T db psql -U maild -d mailddb -c "SELECT id, version, default_domain, admin_user FROM maild_provision"
$DC exec -T db psql -U maild -d postgres -c "\l"

# then the real proof: a fixture mailbox logs in over IMAP/SMTP and the AdminNG UI answers
```

* The `maild_provision` sentinel row is written by the **`api` service** on first boot, not by the
  `db` image: an empty sentinel after a restore means the restore is incomplete (or the deployment
  was never provisioned).
* Migrations are applied on every boot (`db/migrate.sh`), so a restored cluster is brought up to
  the current schema automatically — no manual SQL step.
* Restoring only `mailddb` leaves `contacts` and `adminng` untouched: use the full dump (or the
  matching per-database dump) when you need a consistent point in time across all three.

See also: [`db_upgrade.md`](../db_upgrade.md) (major-version upgrades — same dump/restore
primitives) and [`cron/README.md`](../cron/README.md) (the automated daily backups).

