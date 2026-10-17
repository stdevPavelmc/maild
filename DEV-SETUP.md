# Local Development Setup

This guide explains how to set up the mail system for local development.

## Quick Start

1. **Ensure you have the required configuration:**
   ```bash
   # env.dev: the dev operator env file — compose interpolation AND the containers'
   #          env_file; carries the deployment values + fake, committed dev secrets
   #          (the real local/production passwords in .env are never used by the dev
   #          stack). Every tunable defaults inside the images (ENV in the Dockerfiles).
   cat env.dev
   # env.sample: the production operator env file template (.env)
   cat env.sample
   ```

2. **Create the local data directory:**
   ```bash
   mkdir -p ldata/{db,vmail,spool,clamav,amavis,spamassassin,mua_web,logs,certs,dozzle,backups}
   ```

3. **Generate self-signed certificates (if needed):**
   ```bash
   # Create self-signed certificates for local testing
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout ldata/certs/mail.key \
     -out ldata/certs/mail.crt \
     -subj "/C=JM/ST=Kingston/L=Kingston/O=MailD/OU=Dev/CN=mail.localhost"

   # Generate DH parameters for Postfix
   openssl dhparam -out ldata/certs/RSA2048.pem 2048
   ```

4. **Start the development environment:**
   ```bash
   # --env-file env.dev is mandatory for every command that creates containers (`up`,
   # `build`): without it compose interpolates from .env (the real secrets) and the db
   # password drifts from the one the volume was initialised with.
   docker compose --env-file env.dev -f docker-compose-dev.yml up -d
   ```

5. **Watch the logs:**
   ```bash
   # All services
   docker compose --env-file env.dev -f docker-compose-dev.yml logs -f

   # Specific service
   docker compose --env-file env.dev -f docker-compose-dev.yml logs -f mta
   ```

## One-Command Bootstrap (dev data)

`bootstrap-dev.sh` provisions a (running or stopped) dev stack with usable data, verifies it and
refuses to run against anything but `docker-compose-dev.yml`:

```bash
./bootstrap-dev.sh                         # example.net + the env.dev DEFAULT_DOMAIN; credentials in test.creds
./bootstrap-dev.sh --skip-default-domain   # example.net (or --domain) with users only
./bootstrap-dev.sh --help                  # every option (--domain, --users, --skip-default-domain, …)
```

What it does, idempotently (a second run re-asserts the same state and changes nothing else):

- ensures `db admin mda mta mua cron` are up (`cron` because the amavis entrypoint refuses to
  start without its IP, and amavis sits in the MTA delivery path), waits for Postgres, for the
  PostfixAdmin schema (the `admin` container creates it on boot) and for the web UIs — every wait
  is bounded;
- refuses to run when the stack was created with different secrets than `env.dev` (e.g. a plain
  `docker compose up` without `--env-file`): Postgres only honours `POSTGRES_PASSWORD` on first
  init, so the remedy is always `down` → `rm -rf ldata/` → re-run (dev data is disposable);
- provisions **`DEFAULT_DOMAIN` from `env.dev`** (e.g. `chagod.software`): the `MAIL_ADMIN_USER`
  mailbox — also the PostfixAdmin **superadmin** of the deployment (README *Setup Instructions*) —
  and its default aliases (skip this whole part with `--skip-default-domain`);
- provisions **`example.net`** with `alice`, `bob`, `charlie`, `dylan`, the default aliases
  (`postmaster`, `abuse`, `hostmaster`, `webmaster` → `alice@example.net`) and **alice as the
  domain admin** of `example.net` in PostfixAdmin;
- repairs the ownership of the fresh bind mounts (`ldata/vmail` → uid/gid 5000, `ldata/mua_web` →
  `www-data`, both are created root-owned by docker) and restarts `mua` so SnappyMail regenerates
  its per-domain config;
- restarts `mta` when a peer container changed address: the MTA writes the MDA's IP into
  `main.cf` at start (`virtual_transport = lmtp:inet:<ip>:24`) and would otherwise deliver to a
  dead address while reporting `unhealthy`;
- waits (bounded, `WAIT_CLAMAV`) for the first ClamAV signature download — with AV enabled
  amavis defers every message until `clamd` has a database (~230 MB the first time, minutes on a
  slow link). `--skip-clamav-wait` opts out;
- restarts `amavis` when a provisioned domain still has no DKIM key: amavis builds the keys for
  the domains it sees at its own start, so a domain created afterwards would go out unsigned;
