# Mail Delivery Agent (MDA) — Dovecot for MailD

The `mda` container runs Dovecot 2.4 and handles IMAP/POP3 mailbox access, Sieve filtering,
LMTP local delivery, SASL authentication for the MTA, and mailbox quota enforcement.

## Overview

- **Mailbox protocols:** IMAP (143/993), POP3 (110/995), and ManageSieve (4190).
- **Local delivery:** Dovecot LMTP receives filtered mail from Postfix and writes directly
  to Maildir storage under `/home/vmail/<domain>/<user>`.
- **Catalogue authentication:** Directly queries PostgreSQL (`db`) using SQL passdb and userdb
  lookups for credentials, active status, and mailbox quotas.
- **MTA services:**
  - SASL listener on `:12345` authenticates submission clients for Postfix.
  - Quota-status listener on `:12340` allows Postfix to enforce recipient quota policies at `RCPT TO` time.
- **Password schemes & migration (F-18):** Argon2id is the default hashing scheme. Legacy
  MD5-CRYPT (`$1$`) hashes coexist and are migrated automatically to Argon2id upon successful
  login via `scripts/rehash-password.sh`. Weak scheme support is date-gated and will be disabled
  on **2027-02-01**.
- **Instant SpamAssassin Bayes learning:** ImapSieve triggers scripts in `/usr/lib/dovecot/sieve-pipe/`
  whenever a user moves mail into (`learn-spam.sh`) or out of (`learn-ham.sh`) the `Junk` folder.
- **Daily quota reporting:** A background loop runs `/scripts/quota_report.sh` daily, emailing
  the administrator a summary of mailboxes exceeding the quota warning threshold.
- **Self-signed TLS generation:** Generates fallback self-signed certificates and DH parameters
  on first boot if none are mounted into `/certs`.

## Ports

| Port  | Protocol | Description |
|-------|----------|-------------|
| 110   | POP3     | Plaintext / STARTTLS POP3 |
| 143   | IMAP     | Plaintext / STARTTLS IMAP |
| 993   | IMAPS    | Implicit TLS IMAP |
| 995   | POP3S    | Implicit TLS POP3 |
| 4190  | Sieve    | ManageSieve protocol |
| 12345 | SASL     | Internal Dovecot auth socket for Postfix |

> [!NOTE]
> In production dockerfiles, only the encrypted ports (993, 995) and internal ports are exposed;
> plaintext POP3/IMAP ports are restricted.

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/certs` | `ldata/certs` | TLS certificates (`mail.crt`, `mail.key`, `dh.pem`) |
| `/home/vmail` | `ldata/vmail` | User mailboxes and Sieve scripts (owned by `5000:5000`) |

## Variables

Every tunable defaults inside the image (`mda/Dockerfile`). The operator file (`.env` in
production, `env.dev` in development) overrides any value.

### Mandatory deployment variables
- `DEFAULT_DOMAIN`: Primary domain served by this MailD instance.
- `MAIL_ADMIN_USER`: Local part for the mail administrator.
- `POSTGRES_PASSWORD`: Password for the PostgreSQL catalogue.

### Image defaults (overridable)
- `POSTGRES_HOST=db`: Database service hostname.
- `POSTGRES_DB=mailddb`: Catalogue database name.
- `POSTGRES_USER=maild`: Catalogue database user.
- `PASSWORD_SCHEME=argon2id`: Password hash scheme (`argon2id` recommended, `md5crypt` legacy).
- `DEFAULT_MAILBOX_SIZE=200M`: Fallback mailbox quota if none set in the database.
- `QUOTA_REPORT_HOUR=0`: Hour (UTC) to send the daily mailbox quota report.
- `QUOTA_REPORT_MINUTE=1`: Minute (UTC) to send the daily mailbox quota report.
- `COUNTRY=JM`, `STATE=Kingston`, `CITY=Kingston`, `ORG=MailD`, `OU=MailD`: Self-signed TLS certificate subject fields.

### Optional overrides
- `QUOTA_REPORT_THRESHOLD`: Percentage threshold to flag mailboxes in daily report (default 80).
- `QUOTA_REPORT_CRITICAL`: Critical percentage threshold in daily report (default 99).
- `QUOTA_REPORT_ONLY_WHEN_WARN`: Only send email when mailboxes exceed the threshold (default true).
- `QUOTA_REPORT_MAX_PER_SLOT`: Maximum mailboxes listed per threshold bracket.
- `QUOTA_REPORT_MAX_ATTEMPTS`: Retry attempts for report delivery if MDA is unavailable.
- `MDA_DEBUG_INIT=1`: Verbose container startup logging.
- `MDA_DEBUG_AUTH=1`: Verbose Dovecot authentication logging.
- `MDA_DEBUG_AUTH_PASSWORD=1`: Password mismatch debugging.
- `MDA_DEBUG_MAIL=1`: Mail storage and delivery debugging.
- `MDA_DEBUG_SSL=1`: SSL/TLS handshake debugging.

## Operational commands

```bash
# Health check
docker compose exec mda /check.sh

# View live Dovecot logs
docker compose logs -f mda

# Dovecot status and active connections
docker compose exec mda doveadm who

# Flush authentication cache
docker compose exec mda doveadm auth cache flush

# Run mailbox quota report on-demand (dry-run to stdout)
docker compose exec mda /scripts/quota_report.sh --now --dry-run

# Run and send mailbox quota report immediately
docker compose exec mda /scripts/quota_report.sh --now
```

> [!WARNING]
> Never change the container hostname from `mda` — other services in the stack rely on this hostname to route and deliver mail.
