# Content Filter (AMAVIS) — Amavisd-new for MailD

The `amavis` container acts as the central mail content inspection relay for MailD, combining
Amavisd-new, SpamAssassin, ClamAV antivirus integration, and automated DKIM signing.

## Overview

- **Mail flow:** Receives SMTP mail from Postfix (`mta:25` or `:587/:465`) on port 10024,
  performs content analysis, and reinjects clean or tagged mail back into Postfix on port 10025.
- **Catalogue synchronization:** Queries PostgreSQL (`db`) for active hosted domains so
  Amavis knows which recipients are local vs. relay.
- **Antivirus scanning:** Integrates with the `clamav` container over TCP port 3310 (`CONTSCAN`),
  scanning message bodies and attachments extracted into `/var/lib/amavis/tmp`.
- **Archive decoders:** Contains built-in decompressors (`bzip2`, `xz-utils`, `lrzip`, `lzop`,
  `lz4`, `rpm2cpio`, `7zip`, `unrar-free`, `cabextract`) allowing amavisd's `@decoders` table
  to extract and scan contents of compressed files instead of marking them `UNCHECKED`.
- **SpamAssassin & Bayes:** Runs SpamAssassin filtering. Tuning parameters are generated into
  `/etc/spamassassin/maild.cf` at startup. Operates on a shared Bayes database volume
  (`/var/lib/spamassassin`) fed by instant learning (Dovecot Junk moves), cron batch learning,
  and autolearn during scans.
- **Automated rule updates:** Runs a daily background daemon (`sa-update-loop.sh`) around
  02:50 UTC to pull updated SpamAssassin rules from `updates.spamassassin.org` and reload Amavis.
- **DKIM signing:** Generates 2048-bit RSA keys per domain in `/var/lib/amavis/dkim/<domain>.pem`
  and signs outbound messages. Prints the exact DNS TXT records to publish in container logs.
- **Quarantine:** Infected messages are quarantined in `/var/lib/amavis/virusmails/`.
- **First-boot provisioning gate:** Waits for the `maild_provision` database sentinel before
  generating DKIM keys and completing initialization.

## Ports

| Port  | Protocol | Description |
|-------|----------|-------------|
| 10024 | SMTP     | Amavis content filter listener (fed by Postfix) |

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/var/lib/amavis` | `ldata/amavis` | Temp workspace, DKIM keys (`dkim/`), and quarantined mail (`virusmails/`) |
| `/var/lib/spamassassin` | `ldata/spamassassin` | Shared SpamAssassin Bayes database (`bayes/`) |
| `/etc/spamassassin` | `saconf` | Shared volume for SpamAssassin rules and MailD custom configs |

## Variables

Every tunable defaults inside the image (`amavis/Dockerfile`). The operator file (`.env` in
production, `env.dev` in development) overrides any value.

### Mandatory deployment variables
- `POSTGRES_PASSWORD`: Password for the PostgreSQL catalogue.

### Image defaults (overridable)
- `POSTGRES_HOST=db`: Database service hostname.
- `POSTGRES_DB=mailddb`: Catalogue database name.
- `POSTGRES_USER=maild`: Catalogue database user.
- `MTA=mta`: MTA container hostname for reinjection.
- `CLAMAV=clamav`: ClamAV container hostname for AV scanning.
- `CRON=cron`: Cron maintenance container hostname.
- `SPAM_FILTER_ENABLED=yes`: Enable SpamAssassin spam scanning (`no` disables).
- `AV_ENABLED=yes`: Enable ClamAV antivirus scanning (`no` disables).
- `DKIM_SIGNING=yes`: Enable DKIM key creation and signing (`no` disables).
- `SA_AUTOLEARN_NONSPAM=0.1`: Spam score threshold below which messages autolearn as ham.
- `SA_AUTOLEARN_SPAM=10`: Spam score threshold above which messages autolearn as spam.
- `JUNK_RETENTION_DAYS=7`: Days before old spam messages in Junk folders are purged.
- `SA_HAM_SAMPLE_PER_USER=25`: Maximum random ham messages sampled per mailbox in daily batch learning.
- `SA_HAM_SAMPLE_MAX=400`: Global ceiling of sampled ham messages per daily learning run.
- `AUTO_PROVISION=yes`: Wait for catalogue provisioning sentinel at boot.
- `PROVISION_VERSION=1`: Sentinel schema version expected.
- `PROVISION_WAIT_TIMEOUT=180`: Seconds to wait for catalogue provisioning sentinel.

### Optional overrides
- `SA_BAYES_PATH`: Custom path to Bayes database (defaults to `/var/lib/spamassassin/bayes/db`).
- `SA_UPDATE_HOUR`: Hour (UTC) for daily `sa-update` run (default `2`).
- `SA_UPDATE_MINUTE`: Minute (UTC) for daily `sa-update` run (default `50`).
- `AMAVIS_DEBUG=1`: Enable debug output in Amavis logging.

## Operational commands

```bash
# Health check
docker compose exec amavis /check.sh

# View live Amavis logs
docker compose logs -f amavis

# Extract DKIM DNS records to publish
docker compose logs amavis | grep -A12 "DKIM / DNS config"

# Inspect DKIM keys directly
docker compose exec amavis ls -l /var/lib/amavis/dkim/

# Test DKIM signing key verification with amavisd
docker compose exec amavis amavisd-new testkeys
```

> [!WARNING]
> Never change the container hostname from `amavis` — other services in the stack rely on this hostname to route mail for content filtering.

# Inspect DKIM keys directly
docker compose exec amavis ls -l /var/lib/amavis/dkim/

# Test DKIM signing key verification with amavisd
docker compose exec amavis amavisd-new testkeys
```

> [!WARNING]
> Never change the container hostname from `amavis` — other services in the stack rely on this hostname to route mail for content filtering.

