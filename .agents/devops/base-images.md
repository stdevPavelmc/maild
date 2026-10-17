# Base Images, Dockerfile Rules & Labels

## Base image rules

Default for new services: **Ubuntu `resolute` (26.04 LTS)**. Use Debian only when a
Debian-specific feature is required — then **Debian `trixie`**. The db is special:
**`postgres:18-trixie`** (never try postgres:16); the web UIs use the official
`php:<branch>-apache` images — **`mua` on `php:8.5-apache`**, **`admin` on
`php:8.1-apache-bookworm`** (see the web UI table below).

### Web UI base images (current state + pending work)

The two web UIs follow PHP's own release cadence, not the Ubuntu LTS rollover. Both are Debian
images, and `php:8.3-apache`, `php:8.4-apache` and `php:8.5-apache` are all **trixie** (each bare
tag has the same digest as its `-trixie` sibling), so the `apt-get install` list does not change
between them — the `mua` bump touched nothing but the PHP branch.

| Service | Base today | Notes |
|---------|-----------|-------|
| mua | `php:8.5-apache` (trixie) | Moved from `php:8.3-apache` on 2026-10-17: 8.3 left *active* support on 2025-12-31 (security-only since then, EOL 2027-12-31), 8.5 is active until 2027-12-31 and gets security fixes until 2029-12-31. The bump needed two settings in `mua/snappymail.ini` (`display_errors = Off` + `error_reporting` without the deprecation levels): SnappyMail 2.38.2 predates PHP 8.4 and raises `E_DEPRECATED` from its own code (its `MailSo\Log\Logger` maps `E_STRICT`, deprecated in 8.4), which was printed into the responses — that breaks every later `header()` call and prefixes the JSON API with HTML, killing the webmail in the browser. Details: `.agents/services/catalog.md` → mua. |
| admin | `php:8.1-apache-bookworm` | **PHP 8.1 reached end of life on 2025-12-31.** Not a one-line bump: PHP 8.4 unbundled `ext/imap` to PECL while `admin/Dockerfile` builds `imap` (`docker-php-ext-install imap`) because PostfixAdmin needs it. Pending — its own branch, do not bundle it with `mua`. |

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

The per-service `internet.Dockerfile` / `local.Dockerfile` variants are gone (including `mua`'s):
there is exactly **one `Dockerfile` per service**, and that is what every compose file builds
(`build: ./<svc>/`).

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
