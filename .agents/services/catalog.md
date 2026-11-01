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
  SnappyMail contacts DSN, so the two lists must not be merged. `MCP_DB` (default `mcp`) is
  ensured the same way for the MailD MCP.
- Boot chain: postgres ready → `ensure_databases.sh` → `migrate.sh` (catalogue migrations,
  incl. `003_mcp_service_mailbox.sql`: the `SECURITY DEFINER` function
  `maild_mcp_ensure_service_mailbox(address, hash, name)`, insert-only, Argon2id hashes only,
  EXECUTE revoked from PUBLIC) → `ensure_roles.sh`. The last one runs only when
  `MCP_DB_PASSWORD` is set: it creates/re-asserts the `MCP_DB_USER` role (default `maild_mcp`,
  no superuser/createdb/createrole), makes it owner of `MCP_DB`, and **declaratively** revokes and
  re-grants its catalogue rights on every boot — column `SELECT` on `domain(domain, active)`,
  `mailbox(username, domain, local_part, name, active)` (never `password`) and
  `alias_domain(alias_domain, target_domain, active)` (P2: "external recipient"), `SELECT` on
  `maild_provision`, `EXECUTE` on the function. The password reaches psql as a stdin variable,
  never on a command line. Rotation = change the env file + restart db (and recreate mcp).
- Env (new schema): defaults baked in `db/Dockerfile` (`POSTGRES_HOST/DB/USER/EXTRA_DB`);
  the operator file (`env.dev`/`.env`) is the `env_file:` and overrides any of them. The
  password is passed explicitly with a `${POSTGRES_PASSWORD:?}` guard (compose does not
  interpolate `env_file:` contents; a missing one fails at `compose config`).
  `MCP_DB_PASSWORD` is passed as `${MCP_DB_PASSWORD:-}` (empty = no MCP role; the stack still
  boots); `MCP_DB`/`MCP_DB_USER` are baked (`mcp`/`maild_mcp`) and must match the mcp image.
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
- **Two listeners (D13, since P1b of the MCP work)**: `10024` = policy bank `MTA` (Postfix's
  `content_filter`), `10026` = bank `INTERNAL` (the stack's own submitters: cron's swaks jobs on
  `AMAVIS_SUBMIT_PORT` and the MailD MCP's service mail). Both banks are `originating` (DKIM,
  forward to `mta:10025`). Access is by source address: `conf.d/52-maild-acl` sets each bank's
  `inet_acl` to `127.0.0.1 [::1]` + the mta (10024) / cron + mcp (10026), rendered at boot and
  by a **peer-IP watchdog** (`PEER_WATCH_INTERVAL`, default 30 s, 0 = off; same variable as the
  mta's) that re-resolves mta/cron/mcp and HUPs amavisd when one moved (a reload re-reads
  `inet_acl` — verified by `test.sh` L6). mcp is optional and may join late. Refusals are logged
  as `DENIED ACCESS from IP <x>, policy bank '<bank>'`. Before this, 10024 accepted any source
  (`0.0.0.0/0`): every container on the shared network could send DKIM-signed mail as any hosted
  address. `check.sh` reads both banners; a moved mta/cron is only transiently unhealthy now.
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
- Env: defaults baked in `amavis/Dockerfile` (filter toggles, `SA_*`, peer hostnames
  `MTA`/`CLAMAV`/`CRON`/`MCP`, `PEER_WATCH_INTERVAL=30`); the operator file is the `env_file:`
  and overrides any of them. No published port in any compose file (dev dropped `10024:10024`).

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
- **MCP master user** (opt-in, proposal `mcp/technical-proposal.md` §5.3/§9.1): when
  `MCP_DOVECOT_MASTER_PASSWORD` is set the entrypoint (every boot, `dovecot` branch) renders
  `/etc/dovecot/master-users` (`<MCP_DOVECOT_MASTER_USER>:{ARGON2ID}…`, `0640 root:dovecot`; the
  password goes to `doveadm pw` on stdin) and installs `conf.d/auth-master.conf.ext` from
  `auth-master.conf.ext.in`, picked up by `!include_try` in `10-auth.conf`; unset, both are
  removed. The master passdb lives inside `protocol imap { }` with `result_success = continue`,
  so `user@domain*mcp` + the master password works over IMAP only (POP3, ManageSieve and the
  mta's SASL refuse it) and the SQL userdb lookup (`active='1'`) still applies: inactive or
  missing mailboxes cannot be opened. `rehash-password.sh` exits early when `MASTER_USER` is set
  (userdb field `master_user = %{master_user}`), otherwise the first master login to a legacy
  `$1$` row would store the *master* password as that user's (§5.4, reproduced and fixed
  2026-10-29). `login_log_format_elements` adds `auth_user=<%{auth_user}>` (equals `user` on a
  normal login, the master name on a master login) so every MCP access leaves a Dovecot trail.
  `test.sh` J1–J6 cover it.
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
  password + `DEFAULT_DOMAIN`/`MAIL_ADMIN_USER` passed explicitly at compose level, plus
  `MCP_DOVECOT_MASTER_PASSWORD` as `${…:-}` (empty = no master user).
