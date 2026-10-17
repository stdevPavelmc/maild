# Service Catalog

All services live on the compose network `maild-dev` (dev) / `maild` (production, external).
Service keys are the DNS aliases used everywhere in the config: `db`, `mta`, `mda`,
`amavis`, `clamav`, `admin`, `mua`, `cron` — never rename them.

## db — PostgreSQL catalogue

- Image: `pavelmc/maild-db:develop`, built from `db/Dockerfile` (see
  `.agents/devops/base-images.md` for the base-image rules and their current drift).
- PostgreSQL **18** (`postgres:18-trixie`), with `PGDATA=/var/lib/postgresql/data` pinned in the
  Dockerfile because the 18 images changed the default layout and refuse to start on a mount at the
  legacy path. Major upgrades are a dump/restore into a fresh cluster — the production procedure is
  in `db_upgrade.md`.
- Stores: domains, mailboxes, aliases, quotas — everything Postfix/Dovecot/Amavis query.
- `db/docker-entrypoint-wrapper.sh` starts the stock postgres entrypoint, waits for
  readiness (bounded) and then runs `db/ensure_databases.sh`, which creates any **missing**
  databases from `POSTGRES_DB` + `POSTGRES_EXTRA_DB` (comma-separated, e.g. `contacts`) on
  *every* boot. It never alters existing databases or the schema.
- Env (new schema): defaults baked in `db/Dockerfile` (`POSTGRES_HOST/DB/USER/EXTRA_DB`);
  the operator file (`env.dev`/`.env`) is the `env_file:` and overrides any of them. The
  password is passed explicitly with a `${POSTGRES_PASSWORD:?}` guard (compose does not
  interpolate `env_file:` contents; a missing one fails at `compose config`).
- Port 5432 published for local debugging.

## clamav — antivirus

- Runs clamd; signatures download on first boot (~230 MB) into `ldata/clamav`. On a
  restricted network set `ALTERNATE_MIRROR` in the operator env file (`env.dev`/`.env`).
- Port 3310 published for debugging (`nc -z localhost 3310` to probe).
- Also mounts `/var/lib/amavis`: clamd is asked (by amavis, over TCP 3310) to `CONTSCAN` the
  message files amavisd wrote into its TEMPBASE, so clamd needs read access to that shared
  mount — its user is a member of the **amavis group** (`ARG AMAVIS_GID` in `clamav/Dockerfile`,
  `994` on resolute). The entrypoint fails loudly if that access is missing.
- Env: **no `env_file:` on purpose** (it needs no catalogue access — variable separation);
  its two knobs (`ALTERNATE_MIRROR`, `CLAMAV_DEBUG`) are passed as explicit `environment:`
  entries by the compose files.

## amavis — content filter

- Postfix hands mail to amavis:10024 and takes it back; amavis queries the catalogue for
  the domain list (that is why it needs `POSTGRES_PASSWORD`), scans with SpamAssassin +
  ClamAV, signs DKIM (`DKIM_SIGNING`), and bounces the result to `MTA=mta`.
- Dev toggles `AV_ENABLED` / `SPAM_FILTER_ENABLED` come from compose interpolation
  (`env.dev`); quarantine lands in `ldata/amavis/virusmails/`.
- SpamAssassin config: shared `saconf` volume seeded on first boot; MailD tuning written to
  `/etc/spamassassin/maild.cf` from the env at every start (defaults in `amavis/Dockerfile`).
  Extra `.cf` files can be dropped into the volume without a rebuild (reload/restart amavis).
- `amavis/sa-update-loop.sh` runs daily `sa-update` + reload.
- Waits (bounded) on the `maild_provision` sentinel before the DKIM section, so a fresh
  deploy comes up signed with no restart (`AUTO_PROVISION`).
- Env: defaults baked in `amavis/Dockerfile` (filter toggles, `SA_*`, peer hostnames); the
  operator file is the `env_file:` and overrides any of them.

## mda — Dovecot

- IMAP/POP3/Sieve delivery; reads users/quotas from the catalogue via SQL
  (inline `passdb sql`/`userdb sql` in `mda/dovecot/conf.d/auth-sql.conf.ext` since Dovecot 2.4
  dropped the separate `dovecot-sql.conf.ext` include), Maildir under `/home/vmail`.
