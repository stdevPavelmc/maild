# mua2 — Roundcube webmail (trial)

`mua2` is the candidate replacement for the SnappyMail webmail (`mua`). It runs **next to**
`mua` in the dev stack (http://localhost:8086) until it meets the requirements and the main
developer approves the switch (see [Promotion checklist](#promotion-checklist)). It is not in
the production compose files yet.

| | |
|---|---|
| Base | `debian:trixie-slim` (Debian 13) + Debian's **PHP 8.4** (`libapache2-mod-php8.4`), Apache 2.4 prefork |
| Roundcube | **1.7.6** "complete" tarball, sha256-pinned (signature checked against the Roundcube Developers key when bumping) |
| Dev port | 8086 → 80 |
| State | Roundcube's own database `ROUNDCUBE_DB` (`roundcube`); volume `/var/lib/roundcube` holds only the generated `des_key` (dev: `ldata/mua2`) |
| DB role | `ROUNDCUBE_DB_USER` (`maild_roundcube`), created by the db container (`db/ensure_roles.sh`) — **never** `POSTGRES_PASSWORD` |

## What it does

- **Zero-touch provisioning.** On every start the entrypoint renders the deployment settings
  from the environment, waits (bounded) for the `maild_provision` sentinel like every other
  service, creates Roundcube's schema on an empty database or upgrades it after an image bump
  (`bin/initdb.sh` / `bin/updatedb.sh`), and starts Apache. No installer, no manual step, no
  restart of the stack.
- **Directory address book** (`plugins/maild_directory`): the catalogue's active mailboxes
  (name + address) and, optionally, its distribution lists (aliases that are not a mailbox,
  shown as `List: <name>`), as a read-only "Directory" book. Recipient **autocompletion starts at
  3 typed characters** (`ROUNDCUBE_AUTOCOMPLETE_MIN`) and the same minimum is enforced
  server-side for every free-text search of the directory, so it cannot be pulled one letter at a
  time. Scope: the user's **own domain** by default (`ROUNDCUBE_DIRECTORY_SCOPE=domain`; `all` = every
  hosted domain, `off` = no directory). The MCP service mailbox is hidden. On a user's first
  login the default identity takes its display name from the catalogue (`mailbox.name`).
- **Password change** (Roundcube's `password` plugin, `sql` driver): asks for the current
  password, minimum 8 characters, and writes `mailbox.password` + `modified` hashed per the
  stack-wide **`PASSWORD_SCHEME`**, exactly like the AdminNG API and the SnappyMail driver:
  `argon2id` → `{ARGON2ID}$argon2id$v=19$m=65536,t=4,p=1$…` (PHP `password_hash()` defaults =
  the API's parameters); `md5crypt` → `$1$…` **until 2027-02-01 only**, then argon2id is
  written anyway (checked per request, no restart needed).
- **Sieve** (`managesieve`): filters, vacation and forward on the mda's ManageSieve (4190,
  STARTTLS). The raw script editor is off.
- **Junk button** (`markasjunk`, move only): moving to Junk is what the mda's imapsieve learns
  from. No learning driver is configured (1.7.3 fixed an RCE in `cmd_learn`).
- IMAP on `mda:143` (STARTTLS), SMTP submission on `mta:465` (implicit TLS) as the user, the
  client's IP in a `Received:` header (`http_received_header`, what SnappyMail's
  X-Originating-IP plugin did). Also enabled: `archive`, `zipdownload`, `newmail_notifier`,
  `attachment_reminder`, `hide_blockquote`, `identity_select`.

## Security choices

Roundcube ships security releases often (1.7.3 → 1.7.6, Aug–Nov 2026: Sieve script
injection, IMAP CRLF command injection, CSRF bypasses, SSRF filter bypasses, stored XSS,
header injection, unsafe ImageMagick input, a session-unserialize object injection…). The image
is built to keep that surface small and to limit what a future bug can reach:

- **Patched OS and PHP.** Debian trixie's PHP 8.4 gets the Debian Security Team's backports;
  the build runs `apt-get upgrade`, so every rebuild picks up the published OS/PHP fixes.
  Rebuild on every Debian PHP DSA and every Roundcube security release.
- **Least privilege in the database.** The `maild_roundcube` role owns only the `roundcube`
  database. On the catalogue it has column-level `SELECT` for the directory (never
  `mailbox.password`) and `UPDATE` on `mailbox.password`/`modified` only. A compromised webmail
  cannot read password hashes, where aliases forward to (`alias.goto`), the admin tables or the
  AdminNG/MCP databases' contents.
- **No secrets in reach of PHP.** Compose passes an explicit allow-list (no `env_file`), so
  `POSTGRES_PASSWORD` and the other services' secrets never enter the container. The entrypoint
  renders the settings into `/run/maild-roundcube/maild.inc.php` (root:www-data 0640) and
  starts Apache with a scrubbed environment (`env -i`).
- **Less code exposed.** Only `public_html/` is the document root. The web installer is
  deleted, and so are the unused `enigma`, `squirrelmail_usercopy`, `autologon` and
  `debug_logger` plugins and the sample address book. There is no ImageMagick, GD, LDAP,
  gnupg or aspell. Spell checking, the messages cache and mbox import are off. PHP runs with
  `disable_functions` covering exec/shell/proc_open/popen, `allow_url_fopen=Off` and
  `zend.exception_ignore_args`.
- **Sessions and headers.** The session cookie is `SameSite=Strict` and HttpOnly, with
  client-IP checking and AES-256-CBC session encryption. A login rate limit of 3 failures per
  minute applies per user. `trusted_host_patterns` (default `webmail.<domain>`,
  `webmail2.<domain>`, `localhost`) and `proxy_whitelist` (`ROUNDCUBE_TRUSTED_PROXIES`, private
  ranges by default) are set. Responses carry `X-Frame-Options`, `nosniff`, `Referrer-Policy`
  and `Permissions-Policy`. Remote images are blocked by default, and `Server:` carries no
  version.

## Configuration

Every variable has a default in the image (`mua2/Dockerfile`); the compose allow-list passes
the operator's value through.

| Variable | Default | |
|---|---|---|
| `ROUNDCUBE_DB_PASSWORD` | — (**required**) | the `maild_roundcube` role's password; the **db** service needs it too (it creates the role and the database) |
| `ROUNDCUBE_DB` / `ROUNDCUBE_DB_USER` | `roundcube` / `maild_roundcube` | must match the db's |
| `ROUNDCUBE_DES_KEY` | generated once, kept in the volume | session encryption key (≥ 32 chars); changing it only logs everyone out |
| `ROUNDCUBE_PRODUCT_NAME` | `BANNER_TITLE` | title on the login page and in the browser tab |
| `ROUNDCUBE_LANGUAGE` | `en_US` | default UI language: login page and a user's first login (each user can change it in Settings); any Roundcube locale (`es_ES`, `es_419`, `pt_BR`…) or `auto` = the browser's. dev: `es_ES` |
| `ROUNDCUBE_DIRECTORY_SCOPE` | `domain` | `domain`, `all` or `off` |
| `ROUNDCUBE_DIRECTORY_ALIASES` | `yes` | list the distribution lists too |
| `ROUNDCUBE_DIRECTORY_HIDE` | — | comma-separated addresses never listed (the MCP service mailbox is always added) |
| `ROUNDCUBE_AUTOCOMPLETE_MIN` | `3` | characters before recipient autocompletion starts |
| `ROUNDCUBE_PASSWORD_MIN_LENGTH` | `8` | never below 8 |
| `ROUNDCUBE_SESSION_LIFETIME` | `30` | idle minutes before logout |
| `ROUNDCUBE_TRUSTED_HOSTS` | `webmails.<domain>,webmail.<domain>,webmail2.<domain>,localhost,127.0.0.1` | host names (or regexes) the webmail answers as |
| `ROUNDCUBE_TRUSTED_PROXIES` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` | sources whose `X-Forwarded-For` is believed (the ingress) |
| `ROUNDCUBE_UPLOAD_MAX` | `24M` | attachment limit shown on the compose screen (PHP upload limits follow it). Roundcube's message limit becomes this × 1.33 (base64) + 10 KB, capped by the mta's `MAX_MESSAGESIZE` (a warning is logged and the attachment limit shrinks if it does not fit) |
| `ROUNDCUBE_DEBUG` | — | `yes` logs the IMAP/SMTP dialogues (passwords included: never in production) |
| `PASSWORD_SCHEME`, `BANNER_TITLE`, `MAX_MESSAGESIZE`, `MTA`, `MDA`, `POSTGRES_HOST/DB`, `AUTO_PROVISION`, `PROVISION_*` | as every other service | |

## Operations

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml up -d --build mua2   # (re)build + start
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f mua2         # Apache + PHP + Roundcube log
./test.sh --skip-content --skip-quota                                            # section Q covers mua2
```

The `db` service must have been recreated with `ROUNDCUBE_DB_PASSWORD` set (it creates the
role and the `roundcube` database on its next start; nothing happens while it is empty).

### Updating Roundcube

1. Read the release notes of every version in between.
2. Download `roundcubemail-<ver>-complete.tar.gz` and its `.asc` from the GitHub release, then
   verify them:
   `gpg --recv-keys F3E4C04BB3DB5D4215C45F7F5AB2BAA141C4F7D5 && gpg --verify <tarball>.asc <tarball>`
   (*Good signature from "Roundcube Developers"*).
3. Put the version and the tarball's `sha256sum` in `ARG ROUNDCUBE_VERSION` /
   `ARG ROUNDCUBE_SHA256`, rebuild, and run the test suite. The entrypoint runs
   `bin/updatedb.sh` on the next start.

## Promotion checklist

Before `mua2` replaces `mua`:

- [ ] Functional sign-off by the main developer (UI, Spanish locale, mobile layout).
- [ ] **Two-factor authentication**: SnappyMail's `two-factor-auth` plugin has no bundled
      Roundcube equivalent. Choose one (e.g. a TOTP plugin) or accept that 2FA lives only in
      AdminNG/MCP.
- [ ] **Personal contacts migration**: SnappyMail keeps them in the `contacts` database;
      Roundcube uses its own `contacts` table. This needs a one-shot export/import (vCard)
      script, or users re-import them.
- [x] `ROUNDCUBE_DB` is in the daily cron backups (`maild_roundcube_*.sql.gz`, restored by
      `restore_db.sh`; BACKUP-RESTORE.md). On promotion, add the bare `ROUNDCUBE_DB:` key to
      the cron allow-list of the production compose files (the script defaults to `roundcube`).
- [ ] Production compose: replace `mua` with this image under the `mua` service name and
      hostname (hostnames are immutable), keep `webmail.${DEFAULT_DOMAIN}` behind Traefik with
      `traefik.enable=true`, use the env allow-list, and chain-update `docker-compose.yml`,
      `compose-github.yml` and `compose-gitlab.yml` plus the CI image lists.
- [ ] Retire `mua/`, `POSTGRES_EXTRA_DB=contacts` and the `MUA_*` variables (or keep the
      SnappyMail contacts DB until migrated), and update `.agents/` and `AGENTS.md`.
