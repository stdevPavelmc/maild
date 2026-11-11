# Base Images, Dockerfile Rules & Labels

## Base image rules

Default for new services: **Ubuntu `resolute` (26.04 LTS)**. Use Debian only when a
Debian-specific feature is required — then **Debian `trixie`**. The db is special:
**`postgres:18-trixie`** (never try postgres:16); **`mua`** (Roundcube) is
`debian:trixie-slim` with Debian's own PHP 8.4, and the retired **`admin`** used the official
`php:8.1-apache-bookworm` (see the web UI table below).

The two Python services use the official **`python:3.14-slim-trixie`** image instead: `api`
(AdminNG) and `mcp` (MailD MCP, chosen in `mcp/technical-proposal.md` §12 to match `api`).
Both run non-root; `mcp` also runs on a read-only rootfs.

### Web UI base images (current state + pending work)

The PHP web UIs follow their own release cadence (Debian/PHP security fixes, the app's
releases), not the Ubuntu LTS rollover.

| Service | Base today | Notes |
|---------|-----------|-------|
| mua | `debian:trixie-slim` + Debian's PHP 8.4 (`libapache2-mod-php8.4`) | Roundcube webmail (`mua/README.md`) since 2.0.0-rc3; it replaced the SnappyMail image (`php:8.5-apache`). Deliberately **not** an official `php:` image: the request was the latest Debian with its own PHP, which the Debian Security Team patches for the release's lifetime (trixie's PHP is 8.4; the build runs `apt-get upgrade` so a rebuild picks up every published fix). Rebuild on every Debian PHP DSA and every Roundcube security release. |
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

`.pre-commit` (copy to `.git/hooks/pre-commit`, `chmod +x`) first refuses the commit if any
operator env file (`.env`, `.env-prod`, … — anything whose name starts with `.env`) is staged
(2026-10 audit M-04; `env.dev`/`env.sample` have no leading dot and pass), then rewrites
`org.opencontainers.image.created` with today's date on every modified Dockerfile and
refreshes the `# Copyright … Pavel Milanes` line on modified executable scripts.