- Its listeners carry names in 2.4: `inet_listener auth` (:12345, the mta's SASL path) and
  `inet_listener quota-status` (:12340, Postfix's full-mailbox policy) — renaming either breaks the
  mta.
- Instant Bayes learning: moving mail into/out of `Junk` triggers imapsieve pipe scripts
  (a `sieve_script` on `mailbox Junk` + `imapsieve_from Junk` in `mda/dovecot/conf.d/90-imapsieve.conf`
  → `mda/sieve-pipe/learn-{spam,ham}.sh`).
- `mda/scripts/quota_report.sh` mails the daily mailbox-quota report to
  `MAIL_ADMIN_USER@DEFAULT_DOMAIN`; knobs in `env.sample` (`QUOTA_REPORT_*`); run manually:
  `docker compose exec mda /scripts/quota_report.sh --now [--dry-run]`.
- `mda/configure.sh` (startup helper, invoked by the entrypoint) and `mda/sendmail.py`
  are part of the image.
- **Auth cache** (`mda/dovecot/conf.d/10-auth.conf`): MailD runs it short on purpose —
  `auth_cache_size = 10M` with `auth_cache_ttl = 1 minute` and `auth_cache_negative_ttl = 0`.
  A cached *success* keeps authenticating without asking the catalogue, so a longer TTL made a
  superseded password (a password changed in PostfixAdmin, which never re-authenticates) look
  alive for ten minutes; negative caching for an hour could lock a user out of a password he had
  mistyped before adopting it. See `.agents/devops/workflows.md` for the symptom and
  `doveadm auth cache flush`.
- env: defaults baked in `mda/Dockerfile` (`DEFAULT_MAILBOX_SIZE`, `QUOTA_REPORT_*`, the
  self-signed cert subject); the operator file is the `env_file:` and overrides any of them;
  password + `DEFAULT_DOMAIN`/`MAIL_ADMIN_USER` passed explicitly at compose level.
- Ports: 110, 143, 993, 995 (POP3/IMAP + TLS) and 4190 (ManageSieve), 12345 (SASL).

## mta — Postfix

- SMTP 25, submission 587 (auth), SMTPS 465. SPF (`SPF_ENABLE`) and DNSBL (`DNSBL_ENABLE`,
  `DNSBL_LIST`) checks; `RELAY` / `ALWAYS_BCC` optional; max size `MAX_MESSAGESIZE`.
- Postfix **3.10** (resolute): `compatibility_level = 3.9` (the value the distro ships) and the TLS
  block follows the new parameter set — the two settings Postfix 3.9 obsoleted
  (`smtpd_tls_dh1024_param_file`, `smtpd_tls_eecdh_grade`) are gone and ECDHE auto-curves do the
  work, so the mta no longer reads `/certs/RSA2048.pem` (the mda owns it). 3.9/3.10 also add
  `smtpd_forbid_unauth_pipelining`/`smtpd_forbid_bare_newline` hardening by default.
- The image ships neither `netcat` nor `net-tools`: the healthcheck reads the master pidfile and
  the container's own address (for the 10025 reinjection listener) comes from
  `getent hosts "$(hostname)"`. `postfix-policyd-spf-python` 3.1.0 keeps `/usr/bin/policyd-spf`.
- Hard-depends on mda, amavis, clamav. Delivers local mail over LMTP to the mda's IP
  (baked into `main.cf` at start — restart the mta when the mda is recreated).
- Logs to stdout (`maillog_file = /dev/stdout`); the daily traffic resume parses a syslog
  with rsyslog-style stamps, which only exists in production (dev: `test.sh` phase G
  materialises one).
- Waits (bounded) on the `maild_provision` sentinel before building the `virtual_aliases`, so
  a fresh deploy comes up with them in place and no restart (`AUTO_PROVISION`).
- env: defaults baked in `mta/Dockerfile` (`MAX_MESSAGESIZE`, `SPF_ENABLE`, `DNSBL_*`,
  peer hostnames/timeouts); the operator file is the `env_file:` and overrides any of them;
  `MAILADMIN`, `DEBUG` and the password passed explicitly.

## admin — PostfixAdmin

- Web admin UI on Apache; dev publishes **8080:80** (the container listens on 80;
  publishing 8080:8080 left the UI unreachable while the container looked healthy — found
  by bootstrap-dev.sh).
- Creates/updates the PostfixAdmin schema on boot; emits a one-time **OTP setup password**
  to the logs on every boot (`docker compose logs admin | grep OTP`). The superadmin
  account is `MAIL_ADMIN_USER@DEFAULT_DOMAIN` (provisioned by bootstrap-dev.sh).
- On boot it also runs `admin/seed.sh` **after** `upgrade.php` when `AUTO_PROVISION` is not
  `no`: this is the first-boot provisioner (leader) that seeds the default domain, the
  superadmin (`MAIL_ADMIN_USER@DEFAULT_DOMAIN`), its mailbox and the default aliases, then
  writes the `maild_provision` sentinel. See `.agents/services/provisioning.md`.
- env: defaults baked in `admin/Dockerfile` (`POSTFIXADMIN_*` wiring + the provisioning
  vars); the operator file is the `env_file:` and overrides any of them. The entrypoint maps
  `POSTGRES_PASSWORD` → `POSTFIXADMIN_DB_PASSWORD` itself; `POSTFIXADMIN_SETUP_PASSWORD`
  is ignored (the entrypoint always emits its own OTP).

## mua — SnappyMail

- Webmail on Apache; dev publishes 8081:80. The app is baked into the image at
  `/var/www/html`; **only** `/var/www/html/data` is persisted (`ldata/mua_web`, owned by
  `www-data` — bootstrap-dev.sh fixes the ownership and restarts mua).
- Base image **`php:8.5-apache`** (trixie) since 2026-10-17, was `php:8.3-apache` (active support
  for 8.3 ended on 2025-12-31: security-only until 2027-12-31, while 8.5 is active until
  2027-12-31 and patched until 2029-12-31). SnappyMail 2.38.2 predates PHP 8.4 and so raises
  deprecations from its own code — `MailSo\Log\Logger` maps `E_STRICT` (deprecated in 8.4, see
  `Logger.php:153/171`) and its HTTP client calls `curl_close()`. `mua/snappymail.ini` therefore
  keeps `display_errors = Off` (PHP's compiled default is *On*, because the official image activates
  no `php.ini`; a printed notice fails every later `header()` call — no CSP/X-Frame-Options — and
  prefixes the JSON API with HTML, so `POST /?/Json/` stops being valid JSON and the webmail dies
  in the browser) and `error_reporting = E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED`; every other
  level still reaches `docker compose logs mua` through `log_errors`/`error_log=/dev/stderr`.
  **Never patch SnappyMail's own files inside the image** — its version is pinned by
  `ARG SNAPPY_VERSION` and refreshed by a normal image bump.
- The image builds only `pdo` + `pdo_pgsql` (hence `libpq-dev`): it carries no `gd`/`mcrypt`, so
  the `libfreetype6-dev` / `libjpeg62-turbo-dev` / `libmcrypt-dev` build deps it used to install
  were dropped on 2026-10-17 (−11 MB, `php -m` byte-identical, no extension or Apache module links
  them).
- `config-setup.php` (a PHP helper the entrypoint runs) writes MailD's settings into
  SnappyMail's `application.ini`: `BANNER_TITLE`, the contacts DSN (db `contacts`) with
  `POSTGRES_PASSWORD`, and the admin panel credentials. It patches the file **at text level**
  (comments and foreign settings untouched) quoting the values exactly like SnappyMail does,
  then validates that it still parses and rolls back if it does not. `crudini --set` used to do
  this job: it strips the quotes, PHP rejects the whole file, SnappyMail falls back to its
  factory defaults — `security.admin_password` included — and mints a random password nobody
  printed, so `/?admin` + the OTP from the logs could not work (see Changelog 1.4.0-rc).
- Admin panel: `/?admin`, login `MUA_ADMIN_USER` (**default `maild`**). The password is the OTP
  of the entrypoint banner (`docker compose logs mua`): generated on the first boot and kept in
  the data volume, or the one in `MUA_ADMIN_PASSWORD` when set. A password changed from the
  panel is respected (SnappyMail deletes `admin_password.txt` then) and no OTP is printed.
- Baseline plugins (**`MUA_PLUGINS`**, default `add-x-originating-ip-header,change-password,
  two-factor-auth`): their packages are downloaded at **build time** (pinned `ARG`s in
  `mua/Dockerfile` → `/opt/maild/plugins/`) and the entrypoint copies them over the volume on
  every boot, so a fresh deployment has them and an image bump refreshes them. The plugin
  *settings* live in `configs/plugin-*.json` (volume) and are never overwritten; the enabled
  list is the union of `MUA_PLUGINS` and whatever the panel enabled. Only the managed
  directories are replaced, so a plugin installed later from the panel survives. Bump the
  `ARG PLUGIN_*` versions together with `SNAPPY_VERSION` and re-check each package's `REQUIRED`
  const (the repository only keeps the newer builds:
  `https://snappymail.eu/repository/v2/packages.json`).
- `change-password` ships with **MailD's own driver** (`mua/plugins/change-password-maild/`), a
  sibling package of the plugin (its documented extension point, so a plugin update cannot
  overwrite it). It writes `mailbox.password` (+`modified`) in the catalogue exactly like
  PostfixAdmin does, md5crypt by default — the scheme PostfixAdmin (`POSTFIXADMIN_ENCRYPT`) and
  Dovecot (`default_password_scheme`) both verify — from the container's `POSTGRES_*`, with every
  value overridable in the panel. `config-setup.php` keeps `driver_maild_enabled` on. After a
  change, Dovecot's auth cache (`auth_cache_ttl` **1 minute**, negative caching off — MailD's
  settings in `mda/dovecot/conf.d/10-auth.conf`) may still answer with the old result for up to
  that minute: IMAP/SMTP logins with the *new* password are always accepted, and
  `doveadm auth cache flush` clears the doubt.
- Waits (bounded, `MUA_CONFIG_WAIT_TIMEOUT`) for SnappyMail to create `application.ini`, then
  waits (bounded) on the `maild_provision` sentinel before building the per-domain configs, so
  a fresh deploy gets them with no restart (`AUTO_PROVISION`).
- env: defaults baked in `mua/Dockerfile` (`BANNER_TITLE`, `MUA_*`, `POSTGRES_EXTRA_DB`);
  the operator file is the `env_file:` and overrides any of them.

## cron — maintenance

- Runs `cron -f`; jobs in `cron/crontab` (UTC): traffic resume 01:10, maildir check
  02:13 monthly, Junk purge 03:00, Bayes learning 03:30, db backup 08:00 (scripts in
  `cron/scripts/`).
- `pg_dump`/`psql` come from the **distro** `postgresql-client-18` (`ARG PG_CLIENT_MAJOR=18`): on
  resolute it is ≥ the catalogue server, so the PGDG repository, keyring and `curl` the jammy image
  needed are gone. `backup_db.sh` still refuses to dump when the client is older than the server
  (it mails a CRITICAL with the `PG_CLIENT_MAJOR` remedy instead of keeping an empty archive).
- `pflogsumm` (1.1.14) lives in `/usr/bin` on resolute, so `resume.sh` resolves it from `PATH`;
  SpamAssassin 4.0.2 provides the `sa-learn` the Bayes job uses. The `cron/spamassassin/` file is a
  reference copy of Debian's `/etc/cron.daily/spamassassin` that the image never installs (the
  rules refresh runs in `amavis`).
- Volumes: `ldata/logs:/var/log` (empty in dev — JSON logging), `ldata/vmail:/home/vmail`,
  `ldata/backups:/backups` (prod parity: without it `backup_db.sh` dumps into the
  container's writable layer and the dump vanishes on recreate). It does **not** mount the shared
  SpamAssassin volume: its `sa-learn` runs with `HOME=/tmp`, so the "shared bayes db" contract only
  holds for amavis (known drift, see `.local/caveats.md`).
- HEALTHCHECK: `/var/run/crond.pid` + `kill -0` (added with the resolute move).
- env: defaults baked in `cron/Dockerfile` (`JUNK_RETENTION_DAYS`, `SA_HAM_SAMPLE_*`,
  `MTA`); the operator file is the `env_file:` and overrides any of them. The entrypoint
  dumps the whole environment into `/etc/environment`, from where every cron job sources it.

## dozzle — log viewer (dev only)

- `amir20/dozzle:latest` on 8082; live logs of all `maild-dev-*` containers via the
  read-only docker socket. Not part of production.
