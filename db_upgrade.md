# MailD — upgrading the database service to a new PostgreSQL major

This is the **production procedure** for moving the `db` service to a new PostgreSQL major
(e.g. 15 → 18). It is deliberately separate from
`.agents/devops/base-os-upgrade.md` (the Ubuntu LTS rollover): the database image is the
official `postgres:<major>-<suite>` and follows **its own cadence**, one major at a time.

> Status of this document: written and **verified on the dev bench** for a 15.19 → 18.6
> (`postgres:18-trixie`) upgrade: dumps, fresh initdb, restore, `bootstrap-dev.sh` and the full
> acceptance suite (47 checks) green. The commands below are exactly what was run, with the
> production (named-volume) equivalents added.

## 1. Scope — what an upgrade touches, and what it does not

PostgreSQL data directories are **major-incompatible**: a cluster initialised by 15 cannot be
started by 18 (and vice versa). There is no "pull the new image and restart" path, and MailD
never tries one — the image always initialises a **fresh** cluster and the catalogue travels as a
logical dump.

Services that read the catalogue (all of them connect to the `db` hostname, none of them store
state in it beyond what is dumped):

| Service | What it reads |
|---------|---------------|
| `admin` | the PostfixAdmin schema and every row it manages (domains, mailboxes, aliases, admins) |
| `mda` | `passdb`/`userdb` queries (auth, mailbox path, per-user quota) |
| `mta` | `pgsql:` maps (virtual domains/mailboxes/aliases, sender login, relay domains) |
| `amavis` | the domain list (DKIM key bootstrap) |
| `mua` | the contacts DSN (SnappyMail's own database) |
| `cron` | `psql`/`pg_dump` for the daily backup, quota and traffic reports |

Inside the cluster:

* `mailddb` (`POSTGRES_DB`) — the catalogue: PostfixAdmin's tables plus MailD's
  `maild_provision` sentinel (added by `db/migrations/001_maild_provision.sql`).
* `contacts` (`POSTGRES_EXTRA_DB`, a comma-separated list) — SnappyMail's database; empty in a
  fresh deploy.
* `adminng` (`ADMINNG_DB`) — AdminNG's own state (devices, sessions, TOTP, audit trail); created
  by `ensure_databases.sh` on every boot, empty until AdminNG is used.
* `postgres` — the maintenance database (catalog only; nothing to move).
* the `maild` role (`POSTGRES_USER`, superuser) — **recreated by the image** on the new cluster,
  so the dump does not need to carry the roles.

**Not in the database:** the mail itself (Maildir, on the `vmail` volume), DKIM keys (amavis
volume), TLS certificates (`certs`), SnappyMail's web data. The dump is therefore small (single
MBs) and the downtime window short.

## 2. Pre-flight checklist

1. **Freeze the writers.** `db` is a hard dependency of the whole mail path, so a window is
   required. Nothing is written during the dump itself (a `pg_dump` is a consistent snapshot), but
   mail/IMAP/admin activity between the dump and the restore would be lost.
2. **Record a baseline** (step 3.1 below) and keep the output as the post-restore checklist.
3. **Check that the target image exists** and note its exact tag:
   `docker manifest inspect postgres:18-trixie >/dev/null && echo OK`.
   Use the *trixie* variant for the Debian 13 line (the suite's other images are on
   Ubuntu 26.04; either Debian suite works, but do not mix suites within one tag).
4. **Space and safety**: keep the old data directory/volume untouched until the new cluster has
   been verified, and keep a copy of the dumps **outside** the stack (another host/disk). Dumps
   contain password hashes and DSNs: never commit them (`.gitignore` already covers `ldata/` and
   `*.log`, but not a copy you drop in the repository root).
5. **Collation and encoding**: the new cluster is initialised with the *image's* locale. Compare
   `datcollate`/`datctype` with the old cluster (step 3.1) and, if they differ, set
   `POSTGRES_INITDB_ARGS` (e.g. `--locale=en_US.utf8 --encoding=UTF8`) **before the first start** —
   after initdb it is too late without another dump/restore. (On this bench both clusters came out
   `UTF8` / `en_US.utf8`; PostgreSQL 18 additionally enables `data_checksums` by default, which the
   15 cluster did not have.)