- Ports: 110, 143, 993, 995 (POP3/IMAP + TLS) and 4190 (ManageSieve), 12345 (SASL).
- **Readiness is the auth socket, not the container state.** A cold first boot generates the
  self-signed cert and `openssl dhparam -5 2048` (a safe prime: seconds to minutes) *before* the
  entrypoint `exec`s the master, so a "running" container can have no
  `/run/dovecot/auth-client` at all and every `doveadm`/IMAP probe fails with
  `conn unix:/run/dovecot/auth-client ... No such file or directory`. `bootstrap-dev.sh` waits
  (bounded) for that socket before it verifies the fixtures. The entrypoint's wait for a
  shared, amavis-seeded `/etc/spamassassin/init.pre` is bounded too (120 s, then it warns and
  starts anyway): no compose file mounts `/etc/spamassassin` (the image ships its own copy), and
  an unbounded wait there would leave the container "running" with Dovecot never started.

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

- **Environment (2026-10 audit M-06):** no `env_file` — the compose `environment:` block is an
  allow-list (`POSTGRES_PASSWORD`, `DEFAULT_DOMAIN`, `MAIL_ADMIN_USER` + bare tunable keys), so
  the operator file's other secrets never reach cron. The entrypoint restores the image ENV
  defaults that bare keys unset (snapshot `/etc/maild-image.env`, taken at build) and rewrites
  `/etc/environment` with mode 600. A `docker exec` shell does not see those restored
  defaults: source `/etc/environment` first (every job script that needs them does).
- Every job that mails (resume, backup, maildir check, outbound watch, DNS check) submits with
  `swaks` to `amavis:${AMAVIS_SUBMIT_PORT}` (default **10026**, bank INTERNAL — D13); 10024 only
  admits the mta.
- Runs `cron -f`; jobs in `cron/crontab` (UTC): traffic resume 01:10, maildir check
  02:13 monthly, Junk purge 03:00, Bayes learning 03:30, outbound volume watch
  hourly (:23), DNS health check 04:20, db backup 08:00 (scripts in `cron/scripts/`).
- `check_dns.sh` (daily 04:20): read-only probe of the **public** DNS for every active
  domain in the catalogue — delegation (NS/SOA), MX (resolution, CNAME, private IPs, the
  declared set), SPF (presence, terminal qualifier, syntax, 10-lookup budget, MX-IP
  coverage), DMARC (presence/inheritance, `p`/`sp`/`pct`, `rua` routing), DKIM (the
  published selector compared byte-for-byte with the key Amavis really signs with),
  PTR/FCrDNS of the MX IPs, MTA-STS/TLS-RPT when published and the blocklists
  (`DNS_CHECK_BLOCKLISTS`/`DNS_CHECK_IP_BLOCKLISTS`). Every finding carries
  found → expected → impact → action, and the report is mailed to
  `postmaster@DEFAULT_DOMAIN` (aliased to the admin) only when a finding reaches
  `DNS_CHECK_ALERT_LEVEL` (`critical|warning|notice`, default `warning`); silence means
  all good. The expected MX set is `MX_HOSTNAME` (comma-separated); unset it is inferred
  from `DEFAULT_DOMAIN`'s live MX and reported as a notice, which also downgrades the MX
  mismatch to a warning. `DNS_CHECK_DOMAINS` replaces the catalogue list (`none` disables
  the job — the dev escape hatch), `DNS_CHECK_RESOLVER` pins the resolver (the free
  Spamhaus zones refuse public resolvers with `127.255.255.x`, reported as a notice, never
  as a listing), `DNS_CHECK_DKIM=no` skips the key comparison, `DNS_CHECK_TIMEOUT` bounds
  each query. `--dry-run` prints the report without mailing it, `--domains a,b` and
  `--mx-hostname ''` are the ad-hoc probes, and `--fixture-dir` answers queries from
  `<TYPE>.<name>` files (what `test.sh` G15–G23 drive it with). Exit codes: 0 nothing at
  the gate, 1 findings mailed, 2 the check could not run, 3 the report could not be
  mailed.