- writes **`test.creds`** (git-ignored, mode `0600`) with every password and then verifies them:
  an IMAP login for each mailbox plus a real PostfixAdmin web login (302 → `main.php`).

The *same* password works over IMAP/SMTP and in the PostfixAdmin UI: `admin/docker-entrypoint.sh`
hashes with `md5crypt` and Dovecot verifies `MD5-CRYPT`, which is the same `$1$…` format.

Delete `test.creds` (or run `./bootstrap-dev.sh --rotate-creds`) to get fresh passwords.

## Automated Test Suite (`test.sh`)

`test.sh` is a black-box acceptance suite for the running stack. It reads the passwords from
`./test.creds`, drives the SMTP/IMAP/POP3/Sieve ports and asserts on the mailboxes (through
`doveadm`) and on the content-filter quarantine:

```bash
./test.sh                  # everything
./test.sh --skip-content   # skip the AV / SPAM / banned-filter checks
./test.sh --skip-quota     # skip the (self-cleaning) quota fixture
./test.sh --skip-docker    # only wire-level checks (no `docker compose exec` assertions)
```

- 67 checks: mail-path container health, SMTP policy (25/465/587, the two open-relay negatives, spoofing, size limit), TLS/AUTH,
  aliases and plus-addressing, IMAP/POP3 read-back, content filters, mailbox quota, Sieve redirect,
  DKIM, the deployment domain, the AdminNG catalogue API (login, CRUD, IMAPS login of the
  API-created mailbox, suspension and tenant isolation), the cron jobs (the daily database
  backup, the daily mail traffic resume and the daily Bayes learning) and the SpamAssassin
  maintenance chain (the imapsieve learning trigger and the `sa-update` loop).
- The two open-relay negatives complement each other: `A8` targets the reserved, **non-resolvable**
  `.example` TLD (stopped by `reject_unknown_recipient_domain`), while `F3a` targets
  `RELAY_PROBE_DOMAIN` (`example.com` by default) — resolvable but not hosted here, so it is what
  actually exercises `reject_unauth_destination`.
- The deployment domain (`DEFAULT_DOMAIN` from `env.dev`) is asserted adaptively by `F3b`:
  `bootstrap-dev.sh` provisions it, so mail for `<MAIL_ADMIN_USER>@<DEFAULT_DOMAIN>` on port 25 must
  be **accepted and delivered**; after `bootstrap-dev.sh --skip-default-domain` the MTA does not host
  it and the same message must be **refused as a relay** (swaks exit 24, "no RCPTs accepted").
- The cron-job phase (`G`) runs the real scripts instead of mocking them: `backup_db.sh` is
  executed and its archive validated (including the two failure paths — an aborting `pg_dump`
  and a client older than the server), and the daily traffic resume is triggered and its report
  read back out of the admin's mailbox. Since dev has no syslog for that job to parse, the phase
  materialises one (see *Logging* below) and asserts the report carries **real** traffic rather
  than the blank, all-zeroes one pflogsumm emits for an empty log.
- The SpamAssassin maintenance phase (`H`) covers the rules refresh, which is **not** a cron job:
  `amavis/sa-update-loop.sh` (started by the amavis entrypoint) runs `sa-update` daily at
  `SA_UPDATE_HOUR:SA_UPDATE_MINUTE` and HUPs amavisd. It asserts the loop is alive, that the
  rules it maintains actually load (`spamassassin --lint`, with the `.pre` set matching the
  installed major — a distro jump that ships `v3*.pre` under SpamAssassin 4.x is the failure it
  catches) and, when the channel is reachable, runs the fetch itself (`rc` 0 = rules installed,
  4 = nothing new; any other rc with the channel reachable fails).
- The imapsieve check (`F4`) drives a real IMAP COPY into Junk — imapsieve is an IMAP plugin, so
  `doveadm move` would not trigger it — and proves the "instant learning" pipe ran through the
  state its vmail-user `sa-learn` helper leaves under `/tmp` (`uid 5000`), then expunges the copy.
  The Bayes learning cron job (`G11`) is executed **twice** against the live folders to prove it
  survives empty Junk folders and releases its lock; the summary it logs is captured through an
  injected `logger` (the container has no `/dev/log`), so the counters are visible as output.
- Overridable from the environment: `DOMAIN`, `ADMINMAIL`, `PASS`, `SERVER`, `FROM`,
  `RELAY_PROBE_DOMAIN`.
- Self-cleaning: the quota fixture (`bob@…`), any sieve script it installs, the message it
  copies into Junk for the imapsieve check (plus the `sa-learn` state that run leaves in the
  container) and the `/var/log/syslog` it materialises inside the cron container are
  restored/removed on exit, whatever the outcome; every swaks transcript is appended to
  `./test.log`.
