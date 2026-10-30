# MailD docker version of the MailAD project but using a DB as backend

This project is inspired on [MailAD-Docker](https://github.com/stdevPavelmc/mailad-docker), that is also based on [Mailad](https://github.com/stdevPavelmc/mailad).

This is the docker version with a DB as a backend instead of a domain controler LDAP we have a [telegram group](https://t.me/MailAD_dev) to discuss the development, feel free to join.

## Getting started

The stack **provisions itself on the first boot** — no setup wizard, no manual domain
creation, no down/up cycle. Full, automated walk-through: **[INSTALL.md](./INSTALL.md)**.

TL;DR:

1. `cp env.sample .env` and set `DEFAULT_DOMAIN`, `MAIL_ADMIN_USER`, `POSTGRES_PASSWORD` and
   **`ADMINNG_SECRET_KEY`** (`openssl rand -hex 32`); `MAIL_ADMIN_PASSWORD` is optional —
   comment the line out and one is generated and printed in `docker compose logs api`.
2. Create the external `maild` network once (if it isn't already): `docker network create maild`.
   Pick the compose file for your case and start the stack:

   - **Docker Hub — preferred, general use (from the internet):**
     `docker compose -f docker-compose.yml pull`
     `docker compose -f docker-compose.yml up -d`
   - **GitHub `ghcr.io` — restricted countries (e.g. Cuba) / Docker Hub blocked:**
     `docker compose -f compose-github.yml pull`
     `docker compose -f compose-github.yml up -d`
   - **GitLab (own registry, with the shipped `.gitlab-ci.yml`):**
     `docker compose -f compose-gitlab.yml pull`
     `docker compose -f compose-gitlab.yml up -d`

3. Wait for `api: INFO - catalogue provisioned: domain=... admin=...` in `docker compose logs -f api`, then
   log in to AdminNG as `MAIL_ADMIN_USER@DEFAULT_DOMAIN`, approve the browser server-side and
   enroll TOTP, then create your users.

The webmail (`webmail.<DEFAULT_DOMAIN>`), AdminNG (`adminng.<DEFAULT_DOMAIN>`) and MailD MCP
(`mcp.<DEFAULT_DOMAIN>`) UIs are **not** published directly on production: front them with a reverse proxy / ingress
controller that terminates TLS (Traefik, Nginx, …) on the external `maild` network. The
stack ships **no** TLS for the web UIs.

Prefer to seed by hand? Set `AUTO_PROVISION=no` in `.env` and run
`docker compose exec api adminng.py --provision` once the stack is up.

## Services

To create a really dynamic setup we split the mail server in services:

- [**MTA** (Mail Transport Agent)](./mta/) this is the Postfix field, basically the reception and dispatching of mails to and from the mail server/users.
- [**MDA** (Mail Delivery Agent)](./mda/) This is the Dovecot field, this has to do with the users checking his mails from the mailbox, quotas, etc.
- [**AMAVIS** (Advanced filtering)](./amavis/) it comprises attachments, anti-virus, anti-spam, etc.
- [**ClamAV**](./clamav/) AV scanning solution
- [**Postgres DB**](./db/) this is the database to hold the user's data.
- [**AdminNG**](./adminng/) The administration UI: PWA frontend (`adminng`) + FastAPI (`api`) over the catalogue
- [**MUA**](./mua/) This is the mail user agent, aka: Webmail provided by [Snappy Mail](https://snappymail.eu/)
- [**Cron**](./cron/) This has to deal with scheduled tasks, backups, cleanups, statistics, etc.
- [**MCP**](./mcp/) MailD MCP: lets AI assistants (Claude, ChatGPT, Gemini CLI, Claude Code, …) read, organise and send the user's mail — MCP endpoint with OAuth, a REST mirror with OpenAPI and a SKILL.md, a user page and an admin panel (`mcp.<DEFAULT_DOMAIN>`)

Follow the links for each service to get details for each docker image.

Warning!: Under no circumstance change the name of the hostnames, it will break the setup.

## SpamAssassin: rule updates, learning & maintenance

The anti-spam stack (amavis container, SpamAssassin inside) has an automatic
lifecycle, no manual work is needed:

- **Rule updates**: the amavis container runs `sa-update` daily (~02:50 with
  jitter) from the `updates.spamassassin.org` channel and reloads amavisd after
  installing new rules. Logs go to the container's syslog output.
- **Shared config**: `/etc/spamassassin` is a shared docker volume (`saconf`)
  mounted on the amavis, cron and mda containers; it's seeded with the distro
  files on the first boot. The MailD tuning lives in `/etc/spamassassin/maild.cf`,
  regenerated at every container start; tune it via env vars (see `env.sample`).
  You can also drop extra `.cf` files there and every container will pick them up
  (no rebuild needed, only an amavis reload/restart).
- **Bayes database**: stored on the shared `spamassassin` volume
  (`/var/lib/spamassassin/bayes`) and fed from three sources:
    1. **Instant learning** (mda): moving a message into the `Junk` folder learns
       it as spam and moving one out of it learns it as ham (false positive
       correction). Done via Dovecot's imapsieve plugin + pipe helpers.
    2. **Daily batch** (cron, 03:30): all the remaining messages on the users'
       Junk folders are learned as spam, plus a small random sample of each
       user's INBOX as ham (never learning spam-flagged messages).
    3. **Autolearn** during normal scans, with the thresholds from the amavis env.
- **Junk purge** (cron, 03:00): messages older than `JUNK_RETENTION_DAYS` (7 by
  default) are deleted from every user's Junk folder, keeping the mailboxes small.
- **Weekly health report**: on Sundays the daily stats mail includes the Bayes
  counters (spam/ham/tokens), the spam/ham balance and the freshness of the
  rules channel, so a stalled update or a poisoned database is easy to spot.

Useful env vars (see `env.sample`, defaults baked in the amavis/cron images):
`JUNK_RETENTION_DAYS`,
`SA_HAM_SAMPLE_PER_USER`, `SA_HAM_SAMPLE_MAX`, `SA_AUTOLEARN_NONSPAM`,
`SA_AUTOLEARN_SPAM`, `SA_BAYES_PATH`, `SA_UPDATE_HOUR`, `SA_UPDATE_MINUTE`.

## Mailbox quota: daily fill report

The mda container mails the mail admin (`MAIL_ADMIN_USER@DEFAULT_DOMAIN`) a daily
report of the mailboxes that are close to filling up, so a full mailbox is spotted
before its owner starts losing mail:

- **When**: on the first tick past `QUOTA_REPORT_HOUR`:`QUOTA_REPORT_MINUTE`
  (00:01 by default) that has no report yet that day. A container started later in
  the day fires it on the first tick after the start. Both are read in container
  local time and the containers run UTC (no `TZ` is set in the stack), so that is
  UTC, the same convention the jobs in the cron container's `crontab` follow.
- **What**: only the mailboxes over `QUOTA_REPORT_THRESHOLD` (80% by default),
  grouped per domain and in 5% slots, worst first: critical (over
  `QUOTA_REPORT_CRITICAL`, 99% by default), then over 95%, 90%, 85% and 80%.
  Mailboxes under the threshold are not listed at all, and the ones without a
  quota limit (unlimited) are never reported, only counted in the summary.
- **Figures**: taken from dovecot itself (`doveadm quota get -A`), so they are
  exactly what the quota plugin enforces, and only active mailboxes are seen.
- **Delivery**: through dovecot's own LDA, the same path the per-user quota
  warnings use. A failed delivery is retried up to `QUOTA_REPORT_MAX_ATTEMPTS`
  times (5 by default) and then given up until tomorrow, so a broken delivery
  can't turn into a mail storm.

This complements the per-user quota warnings (`quota_warning` at 80%/95% in
`mda/dovecot/conf.d/90-quota.conf`): those tell *each user* about their own
mailbox when it crosses a limit, this one gives the *admin* the whole picture
every day, including the mailboxes that crossed a limit while nobody was looking.

It runs from `/scripts/quota_report.sh` inside the mda container, as a background
loop started by the entrypoint, so it never blocks dovecot and its output goes to
the container log. Handy commands:

```sh
# render the report on screen without mailing it
docker compose exec mda /scripts/quota_report.sh --now --dry-run

# mail it right away
docker compose exec mda /scripts/quota_report.sh --now
```

Useful env vars: `QUOTA_REPORT_HOUR`, `QUOTA_REPORT_MINUTE`,
`QUOTA_REPORT_THRESHOLD`, `QUOTA_REPORT_CRITICAL`, `QUOTA_REPORT_ONLY_WHEN_WARN`,
`QUOTA_REPORT_MAX_PER_SLOT`, `QUOTA_REPORT_MAX_ATTEMPTS`.

Note: a mailbox created with a quota of 0 in PostfixAdmin has *no* limit (dovecot
reports `-` for it), so it counts as unlimited and is never reported. Give such
mailboxes a real quota for them to show up in the report.

## Daily public-DNS health check

The cron container runs `check_dns.sh` daily at 04:20 UTC and reports what the
outside world sees for every active domain in the catalogue: delegation (NS/SOA),
MX (resolution, CNAME targets, private IPs, and the set declared in
`MX_HOSTNAME`), SPF (presence, terminal qualifier, syntax, the 10-DNS-lookup
budget, MX-IP coverage), DMARC (presence/inheritance, `p`/`sp`/`pct`, `rua`
routing), DKIM (the published selector vs. the key Amavis actually signs with),
PTR/forward-confirmed rDNS of the MX IPs, MTA-STS/TLS-RPT when published, and
domain/IP blocklists. Each finding is reported as *found → expected → impact →
action* and mailed to `postmaster@<DEFAULT_DOMAIN>` (aliased to the admin) only
when it reaches `DNS_CHECK_ALERT_LEVEL` (default `warning`): **silence means
healthy**, there is no daily "all good" mail. Read-only: it never touches mail
state. New knobs, all defaulted in the cron image: `MX_HOSTNAME` (unset ⇒ the
expected MX set is inferred from `DEFAULT_DOMAIN`, reported as a notice),
`DNS_CHECK_DOMAINS` (`none` disables the job), `DNS_CHECK_TO`, `DNS_CHECK_RESOLVER`
(public resolvers matching Spamhaus's `127.255.255.x` are reported as a notice,
never as a listing), `DNS_CHECK_BLOCKLISTS`, `DNS_CHECK_IP_BLOCKLISTS`,
`DNS_CHECK_DKIM`, `DNS_CHECK_ALERT_LEVEL`, `DNS_CHECK_SPF_MX_COVERAGE`,
`DNS_CHECK_TIMEOUT`. The job also takes `--dry-run` (print the report instead of
mailing it), `--domains`, `--mx-hostname` and `--fixture-dir`.

## SMTP security: local-part harvesting tarpit & outbound throttle

The `mta` enforces two security mitigation:

- **Local-part harvesting tarpit on :25** (F-07): external mail to your own
  domains pays a `SMTP_TARPIT_DELAY` (image default 2 s, `0` disables) before the
  `reject_unlisted_recipient` 550, and `smtpd_recipient_restrictions` was
  reordered so relay attempts and authenticated clients skip the DB lookups and
  the tarpit. Submission/smtps and the amavis reinjection override the list.
  The progressive error slowdown now fires correctly (`soft=10`/`hard=60`).
- **Per-user outbound submission throttle with a hard per-account exemption**
  (F-12): the `mta` entrypoint supervises `ratelimitd`, a policy daemon on
  loopback `12341`; `submission`/`smtps` defer (`450`) past
  `OUTBOUND_RATE_RECIPIENTS` (default 200 envelope recipients per user per
  `OUTBOUND_RATE_WINDOW`, default 1h; `0` disables).
  `OUTBOUND_RATE_EXEMPT_USERS` (e.g. `no-reply@`, `sysadmin@`) bypasses the
  throttle for notification senders. Fail-open by contract: a dead daemon stops
  no mail, but the mta healthcheck goes unhealthy and restart-loops it. The cron
  container gains `outbound_watch.sh`: it parses the production syslog for
  per-user submission volume and `maild-ratelimit: throttled` lines and mails
  the admin an `[ALERT]` past `OUTBOUND_ALERT_MESSAGES` (150/day/user, `0` =
  off), honouring `OUTBOUND_ALERT_IGNORE_USERS`, once per user per day. Port 25
  and the amavis reinjection stay unlimited by design (MX + internal paths).

## Password security: Argon2id hashing, rehash-on-login & weak-scheme deprecation

Mailbox and administrator passwords use **Argon2id** hashes by default
(`{ARGON2ID}$argon2id$v=19$m=65536,t=4,p=1$…`), the scheme PostfixAdmin's
catalogue writers and Dovecot's SQL passdb share. A new shared `PASSWORD_SCHEME`
knob (`argon2id` default, `md5crypt` legacy escape hatch) selects the scheme in
the admin, api, mda and mua images. Legacy `$1$` (MD5-CRYPT) hashes coexist and
**rehash-on-login**: `mda/scripts/rehash-password.sh`, wired as an
`imap-postlogin`/`pop3-postlogin` service, migrates a legacy `$1$` row to
Argon2id on the user's next successful IMAP/POP3 login. `adminng.py --legacy-hashes`
lists the rows still on legacy hashes, and the mda logs a startup warning with
the remaining count every boot.

**Weak-scheme (md5crypt) support ends stack-wide on 2027-02-01**, enforced at
runtime: `mda/docker-entrypoint.sh` date-gates `auth_allow_weak_schemes` on
every boot and the API refuses to boot with `PASSWORD_SCHEME=md5crypt` after the
deadline — from then legacy `$1$` hashes stop authenticating. Documented in
`env.sample`, `INSTALL.md`, `.agents/services/configuration.md` and
`adminng/doc/technical-draft.md` §3.1.

## Amavis: attachment decompressor helpers

The `amavis` image carries amavisd's decompressor helpers — `bzip2`,
`xz-utils`, `lrzip`, `lzop`, `lz4` and `rpm2cpio` — so `.bz2`/`.xz`/`.lzma`/
`.lrz`/`.lzo`/`.lz4`/`.rpm` attachments are extracted and scanned instead of
being flagged **UNCHECKED**. Package names differ from the binaries amavisd's
`@decoders` table calls: `xz` comes from `xz-utils` and `lz4c` is a symlink
shipped by the `lz4` package (neither has a same-named distro package).

## Installation & server setup

The installation, the first-boot provisioning, the first login, DKIM and the manual fallback
(`AUTO_PROVISION=no`) are all documented in **[INSTALL.md](./INSTALL.md)**.

# AdminNG — the next-generation admin interface (PWA)

MailD also ships **AdminNG**, a PWA-first administration UI (domains, accounts, aliases,
alias domains, administrators, devices and audit logs) with a zero-trust device model,
mandatory TOTP for superadmins, device-scoped WebAuthn (biometric) sign-in, and a full
audit trail:

- **Dev:** <http://localhost:8083> · **Production:** `https://adminng.<DEFAULT_DOMAIN>`
  through your ingress (Traefik labels are already in the production compose files).
- **LAN/phone (dev):** `https://<lan-ip>:8084` with the local CA — install
  `ldata/certs/adminng-ca.der` on the device first (see
  [`adminng/pwa/README.md`](adminng/pwa/README.md) §2.1).
- **First login:** the browser/phone registers itself by signing in (its state starts
  `PENDING`, device-scoped); a superadmin approves the browser from the server side:
  `docker compose exec api adminng.py --list-devices` then
  `--approve-device '<uuid>'`. Afterwards the superadmin enrolls an
  authenticator (QR) on the first login. The Android APK is built by
  `adminng/pwa/app-generate.sh` (see `adminng/README.md`).
- **New mandatory variable:** `ADMINNG_SECRET_KEY` (JWT signing + TOTP encryption,
  `openssl rand -hex 32`). Rotating it invalidates sessions and enrolled TOTP seeds.
- **Device trust & biometric sign-in:** approving a browser is device-scoped; a
  successful TOTP login arms a fixed `ADMINNG_REMEMBER_TTL` window (default 24 h)
  that skips the TOTP challenge on subsequent logins from that browser. A dismissible
  biometric (WebAuthn/passkey) enrollment prompt appears after the first login, and
  the PWA supports user-verified biometric sign-in and destructive-action re-auth.
- Design and roadmap: `adminng/doc/technical-draft.md` and `adminng/doc/plan.md`;
  operator how-to: `adminng/README.md`. PostfixAdmin was retired with the `admin` service:
  AdminNG is the only web administration UI, and MailD now owns the catalogue schema
  (`db/migrations/002_postfixadmin_catalogue.sql`).

# Contributing.

There are many ways to contribute:

- Review this documentation and fix typos, syntax errors, propose better sentences, etc.
- Propose translations for some of the .md files (Any langs, Spanish, German & French are the most commons, but any will work.)
- Test this setup on dev premises, spot and report/suqash bugs, propose new features/fixes, etc.
- Spread the word about it
- Join to the [telegram group](https://t.me/MailAD_dev) and give some feedback/kudos to the dev.
- Buy the dev a coffee/beer/beef/mouse/? see [this link to know how to send money to the dev](https://github.com/stdevPavelmc/mailad/blob/master/CONTRIBUTING.md#direct-money-donations) to keep it going!
