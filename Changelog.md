# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

<!--
This is a note for developers about the recommended tags to keep track of the changes:

- Added: for new features.
- Changed: for changes in existing functionality.
- Deprecated: for soon-to-be removed features.
- Removed: for now removed features.
- Fixed: for any bug fixes.
- Security: in case of vulnerabilities.

Dates must be YEAR-MONTH-DAY then version number in semver format.
-->

## 2026-10-16 1.6.0-dev
- Added: **AdminNG Phase 0 scaffolding** — the next-generation PWA admin interface
  (`adminng/`): a FastAPI backend (`adminng/api/`, service `api`, internal only, no published
  port) and the PWA frontend served by nginx (`adminng/pwa/`, service `adminng`, dev port
  **8083**, production `adminng.${DEFAULT_DOMAIN}` via the ingress). Both are wired into the
  four compose files, the GitHub/GitLab pipelines and `bootstrap-dev.sh`; the frontend proxies
  `/api/v1/` to the API (same-origin, no CORS) and keeps the exterior access log. The design
  and roadmap live in `adminng/doc/` (`technical-draft.md`, `plan.md`).
- Added: `ADMINNG_DB` (default `adminng`) — the database `db/ensure_databases.sh` creates on
  every boot for AdminNG's own state (devices, sessions, TOTP credentials, audit trail). It is
  a variable of its own, **not** an entry of `POSTGRES_EXTRA_DB`: `mua/config-setup.php` reads
  that one as a single database name for the SnappyMail contacts DSN.
- Changed: `db/ensure_databases.sh` now also ensures `POSTGRES_DB` unconditionally and skips
  duplicate entries in its list (previously it exited early when `POSTGRES_EXTRA_DB` was
  empty).
- Added: **AdminNG Phase 2 — device trust, TOTP, re-auth and audit** (`adminng/api/`):
  `X-Device-ID` is mandatory everywhere (handshake → PENDING → APPROVED/REVOKED, with
  revocation destroying the device's sessions); two-step login (`login-step1`/`login-step2`
  with a device-bound access JWT and an opaque refresh token whose SHA-256 is stored);
  TOTP enrollment and verification (RFC 6238, ±1 step, replay-protected, seeds encrypted at
  rest); `/auth/refresh` rotates the jti and rejects reuse; `POST /auth/reauth-confirm`
  mints the 30-second `X-Security-Validation-Token` that every destructive route now
  requires (`403 OPERATION_NOT_VERIFIED` otherwise); `GET /logs` exposes the audit trail
  with tenant scoping; 5 failed logins per username+IP lock that key out for 15 minutes.
  New CLI verbs `--add-device` / `--approve-device` / `--revoke-device` / `--totp-reset`;
  `bootstrap-dev.sh` pre-approves a well-known dev device (written as `adminng.device=` in
  `test.creds`).
- Changed: **`ADMINNG_SECRET_KEY` is now mandatory** (the four compose files carry a
  `${ADMINNG_SECRET_KEY:?}` guard): it signs the AdminNG JWTs and encrypts the TOTP seeds.
  Generate one with `openssl rand -hex 32`; rotating it invalidates live sessions and
  enrolled TOTP seeds (admins re-enroll). Migration `003_phase2.sql` retires the Phase-1
  sessions (they were not device-bound).
- Changed: `cron/scripts/backup_db.sh` now writes **two** archives per run —
  `maild_backup_*.sql.gz` (the catalogue) and `maild_adminng_*.sql.gz` (device approvals,
  sessions, TOTP seeds, audit trail) — with the same validation and 15-day retention, and
  reports both in the notification mail.
- Added: **AdminNG Phase 1 — catalogue API** (`adminng/api/`): domain/mailbox/alias/admin
  CRUD with cursor pagination, rapid `GET /search`, quota usage from the Maildir++
  `.maildirsize` accounting (read-only vmail mount, `du` fallback, cache) and multi-tenant
  scoping by `domain_admins`. Writes are PostfixAdmin-compatible (md5crypt, `maildir =
  domain/local/`, quota bytes, explicit cascade deletes, admin password mirroring, domain
  counters). Auth is plain bearer for now: `POST /auth/login` mints an opaque token whose
  SHA-256 is the `session.jti` row; suspend/delete revoke the account's sessions.
  Domain creation returns a `RESTART_REQUIRED` advisory (amavis/mua/mta cache the domain
  list at boot). New `test.sh` section I covers login, CRUD, IMAPS login of the created
  mailbox, suspension/reactivation, tenant negatives and the delete cascade; the
  `adminng/api/tests/test_catalogue.py` self-test (run inside the api container) asserts the
  write-compatibility rules. The api process now runs as uid/gid 5000 (the vmail owner) with
  the volume mounted read-only, because maildirs are `0700`.

## 2026-10-17 1.5.1-rc
- Changed: **the `mua` (webmail) base image moved from `php:8.3-apache` to `php:8.5-apache`**
  (both Debian trixie, so the package list is unchanged). PHP 8.3 left *active* support on
  2025-12-31 and only receives critical security fixes until 2027-12-31; 8.5 is actively supported
  until 2027-12-31 and patched until 2029-12-31. No schema, env, volume or config change: an
  existing deployment only needs `docker compose pull` + `up -d` (the webmail app itself, and
  therefore its `data/` volume, is unchanged).
- Fixed: **the webmail was broken on PHP 8.4+ — repaired with configuration only** (no forking of
  SnappyMail): `display_errors = Off` and
  `error_reporting = E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED` in `mua/snappymail.ini`. SnappyMail
  2.38.2 predates PHP 8.4 and raises `E_DEPRECATED` from its own code (`MailSo\Log\Logger` maps
  `E_STRICT`, deprecated in 8.4 — `Logger.php:153/171`; its HTTP client also calls the newly
  deprecated `curl_close()`). Because the official PHP image activates no `php.ini`, PHP's compiled
  default `display_errors = On` applied: the notice was **printed into the response**, which made
  every later `header()` fail (`Cannot modify header information`: no CSP, no X-Frame-Options) and
  prefixed the JSON API with HTML, so `POST /?/Json/` returned invalid JSON and the webmail died in
  the browser. `log_errors`/`error_log = /dev/stderr` are untouched — warnings, notices and fatals
  still reach `docker compose logs mua`.
- Removed: the dead `mua` build dependencies `libfreetype6-dev`, `libjpeg62-turbo-dev` and
  `libmcrypt-dev`. The image builds only `pdo`/`pdo_pgsql` (`libpq-dev` stays); no PHP extension and
  no Apache module links freetype/jpeg/mcrypt, and `php -m`/`php -i`/behaviour are identical
  without them: −11 MB on the image.
- Note: SnappyMail itself is unchanged (2.38.2 is still the newest upstream release, so this
  release improves the *runtime's* support window, not the app's); the `admin` image is still on
  `php:8.1-apache-bookworm` (PHP 8.1 is EOL) and needs its own change, because PHP 8.4 unbundled the
  `imap` extension that PostfixAdmin uses — tracked in `.agents/devops/base-images.md`.