- `outbound_watch.sh` (audit F-12, alerting half): parses the production syslog for the
  day's per-user submission volume (`sasl_username=` on queue-id `from=` lines, plus one
  `maild-mcp: sent user=` line per message sent through the MailD MCP, which skips Postfix SASL)
  and the throttle lines (the mta's `maild-ratelimit: throttled`, the MCP's `maild-mcp:
  throttled`), and mails an `[ALERT]` to the admin via
  `swaks` → amavis:10026 when a user crosses `OUTBOUND_ALERT_MESSAGES` (default
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
- `backup_db.sh` writes **three** archives per run: `maild_backup_*.sql.gz` (the catalogue),
  `maild_adminng_*.sql.gz` (AdminNG: device approvals, sessions, TOTP seeds, audit trail —
  `ADMINNG_DB`, defaulted in the script) and `maild_mcp_*.sql.gz` (the MailD MCP: accounts,
  tokens, settings — `MCP_DB`, default `mcp`; SKIPPED when that database is missing or has no
  table yet). All get the same size/gzip/trailer validation and the same 15-day retention; a
  failed AdminNG or MCP dump keeps the catalogue archive but marks the run FAILED.
- `pflogsumm` (1.1.14) lives in `/usr/bin` on resolute, so `resume.sh` resolves it from `PATH`;
  SpamAssassin 4.0.2 provides the `sa-learn` the Bayes job uses. The `cron/spamassassin/` file is a
  reference copy of Debian's `/etc/cron.daily/spamassassin` that the image never installs (the
  rules refresh runs in `amavis`).