6. **Data layout**: the PostgreSQL **18** images changed the default to major-version directories
   (`PGDATA=/var/lib/postgresql/18/docker`) and *refuse to start* when they find a mount at the
   legacy `/var/lib/postgresql/data` path ("in 18+, these Docker images are configured to store
   database data in a format which is compatible with `pg_ctlcluster` …"). MailD keeps the
   historical single mount at `/var/lib/postgresql/data` (so existing volumes stay valid) and
   pins `PGDATA=/var/lib/postgresql/data` in `db/Dockerfile`, which is the documented opt-out.
   See §5 for the alternative layout and when it is worth adopting.

## 3. Step-by-step (15 → 18; adapt the majors)

Notation: `DC="docker compose --env-file env.dev -f docker-compose-dev.yml"` for the dev bench,
`DC="docker compose --env-file .env -f docker-compose.yml"` for production. The `cron` container is
used to run the dumps: it ships a **newer client** (18) than the old server (15), which is exactly
what `pg_dump` wants, and its `/backups` is a persisted volume in both stacks.

### 3.1 Capture the baseline (before touching anything)

```bash
$DC exec -T db psql -U maild -d mailddb -tAc "SELECT version()"
$DC exec -T db psql -U maild -d mailddb -tAc \
  "SELECT datname, pg_encoding_to_char(encoding), datcollate, datctype
     FROM pg_database WHERE NOT datistemplate ORDER BY 1"        # collation, see §2.5
$DC exec -T db psql -U maild -d mailddb -tAc \
  "SELECT 'domain='||(SELECT count(*) FROM domain),
          'mailbox='||(SELECT count(*) FROM mailbox),
          'alias='||(SELECT count(*) FROM alias),
          'admin='||(SELECT count(*) FROM admin),
          'provision='||(SELECT count(*) FROM maild_provision)"
$DC exec -T db psql -U maild -d mailddb -tAc \
  "SELECT id, version, default_domain, admin_user, provisioned_at FROM maild_provision"
```

> On the dev bench (2026-10-16) the baseline was: PostgreSQL 15.19, `UTF8`/`en_US.utf8` for every
> database, `domain=2 mailbox=5 alias=8 admin=2 provision=1`, sentinel `1|1|maild.cu|sysadmin`.
> Keep your own numbers — step 3.8 compares against them.

### 3.2 Full backup

```bash
$DC exec -T cron mkdir -p /backups/pre-upgrade-15

# roles/globals (for the record — the new cluster recreates `maild` from POSTGRES_USER)
$DC exec -T cron sh -c "PGPASSWORD=\$POSTGRES_PASSWORD pg_dumpall -U maild -h db --globals-only" \
    > pre-upgrade-15/globals.sql
# every database, plain text (the disaster-recovery / bare-cluster path)
$DC exec -T cron sh -c "PGPASSWORD=\$POSTGRES_PASSWORD pg_dumpall -U maild -h db" \
    > pre-upgrade-15/full-all-databases.sql
# the catalogue and the extra databases, custom format (the surgical restore path)
$DC exec -T cron sh -c "PGPASSWORD=\$POSTGRES_PASSWORD pg_dump -U maild -h db -Fc -d mailddb" \
    > pre-upgrade-15/mailddb.dump
$DC exec -T cron sh -c "PGPASSWORD=\$POSTGRES_PASSWORD pg_dump -U maild -h db -Fc -d contacts" \
    > pre-upgrade-15/contacts.dump
```

Verify before going on — an unverified backup is not a backup:

```bash
ls -la pre-upgrade-15
$DC exec -T cron pg_restore -l /backups/pre-upgrade-15/mailddb.dump | grep -c .   # object count
grep -c 'CREATE TABLE' pre-upgrade-15/full-all-databases.sql                     # sanity
```

Then **copy the directory off the stack** (another disk/host) with restrictive permissions — the
dumps carry `mailbox.password` hashes and SnappyMail credentials:

```bash
docker cp "$($DC ps -q cron):/backups/pre-upgrade-15" /root/db-pre-upgrade-15
chmod -R 0700 /root/db-pre-upgrade-15
```

### 3.3 Stop the stack

```bash
$DC stop          # or `down`; NEVER `down -v` — that deletes the named volumes
```

`stop` keeps the containers and their IPs; `down` + `up -d` recreates them (the mta/mda peer
addressing is re-resolved at start and the mta's watchdog covers later moves). Either is fine — the
important part is that **no writer is connected** while the catalogue moves.

### 3.4 Preserve the old data directory / volume

*Dev (bind mount):*

```bash
mv ldata/db ldata/db-15-backup         # the new image initialises a fresh ./ldata/db
```

*Production (named volume `db`):* create a **new** volume and point the db service at it, keeping
the old one intact for rollback:

```bash
docker volume create maild_db18
# edit docker-compose.yml (and mirror into compose-github.yml / compose-gitlab.yml):
#   db service:  - db:/var/lib/postgresql/data   →   - db18:/var/lib/postgresql/data
# top-level volumes:  add `db18:`   (keep `db:` until the cleanup)
# the real docker volume name is `<project>_<key>`, e.g. maild_db — check with `docker volume ls`
```

Reclaiming the name instead (`docker volume rm maild_db` after the dumps) is simpler but leaves no
rollback except the dumps — only do that once they are verified *and* copied off-box.

### 3.5 Switch the base image

```bash
# db/Dockerfile
-FROM postgres:15-bookworm
+FROM postgres:18-trixie
# keep:  ENV PGDATA=/var/lib/postgresql/data      (see §2.6)
$DC build db
```

Update `.agents/devops/base-images.md` (the canonical db rule and its drift table) and
`Changelog.md` in the same commit.

### 3.6 First start — initdb, ensure the databases, apply migrations

```bash
$DC up -d db && $DC logs -f db
```

What a healthy first start looks like (dev bench):

```
PostgreSQL init process complete; ready for start up.
LOG:  starting PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2) ...
LOG:  database system is ready to accept connections
db: INFO - postgres is ready, ensuring extra databases
db: database 'mailddb' already exists        # created by initdb as POSTGRES_DB
db: created database 'contacts'              # POSTGRES_EXTRA_DB
db: INFO - applying schema migrations
db: applying migration 001_maild_provision.sql
db: migrations up to date
```

An `Error: in 18+, these Docker images are configured ...` line means `PGDATA` is not pinned to the
mounted path (§2.6). Confirm the cluster defaults before restoring:

```bash
$DC exec -T db psql -U maild -d mailddb -tAc "SHOW data_directory; SHOW data_checksums;"
$DC exec -T db psql -U maild -d mailddb -tAc \
  "SELECT datname, pg_encoding_to_char(encoding), datcollate FROM pg_database WHERE NOT datistemplate"
```

### 3.7 Restore

```bash
# the catalogue and every extra database, replacing what the fresh boot created
$DC exec -i db pg_restore -U maild -d mailddb  --clean --if-exists < pre-upgrade-15/mailddb.dump  ; echo "rc=$?"
$DC exec -i db pg_restore -U maild -d contacts --clean --if-exists < pre-upgrade-15/contacts.dump ; echo "rc=$?"
$DC exec -i db pg_restore -U maild -d adminng  --clean --if-exists < pre-upgrade-15/adminng.dump  ; echo "rc=$?"
```

* `--clean --if-exists` is **required**: `ensure_databases.sh` already created the databases and
  `migrate.sh` already created `maild_provision` on the fresh cluster, so a plain restore collides
  (`relation already exists`).
* Ownership is preserved because the objects belong to `maild` and you restore as `maild`. For a
  cross-cluster move with different role names add `--no-owner` (and revisit the DSNs).
* Add `-j4` for a parallel restore on a large catalogue.

**Bare-cluster fallback** (empty cluster, no objects yet — e.g. disaster recovery):

```bash
$DC exec -i db psql -U maild -d postgres < pre-upgrade-15/full-all-databases.sql
```

That single file recreates the databases, their objects and the data; it is also restorable with
`gunzip -c … | psql` when you gzip it first.

### 3.8 Verify, then start the stack

```bash
# the same queries as §3.1: the numbers and the sentinel row must match exactly
$DC exec -T db psql -U maild -d mailddb -tAc \
  "SELECT 'domain='||(SELECT count(*) FROM domain), 'mailbox='||(SELECT count(*) FROM mailbox),
          'alias='||(SELECT count(*) FROM alias), 'admin='||(SELECT count(*) FROM admin),
          'provision='||(SELECT count(*) FROM maild_provision)"
$DC exec -T db psql -U maild -d mailddb -tAc \
  "SELECT id, version, default_domain, admin_user, provisioned_at FROM maild_provision"

$DC up -d                                   # every client starts against the new cluster
./bootstrap-dev.sh                          # dev: re-asserts the fixtures and the secrets
./test.sh                                   # the acceptance gate (47 checks)
```

The suite exercises the whole catalogue path (IMAP/SMTP authentication, alias resolution, quotas,
content filters, and the PostfixAdmin login inside `bootstrap-dev.sh`), so a green run **is** the
proof that the restore is complete. If a single client complains, restart it — Postfix, Dovecot,
amavis and PostfixAdmin reconnect per query, but a cached failed connection can linger:

```bash
$DC restart mda mta amavis admin mua cron
```

### 3.9 Cleanup

Once the suite is green and a few days of traffic have gone by:

```bash
rm -rf ldata/db-15-backup        # dev: the rollback copy
docker volume rm maild_db        # prod: the old cluster's volume (only after maild_db18 is verified)
```

Keep the dumps (and the off-stack copy) for the retention period your policy asks for.

## 4. Rollback

The old cluster is untouched, so rolling back is a matter of putting it back in place:

1. `$DC stop`
2. Put the old data back:
   * dev: `mv ldata/db ldata/db18-attempt && mv ldata/db-15-backup ldata/db`
   * prod: point the db service's volume back at the old volume (`db:` instead of `db18:`) — the old
     cluster was never modified, so nothing else is needed.
3. `git revert` the `db/Dockerfile` bump (or restore the previous `FROM`), `$DC build db`, `$DC up -d`.
4. Only if the old cluster was destroyed (the `docker volume rm` path): restore the dumps into a
   *15* cluster — `pg_restore` accepts dumps taken from a 15 server, and the plain
   `full-all-databases.sql` is the fastest path (`psql -f … postgres`).
5. Anything the *new* cluster accepted while it was live is lost in a rollback: keep the mail path
   quiet (or at least know the window) between the dump and the rollback decision.

## 5. Caveats

- **Major incompatibility is absolute.** Never point `postgres:18` at a 15 data directory (or the
  reverse): PostgreSQL refuses to start, and a forced start can corrupt it. The dump/restore above
  exists precisely because of this.
- **Client/server versions.** `pg_dump`/`pg_restore` may be *newer* than the server they work with,
  never older (the same rule the daily backup enforces: `backup_db.sh` refuses to dump when the
  client is older than the server and mails a CRITICAL instead of leaving a silent empty archive).
  A dump taken from 15 restores into 18; the reverse is not supported.
- **PostgreSQL 18 data layout.** The 18 images use `PGDATA=/var/lib/postgresql/18/docker` and
  refuse to start when they find a mount at the legacy `/var/lib/postgresql/data`; MailD pins
  `PGDATA=/var/lib/postgresql/data` (`db/Dockerfile`) to keep existing volumes valid.
- **Collation/encoding** are fixed at `initdb` time. Compare `datcollate` with the old cluster and
  pass `POSTGRES_INITDB_ARGS` on the *first* start if they must match — changing them afterwards
  means another dump/restore (and, in the worst case, reindexing). Distinct collations can also
  change the ordering of text indexes.
- **`data_checksums`** is on by default in 18 (off in the 15 image). That is a benefit, but it
  makes a 18 cluster unable to run on a build without checksum support, and `pg_checksums` is the
  only way to change it later (offline operation).
- **The fresh boot creates objects.** `ensure_databases.sh` creates `POSTGRES_DB` and every
  `POSTGRES_EXTRA_DB` on every boot, and `migrate.sh` applies `db/migrations/*.sql` right after —
  hence the mandatory `--clean --if-exists` on the restore. `migrate.sh` is idempotent
  (`CREATE TABLE IF NOT EXISTS`), so re-running is always safe.
- **The `maild_provision` sentinel travels in the dump.** It gates the boot-time config stages of
  amavis/mua/mta. If the restore loses it, those services either re-provision or never gate —
  always verify it (§3.8) rather than assuming.
- **Password and DSN continuity.** `POSTGRES_PASSWORD` (from `env.dev`/`.env`) must stay the same:
  compose passes it explicitly to every client, and the entrypoint bakes it into the new role. The
  *mailbox* passwords are unaffected (they are md5crypt hashes inside `mailbox.password`).
- **Extra databases are a list.** `POSTGRES_EXTRA_DB` is comma-separated (`contacts` today), and
  AdminNG keeps its own `ADMINNG_DB` (default `adminng`): dump and restore **every** entry,
  including `adminng`, and check the mua's env (`POSTGRES_EXTRA_DB`, defaulted in
  `mua/Dockerfile`) if SnappyMail starts complaining about its contacts DSN.
- **Downtime.** The whole mail path depends on `db`: while it is down, SMTP submissions fail at
  authentication, IMAP/POP3 logins fail and the admin UI is unusable. A remote sender will retry
  (the mta queues only what it has already accepted), so keep the window short and, ideally,
  announce it. Plan for the dump to be the slow part on a large catalogue (use `-Fc -j`, and
  consider `pg_dump` per database in parallel).
- **Do not restore into a live, written-to cluster.** You would lose whatever arrived after the
  dump; stop the stack first (§3.3).
- **Secrets.** Dumps contain password hashes and DSNs: keep them `0600`, store the off-stack copy
  encrypted, and never commit them (`ldata/` is ignored, a stray copy in the repository root is
  not).
- **The daily backups are not an upgrade tool.** `db/backups` holds the `cron` container's
  `maild_backup_*.sql.gz` (a plain `pg_dump | gzip`); it is a valid *fallback source*
  (`gunzip -c … | psql`), but it is a single-database snapshot with its own retention, not a
  migration plan.
- **Rehearse.** Restore the dumps into a scratch cluster first if the catalogue is big or the
  window is tight; the `pg_restore -l` listing plus a `--clean` restore catch version and ownership
  surprises before they cost you the window.
- **Document it.** After a successful upgrade, update `.agents/devops/base-images.md` (rule +
  drift table), `Changelog.md` and this file if the procedure changed — the repository rule is
  "docs in the same commit".

## 6. Alternatives (and when they are worth it)

- **`pg_upgrade --link`** — in-place, minutes instead of a dump/restore for a big catalogue, but it
  needs *both* major binaries in one container and a data layout that does not cross a mount
  boundary (that is exactly why the upstream 18 images moved to `PGDATA=/var/lib/postgresql/18/docker`
  with a single mount at `/var/lib/postgresql`). MailD ships a plain `postgres:<major>` image, so
  adopting it would mean a custom image with both versions plus a one-off layout migration — worth
  it only for catalogues where the dump/restore window is unacceptable.
- **The upstream 18+ layout** (single mount at `/var/lib/postgresql`, data in the major-version
  subdirectory): it makes future `pg_upgrade --link` runs possible and is what the images recommend.
  Adopting it means changing the `db` service's mount point in `docker-compose-dev.yml`,
  `docker-compose.yml`, `compose-github.yml` and `compose-gitlab.yml` plus the production volume
  name — a deliberate, documented change (MailD's `PGDATA` pin exists to avoid forcing it on
  existing deployments).
- **Logical replication / `pglogical`** — near-zero downtime for very large catalogues; heavy
  machinery for a catalogue of a few MB.
- **Doing nothing** — not an option: the image tag is the cluster's major version, so an upgrade
  *is* a new cluster, and the procedure above is the supported path.

## 7. Related documentation

| Where | What |
|-------|------|
| `db/Dockerfile` | the image, the `PGDATA` pin and the entrypoint wrapper chain |
| `db/docker-entrypoint-wrapper.sh` | boot order: stock entrypoint → readiness → `ensure_databases.sh` → `migrate.sh` |
| `db/ensure_databases.sh` | creates `POSTGRES_DB` + `POSTGRES_EXTRA_DB` when missing (never alters) |
| `db/migrate.sh`, `db/migrations/` | idempotent schema migrations (the `maild_provision` sentinel) |
| `cron/scripts/backup_db.sh` | the daily dump, its version guard and its verification |
| `.agents/devops/base-images.md` | the canonical base-image rule for `db` and the drift table |
| `.agents/services/catalog.md` | the `db` service in the stack map |
| `.agents/devops/base-os-upgrade.md` | the separate Ubuntu LTS rollover (does not cover `db`) |
