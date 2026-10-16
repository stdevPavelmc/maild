# First-boot provisioning

MailD deploys the catalogue itself on the first boot so a fresh stack is usable without the
manual `/setup.php` wizard, the "create domain" clicks, the down/up cycle or the per-service
restart that `INSTALL.md` used to require.

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

## Design — sentinel + leader / worker

```
 db    : migrate.sh creates the maild_provision sentinel table (the only DDL MailD adds)
 admin : upgrade.php (schema) → seed.sh (LEADER) → writes the sentinel row
 amavis ┐
 mua    ├─ wait_for_provision() gate → then run the boot config once → exec the server
 mta    ┘
 mda /  ── no boot-time domain cache → no gate
 cron
```

- **Sentinel** = one row in `maild_provision` (`db/migrations/001_maild_provision.sql`). The
  DB is the only store shared by *every* service in all deployment contexts (compose, swarm,
  CI); there is no single volume mounted in all of them, which is why a marker file will not
  do.
- **Leader** = the `admin` container: it already owns the PostfixAdmin schema, it exists in
  every compose file, and it is the only service whose job is catalogue management.
  `admin/seed.sh` runs after `public/upgrade.php`. Its work is one transaction guarded by
  `pg_advisory_xact_lock(842019019)`, so concurrent swarm replicas serialise and converge.
- **Worker gate** = a small `wait_for_provision()` inlined in the amavis / mua / mta
  entrypoints (they already inline `get_domains`/pgpass, so this matches the codebase style
  and keeps every image self-contained — the Docker build context is the per-service
  directory, so a shared top-level module would not be COPY-able without reworking all
  build contexts).
- The gate is **bounded** (`PROVISION_WAIT_TIMEOUT`, default 180s): a broken provisioner
  degrades to today's manual flow instead of deadlocking the boot.

## What gets seeded

`admin/seed.sh` writes the same data the manual procedure did: `DEFAULT_DOMAIN`, the
superadmin `MAIL_ADMIN_USER@DEFAULT_DOMAIN` (plus its mailbox with the *same* password),
and the default aliases → the admin address. The password comes from `MAIL_ADMIN_PASSWORD`;
when empty it is generated and printed OTP-style in `docker compose logs admin`.

Seeding the catalogue **directly in the DB** also bypasses PostfixAdmin's interactive "the
domain must resolve on the internet" check, which is a real obstacle on air-gapped or
behind-proxy deployments.

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `AUTO_PROVISION` | `yes` | `no` restores the classic OTP + `/setup.php` manual flow. |
| `MAIL_ADMIN_PASSWORD` | *(empty)* | Superadmin + admin-mailbox password. Empty ⇒ generated + logged. |
| `PROVISION_VERSION` | `1` | Bump to re-assert the defaults on the next boot. |
| `PROVISION_WAIT_TIMEOUT` | `180` | Seconds a gated service waits for the sentinel. |
| `PROVISION_FORCE` | `no` | `yes` re-writes the admin password even if it exists. |

`MAIL_ADMIN_PASSWORD` is already injected by `.gitlab-ci.yml`; the rest live in `env.sample`
(`env.sample` is loaded as an `env_file` by every container, and copied to `.env` in
production).

## Operations

- Reprovision / re-assert by hand: `docker compose exec admin /seed.sh`
  (with `AUTO_PROVISION=yes` in the env; pass `PROVISION_FORCE=yes` to reset the password).
- Working on the dev stack: `bootstrap-dev.sh` still owns the fixtures and re-asserts the
  `test.creds` passwords after the container has seeded, so `test.sh` is unaffected.
- Adding a *later* domain through the PostfixAdmin UI still needs a targeted
  `docker compose restart amavis mua` for DKIM / SnappyMail (inherent: they cache at boot).
