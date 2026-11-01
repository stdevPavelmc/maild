# Mail Transport Agent (MTA) — Postfix for MailD

The `mta` container runs Postfix 3.10 and handles inbound and outbound mail transfer,
client submission, recipient policy enforcement, and inter-service routing.

## Overview

- **Inbound / Outbound SMTP:** Listens on port 25 (SMTP), 465 (SMTPS), and 587 (Submission).
- **Catalogue integration:** Connects to PostgreSQL (`db`) for live virtual domains,
  mailboxes, aliases, and alias domains (including catch-all rewriting).
- **Authentication:** Delegates SASL authentication on ports 465/587 to Dovecot (`mda:12345`).
- **Quota status policy:** Checks mailbox quota at `RCPT TO` time against Dovecot (`mda:12340`),
  rejecting mail with 552 before accepting messages that would exceed quota limits.
- **Content filtering:** Hands mail off to Amavis (`amavis:10024`) for SpamAssassin and ClamAV
  scanning and DKIM signing, receiving scanned mail back on port 10025.
- **Delivery:** Routes scanned local mail to Dovecot via LMTP.
- **Anti-enumeration tarpit (F-07):** Delays rejecting unknown recipients on port 25 by
  `SMTP_TARPIT_DELAY` seconds, slowing down dictionary and harvesting attacks.
- **No AUTH on port 25 + SASL throttle (audit M-01):** the MX port never offers AUTH (only
  587/465 do); anvil caps AUTH commands per client IP (`SMTP_AUTH_RATE_LIMIT`) and connections
  on 587/465 (`SMTP_CONNECTION_RATE_LIMIT`), `mynetworks` exempt.
- **Outbound throttle (F-12):** Supervised internal `ratelimitd` daemon (`127.0.0.1:12341`)
  tracks submission recipient counts per authenticated user over `OUTBOUND_RATE_WINDOW`,
  deferring (`450`) once `OUTBOUND_RATE_RECIPIENTS` is reached. Accounts in
  `OUTBOUND_RATE_EXEMPT_USERS` bypass the throttle.
- **Peer IP watchdog:** Background loop resolves and tracks IP changes for `amavis`, `mda`,
  and `mua`, updating Postfix configurations and reloading seamlessly when containers restart.
- **First-boot gate:** Synchronizes with the `maild_provision` database sentinel to ensure
  the catalogue and default aliases exist before finalizing virtual alias maps.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 25   | SMTP     | Public mail exchange (MX) |
| 465  | SMTPS    | Implicit TLS mail submission (authenticated) |
| 587  | Submission | STARTTLS mail submission (authenticated) |

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/certs` | `ldata/certs` | TLS certificate (`mail.crt`) and private key (`mail.key`) |
| `/home/vmail` | `ldata/vmail` | Mail storage volume (owned by `5000:5000`) |
| `/var/spool` | `ldata/spool` | Postfix mail queue spool |

## Variables

Every tunable defaults inside the image (`mta/Dockerfile`). The operator file (`.env` in
production, `env.dev` in development) overrides any value.

### Mandatory deployment variables
- `DEFAULT_DOMAIN`: Primary domain served by this MailD instance (e.g. `example.com`).
- `MAIL_ADMIN_USER`: Local part for the mail administrator (e.g. `sysadmin`).
- `POSTGRES_PASSWORD`: Password for the PostgreSQL catalogue.

### Image defaults (overridable)
- `POSTGRES_HOST=db`: Database service hostname.
- `POSTGRES_DB=mailddb`: Catalogue database name.
- `POSTGRES_USER=maild`: Catalogue database user.
- `MAX_MESSAGESIZE=34865152`: Maximum message size in bytes (~25 MB; formula `1024 * 1024 * MB * 1.33`).
- `SPF_ENABLE=True`: Enable SPF policy checks via `policyd-spf`.
- `DNSBL_ENABLE=true`: Enable DNS-based blackhole list checks.
- `DNSBL_LIST=zen.spamhaus.org=127.0.0.[2..11]*2,psbl.surriel.com,bl.spamcop.net,bl.spameatingmonkey.net`: Comma-separated DNSBL list.
- `SMTP_TARPIT_DELAY=2`: Seconds to sleep before rejecting unknown recipients on port 25 (`0` disables).
- `SMTP_AUTH_RATE_LIMIT=60`: AUTH commands per client IP per minute (`smtpd_client_auth_rate_limit`, `0` disables).
- `SMTP_CONNECTION_RATE_LIMIT=60`: Connections per client IP per minute on 587/465 only (`0` disables).
- `OUTBOUND_RATE_RECIPIENTS=200`: Maximum outbound recipients per user per rate window (`0` disables).
- `OUTBOUND_RATE_WINDOW=3600`: Outbound rate limit window in seconds (default 1 hour).
- `OUTBOUND_RATE_EXEMPT_USERS=`: Comma-separated addresses exempt from outbound rate limiting (e.g. `no-reply@example.com`).
- `PEER_WAIT_TIMEOUT=120`: Seconds to wait at boot for peer services (`amavis`, `mda`) to resolve.
- `PEER_WATCH_INTERVAL=30`: Seconds between peer IP watchdog checks (`0` disables).
- `AMAVIS=amavis`: Amavis content filter container hostname.
- `MDA=mda`: Dovecot MDA container hostname.
- `MUA=MUA`: Webmail container hostname.
- `AUTO_PROVISION=yes`: Await sentinel row written by `api` seeder before map configuration.
- `PROVISION_VERSION=1`: Sentinel schema version expected.
- `PROVISION_WAIT_TIMEOUT=180`: Seconds to wait for catalogue provisioning sentinel.

### Optional overrides
- `RELAY`: Upstream relay / smart host (e.g. `[smtp.relay.net]:587`).
- `ALWAYS_BCC`: Address to receive hidden carbon copies of all inbound/outbound mail.
- `POSTMASTER_ABUSE_SETUP=true`: Point domain postmaster and abuse aliases to the administrator.
- `DEBUG=true`: Dumps the generated virtual alias mapping file at boot.
- `MTA_DEBUG=1`: Verbose logging in Postfix daemon processes.

## Operational commands

```bash
# Check Postfix health / status
docker compose exec mta /check.sh

# View Postfix live mail logs
docker compose logs -f mta

# Inspect the mail queue
docker compose exec mta mailq

# Flush the mail queue
docker compose exec mta postfix flush

# Reload configuration
docker compose exec mta postfix reload
```

> [!WARNING]
> Never change the container hostname from `mta` — other services in the stack rely on this hostname to route mail.

# Inspect the mail queue
docker compose exec mta mailq

# Flush the mail queue
docker compose exec mta postfix flush

# Reload configuration
docker compose exec mta postfix reload
```

> [!WARNING]
> Never change the container hostname from `mta` — other services in the stack rely on this hostname to route mail.