- The content-filter checks need AV/SpamAssassin (on by default in `env.dev`) and, for AV, the
  first ClamAV signature download to have landed — `bootstrap-dev.sh` waits for it.

What the content checks assert, given the shipped policies:

- EICAR (`$final_virus_destiny = D_DISCARD`): accepted, discarded, quarantined under
  `ldata/amavis/virusmails/` and no NDR. It travels as an *attachment*: clamd only matches a
  byte-exact EICAR file, not the string reflowed into a message body.
- GTUBE (`$final_spam_destiny = D_PASS`): SpamAssassin scores it ~999 and amavis quarantines it
  as spam (a `spam-*` entry); with `D_PASS` nothing changes at the SMTP level.
- `.exe` attachments: banned by `$banned_filename_re`, discarded like a virus.
- Quota: `bob@…` is limited to 5 MB and filled from the other mailboxes; the 80 %/95 %
  `quota_warning` mails are checked in his INBOX, the MTA refuses further mail at RCPT
  (`552 Mailbox is full`, through the dovecot quota-status policy) and over-quota submissions
  bounce back with an NDR.

## AdminNG frontend: browser suite and Lighthouse

The PWA has its own gates on top of `test.sh` (plan.md Phase 3). They run in the dev-only
`pwa-test` container — no host Node, Chromium or `npx playwright install` is needed:

```bash
cd adminng/pwa && npm run i18n:check     # en/es keys, placeholders, empty values (in `npm run build`)
./adminng/pwa-test/run.sh verify         # Playwright flows + installability + Lighthouse budget
./adminng/pwa-test/run.sh visual         # PNG screenshots (desktop/mobile, EN/ES) under ldata/e2e/screens
./adminng/pwa-test/run.sh a11y           # axe-core WCAG 2.1 A/AA audit under ldata/e2e/a11y
```

- The harness approves its own device with `adminng.py --approve-device` inside the api
  container (it mounts the docker socket), so `bootstrap-dev.sh` must have run. The UI path
  (devices panel, re-auth + armed authorize) is covered by `run.sh superadmin`.
- Reports: `ldata/e2e/report/` (Playwright HTML), `ldata/e2e/results/` (traces/videos on
  failure), `ldata/e2e/screens/` and `ldata/e2e/lighthouse.report.{json,html}`.
- Lighthouse gates performance ≥ 0.85, accessibility ≥ 0.9 and best-practices ≥ 0.9. SEO is
  reported only: `public/robots.txt` disallows crawling the private panel on purpose.
- CI: `.github/workflows/pwa-e2e.yml`, manual dispatch (it builds ten images, ~30 min).


## Differences from Production

The `docker-compose-dev.yml` configuration includes several changes optimized for local development:

### Configuration
- Uses `env.dev` for **both** compose interpolation and the containers' `env_file:` —
  fake, committed dev secrets over the image `ENV` defaults (baked in each Dockerfile).
  The git-ignored `.env` (real local/production passwords) is never read by the dev
  stack (see `./bootstrap-dev.sh` for a one-command setup)
- Fixed image names: `pavelmc/maild-*:develop`
- Network: Local bridge network `maild-dev` (not external)
- Restart policy: `unless-stopped` instead of `always`

### Volumes
- All data stored in local `./ldata/` directory
- Easier to inspect, backup, and clean up
- No Docker named volumes

### Logging
- JSON logging to stdout (default Docker logging)
- No syslog driver (easier to view with `docker compose logs`)
- Consequence: nothing ever writes into `ldata/logs/`, so the cron jobs that parse
  `/var/log/syslog` find an empty directory in dev — `resume.sh` (the daily mail traffic
  resume) still runs and still exits 0, but mails an all-zeroes report. Production avoids that
  by binding the host `/var/log` into the cron container *and* logging through Docker's syslog
  driver; `test.sh` phase G works around it by materialising a syslog out of
  `docker compose logs mta`, prefixed with the rsyslog-style stamp the script's date filter
  needs, and removes it again on exit.

### Exposed Ports
All services expose debugging ports:

| Service | Port(s) | Description |
|---------|---------|-------------|
| db      | 5432    | PostgreSQL database |
| admin   | 8080    | PostfixAdmin web interface |
| mua     | 8081    | Webmail interface |
| mda     | 110, 143, 993, 995, 4190, 12345 | Dovecot (POP3, IMAP, IMAPS, POP3S, ManageSieve, SASL) |
| mta     | 25, 465, 587 | Postfix (SMTP, SMTPS, Submission) |
| clamav  | 3310    | ClamAV antivirus |
| amavis  | 10024   | Amavis content filter |
| dozzle  | 8082    | Live log viewer (web) |

