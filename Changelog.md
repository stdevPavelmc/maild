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

## 2026-10-04 1.3.0-rc

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
