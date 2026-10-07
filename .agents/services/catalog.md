# Service Catalog

All services live on the compose network `maild-dev` (dev) / `maild` (production, external).
Service keys are the DNS aliases used everywhere in the config: `db`, `mta`, `mda`,
`amavis`, `clamav`, `admin`, `mua`, `cron` — never rename them.

## db — PostgreSQL catalogue

- Image: `pavelmc/maild-db:develop`, built from `db/Dockerfile` (see
  `.agents/devops/base-images.md` for the base-image rules and their current drift).
- Stores: domains, mailboxes, aliases, quotas — everything Postfix/Dovecot/Amavis query.
- `db/docker-entrypoint-wrapper.sh` starts the stock postgres entrypoint, waits for
  readiness (bounded) and then runs `db/ensure_databases.sh`, which creates any **missing**
  databases from `POSTGRES_DB` + `POSTGRES_EXTRA_DB` (comma-separated, e.g. `contacts`) on
  *every* boot. It never alters existing databases or the schema.
- env_file: `vars/db.env` (POSTGRES_HOST/DB/USER/EXTRA_DB), `vars/mua.env` (CTDB=contacts),
  `env.sample`. The password is passed explicitly: `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}`
  (compose does not interpolate `env_file:` contents; without it a fresh volume refuses to
  initialise).
- Port 5432 published for local debugging.

## clamav — antivirus

- Runs clamd; signatures download on first boot (~230 MB) into `ldata/clamav`. On a
  restricted network set `ALTERNATE_MIRROR` in `vars/clamav.env`.
- Port 3310 published for debugging (`nc -z localhost 3310` to probe).
- env_file: `vars/clamav.env`, `env.sample`.

## amavis — content filter

- Postfix hands mail to amavis:10024 and takes it back; amavis queries the catalogue for
  the domain list (that is why it needs `POSTGRES_PASSWORD`), scans with SpamAssassin +
  ClamAV, signs DKIM (`DKIM_SIGNING`), and bounces the result to `AMAVIS_MTA=mta`.
- Dev toggles `AV_ENABLED` / `SPAM_FILTER_ENABLED` come from compose interpolation
  (`env.dev`); quarantine lands in `ldata/amavis/virusmails/`.
- SpamAssassin config: shared `saconf` volume seeded on first boot; MailD tuning written to
  `/etc/spamassassin/maild.cf` from `vars/amavis.env` at every start. Extra `.cf` files can
  be dropped into the volume without a rebuild (reload/restart amavis).
- `amavis/sa-update-loop.sh` runs daily `sa-update` + reload.
- Waits (bounded) on the `maild_provision` sentinel before the DKIM section, so a fresh
  deploy comes up signed with no restart (`AUTO_PROVISION`).
- env_file: `vars/amavis.env`, `vars/db.env`, `env.sample`.

## mda — Dovecot

- IMAP/POP3/Sieve delivery; reads users/quotas from the catalogue via SQL
  (`mda/dovecot/dovecot-sql.conf.ext`), Maildir under `/home/vmail`.
- Instant Bayes learning: moving mail into/out of `Junk` triggers imapsieve pipe scripts
  (`mda/dovecot/sieve/*.sieve` → `mda/sieve-pipe/learn-{spam,ham}.sh`).
- `mda/scripts/quota_report.sh` mails the daily mailbox-quota report to
  `MAIL_ADMIN_USER@DEFAULT_DOMAIN`; knobs in `env.sample` (`QUOTA_REPORT_*`); run manually:
  `docker compose exec mda /scripts/quota_report.sh --now [--dry-run]`.
- `mda/configure.sh` (startup helper, invoked by the entrypoint) and `mda/sendmail.py`
  are part of the image.
- env_file: `vars/db.env`, `vars/mda.env`, `vars/ssl.env`, `env.sample`; password +
  `DEFAULT_DOMAIN`/`DEFAULT_MAILBOX_SIZE` passed explicitly at compose level.
- Ports: 110, 143, 993, 995 (POP3/IMAP + TLS) and 4190 (ManageSieve), 12345 (SASL).

## mta — Postfix

- SMTP 25, submission 587 (auth), SMTPS 465. SPF (`SPF_ENABLE`) and DNSBL (`DNSBL_ENABLE`,
  `DNSBL_LIST`) checks; `RELAY` / `ALWAYS_BCC` optional; max size `MAX_MESSAGESIZE`.
- Hard-depends on mda, amavis, clamav. Delivers local mail over LMTP to the mda's IP
  (baked into `main.cf` at start — restart the mta when the mda is recreated).
- Logs to stdout (`maillog_file = /dev/stdout`); the daily traffic resume parses a syslog
  with rsyslog-style stamps, which only exists in production (dev: `test.sh` phase G
  materialises one).
- Waits (bounded) on the `maild_provision` sentinel before building the `virtual_aliases`, so
  a fresh deploy comes up with them in place and no restart (`AUTO_PROVISION`).
- env_file: `vars/mta.env`, `vars/ssl.env`, `vars/db.env`, `env.sample`; `MAILADMIN`,
  `DEBUG` and the password passed explicitly.

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
- env_file: `vars/db.env`, `vars/admin.env`, `env.sample`; `POSTFIXADMIN_DB_PASSWORD` and
  `POSTFIXADMIN_SETUP_PASSWORD` passed explicitly at compose level.

## mua — SnappyMail

- Webmail on Apache; dev publishes 8081:80. The app is baked into the image at
  `/var/www/html`; **only** `/var/www/html/data` is persisted (`ldata/mua_web`, owned by
  `www-data` — bootstrap-dev.sh fixes the ownership and restarts mua).
- Writes the contacts DSN (db `contacts`) with `POSTGRES_PASSWORD` at start.
- Waits (bounded) on the `maild_provision` sentinel before building the SnappyMail
  per-domain configs, so a fresh deploy gets them with no restart (`AUTO_PROVISION`).
- env_file: `vars/db.env`, `vars/mua.env`, `env.sample`.

## cron — maintenance

- Runs `cron -f`; jobs in `cron/crontab` (UTC): traffic resume 01:10, maildir check
  02:13 monthly, Junk purge 03:00, Bayes learning 03:30, db backup 08:00 (scripts in
  `cron/scripts/`).
- Volumes: `ldata/logs:/var/log` (empty in dev — JSON logging), `ldata/vmail:/home/vmail`,
  `ldata/backups:/backups` (prod parity: without it `backup_db.sh` dumps into the
  container's writable layer and the dump vanishes on recreate).
- Shares the SpamAssassin bayes db with amavis (`ldata/spamassassin`).
- env_file: `vars/db.env`, `vars/amavis.env`, `env.sample`.

## dozzle — log viewer (dev only)

- `amir20/dozzle:latest` on 8082; live logs of all `maild-dev-*` containers via the
  read-only docker socket. Not part of production.