### No Traefik
- No Traefik reverse proxy labels
- Access services directly via exposed ports

## Accessing Services

- **Webmail:** http://localhost:8081
- **Webmail admin panel:** http://localhost:8081/​?admin — login `maild`, password = the OTP the
  mua container prints at boot (`docker compose logs mua | grep -A3 'admin panel'`)
- **Mailbox password change:** from the webmail itself (Settings → Password) — the `change-password`
  plugin and the MailD catalogue driver ship with the image, as do the X-Originating-IP header and
  TOTP two-factor plugins (`MUA_PLUGINS`), installed on every boot
- **Admin Interface:** http://localhost:8080
- **Database:** localhost:5432
  - User: `maild`
  - Database: `mailddb`
  - Password: `POSTGRES_PASSWORD` from `env.dev`

## Useful Commands

### Build Images
```bash
docker compose --env-file env.dev -f docker-compose-dev.yml build
```

### Stop Services
```bash
docker compose --env-file env.dev -f docker-compose-dev.yml down
```

### Clean Up (Remove all data)
```bash
# Stop and remove containers
docker compose -f docker-compose-dev.yml down

# Remove local data
sudo rm -rf ldata/
```

### Restart a Single Service
```bash
docker compose --env-file env.dev -f docker-compose-dev.yml restart mta
```

### Shell into a Container
```bash
docker compose --env-file env.dev -f docker-compose-dev.yml exec mta bash
```

### View Container Resource Usage
```bash
docker stats
```

## Testing Email Flow

1. **Send a test email:**
   ```bash
   # Using swaks (install: apt-get install swaks)
   swaks --to user@example.com \
         --from test@localhost \
         --server localhost:587 \
         --tls \
         --auth-user user@example.com \
         --auth-password yourpassword
   ```

2. **Check mail logs:**
   ```bash
   docker compose -f docker-compose-dev.yml logs -f mta mda
   ```

3. **Inspect mailbox:**
   ```bash
   # Check vmail directory
   ls -la ldata/vmail/

   # Read mail files directly
   find ldata/vmail/ -type f -name "*" -exec cat {} \;
   ```

## Troubleshooting

### Permission Issues
If you encounter permission issues with volumes:
```bash
# Fix ownership (user/group 5000 is vmail)
sudo chown -R 5000:5000 ldata/vmail/
```

### Database Connection Issues
```bash
# Check database is running
docker compose --env-file env.dev -f docker-compose-dev.yml ps db

# Check database logs
docker compose --env-file env.dev -f docker-compose-dev.yml logs db

# Connect to database
docker compose --env-file env.dev -f docker-compose-dev.yml exec db psql -U maild -d mailddb
```

### ClamAV Not Starting
ClamAV requires significant memory and time to start (virus database update):
```bash
# Check ClamAV logs
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f clamav

# ClamAV typically needs 2-3GB RAM and 5-10 minutes for first start
```

### Reset Everything
```bash
# Stop all services
docker compose --env-file env.dev -f docker-compose-dev.yml down

# Remove all local data
sudo rm -rf ldata/

# Start fresh
mkdir -p ldata/{db,vmail,spool,clamav,amavis,spamassassin,mua_web,logs,certs,dozzle,backups}
docker compose --env-file env.dev -f docker-compose-dev.yml up -d
```

## Environment Variables

All environment variables are documented in `env.sample`. Key variables for local development:

- `DEFAULT_DOMAIN`: Your test domain (e.g., `localhost` or `mail.local`)
- `DEBUG`: Set to `true` for verbose logging
- `DEFAULT_MAILBOX_SIZE`: Mailbox quota (e.g., `200M`)
- `MAX_MESSAGESIZE`: Maximum message size in bytes
- Service-specific debug flags: `MTA_DEBUG`, `MDA_DEBUG_*`, `AMAVIS_DEBUG`, etc.

## Production Deployment

When ready to deploy to production:

1. Use `docker-compose.yml` (not `docker-compose-dev.yml`)
2. Create a proper `.env` file with production secrets
3. Use real SSL/TLS certificates (not self-signed)
4. Configure proper DNS records (MX, SPF, DKIM, DMARC)
5. Set up external Traefik reverse proxy
6. Configure proper backup strategy for volumes
7. Review and adjust resource limits
8. Enable syslog logging for centralized log management
