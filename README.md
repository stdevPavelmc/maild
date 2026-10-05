# MailD docker version of the MailAD project but using a DB as backend

This project is inspired on [MailAD-Docker](https://github.com/stdevPavelmc/mailad-docker), that is also based on [Mailad](https://github.com/stdevPavelmc/mailad).

This is the docker version with a DB as a backend instead of a domain controler LDAP we have a [telegram group](https://t.me/MailAD_dev) to discuss the development, feel free to join.

## Getting started

The stack **provisions itself on the first boot** — no `/setup.php`, no manual domain
creation, no down/up cycle. Full, automated walk-through: **[INSTALL.md](./INSTALL.md)**.

TL;DR:

1. `cp env.sample .env` and set `DEFAULT_DOMAIN`, `MAIL_ADMIN_USER`, `MAIL_ADMIN_PASSWORD`
   and `POSTGRES_PASSWORD`.
2. Pick the compose file for your case and start the stack:

   - **Docker Hub — preferred, general use (from the internet):**
     `docker compose -f docker-compose.yml up -d`
   - **GitHub `ghcr.io` — restricted countries (e.g. Cuba) / Docker Hub blocked:**
     `docker compose -f compose-github.yml up -d`
   - **GitLab (own registry, with the shipped `.gitlab-ci.yml`):**
     `docker compose -f compose-gitlab.yml up -d`

3. Wait for `seed: catalogue provisioned: ...` in `docker compose logs -f admin`, then log in
   to PostfixAdmin as `MAIL_ADMIN_USER@DEFAULT_DOMAIN` and create your users.

The webmail (`webmail.<DEFAULT_DOMAIN>`) and admin (`mailadmin.<DEFAULT_DOMAIN>`) UIs are
**not** published directly on production: front them with a reverse proxy / ingress
controller that terminates TLS (Traefik, Nginx, …) on the external `maild` network. The
stack ships **no** TLS for the web UIs.

Prefer the classic manual setup (OTP + `/setup.php`)? Set `AUTO_PROVISION=no` in `.env`.

## Services

To create a realy dynamic setup we split the mail server in services:

- [**MTA** (Mail Transport Agent)](./mta/) this is the Postfix field, basically the reception and dispatching of mails to and form the mail server/users.
- [**MDA** (Mail Delivery Agent)](./mda/) This is the Dovecot field, this has to do with the users checking his mails from the mailbox, quotas, etc.
- [**AMAVIS** (Advanced filtering)](./amavis), it comprises attachments, anti-virus, anti-spam, etc.
- [**ClamAV**](./clamav/) AV scanning solution
- **Postgres DB** this is the database lo hold the users data.
- [**PostfixAdmin**](./admin/) This is a simple Web Management interface
- [**MUA**](./mua/) This is the mail user agent, aka: Webmail provided by [Snappy Mail]()
- [**Cron**](./cron/) This has to deal with scheduled tasks, backups, cleanups, statistics, etc.

Follow the links for each service to get details for each docker image.

Warning!: Under no cirscuntance change the name of the hostnames, it will break the setup.

## SpamAssassin: rule updates, learning & maintenance

The anti-spam stack (amavis container, SpamAssassin inside) has an automatic
lifecycle, no manual work is needed:

- **Rule updates**: the amavis container runs `sa-update` daily (~02:50 with
  jitter) from the `updates.spamassassin.org` channel and reloads amavisd after
  installing new rules. Logs go to the container's syslog output.
- **Shared config**: `/etc/spamassassin` is a shared docker volume (`saconf`)
  mounted on the amavis, cron and mda containers; it's seeded with the distro
  files on the first boot. The MailD tuning lives in `/etc/spamassassin/maild.cf`,
  regenerated at every container start; tune it via env vars on `vars/amavis.env`.
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
    3. **Autolearn** during normal scans, with the thresholds on `vars/amavis.env`.
- **Junk purge** (cron, 03:00): messages older than `JUNK_RETENTION_DAYS` (7 by
  default) are deleted from every user's Junk folder, keeping the mailboxes small.
- **Weekly health report**: on Sundays the daily stats mail includes the Bayes
  counters (spam/ham/tokens), the spam/ham balance and the freshness of the
  rules channel, so a stalled update or a poisoned database is easy to spot.

Useful env vars (see `vars/amavis.env`): `JUNK_RETENTION_DAYS`,
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

## Installation & server setup

The installation, the first-boot provisioning, the first login, DKIM and the manual fallback
(`AUTO_PROVISION=no`) are all documented in **[INSTALL.md](./INSTALL.md)**.

# Contributing.

There are many ways to contribute:

- Review this documentation and fix typos, syntax errors, propose better sentences, etc.
- Propose translations for some of the .md files (Any langs, Spanish, German & French are the most commons, but any will work.)
- Test this setup on dev premises, spot and report/suqash bugs, propose new features/fixes, etc.
- Spread the word about it
- Join to the [telegram group](https://t.me/MailAD_dev) and give some feedback/kudos to the dev.
- Buy the dev a coffee/beer/beef/mouse/? see [this link to know how to send money to the dev](https://github.com/stdevPavelmc/mailad/blob/master/CONTRIBUTING.md#direct-money-donations) to keep it going!