- Volumes: `ldata/logs:/var/log` (empty in dev — JSON logging), `ldata/vmail:/home/vmail`,
  `ldata/backups:/backups` (prod parity: without it `backup_db.sh` dumps into the
  container's writable layer and the dump vanishes on recreate), and `ldata/amavis:/var/lib/amavis:ro`
  (prod: `amavis:/var/lib/amavis:ro`) so `check_dns.sh` can compare each domain's published
  DKIM selector against the key it signs with — read-only, the job never writes there. It does
  **not** mount the shared SpamAssassin volume: its `sa-learn` runs with `HOME=/tmp`, so the
  "shared bayes db" contract only holds for amavis (known drift, see `.local/caveats.md`).
- HEALTHCHECK: `/var/run/crond.pid` + `kill -0` (added with the resolute move).
- env: defaults baked in `cron/Dockerfile` (`JUNK_RETENTION_DAYS`, `SA_HAM_SAMPLE_*`,
  `MTA`, `DNS_CHECK_*`); the operator file is the `env_file:` and overrides any of them. The
  entrypoint dumps the whole environment into `/etc/environment` **shell-quoted** (a raw `env`
  dump broke `source` as soon as a value had spaces: dev's `BANNER_TITLE=MailD Dev Override`
  printed "Dev: command not found" on every job), from where every cron job sources it.

## mcp — MailD MCP server

- Image `pavelmc/maild-mcp:develop` from `mcp/Dockerfile`: stage 1 `node:26-alpine` builds the
  user SPA (`mcp/ui`, React 18 + Vite 5 + Tailwind 3 + i18next, pinned to the AdminNG versions;
  `npm run build` runs the EN/ES `i18n:check`), stage 2 `python:3.14-slim-trixie`, uid 10001,
  read-only rootfs + `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`. Design and decisions:
  `mcp/technical-proposal.md`; delivery status: `mcp/progress.md`.
- Routing (`mcp/app/asgi.py`, uvicorn `--lifespan on`): `/api/v1/mcp` → bearer wrapper → MCP SDK
  2.3 (`MCPServer`, stateless Streamable HTTP, JSON responses, Host/Origin allow-list);
  `/api/v1/mail/<tool>` → the same bearer checks → the REST mirror (`mcp/app/restapi`);
  `/api/v1/openapi.json` and `/api/v1/skill.md` → generated public documents; everything
  else → Django (`/healthz`, `/webapi/*` django-ninja, the SPA at `/` + `/confirm`, hashed assets
  under `/assets/` via WhiteNoise, cached immutable; `index.html` no-cache with a strict CSP).
  The lifespan also runs the jobs loop: IMAP pool sweep every 30 s, hourly jobs under a pg
  advisory lock (idle-PAT disable, expired pending addresses, ALTCHA/session cleanup, log
  retention); `manage.py mcp_jobs --once` runs them on demand.
- **MCP auth** (wrapper, proposal §8.2): 401 + `WWW-Authenticate: Bearer resource_metadata=…` for a
  missing/invalid/expired/idle token, 403 `mcp_disabled` when the account switch is off, 403
  `insufficient_scope` (+ `scope=`) when a `tools/call` names a tool outside the token's scopes
  (the JSON-RPC body is read, bounded at 4 MB, and replayed). Tools re-check the address chain
  per call (active in the account, inside the token's subset, mailbox active, domain allowed).
- **Read tools (P1)**: `list_accounts`, `list_folders`, `check_new_mail` (watermark handle),
  `search_emails` (filter `sender`, not `from`: the SDK cannot map a `from` keyword; cursor
  handle), `get_email` (marks `\Seen` unless `mark_read=false`; body wrapped in untrusted
  markers, HTML → text, 100 000 chars cap), `get_thread`, `get_attachment` (embedded resource,
  5 MB cap), `get_quota` (an unlimited mailbox reports no QUOTAROOT → `unlimited`). Handles are
  HMAC-signed and bound to the token. Reads use EXAMINE + `BODY.PEEK`.
- **IMAP**: STARTTLS to `mda:143` with the leaf certificate **pinned** to the first cert of
  `MCP_IMAP_CA_FILE` (no hostname/chain check: the cert is never issued for `mda`); master-user
  pool ≤ 3 connections per mailbox, idle close 60 s. Web logins use the user's own credentials.
- **Web API / user page**: ALTCHA v1 (single use), lockout 5 failures per email+IP → 15 min,
  login = IMAP check; 15-min access JWT in memory + `mdmcp_refresh` cookie (HttpOnly, Secure,
  SameSite=Strict, Path=/webapi) rotating, reuse of the superseded one revokes the session,
  24 h absolute. Secondary addresses: magic link (24 h, `MCP_PUBLIC_URL/confirm#token`, confirmed
  by an explicit POST), resend backoff 2^n min, D11 conflicts ("Already in use" + one postmaster
  notice per claimer/address/day), owner wins over a pending claim, a disabled secondary's own
  login is refused. PATs `mdmcp_pat_…` (HMAC-stored, scopes, optional address subset, 30 d /
  n days / forever, idle 30 d → disabled, re-enable only from the page).
- **Write tools (P2)**: `mark_emails`, `move_emails`, `create_folder`, `rename_folder`,
  `save_draft` (scope `mail.modify`); `report_spam`, `not_spam`, `trash_emails`,
  `restore_from_trash`, `delete_folder` (`mail.trash`) — the destructive ones are **two-step**:
  without `confirm` they return a preview + a handle (`mdmcp_cf_…`, `confirm_handle` table, HMAC
  stored, single use, 5 min, bound to token + tool + a digest of every other argument). No path
  expunges: spam/trash are MOVEs into the special-use folders (Junk moves fire imapsieve's Bayes
  learning through the master-user IMAP session), `delete_folder` only takes an empty, non-special
  folder.
- **Sending (P2)**: `send_email`, `reply_email`, `forward_email` (`mail.send`, filter/argument
  `sender`, not `from`) build the MIME message (`policy.SMTP`, generated `Message-ID`,
  `User-Agent: MailD-MCP/…`, `X-MailD-MCP-Token: <public id>`, signature preference) and submit it
  to `amavis:10026` (DKIM-signed by bank INTERNAL). Enforced by the MCP because the path skips
  Postfix: sender = a usable address of the caller; recipients per window per account AND per
  sender (`send_counter`, `MCP_SEND_RATE_RECIPIENTS`/`MCP_SEND_RATE_WINDOW`, logged as
  `maild-mcp: throttled`); `MAX_MESSAGESIZE` (the mta's variable). `Bcc` only on the envelope,
  kept in the Sent copy (APPEND `\Seen`; a failed APPEND is a warning, the send stands). Every
  send logs `maild-mcp: sent user=<addr> rcpts=<n> token=<id>` (counted by cron's
  `outbound_watch.sh`). Confirmation by preference: `always`, or `external` (default: any
  recipient outside the active domains + alias domains); `never` is not offered until the P3
  admin setting. Reply: default sender = the caller's address in Delivered-To/To/Cc, else the
  mailbox; `Re:`, In-Reply-To/References, quoted original. Forward keeps attachments unless told
  not to.
- **Preferences (P2)** `account.prefs`, `GET/PUT /webapi/user/prefs`: `confirm_send`,
  `default_sender`, `signature`, `hidden_folders` (never listed, searched, threaded, watched or
  touched; INBOX cannot be hidden), `allow_attachments`; `GET /webapi/user/activity` = the last
  50 audit actions of the account (per-request `bearer.access` records excluded).
- **Admin panel (P3)** at `/adminmcp` — a separate Vite entry (no admin code in the user page's
  chunks) over `/webapi/admin/*`. Sign-in = username + password + ALTCHA + a **6-digit code mailed
  to the admin address at every login** (10 min, 5 attempts; `otp_challenge`), lockout 5/15 min,
  72 h session (`MCP_ADMIN_SESSION_TTL`, refresh cookie `mdmcp_admin_refresh`, Path=/webapi/admin).
  Recovery link (30 min, neutral answer), password change (current + code), email change (codes to
  the old AND new address, checked together), CLI `manage.py mcp_admin_reset [--password …]`
  (revokes the admin sessions). Settings groups in the `setting` table (`mcpcore/settings_store.py`,
  validated, cached 2 s per worker; the panel's own reads bypass the cache): `logging` (on/off, 7 category switches, day/week/month
  rotation, retention), `user_policy` (token limits, idle ≤ 30 d, send limits, size ≤ the mta's
  `MAX_MESSAGESIZE`, `allow_external`, `force_confirm`, `allow_no_confirm`, magic-link/resend,
  `master_notify_user`), `service_email` (internal | external SMTP: host, port, none/STARTTLS/
  implicit, `verify_tls` opt-out (default on; off = encrypted but unauthenticated, with a UI
  warning), user, Fernet-encrypted write-only password; the Test button returns a step
  transcript). `mcpcore/policy.py` resolves the tunable values from `user_policy` on every access.
  Domains dual list (PUT = the allowed set). Logs viewer (`audit`/`access`/`errors`, filter).
- **Master tokens (P3, D7)** `mdmcp_mst_…`: admin-created, 24 h default, at most
  `MCP_MASTER_TOKEN_MAX_TTL` (7 d), never forever, optional source-CIDR allowlist, scopes,
  Active/Disabled/Revoked tabs. Every request names the mailbox in **`X-MailD-Act-As`** (400
  `act_as_required`; 403 `act_as_denied` for an inactive mailbox or a denied domain; 403
  `ip_not_allowed`). It ignores the owner's MCP switch, addresses and preferences (policy
  defaults apply), is rate-limited as `master:<id>`, and is **always audited** (the logging
  switches cannot silence it: `security/master_token_use` + the tool calls). Owner notice only when
  the admin enables `master_notify_user` (once per token and mailbox per day).
- **OAuth 2.1 (P4, D1)** for "Add custom connector" in Claude / ChatGPT: a 401 from
  `/api/v1/mcp` carries `WWW-Authenticate: Bearer resource_metadata=…` →
  `/.well-known/oauth-protected-resource[/api/v1/mcp]` (RFC 9728) →
  `/.well-known/oauth-authorization-server` (RFC 8414; issuer = `MCP_PUBLIC_URL`). Endpoints
  `/oauth/authorize|token|revoke|register`. Public clients only, PKCE **S256** required, `iss` in
  every authorization response (RFC 9207), access tokens audience-bound to `MCP_RESOURCE_URL`
  (RFC 8707). Clients: **CIMD** (the `client_id` is an https URL of a metadata document; fetch
  https-only, every resolved address must be public — loopback/private/link-local/CGNAT/mapped
  refused —, connects to the checked IP, 5 s, 64 KB, no redirects, cached 5 min–24 h) or
  **DCR** (RFC 7591, `mdmcp_dcr_…`, 20 per source IP per hour, shown as "unverified"). Redirect
  URIs: https, loopback http (any port at use, RFC 8252) or a private-use scheme; an unregistered
  one gets an error page, never a redirect. `/consent#<request>` (SPA) signs the user in, shows
  the client and where it returns, and lets the user narrow scopes and addresses. Codes
  `mdmcp_oac_…` 2 min single use; access `mdmcp_oat_…` `MCP_OAUTH_ACCESS_TTL` (1 h); refresh
  `mdmcp_ort_…` `MCP_OAUTH_REFRESH_TTL` (30 d, sliding), rotated on every use — presenting a
  rotated one revokes the whole grant (`security/oauth.refresh_reuse`). Grants are listed in the
  user's token list by client name ("app connection", revoke only); `/oauth/revoke` (RFC 7009)
  takes the whole grant for a refresh token. Tables `oauth_client`, `oauth_request`,
  `oauth_code`; `mcp_jobs` drops expired codes/requests and day-old expired access tokens.
- **REST mirror (P5)** `POST /api/v1/mail/<tool>`, JSON body = the MCP tool's arguments, 200 =
  its structured result (`get_attachment`: the file itself, with Content-Type and an RFC 6266
  filename). It calls the tools through the SDK's tool manager (`server.call_tool`, the Principal
  handed over in a context variable), so validation, authorization, two-step confirmations and
  audit are the MCP ones. Tokens: PATs and master tokens (`X-MailD-Act-As`) only; an OAuth access
  token gets 401 `wrong_audience` (it is bound to `/api/v1/mcp`, RFC 8707). Errors are JSON
  `{error, message[, retryable][, details]}`: 401 (`WWW-Authenticate: Bearer realm="MailD MCP
  REST"`, no OAuth discovery), 403 `insufficient_scope` / `forbidden` / `mcp_disabled`, 404
  `unknown_tool`, 405 non-POST, 400 `invalid_json` / `mail_error` / `confirmation_invalid` /
  `invalid_handle`, 422 `invalid_arguments` (`details` per field), 429 `rate_limited`, 413, 503
  `mail_unavailable` / `send_unavailable`. Tool failures carry their HTTP status in
  `CodedToolError` (MCP clients still only see the message). `/api/v1/openapi.json` (OpenAPI 3.1,
  one operation per tool, the tools' own JSON Schemas with `$defs` hoisted into
  `components.schemas`, scope per operation) and `/api/v1/skill.md` (Agent Skills frontmatter
  `name: maild-mail`, usage rules, the tool list) are generated from the tool list at first use.
  Audit: `bearer.access/rest` with the tool, then the tool's own record.
- **Connection help (P5)** on the user page: copy-ready settings built from the page origin for
  Claude and ChatGPT (connector URL, OAuth), Claude Code (`claude mcp add --transport http`, OAuth
  or PAT header), Gemini CLI (`httpUrl` + header), `mcp-remote` (stdio bridge) and REST + links to
  the OpenAPI and SKILL.md documents.
- **User notifications (P3)**, preferences `notify_new_token`, `notify_new_client` (first use of a
  token from a new IP/client pair), `notify_master_access`; mailed to the main address.
- **Service mail** (magic links, notices, admin codes) to `MCP_SMTP_HOST:MCP_SMTP_PORT` (amavis:10026, bank
  INTERNAL) or the admin's external SMTP as `MCP_SERVICE_EMAIL`, EN/ES, `Auto-Submitted: auto-generated`.
- **Logs**: JSON Lines `audit-/access-/errors-YYYY-MM-DD.log` in `MCP_LOG_DIR` (O_APPEND, 90 files
  kept); never passwords, tokens, codes, bodies or subjects.
- Domain allow-list (D6): `manage.py mcp_domains list|allow|deny <domain>` (audited) until the
  P3 panel; new catalogue domains start denied; the policy is read on every call, only the
  catalogue state is cached 30 s.
- Boot (`docker-entrypoint.sh` → `manage.py mcp_boot`): wait for the `maild_provision` sentinel
  (bounded by `PROVISION_WAIT_TIMEOUT`) → `migrate` under a pg advisory lock → seed the admin on
  first boot only (`MCP_ADMIN_USER/PASSWORD/EMAIL`; password generated and printed OTP-style when
  unset; ignored once a row exists) → ensure the service mailbox `MCP_SERVICE_EMAIL` (default
  `mcp@<DEFAULT_DOMAIN>`) through `maild_mcp_ensure_service_mailbox()`: created with an Argon2id
  hash of `MCP_SERVICE_PASSWORD` or a generated password (printed once), never modified when it
  exists (warning when inactive), boot fails on an unknown or inactive domain. Then `exec uvicorn`.
- DB: connects **only** as `MCP_DB_USER` (`maild_mcp`): `default` alias = `MCP_DB` (Django
  models), `catalogue` alias = `POSTGRES_DB` (raw read-only SQL through the column grants,
  never migrated — `maild_mcp/routers.py`).
- **No `env_file`** (decision 2026-10-29, `mcp/progress.md`): the operator file carries
  `POSTGRES_PASSWORD` and every other service's secrets, so the compose files pass an explicit
  allow-list — the three secrets with `:?` guards plus bare `MCP_*`/`POSTGRES_HOST/PORT/DB`/
  `PROVISION_WAIT_TIMEOUT` keys (passed through when set, unset otherwise so the image default
  applies). A new MCP tunable must be added to that list in all four compose files.
- Mounts: the log volume (`/var/log/maild-mcp`; dev `ldata/mcp_logs`, prepared `10001:10001` by
  `bootstrap-dev.sh`) and the certs read-only (`/certs/mail.crt` verifies mda's STARTTLS). Never
  the mail storage.
- Ports: dev publishes `8085:8080`; production has no published port, Traefik labels route
  `${MCP_HOSTNAME:-mcp.${DEFAULT_DOMAIN}}` to 8080 (TLS at the operator's ingress).
- `test.sh` J7–J11 (role grants, service mailbox, healthz), G4c (backup archive), G14b (MCP sends
  in the outbound alert), M1–M15 (write tools, confirmations, sending, preferences), N1–N10 + N7b
  (admin panel, master tokens, external SMTP via mta:587) and K1–K22
  (user side + read tools through the SDK client, `tests/mcp_call.py`); browser flows:
  `./adminng/pwa-test/run.sh mcp`; unit tests: `mcp/tests/test_units.py` (pytest, run in a
  throwaway container — command in `mcp/tests/conftest.py`).

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
- Mode `mcp` reuses the same image for the MailD MCP user page: the tunnel switches to
  `localhost:8085 → mcp:8080` (health `/healthz`) and only `tests/mcp/*.spec.ts` runs (the
  default gate ignores them). Fixtures via `docker exec` (`lib/mcp.ts`): the `mcp_domains` CLI,
  psql cleanup of the `example.net` MCP accounts, the magic link read with doveadm. The real
  ALTCHA widget solves in Chromium, so the CSP is exercised too.
