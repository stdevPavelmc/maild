# Maintenance Cron (`cron`) for MailD

The `cron` container runs scheduled maintenance, security auditing, automated database backups,
SpamAssassin Bayes training, and junk folder purging for the MailD stack.

## Overview

The container executes scheduled jobs defined in `/etc/cron.d/maild` (crontab operates on UTC):

- **01:10 UTC — Daily traffic resume (`resume.sh`):**
  Parses mail logs using `pflogsumm` and sends a daily summary of sent/received/bounced traffic
  to the mail administrator.
- **02:13 UTC (Monthly, 1st) — Maildir integrity check (`maildir_check.sh`):**
  Scans user mailboxes for structure and permission consistency.
- **03:00 UTC — Junk folder purge (`purge_junk.sh`):**
  Permanently deletes messages older than `JUNK_RETENTION_DAYS` (default 7 days) from every
  user's `Junk` folder to keep mailbox storage bounded.
- **03:30 UTC — Daily Bayes batch learning (`learn_from_folders.sh`):**
  Trains SpamAssassin's Bayes classifier by learning remaining messages in Junk folders as spam
  and sampling random messages from users' INBOXes as ham (`SA_HAM_SAMPLE_PER_USER`, capped at `SA_HAM_SAMPLE_MAX`).
- **Hourly (:23) — Outbound submission volume watch (`outbound_watch.sh`):**
  Monitors authentication logs for outbound spikes exceeding `OUTBOUND_ALERT_MESSAGES` (default 150/day)
  and for MTA rate-limit throttle events (`maild-ratelimit: throttled`), emailing an alert to the administrator.
  Accounts in `OUTBOUND_ALERT_IGNORE_USERS` are excluded.
- **04:20 UTC — Public DNS health check (`check_dns.sh`):**
  Audits external DNS configuration for all active domains:
  - Domain delegation (NS and SOA records).
  - MX targets compared against `MX_HOSTNAME`.
  - SPF record syntax, terminal qualifier, and 10-lookup query limit.
  - DMARC presence, policy (`p=`, `sp=`), percentage (`pct=`), and aggregate report routing (`rua=`).
  - DKIM public DNS record byte-for-byte comparison against actual private keys in `/var/lib/amavis/dkim/`.
  - Reverse DNS (PTR / Forward-Confirmed reverse DNS) of sending MX IPs.
  - MTA-STS and TLS-RPT DNS records.
  - DNSBL / SURBL blocklists (`multi.surbl.org`, `zen.spamhaus.org`).
  - Emails findings to `DNS_CHECK_TO` (defaults to `postmaster@DEFAULT_DOMAIN`) only if findings meet or exceed `DNS_CHECK_ALERT_LEVEL` (default `warning`). Silent when healthy.
- **08:00 UTC — Automated database backups (`backup_db.sh`):**
  Uses `pg_dump` to create compressed backups:
  - `maild_backup_<date>.sql.gz`: Catalogue database (`mailddb`).
  - `maild_adminng_<date>.sql.gz`: AdminNG state database (`adminng`).
  - `maild_mcp_<date>.sql.gz`: MailD MCP database (`MCP_DB`, default `mcp`); skipped while that database is missing or empty.
  - Validates gzip archive integrity and prunes archives older than 15 days.

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/backups` | `ldata/backups` | Target directory for daily PostgreSQL database dumps |
| `/home/vmail` | `ldata/vmail` | User mailboxes for Junk purging and Bayes learning |
| `/var/lib/amavis` | `ldata/amavis` | Mounted **read-only** to compare DKIM keys during DNS audits |
| `/var/log` | `ldata/logs` | Mail log directory for traffic statistics and rate-limit auditing |

## Variables

Every tunable defaults inside the image (`cron/Dockerfile`). The operator file (`.env` in
production, `env.dev` in development) overrides any value. The container entrypoint exports
these variables shell-quoted into `/etc/environment` for cron jobs to source.

### Mandatory deployment variables
- `DEFAULT_DOMAIN`: Primary domain served by MailD.
- `MAIL_ADMIN_USER`: Local part for mail administrator.
- `POSTGRES_PASSWORD`: PostgreSQL catalogue password.

### Image defaults (overridable)
- `POSTGRES_HOST=db`: Database hostname.
- `POSTGRES_DB=mailddb`: Primary catalogue database name.
- `POSTGRES_USER=maild`: Database user.
- `ADMINNG_DB=adminng`: AdminNG database name to back up.
- `MTA=mta`: MTA hostname used by `swaks` for mail report delivery.
- `JUNK_RETENTION_DAYS=7`: Days before Junk messages are purged (`0` disables purge).
- `SA_HAM_SAMPLE_PER_USER=25`: Random ham messages sampled per mailbox during daily training.
- `SA_HAM_SAMPLE_MAX=400`: Maximum ham messages sampled globally per training run.
- `OUTBOUND_ALERT_MESSAGES=150`: Daily outbound message limit triggering admin alerts (`0` disables).
- `OUTBOUND_ALERT_IGNORE_USERS=`: Comma-separated addresses excluded from outbound alerts.
- `MX_HOSTNAME=`: Expected MX target hostnames (comma-separated; if unset, inferred from `DEFAULT_DOMAIN`).
- `DNS_CHECK_DOMAINS=`: Comma-separated list of domains to check (if unset, all active domains in catalogue; set to `none` to disable).
- `DNS_CHECK_TO=`: Recipient address for DNS health reports (defaults to `postmaster@DEFAULT_DOMAIN`).
- `DNS_CHECK_ALERT_LEVEL=warning`: Minimum severity triggering an alert email (`critical`, `warning`, or `notice`).
- `DNS_CHECK_RESOLVER=`: Custom DNS resolver IP (recommended to use a private recursive resolver).
- `DNS_CHECK_BLOCKLISTS=multi.surbl.org`: Domain blocklists to query.
- `DNS_CHECK_IP_BLOCKLISTS=zen.spamhaus.org`: IP blocklists to query.
- `DNS_CHECK_DKIM=auto`: Compare DKIM TXT record against Amavis private keys (`auto` or `no`).
- `DNS_CHECK_SPF_MX_COVERAGE=warning`: Severity if MX IPs are missing from SPF (`warning`, `notice`, or `off`).
- `DNS_CHECK_TIMEOUT=10`: Per-query DNS timeout in seconds.

## Operational commands

```bash
# Run database backup immediately
docker compose exec cron /scripts/backup_db.sh

# Run public DNS health check on-demand (dry-run to stdout)
docker compose exec cron /scripts/check_dns.sh --dry-run

# Run DNS check for specific domains without sending email
docker compose exec cron /scripts/check_dns.sh --domains example.com,test.com --dry-run

# Run daily Bayes learning manually
docker compose exec cron /scripts/learn_from_folders.sh

# Run Junk purge manually
docker compose exec cron /scripts/purge_junk.sh

# Run outbound volume audit manually
docker compose exec cron /scripts/outbound_watch.sh
```

> [!WARNING]
> Never change the container hostname from `cron` — the stack relies on this service for maintenance and reporting.

# Run daily Bayes learning manually
docker compose exec cron /scripts/learn_from_folders.sh

# Run Junk purge manually
docker compose exec cron /scripts/purge_junk.sh

# Run outbound volume audit manually
docker compose exec cron /scripts/outbound_watch.sh
```

> [!WARNING]
> Never change the container hostname from `cron` — the stack relies on this service for maintenance and reporting.