## 2026-10-16 1.5.0-rc
- Changed: **new env distribution schema — one env file per deployment.** Every tunable now
  defaults INSIDE each service image (an `ENV` block per Dockerfile, only the variables that
  service's own entrypoint/scripts consume); a same-named variable in the operator env file
  always wins over the image default (runtime env beats image `ENV`). Deploying needs a
  single small env file: the mandatory `DEFAULT_DOMAIN`, `MAIL_ADMIN_USER`,
  `POSTGRES_PASSWORD` (+ the optional secrets and any deviation from a default) —
  `cp env.sample .env`, edit, `docker compose up -d`; or let the CI craft `.env` from its own
  variables (`.gitlab-ci.yml` now builds it from `env.sample_gitlab` + the CI/CD variables:
  the mandatory ones must be defined as masked CI/CD settings).
- Removed: the `vars/` directory and its 8 per-service env files. The tunables and the
  hardcoded inter-service hostnames (`AMAVIS=amavis`, `MTA=mta`, `CLAMAV=clamav`, …) are
  image `ENV` now, the `${VAR:-default}` forwarding hacks are gone, and two dead variables
  were dropped with them (`CTDB` — unused, the mua reads `POSTGRES_EXTRA_DB`; and
  `AMAVIS_MTA` — unused, the amavis entrypoint reads `MTA`). `env.sample` became the
  minimal operator template; the full default catalogue (the per-service variable matrix)
  lives in `.agents/services/configuration.md`.
- Changed: **strict variable separation** — the env file is `env_file:`-loaded ONLY into
  the 7 DB-consumer services (db, admin, mua, mda, mta, amavis, cron); clamav gets no
  `env_file` on purpose (it needs no catalogue access): its two knobs (`ALTERNATE_MIRROR`,
  `CLAMAV_DEBUG`) are explicit `environment:` entries. `POSTGRES_PASSWORD` and
  `DEFAULT_DOMAIN` are passed explicitly with `:?` fail-fast guards, so a missing mandatory
  value fails at `docker compose config` instead of at runtime.
- Changed: `docker-compose-dev.yml` uses `env.dev` for BOTH the compose interpolation and
  the containers' `env_file:` — the "keep `DEFAULT_DOMAIN`/`MAIL_ADMIN_USER` in sync between
  env.dev and env.sample" constraint is gone, there is only one file per context now;
  production (`docker-compose.yml` and the `compose-github.yml`/`compose-gitlab.yml` strict
  copies) uses `.env` the same way. The redundant `DEFAULT_MAILBOX_SIZE` and
  `POSTFIXADMIN_SETUP_PASSWORD` pass-throughs are gone (the admin entrypoint always emits
  its own OTP; the variable was always ignored).
- Changed: the empty-value trap is now explicit: never leave a variable EMPTY in the env
  file (`FOO=` overrides the image default with an empty string) — comment the line out
  instead. Documented in `env.sample` and `.agents/services/configuration.md`.
- Added: `test.sh` gains an env-schema check (an untouched image default, an env-file
  override that wins over the image default, and a baked peer hostname the env file never
  mentions), so the schema's core promise is asserted on every run.
- Changed: documentation updated in the same commits — `AGENTS.md`, `README.md`,
  `INSTALL.md`, `DEV-SETUP.md`, `db_upgrade.md` and the `.agents/` set
  (`configuration.md` carries the authoritative variable matrix; `catalog.md`,
  `provisioning.md`, `environment-setup.md`, `workflows.md`, `base-os-upgrade.md` moved to
  the new chain).

## 2026-10-15 1.4.0-rc
- Changed: **`amavis` base moved `ubuntu:jammy` → `ubuntu:resolute`** (26.04 LTS), the second
  service of the LTS rollover (**2/5** — `mta`, `mda`, `cron` still on jammy). The templates are
  the resolute `amavisd-new` 2.13.0 / `spamassassin` 4.0.2 files with MailD's long-standing edits
  re-applied verbatim — those edits are *not* distro defaults: the pristine `conf.d` trees are
  byte-identical between jammy and resolute **except `21-ubuntu_defaults`**, so everything the
  port had to keep (`$inet_socket_bind = ''`, `hostname -d`, the full `$banned_filename_re`, the
  ClamAV-only `@av_scanners`, the commented `$unix_socketname`, the `_MTA_`/`_MTAIP_`/
  `_CRONIP_`/`_CLAMAVIP_` placeholders and the `50-user` policy bank) came from MailD's own
  files, not from the distro. Four resolute package changes: `netcat` → `netcat-openbsd` (the
  former is now an unresolvable virtual package), `p7zip-full` → `7zip` (Provides p7zip-full,
  same `/usr/bin/7z`) and — the one that matters — the daemon is now **`/usr/sbin/amavisd`**:
  `amavisd-new` 2.13 dropped the `/usr/sbin/amavisd-new` name, so the entrypoint's `genrsa`,
  `showkeys`, `test-config` and foreground calls were updated. resolute also allocates the
  `amavis` uid/gid differently (`994:994` where jammy used `101:101`): the new ids win, so
  there is **no pin in the image** and the dev testbed was moved to match (`bootstrap-dev.sh`
  owns `ldata/amavis` as `994:994`). An existing deployment keeps its `amavis` volume owned by
  the old ids, so re-own it once — name-based, so it resolves to whatever the image runs as:
  `docker compose run --rm --no-deps --user root --entrypoint chown amavis -R amavis:amavis /var/lib/amavis`
  (dev: just re-run `./bootstrap-dev.sh`). Two `21-ubuntu_defaults` flips that would have changed
  how MailD handles mail are pinned back in `50-user` (which loads last): spam is still
  **delivered** so it reaches the user's Junk folder — resolute sets
  `$final_spam_destiny = D_DISCARD` — and the `postmaster` virus/spam notifications stay on
  (resolute sets `$virus_admin`/`$spam_admin = undef`). The third, `20-debian_defaults` no longer
  being the file that sets `$inet_socket_bind = ''`, is already covered because MailD's own copy
  of that file carries the line — without it amavisd falls back to its built-in loopback default
  (`Amavis/Conf.pm`) and the `mta → amavis:10024` hop breaks. SpamAssassin 4.0 brings the
  upstream rule/plugin updates (`v400`–`v402.pre`, `HashBL` on by default, welcomelist/blocklist
  naming); MailD's only edit there (the `TextCat` plugin) was re-applied. Recorded in
  `.agents/devops/base-os-upgrade.md`.
- Fixed: **content filtering would have failed on every message after the `amavis` base move.**
  The `clamav` container does not receive the message — it is handed *file paths*: clamd
  `CONTSCAN`s the files amavisd drops in its TEMPBASE, which both containers see through the
  **shared** `/var/lib/amavis` mount. Those temp dirs/files are `0750`/`0640` owned by `amavis`,
  and on jammy that worked only because the distro happened to hand uid **101** to *both*
  `amavis` (101:101) and `clamav` (101:102). resolute gives amavis `994:994` and keeps clamav at
  `100:101`, so clamd answered "File path check failure: Permission denied" and amavisd logged
  `AV: ALL VIRUS SCANNERS FAILED` for every message: mail was quarantined/dropped and spam
  scoring never ran (the EICAR and GTUBE acceptance checks are what caught it). The `clamav`
  image now puts its user in the amavis group (`ARG AMAVIS_GID=994` — supplementary-group
  membership lives in the image's own `/etc/group` and cannot follow another image's dynamic
  allocation), and its entrypoint asserts read access to `/var/lib/amavis/tmp` at start so a
  future id drift fails loudly instead of silently disabling the AV path.
- Changed: **`clamav` base moved `ubuntu:jammy` → `ubuntu:resolute`** (26.04 LTS), the first
  service of the LTS rollover (**1/5** — `mta`, `mda`, `amavis`, `cron` still on jammy). The
  templates are the resolute `clamav-daemon`/`clamav-freshclam` generated configs with MailD's
  container tweaks re-applied (`TCPSocket 3310`, `Foreground true`, `DisableCertCheck yes`,
  stdout logging, `LogRotate false`); the 1.5.x additions (`CVDCertsDirectory`,
  `FIPSCryptoHashLimits`, `Enable*Command`, `JsonStore*`) come along. Both images ship
  ClamAV 1.5.4, so there is no engine jump. Two resolute package changes: `libclamunrar9` →
  `libclamunrar12` (multiverse) and `netcat` → `netcat-openbsd` (the former virtual package no
  longer resolves). resolute also allocates the `clamav` uid/gid differently (`100:101` where
  jammy used `101:102`): the new ids win, so there is **no pin in the image** and the dev
  testbed was moved to match (`bootstrap-dev.sh` owns `ldata/clamav` as `100:101`). An existing
  deployment keeps its `clamav` volume owned by the old ids, so re-own it once — name-based, so
  it resolves to whatever the image runs as:
  `docker compose run --rm --no-deps --user root --entrypoint chown clamav -R clamav:clamav /var/lib/clamav`
  (dev: just re-run `./bootstrap-dev.sh`). Recorded in `.agents/devops/base-os-upgrade.md`.
- Fixed: **the mta ↔ amavis link could come up silently broken.** The mta resolved the
  amavis/mda/admin addresses exactly once, at its own start, with no retry and no validation —
  if a peer was not resolvable yet (it started later) the address was baked **empty**. An empty
  address in the `10025` amavis reinjection allow-list makes Postfix reject the content filter's
  return path (`554 5.7.1 … Client host rejected: Access denied`), so every filtered message
  deferred while the container merely reported `unhealthy` and nothing acted on it. The mta now
  waits (bounded, `PEER_WAIT_TIMEOUT`, default 120s) for amavis/mda and **refuses to start with
  an incomplete mail path**; a runtime watchdog (`PEER_WATCH_INTERVAL`, default 30s) re-resolves
  the peers and repatches + reloads Postfix when one is recreated with a new address;
  `bootstrap-dev.sh` counts an **empty** cached address as drift (it used to skip it) and also
  restarts an unhealthy mta, waiting for it to come back healthy; and `test.sh` asserts the
  mail-path containers are healthy up front instead of leaking ~8 unrelated delivery failures.
  Also fixed the `/tmp/OWNIP` typo in the mta entrypoint (always wrote an empty file).

- Changed: **`mda` base moved `ubuntu:jammy` → `ubuntu:resolute`** (26.04 LTS), the third
  service of the LTS rollover (**3/5** — `mta` and `cron` still on jammy). This one is not a
  package swap: the jump is **Dovecot 2.3.16 → 2.4.2** (plus SpamAssassin 3.4.6 → 4.0.2 and
  `netcat` → `netcat-openbsd`), and 2.4 does not read 2.3 configuration at all, so the whole
  `/etc/dovecot` tree had to be re-expressed in the new schema. Measured against the real package
  (throwaway `ubuntu:resolute` container and then the dev stack): `doveconf -n` clean and
  warning-free, the daemon starts with every MailD listener up (110/143/993/995/4190/12345/12340),
  TLS on 993/995, authentication against the live catalogue, and the full acceptance suite green.
  What changed in the configuration: `dovecot_config_version`/`dovecot_storage_version = 2.4.0` are
  now mandatory; every section needs a name (Postfix SASL became `inet_listener auth { port =
  12345 }`, the Postfix quota policy `inet_listener quota-status { port = 12340 }`, and the empty
  `plugin { }`/`dict { }` skeletons are gone — `plugin` no longer exists as a section);
  `mail_location` was replaced by `mail_driver = maildir` + `mail_path = ~/maildir`, and `%d`/`%n`
  by the `%{user | domain}`/`%{user | username}` filters; `ssl_cert`/`ssl_key`/`ssl_dh` became
  `ssl_server_cert_file`/`ssl_server_key_file`/`ssl_server_dh_file` (plain paths — the `<` prefix
  would read the file *content* into the setting) and `ssl_prefer_server_ciphers = yes` became
  `ssl_server_prefer_ciphers = server`; `disable_plaintext_auth = no` has **no** 2.4 successor
  because 2.4 rejects `auth_allow_cleartext = yes` next to `ssl = required` — which was already
  the effective 2.3 behaviour (TLS is mandatory before any login); the legacy `$var` references no
  longer expand (`$mail_plugins` and `$default_internal_user` are written out explicitly, the
  latter as `$SET:default_internal_user`, a bare reference refusing to start); the SQL moved from
  the dropped `dovecot-sql.conf.ext` include into inline `sql_driver`/`pgsql { parameters }` +
  `passdb sql`/`userdb sql` blocks; the sieve locations became `sieve_script` storages
  (`personal`, `default`) and the instant-learning imapsieve settings became a `sieve_script`
  attached to `mailbox Junk` plus an `imapsieve_from Junk` section (with `sieve_plugins =
  sieve_imapsieve sieve_extprograms` and the extension blocks, since the 2.3 `= +vnd.dovecot.pipe`
  spelling is ignored); the quota is a named root now (`quota "User quota" { driver = maildir
  storage_grace = 20M warning warn95/warn80 { execute quota-warning { args } } }`); `sieve_user_log`
  and `sieve_global_path` were dropped (removed in 2.4 / never existing in the image) and
  `20-lmtpd.conf` follows the upstream rename to `20-lmtp.conf`. Recorded in
  `.agents/devops/base-os-upgrade.md`.
- Changed: **MD5-CRYPT is disabled by default in Dovecot 2.4**, while PostfixAdmin — and therefore
  `admin/seed.sh` and the dev fixtures — hashes mailboxes with md5crypt (`$1$…`). The mda sets
  `auth_allow_weak_schemes = yes`, without which **every existing mailbox stops authenticating**
  (those hashes cannot be regenerated without the clear-text password). Dovecot logs "Weak password
  schemes are allowed" at start-up as the standing reminder; migrating the catalogue to
  SHA512-CRYPT is a separate, product-wide decision.
- Changed: **the `mda` Dovecot configuration tree was rewritten for 2.4** (`mda/dovecot/**`). The
  2.3 files are archived under `mda/dovecot-jammy/` (read-only, kept in-tree until the whole
  rollover ends) and were replaced by the `ubuntu:resolute` package templates plus the MailD
  customizations re-expressed in the new schema, so `git diff mda/dovecot-jammy mda/dovecot` shows
  every deliberate change for review. Layout-wise: the SQL moved from the separate
  `dovecot-sql.conf.ext` into `conf.d/auth-sql.conf.ext`, the instant-learning trigger moved into
  `conf.d/90-imapsieve.conf` (as a `mailbox Junk` / `imapsieve_from Junk` pair), the quota root and
  its warnings into `conf.d/90-quota.conf`, the sieve storages into `conf.d/90-sieve.conf`, and
  `conf.d/90-acl.conf` / `conf.d/90-plugin.conf` are gone (they only carried the empty `plugin { }`
  blocks that 2.4 removed), while `conf.d/20-lmtpd.conf` is `conf.d/20-lmtp.conf` now (upstream
  rename in 2.4).
- Fixed: **the per-user quota would have been silently pinned to the configured default.** Measured
  on 2.4.2: a `storage_size` declared inside the quota root *shadows* the `quota_storage_size` the
  userdb returns, so every mailbox would have ignored its PostfixAdmin quota. The root therefore
  declares only the driver (and the warnings), `auth-sql.conf.ext` keeps returning the `quota`
  column (bytes, 0 = unlimited) and the suite now pins both ends (5120 KB for a 5 MB mailbox, `-`
  for unlimited).
- Fixed: **the quota-warning mails would never have been sent.** `quota-warning.sh` handed the LDA
  `-o "plugin/quota=maildir:User quota:noenforcing"`, which 2.4 rejects as an unknown setting (the
  LDA aborts, so the 80 %/95 % warnings silently disappeared): it is `-o quota_driver=maildir -o
  quota_enforce=no` now. 2.4 also dropped the percentage grace (`quota_grace = 10%%`), so the root
  carries an absolute `storage_grace = 20M` instead — 10 % of the default 200M mailbox, the closest
  expressible equivalent.
- Fixed: the mda debug knobs were unreachable — `MDA_DEBUG_AUTH_PASSWORD`, `MDA_DEBUG_MAIL` and
  `MDA_DEBUG_SSL` were read from `MTA_*` variables, and the SSL one flipped `verbose_ssl`, which
  2.4 removed. The variable names are corrected and the SSL knob now says why it is a no-op.
- Changed: **`cron` base moved `ubuntu:jammy` → `ubuntu:resolute`** (26.04 LTS), the **fourth**
  service of the LTS rollover (**4/5** — only `mta` is still on jammy). The PGDG repository dance
  is gone with it: jammy only shipped `postgresql-client` 14 (older than the 15 server, which is
  the combination that used to produce silent 20-byte "successful" dumps), while resolute ships
  **`postgresql-client-18`** — ≥ the working-tree server (`postgres:15-bookworm`) *and* equal to
  the canonical target (`postgres:18-bookworm`) — so the image installs the distro package
  (`ARG PG_CLIENT_MAJOR=18`), losing the keyring fetch, the extra apt source and `curl`. Measured
  on the real packages: `pg_dump 18.6` dumps the 15.19 catalogue (the suite's G1/G3 gate passes),
  SpamAssassin moves 3.4.6 → **4.0.2** (only `sa-learn` is used; `Learned tokens from N message(s)`
  and the `--dump magic` `non-token data:` lines are unchanged, and with no bayes db it degrades
  to the same zeros as before), pflogsumm 1.1.5 → **1.1.14**, swaks 20201014 → 20240103 and
  bind9-host 9.18 → 9.20. The daemon is still `cron 3.0pl1`. A **HEALTHCHECK** was added (the
  documented exception until now): it reads `/var/run/crond.pid` and checks the process, so `cron`
  reports health like every other service.
- Fixed: **`cron/scripts/resume.sh` hardcoded `/usr/sbin/pflogsumm`**, and resolute's pflogsumm
  1.1.14 installs to `/usr/bin/pflogsumm`: the daily traffic resume would have failed with
  "No such file or directory" and mailed an empty report (the report *layout* is unchanged — the
  suite's G8/G9/G10 pass with 117 received / 117 delivered and the domain in the body). The script
  resolves `pflogsumm` from `PATH` now, like every other tool it calls.
- Changed: **the `cron/spamassassin/` reference copy was refreshed from the resolute SpamAssassin
  4.0.2 package** (the jammy one is archived in `cron/spamassassin-jammy/`). It is a reference
  only: the image never installs it (the Dockerfile purges `/etc/cron.*/*`) and the rules refresh
  runs in `amavis` — the playbook and `catalog.md` no longer imply otherwise.
- Changed: **`mta` base moved `ubuntu:jammy` → `ubuntu:resolute`** (26.04 LTS), the fifth and last
  service of the LTS rollover — which is now **complete (5/5: clamav, amavis, mda, cron, mta)**.
  Postfix jumps **3.6.4 → 3.10.6** and `postfix-policyd-spf-python` 2.9.3 → 3.1.0 (same
  `/usr/bin/policyd-spf` binary and `/etc/postfix-policyd-spf-python/policyd-spf.conf` path, so
  `master.cf` needed no change). Ported: the two parameters Postfix 3.9 obsoleted —
  `smtpd_tls_dh1024_param_file` and `smtpd_tls_eecdh_grade` — are gone (with ECDHE auto-curves the
  DHE parameters are not needed, so the mta no longer reads `/certs/RSA2048.pem`: the mda keeps that
  file as its own `ssl_server_dh_file`), and `compatibility_level` is **3.9**, the value the
  resolute package ships in its own `main.cf`, now declared only in `main.cf.s` — the entrypoint used
  to force 3.6 at start-up, silently overriding the template. The rest of MailD's TLS block
  (`smtpd_tls_ciphers`, the `*_tls_mandatory_protocols`/`*_tls_protocols` lists, the cipher
  exclusions) is *not* obsolete in 3.10 and was kept as-is. Postfix 3.9/3.10 also bring security
  defaults that now apply, deliberately: `smtpd_forbid_unauth_pipelining = yes`,
  `smtpd_forbid_bare_newline = normalize`, `cleanup_replace_stray_cr_lf = yes` and a DNS-result cap.
  The image drops `net-tools` and `netcat`: nothing in it used `nc`, `netstat` or `ifconfig` after
  the port (the healthcheck reads the master pidfile).
- Fixed: **the mta container would have crash-looped on resolute.** Two 3.10 changes bit the
  entrypoint: `/usr/lib/postfix/configure-instance.sh` now refuses to run when invoked directly
  ("E: This is internal script used by postfix" — it expects postfix-script's environment), so the
  explicit call is gone and postfix-script runs it on every instance start as designed; and the
  container's own address, used for the `_OWN_IP_` placeholder of the 10025 reinjection listener,
  came from `ifconfig` (net-tools, no longer installed), which after the package cleanup produced an
  **empty** value and bound that listener to every interface. It is resolved with
  `getent hosts $(hostname)` (falling back to `hostname -i`), dependency-free. Verified: the mta
  binds `<container-ip>:10025`, starts with `postfix -v check` clean and without
  obsolete-parameter warnings, and the full acceptance suite is green (47 checks).
- Changed: **the `db` service is on `postgres:18-trixie`** (was `postgres:15-bookworm`): the
  catalogue moved **15.19 → 18.6**. PostgreSQL data directories are major-incompatible, so this is
  not a rebuild — it is a **logical dump + restore into a freshly initialised cluster** (15 and 18
  cannot share a data dir). The db is not part of the Ubuntu LTS rollover: it follows the official
  image's own cadence. The `postgres:18` images changed the default data layout
  (`PGDATA=/var/lib/postgresql/18/docker` with a single mount at `/var/lib/postgresql`) and
  *refuse to start* when they find a mount at the legacy `/var/lib/postgresql/data`, so
  `db/Dockerfile` pins `PGDATA=/var/lib/postgresql/data`: existing volumes stay valid and the
  upgrade is dump/restore only. Verified on the dev bench: same encoding/collation
  (`UTF8`/`en_US.utf8`), `data_checksums` now on (a 18 default), every row restored
  (`domain=2 mailbox=5 alias=8 admin=2`, plus the `maild_provision` sentinel bit-for-bit), and
  `bootstrap-dev.sh` + the full acceptance suite (47 checks) green. The production procedure, its
  caveats (collation/`POSTGRES_INITDB_ARGS`, the mandatory `--clean --if-exists`, the sentinel,
  secrets, downtime) and the rollback path are documented in the new **`db_upgrade.md`**.
- Fixed: **the SnappyMail admin panel rejected the OTP the `mua` container printed**
  (`/?admin` + `admin:<password from docker compose logs mua>` answered `AuthError[102]` for
  ever). The entrypoint patched SnappyMail's own `application.ini` with
  `crudini --set --inplace`, and crudini writes every value *unquoted* where SnappyMail quotes
  its strings: `pdo_dsn = host=db;port=5432;dbname=contacts` is a syntax error for PHP's ini
  parser, so `parse_ini_file()` returned `false` **for the whole file**.
  `RainLoop\Config\AbstractConfig::Load()` reads an unparsable file as "no configuration" and
  calls `Save()`, which rewrote it from the factory defaults — `security.admin_password`
  included, so the `BANNER_TITLE` and the contacts settings were silently lost as well. The next
  admin-panel request then found an empty password and minted a new random one
  (`ActionsAdmin::AdminAppData`), written to `data/_data_/_default_/admin_password.txt` *and* to
  the config hash: the one password nobody printed, while the entrypoint kept advertising the
  stale one. Proven by the timestamps (`admin_password.txt` at 16:33:50.542, the config hash at
  16:33:50.606 — the two writes of that single request), by `password_verify()` against what was
  printed (mismatch), and by reproducing the parser failure on crudini's output. The new
  **`mua/config-setup.php`** replaces that block: it patches the file **at text level** (comments
  and foreign settings untouched) with SnappyMail's own quoting rules, repairs values an older
  release left unquoted, validates that it still parses, and only then touches the credentials —
  writing atomically and rolling the file back if the result does not verify. The wait loop no
  longer blocks on `admin_password.txt` either (SnappyMail deletes it when an administrator sets
  a password from the panel): if it finds a hash whose plaintext is gone it now says
  `unchanged, set from the admin panel` instead of silently rotating a password somebody chose.
- Added: **`MUA_ADMIN_USER`** (default **`maild`**, the panel login used to be the hardcoded
  `admin`) and **`MUA_ADMIN_PASSWORD`** (empty ⇒ random, generated on the first boot, kept in the
  data volume and printed as an OTP by the entrypoint banner; set ⇒ applied on every boot and the
  plaintext file — hence the panel's "weak password" flag — is dropped). `MUA_CONFIG_WAIT_TIMEOUT`
  bounds the configuration wait. Documented in `env.sample`, `env.sample_gitlab`, `vars/mua.env`,
  `INSTALL.md` ("First login"), `.agents/services/catalog.md` and
  `.agents/devops/workflows.md` (debug recipe + the two failure modes).
- Fixed: two smaller `mua` entrypoint defects on the same path: `chmod 0600 ~/.pgpass &1>2` (a
  typo — the bare `1>2` redirection created an empty **root-owned `2` file inside `domains/`** on
  every boot; the cleanup is now `find … -maxdepth 1 -type f -delete`, which also drops stale
  per-domain JSONs and does not choke on names with spaces), and `contacts enabled On`, a key
  SnappyMail does not have (it is **`enable`**), so the contacts database had never actually been
  enabled.
- Changed: `mua/snappymail.ini` enables `log_errors` (`error_log = /dev/stderr`) so a PHP level
  failure of the webmail surfaces in `docker compose logs mua` — a silent ini parse error is what
  hid this bug — and its comments now use `;`: the php.ini parser reads a `#` line as a bogus key
  and rejects the whole file as soon as such a line is not a valid `key = value` (the previous
  `# log_errors = On` lines were inert for that reason). `crudini` is no longer installed.
- Added: **the webmail ships a working password change (Settings → Password) and its plugin
  baseline comes from the image instead of from a hand-installed volume.** Three packages —
  `add-x-originating-ip-header` (2.0), `change-password` (2.38) and `two-factor-auth` (2.19.0) —
  are downloaded at **build time** from `snappymail.eu/repository/v2/` (pinned `ARG PLUGIN_*`,
  bump them together with `SNAPPY_VERSION`) into `/opt/maild/plugins/`, and the mua entrypoint
  copies them over the data volume on every boot (`MUA_PLUGINS`, additive to whatever the admin
  panel enabled; only the managed directories are replaced, so a plugin installed later from the
  panel survives). Their **settings** live in the volume (`configs/plugin-*.json`) and are never
  rewritten by the boot. Before this the plugins only existed because they had been installed by
  hand into one volume — a fresh deployment had none — and `change-password` answered **"There
  are no change-password drivers enabled"** on any deployment, because that plugin only offers a
  driver when its `driver_<name>_enabled` setting is set and nothing ever set it.
- Added: **`mua/plugins/change-password-maild/driver.php`**, MailD's own change-password driver.
  It is a *sibling package* of the plugin (`plugins/change-password-<name>/driver.php`, the
  extension point that plugin globs) so installing or updating `change-password` from the admin
  panel cannot overwrite it. It writes `mailbox.password` (and `modified`) in the catalogue
  exactly like PostfixAdmin — **md5crypt by default**, the scheme `POSTFIXADMIN_ENCRYPT` and
  Dovecot's `default_password_scheme` both verify, generated the way `admin/seed.sh` generates it
  — over PDO/pgsql with the container's `POSTGRES_*`, every value (DSN, credentials, hash scheme,
  `{SCHEME}` prefix) overridable in the panel. Verified live on the dev bench: changing
  `alice@example.net`'s password from the webmail wrote `$1$…` and bumped `modified`, the new
  password logged in over IMAPS *and* verified through PostfixAdmin's own `pacrypt()` while the
  old one stopped working (the fixture password was restored afterwards). A superseded password can
  still authenticate until Dovecot's `auth_cache_ttl` runs out — see the cache bullet below.
- Changed: the mua entrypoint syncs the plugin directories before the config stage and tightens
  their modes (`chmod go-rwx`, matching SnappyMail's own installer); `config-setup.php` keeps
  `[plugins] enable = On` and `enabled_list` at the union of `MUA_PLUGINS` and the panel's list,
  and seeds `driver_maild_enabled` (forced while `change-password` is managed) and
  `driver_maild_allowed_emails` (only when absent, so an operator restriction survives).
  Documented in `env.sample`, `env.sample_gitlab`, `vars/mua.env`, `INSTALL.md`, `DEV-SETUP.md`,
  `.agents/services/catalog.md` and `.agents/devops/workflows.md`.
- Changed: **Dovecot's authentication cache is now short** —
  `mda/dovecot/conf.d/10-auth.conf`: `auth_cache_ttl = 1 minute` and
  `auth_cache_negative_ttl = 0` (the 10M cache itself is kept). Prompted by a bench report: after
  changing a password in the webmail, the *old* password still logged in. The change itself was
  correct — the catalogue verified with PostfixAdmin's own `pacrypt()`, and the webmail with the
  new password — but a cached *success* answers an authentication without querying the passdb for
  the whole TTL, so the superseded password kept working for up to Dovecot's default ten minutes
  (and for a password changed in PostfixAdmin, which never re-authenticates, nothing refreshes the
  entry before it expires; the webmail does refresh it, because it re-authenticates with the new
  password right after the change). The same cache did the opposite, and worse: a *mismatch* cached
  for an hour could lock a user out of a password he had mistyped once *before* adopting it. One
  minute without negative caching makes both realistic, still absorbs a mail client's reconnect
  bursts, and `doveadm auth cache flush` remains the instant remedy — measured on the bench: a
  superseded password still authenticates right after the change and fails 65 s later, and a
  previously-mistyped password works the moment it is set. `.agents/devops/workflows.md` and the
  `mda` entry of `.agents/services/catalog.md` document the symptom and the settings.

## 2026-10-06 1.3.1-rc
- Changed: **GitHub Actions pipeline** (`.github/workflows/docker-image.yml`) rebuilt into
  three gated phases on `develop`/`main`. (1) Validate every compose file, build the `:develop`
  images, start the dev stack, bootstrap the fixtures and run the full `test.sh` suite — this
  also runs on pull requests. (2) On a push, retag and push the images to Docker Hub and
  ghcr.io (`:develop` on `develop`, `:latest` on `main`). (3) On a push to `main`, tag the
  `:latest` images with the `VERSION` file value (e.g. `1.3.0-rc`) and push them to both
  registries. Documented in `.agents/devops/workflows.md`.
- Fixed: the Actions job installs `swaks` + `libnet-ssleay-perl` before running the suite
  (`test.sh`'s no-root swaks fallback ships no Perl TLS module, so every port 465/587 and
  authenticated check failed with `rc=10`); bumped `actions/checkout` to `v5`.

## 2026-10-04 1.3.0-rc
- Changed: **compose file refactor.** `docker-compose.yml` is now the single production source
  of truth (derived from `docker-compose-dev.yml`); `compose-github.yml` and `compose-gitlab.yml`
  are strict copies that differ only in the `image:` lines. All images use the
  `maild-<svc>:<tag>` naming. `compose-dockerhub.yml` was **removed** (`docker-compose.yml`
  is the Docker Hub file). See `AGENTS.md` → Core principles for the sync rule.
- Added: Traefik labels on every production compose file exposing `webmail.<DEFAULT_DOMAIN>`
  (`mua`) and `mailadmin.<DEFAULT_DOMAIN>` (`admin`); the web UIs are no longer published
  directly — an external ingress that terminates TLS is **required** (Traefik, Nginx, …; not
  provided).
- Changed: the mta/mda ports are published on every compose file; `dozzle` is dev-only.
- Fixed: `.github/workflows/docker-image.yml` no longer references the removed
  `compose-dockerhub.yml` nor the non-existent `setrepos.sh`; `.gitlab-ci.yml` now sets
  `COMPOSE_FILE=compose-gitlab.yml` and `IMG_*` to `$CI_REGISTRY_IMAGE/maild-<svc>`.
- Changed: `README.md` / `INSTALL.md` document the three deployment cases (Docker Hub
  preferred, GitHub for restricted countries, GitLab) and the required ingress.
- Added: **zero-touch first-boot provisioning**. A fresh deploy now comes up ready to use:
  on the first boot `db` creates the catalogue plus the `maild_provision` sentinel table (a
  migration), then `admin` seeds `DEFAULT_DOMAIN`, the PostfixAdmin superadmin
  (`MAIL_ADMIN_USER@DEFAULT_DOMAIN`) with its mailbox and the default aliases
  (postmaster/abuse/hostmaster/webmaster) and records the sentinel. The services that cache
  the domain list at boot — `amavis` (DKIM), `mua` (SnappyMail per-domain config) and `mta`
  (virtual aliases) — wait for the sentinel before their config stage, so there is no
  `/setup.php`, no down/up cycle and no per-service restart. It is race-safe under an
  orchestrator (sentinel + `pg_advisory_xact_lock`).
- Added: `MAIL_ADMIN_PASSWORD` as the superadmin/mailbox password source (empty ⇒ generated
  and printed OTP-style); new `AUTO_PROVISION`, `PROVISION_VERSION`, `PROVISION_WAIT_TIMEOUT`
  and `PROVISION_FORCE` variables (`env.sample`, `env.sample_gitlab`, forwarded via
  `vars/*.env`). `AUTO_PROVISION=no` restores the classic manual OTP flow.
- Added: `admin/seed.sh` (the idempotent seeder), `db/migrations/001_maild_provision.sql` +
  `db/migrate.sh` (run from the db entrypoint chain — the only DDL added; no PostfixAdmin core
  table is altered) and `.agents/services/provisioning.md`.
- Changed: `admin/Dockerfile` now ships `postgresql-client` (the seeder uses `psql`).
- Changed: `Install.md` renamed to **`INSTALL.md`** and rewritten around the automated
  workflow, including the isolated-environment caveats (`AUTO_PROVISION=no` manual fallback,
  alternate ClamAV mirror, github vs dockerhub images); `README.md` now points to it.
- Fixed: `amavis` creates its runtime dirs (`tmp`/`db`/`dkim`/`virusmails`) at startup and its
  Dockerfile no longer relies on brace expansion (`dash` does not expand
  `mkdir -p {a, b, c}`). A fresh dev **bind** mount of `./ldata/amavis` is empty (docker only
  pre-populates *named* volumes), which made amavisd die with
  `No TEMPBASE directory: /var/lib/amavis/tmp` on a clean boot.
- Fixed: `mta/check.sh` no longer calls `postfix status` (Postfix routed
  `the Postfix mail system is running: PID: N` through `postlog` -> `maillog_file=/dev/stdout`,
  appending a line to the container log on every healthcheck tick, once a minute). It now probes
  the master pidfile with `kill -0`, which is silent and equivalent.
- Changed: version bumped to `1.3.0-rc`.

## 2026-10-04 1.2.1-rc

- Changed: **major overhaul of the agent-facing docs** — `AGENTS.md` is now a compact
  entrypoint (core principles + fast lane + debugging quick reference) and the detail moved
  into a restructured `.agents/` tree: `architecture/overview.md` (system map, mail flow,
  startup order, data layout, entrypoints/healthchecks, cron schedule), `services/catalog.md`
  (per-service roles/ports/volumes/env_file lists), `services/configuration.md` (the env
  chain and how to add a variable), `devops/base-images.md`, `devops/environment-setup.md`
  and `devops/workflows.md`. `devops-n-test/` was renamed to `devops/` and every statement
  was re-verified against the working tree (dev ports 8080/8081/8082, `--env-file env.dev`,
  `bootstrap-dev.sh`/`test.sh`, the cron schedule, the Postfix→amavis→LMTP flow).
- Added: **OCI LABELS block on every Dockerfile** (`org.opencontainers.image.*`: title,
  description, authors, url, source, licenses=GPL-3.0-or-later, created; admin also carries
  `cu.maild.original-maintainer` for the PostfixAdmin upstream). The legacy
  `maintainer`/`last_modified`/`image.app`/`image.name` labels are retired.
- Changed: the `.pre-commit` hook now rewrites `org.opencontainers.image.created` with
  today's date on modified Dockerfiles (it stamped the retired `last_modified` label before).
- Changed: `.gitignore` now covers `.local/` (local dev binaries, e.g. the swaks copy).
- Removed: `Install.md` instructions referencing the deleted `setrepos.sh` /
  `sources.list_debian` / `sources.list_ubuntu` local-repo mechanism (no longer in use).


## 2026-10-03 1.2.0-rc

- Added: **test.sh now covers the daily mail traffic resume** (`cron/scripts/resume.sh`, which
  cron runs at 01:10 UTC over *yesterday's* traffic) — four new checks in phase G, 39 → 43:
  - **G7** materialises the day's real `mta` log as `/var/log/syslog` inside the cron container.
    The job parses `/var/log/syslog{,.1}`, which only exists in production (the cron container
    binds the host `/var/log` *and* every service logs through Docker's syslog driver, so the
    host's rsyslog writes it); dev logs to JSON and `./ldata/logs` stays empty, so without this
    the job parses nothing. Each line gets an outer rsyslog stamp in front of Postfix' own
    `maillog_file = /dev/stdout` line — not cosmetic: that stamp is what makes the script's
    `grep " Mon DD "` (leading space) and its stamp-stripping `sed` match at all, since Postfix'
    own line starts at column 0. A `/var/log/syslog` that is already there is left untouched.
  - **G8** runs `/scripts/resume.sh today` the way cron runs it and asserts it exits 0
    announcing the summary for the *cron container's* date (it runs UTC; the host may not).
  - **G9** waits for the report in `MAIL_ADMIN_USER@DEFAULT_DOMAIN`'s INBOX, counted on the
    resume's own subject rather than on the mailbox size: the backup checks above mail that same
    mailbox, so only a delta on that subject proves *this* run's report landed.
  - **G10** fetches the message and asserts the **body** carries real traffic — non-zero
    `received`/`delivered` tallies, the `Grand Totals` and `Per-Hour Traffic Summary` sections
    and the deployment domain. Both signals had to be read from the body: pflogsumm's blank
    report for an empty log is still ~3 KB of nothing but zeroes (so size proves nothing), and
    the message's own headers name the domain anyway (`Received: from mta.…`, DKIM `d=…`), so
    grepping the whole message matched the blank report too.
- Added: four subject-scoped mailbox helpers in test.sh (`subj_count`, `wait_subj_count_gt`,
  `msg_newest_uid`, `msg_text`) — a mailbox total cannot say *which* message arrived, and every
  cron job writes to the same admin mailbox.
- Changed: phase G is now "cron jobs" (database backup + traffic resume), and `cleanup()` also
  removes the materialised `/var/log/syslog` on exit, so the cron container is left exactly as
  it was found even when the run is interrupted.
- Changed: `DEV-SETUP.md` — the suite's check count was still documented as 33; it now lists the
  cron-job phase and notes that dev's JSON logging leaves no syslog for the resume to parse.
- Added: `env.sample` gained a "Daily Traffic Resume (cron)" section next to the backup one:
  what the job mails, that it needs *both* the host `/var/log` bind and the syslog logging
  driver, and that it fails silently (exit 0, an all-zeroes report) when either is missing.

- Fixed: the daily PostgreSQL backup had been producing **empty archives reported as
  successful** — the `[OK] MailD Daily Database Backup Completed` mail listed 20-byte files
  (`Backup Size: 4.0K`, `Total Storage Used: 348K` for 16 "backups"). Three defects stacked up:
  the cron image installed ubuntu jammy's `postgresql-client` (**pg_dump 14**) while the server
  is `postgres:15-bookworm` (**15.19**), and pg_dump refuses a newer server (`aborting because
  of server version mismatch`) writing **nothing** on stdout; the script tested the exit status
  of `pg_dump | gzip`, which is gzip's (no `pipefail`), so the abort was invisible; and the
  "is it empty?" guard was `[ ! -s file ]`, which a 20-byte gzip of an empty stream passes. On
  top of that `2>> $LOG_FILE` was attached to gzip, so pg_dump's error never reached
  `/backups/db/backup.log` and the only trace was the container log
- Fixed: `cron/Dockerfile` now installs `postgresql-client-15` from the PGDG archive
  (`ARG PG_CLIENT_MAJOR=15`; jammy only ships 14) and purges the v14 client, asserting
  `pg_dump --version` at build time. Bump `PG_CLIENT_MAJOR` together with the server image in
  `db/Dockerfile`
- Fixed: `cron/scripts/backup_db.sh` can no longer call an unusable dump a backup:
  `set -o pipefail` plus `PIPESTATUS` read pg_dump's own status, its stderr is copied into the
  log, the client/server major pair is checked before dumping (an older client fails with the
  `PG_CLIENT_MAJOR=<n>` remedy spelled out) and the archive is validated — `BACKUP_MIN_BYTES`
  (1024) minimum, `gzip -t` and the `-- PostgreSQL database dump` / `dump complete` markers —
  before `SUCCESS` is reported. A dump that fails any of those is **deleted** (it used to stay
  behind and be counted as a backup) and mailed as `[CRITICAL]` with the reason
- Changed: the notification mail reports the exact byte and table counts
  (`Backup Size: 348K (356123 bytes, 24 tables)`) instead of `du -h` alone, which rounded a
  20-byte archive up to "4.0K" and hid the problem
- Added: `./ldata/backups:/backups` to the cron service in `docker-compose-dev.yml` — production
  binds `/var/backups/maild:/backups` but the dev stack had no such mount, so a local run wrote
  into the container's writable layer and the dump vanished on the next recreate (this is why
  the backup could not be exercised locally at all)
- Added: phase **G. database backup** to `test.sh` (33 → 39 checks): the client/server version
  pair, `/backups` being a real mount, a live `backup_db.sh` run producing a complete dump of
  the catalogue (`gzip -t` + trailer + `CREATE TABLE public.mailbox`), and the two failure
  guards — an aborting pg_dump must exit non-zero and delete its empty archive, an older client
  must be refused by the version guard
- Added: a "Database Backup (cron)" section to `env.sample` documenting the job, the mount, the
  client/server coupling and `BACKUP_MIN_BYTES`; `backups` added to the `ldata/` scaffold in
  DEV-SETUP.md

## 2026-10-02

- Added: a daily mailbox quota report for the mail admin — `mda/scripts/quota_report.sh`,
  shipped to `/scripts/` in the mda image and started as a background loop by the entrypoint
  (it never blocks dovecot, its output goes to the container log). On the first tick past
  `QUOTA_REPORT_HOUR`:`QUOTA_REPORT_MINUTE` (00:01 by default) with no report yet that day it
  mails `MAIL_ADMIN_USER@DEFAULT_DOMAIN` the mailboxes over `QUOTA_REPORT_THRESHOLD` (80% by
  default), grouped per domain and in 5% slots, worst first: critical (over
  `QUOTA_REPORT_CRITICAL`, 99%), then over 95%, 90%, 85% and 80%. Mailboxes under the threshold
  are not listed and the ones without a quota limit are only counted in the summary. Figures come
  from `doveadm quota get -A` (active mailboxes only, exactly what the quota plugin enforces) and
  the report is delivered through dovecot's own LDA, the same path the per-user quota warnings
  use; a failed delivery is retried up to `QUOTA_REPORT_MAX_ATTEMPTS` (5) times and then given up
  until tomorrow, so a broken delivery can't turn into a mail storm. `--now` forces a report and
  `--now --dry-run` renders it on stdout without mailing it
- Added: the `QUOTA_REPORT_*` knobs to `env.sample` (`HOUR`, `MINUTE`, `THRESHOLD`, `CRITICAL`,
  `ONLY_WHEN_WARN`, `MAX_PER_SLOT`, `MAX_ATTEMPTS`), a "Mailbox quota: daily fill report" section
  to the README, and the daily-report loop to the mda entrypoint/Dockerfile
- Fixed: `test.sh` phase F asserted that port 25 refuses `sysadmin@DEFAULT_DOMAIN` unconditionally,
  which only holds after `bootstrap-dev.sh --skip-default-domain`. The default bootstrap provisions
  `DEFAULT_DOMAIN`, so the MTA correctly answered `250 2.1.0/2.1.5 Ok` (local delivery, not a relay)
  and the suite reported a false failure. The check is now split in two: **F3a**, an open-relay
  negative against a resolvable domain that is not hosted here (`RELAY_PROBE_DOMAIN`, `example.com`
  by default) — this is what actually exercises `reject_unauth_destination`, which the `.example`
  probe of A8 never reached because `reject_unknown_recipient_domain` fires first — and **F3b**,
  adaptive on `DEFAULT_DOMAIN` through the new `domain_is_hosted()` helper (the `domain` table when
  docker assertions are on, `test.creds` otherwise): mail for `<MAIL_ADMIN_USER>@<DEFAULT_DOMAIN>`
  must be accepted **and delivered** when the MTA hosts it, and refused as a relay when it does not
- Changed: the suite went from 32 to 33 checks; `MAIL_ADMIN_USER` is now read from `env.dev` (with
  `env.sample` and `sysadmin` as fallbacks, as `bootstrap-dev.sh` does) instead of being hardcoded,
  and `RELAY_PROBE_DOMAIN` is overridable from the environment

## 2026-10-01

- Added: `env.dev` — fake, committed compose interpolation file for the dev stack; the dev
  stack no longer reads the real secrets in `.env` (bootstrap passes `--env-file env.dev`
  and refuses to run when the running containers were created with different secrets)
- Fixed: `.gitignore` did not cover `test.creds` (the credentials file bootstrap writes)
- Fixed: the amavis content-filter toggles — `AV_ENABLED`/`SPAM_FILTER_ENABLED` were tested for
  non-emptiness, so the documented `no` (the dev compose default) actually *enabled* the filters,
  and the SPAM `sed` edited the virus line; both values are now parsed as yes/no/true/false/1/0
  and the bypass maps are written to a dedicated `60-maild_content_filter_mode` (the log line
  `Content filter mode: AV=on, SpamAssassin=on` reflects it)
- Fixed: the Dovecot quota-warning script — dovecot-lda inherited `info_log_path = /dev/stdout`,
  which does not exist inside a dovecot `script` service, so every quota warning died with
  "Can't open log file /dev/stdout: No such device or address"; the LDA now logs to
  `/var/log/dovecot-quota-warning.log`
- Added: the dev stack runs with AV and SpamAssassin enabled (`env.dev`), and bootstrap-dev.sh
  waits for ClamAV's first signature download (~230 MB) because amavis defers all mail until
  clamd has a database (`--skip-clamav-wait` opts out)
- Added: bootstrap-dev.sh restarts amavis when a provisioned domain still has no DKIM key
  (amavis builds its keys from the domain list it sees at start)
- Changed: `test.sh` is now an acceptance suite (32 checks) covering SMTP policy, TLS/AUTH,
  alias and plus-addressing delivery, IMAP/POP3 read-back, EICAR/GTUBE/banned content filtering,
  the mailbox-quota fixture (limit, warnings, 552 at RCPT, NDR) and Sieve redirect/DKIM; it reads
  `test.creds`, is self-cleaning and prints pass/fail/skip counters with a non-zero exit code
- Added: automatic daily SpamAssassin rule updates (sa-update loop on the amavis
  container + amavisd reload after new rules are installed)
- Added: automatic Bayes learning from the user's Junk folders plus a random
  INBOX sample as ham (cron container, daily at 03:30)
- Added: instant Bayes learning via Dovecot imapsieve: moving a message into/out
  of the Junk mailbox learns it as spam/ham (mda container)
- Added: shared SpamAssassin config volume (saconf) mounted on amavis, cron and
  mda; the MailD tuning is written to /etc/spamassassin/maild.cf on startup and
  can be tuned via env vars (vars/amavis.env)
- Added: daily purge of the users' Junk folders, messages older than
  JUNK_RETENTION_DAYS (7 by default) are deleted (cron, 03:00)
- Added: weekly Bayes health stats (spam/ham/tokens, balance and rules channel
  freshness) appended to the daily stats resume on Sundays
- Changed: mda & cron images now include SpamAssassin; the /etc/spamassassin
  folder is a shared docker volume seeded from the image distro files
- Fixed: check_maildirs.sh broken redirection on ~/.pgpass chmod (was `&1>2`)
- Fixed: check_maildirs.sh malformed test `[ ${days} -gt 365 -a ]` that pushed
  all >365 days maildirs into the warn list instead of the erased list

## 2026-01-19 1.1.0

- Added: Some upgrades, and bug fixes just stabilize the actual code from updated versions on OS and software

## 2024-08-11 1.0.0

- Added: Github docker repository support, to avoid setting a vpn/proxy from Cuba

## 2024-08-11 1.0.0-rc2

- Changed: Added the logic to save internet setting local repos and local source files.
- Added: Improved the documentation, review and one more time ran a local build & install to test.

## 2024-07-14 1.0.0-rc1

- Added: setrepos.sh script to allow to use local/net OS repos in dev mode
- Changed: Upgraded snappy mail to version 2.36.4 from 2.35.3

## 2024-07-13 1.0.0-rc

- To many to list, preps to release v1.0.0
