# First-boot provisioning

MailD deploys the catalogue itself on the first boot so a fresh stack is usable without a
setup wizard, the "create domain" clicks, a down/up cycle or a per-service restart.

## The problem it solves

Three services cache the domain list **at boot** and never re-read it:

- `amavis` (`amavis/docker-entrypoint.sh`) queries `SELECT domain FROM domain;` and generates
  one DKIM key per domain;
- `mua` (`mua/docker-entrypoint.sh`) builds one SnappyMail JSON config per domain;
- `mta` (`mta/docker-entrypoint.sh`) materialises the `virtual_aliases`
  (postmaster/abuse, `POSTMASTER_ABUSE_SETUP`).

A domain created *after* they start is invisible to them, which is why the old guide told
the operator to "take the stack down and up". A `docker restart` from inside a container is
impossible without the docker socket (and meaningless in swarm), so instead the services
**wait for the catalogue to be seeded before they run their config stage**.

## Design — schema owner + leader + sentinel

```
 db    : ensure_databases.sh → POSTGRES_DB, POSTGRES_EXTRA_DB, ADMINNG_DB
         migrate.sh         → 001_maild_provision.sql          (the sentinel table)
                              002_postfixadmin_catalogue.sql   (the catalogue schema)
 api   : wait for the `domain` table → seed (LEADER) → sentinel row
         → apply its own migrations to ADMINNG_DB → exec uvicorn
 amavis ┐
 mua    ├─ wait_for_provision() gate → run the boot config once → exec the server
 mta    ┘
 mda /  ── no boot-time domain cache → no gate
 cron
```

- **Schema owner = `db`.** `db/migrations/002_postfixadmin_catalogue.sql` is a `pg_dump`
  snapshot of the schema PostfixAdmin 3.3.13 created (13 tables: `config`, `domain`,
  `mailbox`, `alias`, `alias_domain`, `admin`, `domain_admins`, `log`, `vacation`,
  `vacation_notification`, `fetchmail`, `quota`, `quota2`), rewritten idempotent. It used to
  run in the `admin` container through `public/upgrade.php`, before that service retired.
- **Leader = `api`.** `adminng/api/app/provision.py` runs from `app/bootstrap.py` before
  uvicorn starts. Its work is one transaction guarded by
  `pg_advisory_xact_lock(842019019)` — the same key the shell seeder used, so a rolling
  upgrade can never interleave — with `INSERT … ON CONFLICT DO NOTHING` everywhere, so
  concurrent swarm replicas converge instead of racing.
- **Sentinel** = one row in `maild_provision` (`db/migrations/001_maild_provision.sql`). The
  DB is the only store shared by *every* service in all deployment contexts (compose, swarm,
  CI); there is no single volume mounted in all of them, which is why a marker file will not
  do.
- **Worker gate** = a small `wait_for_provision()` inlined in the amavis / mua / mta
  entrypoints (they already inline `get_domains`/pgpass, so this matches the codebase style
  and keeps every image self-contained — the Docker build context is the per-service
  directory, so a shared top-level module would not be COPY-able without reworking all
  build contexts).
- The gate is **bounded** (`PROVISION_WAIT_TIMEOUT`, default 180s): a broken provisioner
  degrades to today's manual flow instead of deadlocking the boot.

## What gets seeded

The same data the manual procedure always created:

- the `DEFAULT_DOMAIN` row (`transport = virtual`);
- the superadmin `MAIL_ADMIN_USER@DEFAULT_DOMAIN` — an `admin` row with `superadmin = true`;
- the matching **mailbox** with the *same* password (so it is a real IMAP/SMTP account);
- the default aliases `postmaster`/`abuse`/`hostmaster`/`webmaster` → the administrator;
- the `maild_provision` sentinel row, last.

The password comes from `MAIL_ADMIN_PASSWORD`; when empty it is generated and printed
OTP-style in `docker compose logs api`. It is hashed with the stack-wide `PASSWORD_SCHEME`
(`argon2id` by default → `{ARGON2ID}$argon2id$…`, the format Dovecot's SQL passdb and the
AdminNG API both verify).

Seeding the catalogue **directly in the DB** also bypasses PostfixAdmin's interactive "the
domain must resolve on the internet" check, which is a real obstacle on air-gapped or
behind-proxy deployments.

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `AUTO_PROVISION` | `yes` | `no` disables the boot-time seeder (manual: `adminng.py --provision`). |
| `MAIL_ADMIN_PASSWORD` | *(empty)* | Superadmin + admin-mailbox password. Empty ⇒ generated + logged. |
| `PROVISION_VERSION` | `1` | Bump to re-assert the defaults on the next boot. |
| `PROVISION_WAIT_TIMEOUT` | `180` | Seconds the api waits for the schema, and each gated service for the sentinel. |
| `PROVISION_FORCE` | `no` | `yes` re-writes the administrator password even if it exists. |

`MAIL_ADMIN_PASSWORD` is injected by `.gitlab-ci.yml`; the rest default in the images
(`api` bakes the seeder set, `amavis`/`mua`/`mta` the gate set — see the matrix in
`.agents/services/configuration.md`) and `env.sample` documents them as optional overrides
of the operator file (`env.dev` in dev, `.env` in production).

## Operations

- **Reprovision / re-assert by hand:**
  `docker compose exec api adminng.py --provision` (add `--force` to reset the password).
  It ignores `AUTO_PROVISION` on purpose: that switch only silences the *boot-time* run.
- **Manual mode (`AUTO_PROVISION=no`):** the stack comes up unseeded; the operator runs the
  CLI above once. This replaces the old `POSTFIXADMIN_SETUP_PASSWORD` + `/setup.php` wizard,
  which retired with the `admin` service. The amavis/mua/mta gates wait out
  `PROVISION_WAIT_TIMEOUT` once in that mode.
- **Working on the dev stack:** `bootstrap-dev.sh` owns the fixtures and re-asserts the
  `test.creds` passwords after the container has seeded, so `test.sh` is unaffected. Its
  `--skip-default-domain` mode exports `AUTO_PROVISION=no` so the "domain not hosted" branch
  stays testable.
- **Adding a *later* domain** through AdminNG writes the same four default aliases, but a
  targeted `docker compose restart amavis mua` is still needed for DKIM / SnappyMail
  (inherent: they cache at boot).
- **PostfixAdmin is retired.** Do not point an old PostfixAdmin instance at the catalogue:
  its `public/upgrade.php` would re-run unguarded migration steps against a schema MailD now
  owns. The `config('version')` row is still seeded so an inspection copy does not think the
  schema is older than itself.

