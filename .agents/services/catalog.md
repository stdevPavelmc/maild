# Service Catalog

All services live on the compose network `maild-dev` (dev) / `maild` (production, external).
Service keys are the DNS aliases used everywhere in the config: `db`, `mta`, `mda`,
`amavis`, `clamav`, `api`, `adminng`, `mua`, `cron` — never rename them.

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
  databases from `POSTGRES_DB` + `POSTGRES_EXTRA_DB` (comma-separated, e.g. `contacts`) plus
  `ADMINNG_DB` (AdminNG's own database, default `adminng`) on *every* boot. It never alters
  existing databases or the schema. `ADMINNG_DB` is a separate variable on purpose:
  `mua/config-setup.php` reads `POSTGRES_EXTRA_DB` as a single database name for the
  SnappyMail contacts DSN, so the two lists must not be merged.
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
- Archive scanning: the image carries the decompressors amavisd's `@decoders` table
  shells out to — `bzip2` (bz2), `xz-utils` (xz/lzma), `lrzip` (lrz), `lzop` (lzo), `lz4`
  (its `lz4c` symlink) and `rpm2cpio` (rpm) — plus `7zip`, `unrar-free` and `cabextract`, so
  those attachment types are extracted and scanned instead of being flagged **UNCHECKED**.
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
- **Socket permissions for the mail user**: `service lmtp { user = vmail }` (`10-master.conf`) runs
  the whole LMTP service as uid/gid 5000, while Dovecot 2.4 creates the anvil listener root-only
  (`/run/dovecot/anvil` = `0600 root:root`; upstream `beca41cc`, which relaxes it to `0660` +
  `default_internal_group`, landed *after* 2.4.2 — the version `ubuntu:resolute` ships).
  `90-stats-perms.conf` (stats-reader/stats-writer) and `90-anvil-perms.conf` (anvil) hand those
  listeners to `vmail` (`0660`) so the mail processes can reach them. Without the anvil one, LMTP
  logged `net_connect_unix(/run/dovecot/anvil) failed: Permission denied` +
  `lmtp_user_concurrency_limit lookup failed - skipping` for every recipient (mail was still
  delivered; only the per-user concurrency lookup was skipped).
- Instant Bayes learning: moving mail into/out of `Junk` triggers imapsieve pipe scripts
  (a `sieve_script` on `mailbox Junk` + `imapsieve_from Junk` in `mda/dovecot/conf.d/90-imapsieve.conf`
  → `mda/sieve-pipe/learn-{spam,ham}.sh`). The scripts live in `/etc/dovecot/sieve` (root-owned, and
  read-only for `vmail` on purpose: they are the global filters) while their compiled binaries are
  cached in `/var/lib/dovecot/sieve/imapsieve` — `bin_path` in that same file, a `root:vmail 0770`
  dir created by the Dockerfile. Pigeonhole would otherwise try to save `<script>.svbin` next to the
  source, fail as `vmail` and recompile the script on every load, logging
  `Error: sieve: binary /etc/dovecot/sieve/learn-spam.svbin: save: failed to create temporary file`.

- `mda/scripts/quota_report.sh` mails the daily mailbox-quota report to
  `MAIL_ADMIN_USER@DEFAULT_DOMAIN`; knobs in `env.sample` (`QUOTA_REPORT_*`); run manually:
  `docker compose exec mda /scripts/quota_report.sh --now [--dry-run]`.
- `mda/configure.sh` (startup helper, invoked by the entrypoint) and `mda/sendmail.py`
  are part of the image.
- **rehash-on-login** (2026-10 audit F-18): `mda/scripts/rehash-password.sh` is wired as an
  `imap-postlogin`/`pop3-postlogin` service in `mda/dovecot/conf.d/10-master.conf` (`script-login`,
  runs as `vmail`) and migrates a legacy `$1$` row to Argon2id on a successful IMAP/POP3 login
  (guarded `UPDATE … WHERE password LIKE '$1$%'`; skipped under `PASSWORD_SCHEME=md5crypt`). It
  reads `PLAIN_PASS` from the userdb `plain_pass = %{password}` field (`auth-sql.conf.ext`) and
  the catalogue credentials from `/etc/dovecot/rehash-creds.sh` (0640 root:vmail), which is why the
  image installs `postgresql-client`. The script sets its own `PATH` (script-login runs it with a
  minimal environment) and logs to stderr at *Error* level only. The entrypoint also date-gates
  `auth_allow_weak_schemes` (yes before 2027-02-01, no from it) and warns with the remaining
  legacy count on every boot.
- **Auth cache** (`mda/dovecot/conf.d/10-auth.conf`): MailD runs it short on purpose —
  `auth_cache_size = 10M` with `auth_cache_ttl = 1 minute` and `auth_cache_negative_ttl = 0`.
  A cached *success* keeps authenticating without asking the catalogue, so a longer TTL made a
  superseded password (a password changed in PostfixAdmin, which never re-authenticates) look
  alive for ten minutes; negative caching for an hour could lock a user out of a password he had
  mistyped before adopting it. See `.agents/devops/workflows.md` for the symptom and
  `doveadm auth cache flush`.
- env: defaults baked in `mda/Dockerfile` (`PASSWORD_SCHEME`, `DEFAULT_MAILBOX_SIZE`,
  `QUOTA_REPORT_*`, the self-signed cert subject); the operator file is the `env_file:` and
  overrides any of them;
  password + `DEFAULT_DOMAIN`/`MAIL_ADMIN_USER` passed explicitly at compose level.
- Ports: 110, 143, 993, 995 (POP3/IMAP + TLS) and 4190 (ManageSieve), 12345 (SASL).

## mta — Postfix

- SMTP 25, submission 587 (auth), SMTPS 465. SPF (`SPF_ENABLE`) and DNSBL (`DNSBL_ENABLE`,
  `DNSBL_LIST`) checks; `RELAY` / `ALWAYS_BCC` optional; max size `MAX_MESSAGESIZE`.
- Anti-enumeration (audit F-07): `smtpd_recipient_restrictions` sleeps `SMTP_TARPIT_DELAY`
  seconds (image default 2; `0` makes the entrypoint strip the line) before the
  unknown-recipient `550`, and the list was reordered — `permit_sasl_authenticated` +
  `reject_unauth_destination` come first, so relay attempts and authenticated clients skip
  the map/policy lookups *and* the tarpit; only external mail addressed to the hosted
  domains pays the delay. Submission/smtps and the amavis reinjection override
  `smtpd_recipient_restrictions` in `master.cf`, so only the public MX port is affected.
  The 250/550 oracle itself is kept by design (reject-at-RCPT is Postfix best practice;
  accept-then-bounce would create backscatter). Error limits: `smtpd_soft_error_limit=10`
  / `smtpd_hard_error_limit=60` (progressive 1s slowdown, then cut-off) — they used to be
  inverted at 60/10, where the slowdown never engaged.
- Per-user outbound throttle (audit F-12): the entrypoint starts **`ratelimitd`**
  (`mta/ratelimitd/ratelimitd.py`, stdlib python3 already in the image), a Postfix SMTP
  policy daemon on loopback `127.0.0.1:12341`, supervised like the peer watchdog and
  probed by the healthcheck. `submission`/`smtps` consult it via
  `-o smtpd_recipient_restrictions=check_policy_service inet:127.0.0.1:12341`; it counts
  envelope recipients per `sasl_username` over `OUTBOUND_RATE_WINDOW` and defers (`450`)
  past `OUTBOUND_RATE_RECIPIENTS` (default 200/window; `0` strips the override lines,
  restores the empty pre-F-12 override and skips the daemon). Accounts in
  `OUTBOUND_RATE_EXEMPT_USERS` (exact addresses) bypass it from any IP — the hard
  exemption for notification senders. Fail-open by contract:
  `smtpd_policy_service_default_action=DUNNO` + a 5s policy timeout, so a dead daemon
  stops no mail; counters are in-memory (an mta restart resets them, like anvil) and
  every engagement is logged as a greppable `maild-ratelimit: throttled user=…` line for
  the cron alert job. Port 25 and the amavis reinjection are untouched by design.
- Postfix's PostgreSQL maps include the PostfixAdmin alias-domain maps:
  `virtual_alias_domains.cf` recognizes active alias domains, and
  `virtual_alias_domain_maps.cf` preserves the local part while rewriting to the target.
  `virtual_alias_domain_catchall.cf` handles the `@alias-domain` form. Alias domains are
  excluded from `virtual_mailbox_domains` while active so Postfix treats them as virtual
  aliases, not independent mailbox domains. The SQL lookups are live; adding or deactivating
  an alias-domain row does not require an MTA restart.
- Postfix **3.10** (resolute): `compatibility_level = 3.9` (the value the distro ships) and the TLS
  block follows the new parameter set — the two settings Postfix 3.9 obsoleted
  (`smtpd_tls_dh1024_param_file`, `smtpd_tls_eecdh_grade`) are gone and ECDHE auto-curves do the
  work, so the mta no longer reads `/certs/RSA2048.pem` (the mda owns it). 3.9/3.10 also add
  `smtpd_forbid_unauth_pipelining`/`smtpd_forbid_bare_newline` hardening by default.
- The image ships neither `netcat` nor `net-tools`: the healthcheck reads the master pidfile and
  the container's own address (for the 10025 reinjection listener) comes from
  `getent hosts "$(hostname)"`. `postfix-policyd-spf-python` 3.1.0 keeps `/usr/bin/policyd-spf`.
- Hard-depends on mda, amavis, clamav. Delivers local mail over LMTP to the mda's IP
  (rendered into `main.cf`/`master.cf` at start), repatched by the **peer-IP watchdog**
  (`PEER_WATCH_INTERVAL`, default 30s, `0` disables it) when `amavis`/`mda`/`mua` come back with
  a new address; the mta reloads Postfix itself after the repatch.
- Logs to stdout (`maillog_file = /dev/stdout`); the daily traffic resume parses a syslog
  with rsyslog-style stamps, which only exists in production (dev: `test.sh` phase G
  materialises one).
- Waits (bounded) on the `maild_provision` sentinel before building the `virtual_aliases`, so
  a fresh deploy comes up with them in place and no restart (`AUTO_PROVISION`).
- env: defaults baked in `mta/Dockerfile` (`MAX_MESSAGESIZE`, `SPF_ENABLE`, `DNSBL_*`,
  peer hostnames/timeouts); the operator file is the `env_file:` and overrides any of them;
  `MAILADMIN`, `DEBUG` and the password passed explicitly.

## admin — PostfixAdmin (retired)

The `admin` service, its image (`maild-admin`) and the `mailadmin.${DEFAULT_DOMAIN}`
ingress route are **gone**. Its two provisioning duties moved:

- the catalogue schema (PostfixAdmin's own DDL, created by `public/upgrade.php`) is now
  `db/migrations/002_postfixadmin_catalogue.sql`, applied by the `db` container;
- the first-boot seeder (`admin/seed.sh`) is now `adminng/api/app/provision.py`, run by
  the `api` container.

The `POSTFIXADMIN_*` variables, the OTP setup password and `/setup.php` do not exist any
more. See `.agents/services/provisioning.md`.

## api — AdminNG backend

- FastAPI (Uvicorn) on `python:3.14-slim-trixie`, built from `adminng/api/`; service
  hostname `api`, **no published port** — only the `adminng` frontend talks to it, over the
  compose network (`/api/v1/` proxy).
- Two databases on `db`: the PostfixAdmin catalogue `POSTGRES_DB` (read/write, **zero
  DDL** — the schema belongs to `db/migrations/002_postfixadmin_catalogue.sql`; it writes
  rows exactly like PostfixAdmin: `maildir = domain/local/`, quota in bytes, Argon2id
  passwords with md5crypt accepted as legacy) and its own `ADMINNG_DB` (devices, sessions,
  TOTP credentials, device-scoped WebAuthn credentials/challenges, audit trail), whose
  schema it migrates at boot from `adminng/api/migrations/`.
- **First-boot provisioning leader** (`app/provision.py`, run before uvicorn): seeds
  `DEFAULT_DOMAIN`, the superadmin (`admin` row) plus its mailbox, the four default aliases
  and the `maild_provision` sentinel; one transaction under the advisory lock, idempotent,
  fast path on every later boot. `AUTO_PROVISION=no` disables it, and
  `docker compose exec api adminng.py --provision [--force]` is the manual path. See
  `.agents/services/provisioning.md`.
- Mounts the vmail volume **read-only**: quota usage comes from the Maildir++ `.maildirsize`
  files (never a Dovecot secret, never a write). Because maildirs are `0700 vmail:vmail`,
  the process runs as **uid/gid 5000** (the vmail owner): read-only mount + matching uid =
  sizes readable, mail never writable.
- Phase 1 serves the catalogue API under `/api/v1/` (domains, mailboxes, aliases, admins,
  `search`, `mailboxes/{u}/quota`) behind **plain bearer auth**: `POST /auth/login` verifies
  the catalogue `admin` row (md5crypt) and mints an opaque token whose SHA-256 is the
  `session.jti` row; the idle purge (`ADMINNG_REFRESH_IDLE_TTL`) and the account's `active`
  flag are enforced on every request. Phase 2 replaces issuance with device-bound
  `login-step1/2` + TOTP.
- Catalogue writes are PostfixAdmin-compatible (Argon2id by default; admin.password mirrors
  the mailbox password), delete/suspend revokes the account's sessions, and domain counters
  stay in step. Creating a domain also writes the four default aliases
  (postmaster/abuse/hostmaster/webmaster → the creating admin), like the old
  "create domain" click. Dovecot's auth cache can hold a superseded result for up to a
  minute after a suspend or password change (`doveadm auth cache flush` in the mda clears
  it).
- Phase 2 adds the zero-trust device gate (`/device/status?username=`, `/admin/devices`),
  two-step login (`/auth/login-step1|step2`), TOTP enrollment
  (`/auth/totp-enroll|confirm`, RFC 6238, secrets encrypted with
  `ADMINNG_SECRET_KEY`), refresh rotation, the 30-second re-auth token required by
  every destructive route (`POST /auth/reauth-confirm`) and the audit trail
  (`GET /logs`). Lockout: 5 failures per username+IP → 429 for 15 minutes.
- The device gate (audit F-11) requires `X-Device-ID` **and** `X-Device-Secret` on every
  request; the secret is client-minted and stored only as `sha256(secret)`. There is **no
  anonymous handshake**: a browser registers inside a `login-step1` whose password verified,
  and approval is **device-scoped** (`device.state`) starting `PENDING` — only a superadmin
  (panel/CLI) approves it, after which any admin may sign in from that browser. The
  `device_grant` row is a per-admin activity log that also carries the 24-hour trust window
  (below). `GET /device/status` needs the matching secret (anything else is `404
  DEVICE_UNKNOWN`). Stale `PENDING` browsers are purged after `ADMINNG_PENDING_TTL_DAYS`
  (default 3, 0 disables) at boot and hourly.
- "Remember this device for 24 hours": a successful TOTP (or biometric) login arms a fixed
  `ADMINNG_REMEMBER_TTL` window on the `(device, admin)` pair, so subsequent logins answer
  `AUTHENTICATED` and skip the code until it lapses; it is not extended by password-only
  logins.
- Phase 6.1 adds `/auth/webauthn/*`: password-proven platform-credential enrollment/removal,
  device-scoped biometric login (including superadmin TOTP bypass after user verification),
  and biometric destructive-action re-auth that mints the existing short-lived validation
  token. Challenges are single-use and expire after `ADMINNG_WEBAUTHN_CHALLENGE_TTL`; the
  exact `ADMINNG_WEBAUTHN_ORIGINS` allowlist and `ADMINNG_WEBAUTHN_RP_ID` must match the
  browser. Device revocation deletes its credentials. Password + TOTP remains the fallback.
- `ADMINNG_SECRET_KEY` is **mandatory** (compose `${ADMINNG_SECRET_KEY:?}` guard):
  it signs the JWTs and encrypts the TOTP seeds; rotating it invalidates sessions
  and enrolled seeds (admins re-enroll).
- Ships the `adminng.py` CLI (`--list-devices`, `--approve-device <id>`,
  `--revoke-device`, `--revoke-grant <id> --user <admin>`, `--purge-pending`, `--totp-reset`)
  — the server-side device-authorization path (`adminng/README.md`).
- HEALTHCHECK: `GET /health`, 200 only when the adminng database answers.
- env: defaults baked in `adminng/api/Dockerfile` (`POSTGRES_*`, `ADMINNG_DB`,
  `ADMINNG_*` TTLs/toggles and localhost-only WebAuthn development origins); production
  operators must override the WebAuthn RP ID/origin allowlist for their public HTTPS host.
  The operator file is the `env_file:` and overrides image defaults; `POSTGRES_PASSWORD` is
  passed explicitly with the compose `${POSTGRES_PASSWORD:?}` guard.

## adminng — AdminNG frontend (PWA)

- nginx serving the built Vite/React PWA plus a `/api/v1/` reverse proxy to `api:8080`.
  Dev publishes **8083:80** (plain HTTP: browser harness, desktop LAN, CA download) and
  **8084:443** (HTTPS for LAN devices/APK, local CA from `ldata/certs`); production publishes
  **no port** and is routed by the ingress (`adminng.${DEFAULT_DOMAIN}`, Traefik labels; TLS
  terminated by the operator's proxy). The 443 vhost is **inactive in the image** (kept in
  `/etc/nginx/tls-available/`) and only `docker-compose-dev.yml` mounts it into `conf.d`.
- Serves the local CA at `http://<lan-ip>:8083/ca.der` (public certificate only, never the key)
  so a phone can import it before trusting 8084. Generated by
  `adminng/pwa/tls-cert-generate.sh` (`bootstrap-dev.sh` runs it); `mail.crt` is untouched. The
  leaf SAN lists the host name, `localhost` and every global IPv4 (multi-NIC hosts have several),
  so any local address works as the APK origin; a stale leaf is re-issued with
  `RENEW=1 ./tls-cert-generate.sh --ip <addr>` (CA unchanged) plus a listener restart.
- Stateless and env-free: **no `env_file:`** (variable separation, like clamav). Its access
  log (stdout) is the exterior interaction record; the functional audit trail lives in the
  `adminng` DB's `audit_event` table.
- Built multi-stage from `adminng/pwa/` (`node:26-alpine` build → `nginx:1.27-alpine`).
- Clients (browser/PWA/APK) can only log in until their device is approved; the Android
  APK (Phase 4) is the only client that needs the server-URL onboarding screen.

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
  overwrite it). It writes `mailbox.password` (+`modified`) in the catalogue in exactly the
  same row format the AdminNG API uses, following `PASSWORD_SCHEME` (Argon2id
  `{ARGON2ID}$…` by default; md5crypt `$1$…` is the legacy escape hatch, both verified by
  Dovecot's passdb) — from the container's `POSTGRES_*`, with every
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
  02:13 monthly, Junk purge 03:00, Bayes learning 03:30, outbound volume watch
  hourly (:23), db backup 08:00 (scripts in `cron/scripts/`).
- `outbound_watch.sh` (audit F-12, alerting half): parses the production syslog for the
  day's per-user submission volume (`sasl_username=` on queue-id `from=` lines) and the
  mta's `maild-ratelimit: throttled` lines, and mails an `[ALERT]` to the admin via
  `swaks` → amavis:10024 when a user crosses `OUTBOUND_ALERT_MESSAGES` (default
  150/day, `0` = off) or tripped the throttle. `OUTBOUND_ALERT_IGNORE_USERS` is the
  alert-side twin of the mta's `OUTBOUND_RATE_EXEMPT_USERS`; one alert per user per day
  (marker in `/tmp`), a failed delivery is retried next run. Skips cleanly when no
  syslog exists (dev); a dead `ratelimitd` is the mta healthcheck's job, not this one.
  The day marker matches the *date* (`Oct 19`) at the start of a line or after a
  separator — not a fixed `" Oct 19 "`: rsyslog stamps the line at column 0 while
  Postfix adds a second stamp inside the message, so a leading-space match would
  skip the bare `maild-ratelimit:` lines and never report a throttle engagement.
- `pg_dump`/`psql` come from the **distro** `postgresql-client-18` (`ARG PG_CLIENT_MAJOR=18`): on
  resolute it is ≥ the catalogue server, so the PGDG repository, keyring and `curl` the jammy image
  needed are gone. `backup_db.sh` still refuses to dump when the client is older than the server
  (it mails a CRITICAL with the `PG_CLIENT_MAJOR` remedy instead of keeping an empty archive).
- `backup_db.sh` writes **two** archives per run: `maild_backup_*.sql.gz` (the catalogue) and
  `maild_adminng_*.sql.gz` (AdminNG: device approvals, sessions, TOTP seeds, audit trail —
  `ADMINNG_DB`, defaulted in the script). Both get the same size/gzip/trailer validation and the
  same 15-day retention; a failed AdminNG dump keeps the catalogue archive but marks the run FAILED.
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

## pwa-test — browser harness (dev only)

- `adminng/pwa-test/` builds `maild-pwa-test:develop` from
  `mcr.microsoft.com/playwright:v1.64.1-noble` (pinned to the `@playwright/test` version in
  the lockfile) plus the static Docker CLI. One-shot: `docker compose run --rm pwa-test`
  through `adminng/pwa-test/run.sh`; `profiles: ["test"]`, so `up` never starts it.
- No published port. It joins `maild-dev`, waits for the `api`/`adminng` healthchecks, and
  the entrypoint tunnels `http://localhost:8083` to `http://adminng:80` — `localhost` is a
  secure context, so service-worker/installability checks are real.
- Mounts `./test.creds` read-only (`MAILD_ROOT=/repo`), `./ldata/e2e` as `/artifacts`, and
  the docker socket: the suite authorizes its own browser with the documented
  `adminng.py --approve-device <id>` inside the `api` container. Absent from all
  production compose files; the operator's stack never sees it.
- `run.sh` maps the invoking uid/gid so the artifacts stay host-owned.
