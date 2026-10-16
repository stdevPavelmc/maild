# Base Images, Dockerfile Rules & Labels

## Base image rules

Default for new services: **Ubuntu `resolute` (26.04 LTS)**. Use Debian only when a
Debian-specific feature is required — then **Debian `trixie`**. The db is special:
**`postgres:18-trixie`** (never try postgres:16); the web UIs use the official
`php:8.3-apache(-bookworm)` images.

### ⚠️ Known drift between these rules and the working tree

The uncommitted working tree currently pins older bases for the two web UIs (HEAD already had the
newer ones). Confirm the intended direction with the maintainer before "fixing" either side:

| Service | Rule (canonical) | Working tree today |
|---------|------------------|--------------------|
| admin | `php:8.3-apache-bookworm` | `php:8.1-apache-bookworm` |
| mua | `php:8.3-apache` | `php:8.0-apache` (the kept `mua/internet.Dockerfile` / `mua/local.Dockerfile` variants already use 8.3) |

`clamav`, `amavis`, `mda`, `cron` and `mta` all moved to `ubuntu:resolute` on 2026-10-15/16: the
Ubuntu LTS rollover is **complete (5/5)** — the procedure and the package traps each step uncovered
are in `.agents/devops/base-os-upgrade.md`. Highlights: `mda` was the heavy one (Dovecot 2.3.16 →
**2.4.2**, which does not read 2.3 configuration, so its whole `/etc/dovecot` tree was rewritten),
`mta` (Postfix **3.10.6**) needed its two obsoleted TLS parameters dropped and its
`configure-instance.sh`/`ifconfig` traps fixed, and `cron` dropped the PGDG repository entirely
(resolute's `postgresql-client-18` is newer than both the current and the canonical db server).

Note: changing the db major version on an existing `ldata/db` directory is not a rebuild —
PostgreSQL data directories are major-incompatible, so the cluster is moved with a logical
dump/restore (the production procedure, with its caveats and rollback: `db_upgrade.md`). The
`postgres:18` images also changed the default data layout and need the `PGDATA` pin MailD keeps in
`db/Dockerfile`.

CI publishes its own variants: `mua/internet.Dockerfile` and `mua/local.Dockerfile` still
exist for that; the dev compose always builds the plain `./<svc>/Dockerfile` (admin's
internet/local variants were removed — a single Dockerfile per service is the goal).

## Dockerfile order & hygiene

1. Install dependencies.
2. Install apps/libs not in the repo.
3. Copy the local code.
4. Fix owners and permissions.

You may reorder to shrink the image, but keep those four concerns in order. Also:

- Declare the volumes and ports the service uses.
- Always declare a `HEALTHCHECK` (the dev compose relies on the in-image one; `cron` is the
  historical exception — add one when practical).
- Set `ENTRYPOINT` + `CMD` explicitly.
- No package cache trickery: builds run against the official repos (the old local
  `sources.list` template/cache mechanism was removed).

## OCI labels — mandatory, at the end of every Dockerfile

Always append this block as the **last** lines of the Dockerfile, filling the brackets:

```dockerfile
LABEL org.opencontainers.image.title="MailD <short purpose>" \
      org.opencontainers.image.description="MailD <longer purpose>" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="YYYY-MM-DD"
```

- `created` must stay the **last** label line (no trailing backslash) — the pre-commit hook
  rewrites it.
- Add `cu.maild.original-maintainer="…"` only when the image is built from a custom
  Dockerfile or derived from a non-trivial upstream (e.g. admin documents the PostfixAdmin
  upstream author).
- Legacy labels (`maintainer`, `last_modified`, `image.app`, `image.name`, `modified`,
  `original_maintainer`) are retired — fold their information into the block above.

## Pre-commit hook

`.pre-commit` (copy to `.git/hooks/pre-commit`, `chmod +x`) rewrites
`org.opencontainers.image.created` with today's date on every modified Dockerfile and
refreshes the `# Copyright … Pavel Milanes` line on modified executable scripts.
