# Local Development Setup

This guide explains how to set up the mail system for local development.

## Quick Start

1. **Ensure you have the required configuration:**
   ```bash
   # The env.sample file contains all necessary variables
   # Review and adjust values if needed (especially DEFAULT_DOMAIN)
   cat env.sample
   ```

2. **Create the local data directory:**
   ```bash
   mkdir -p ldata/{db,vmail,spool,clamav,amavis,spamassassin,mua_web,logs,certs,backups}
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
   docker compose -f docker compose-dev.yml up -d
   ```

5. **Watch the logs:**
   ```bash
   # All services
   docker compose -f docker compose-dev.yml logs -f

   # Specific service
   docker compose -f docker compose-dev.yml logs -f mta
   ```

## Differences from Production

The `docker compose-dev.yml` configuration includes several changes optimized for local development:

### Configuration
- Uses `env.sample` instead of `.env` (no secrets needed for local dev)
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

### Exposed Ports
All services expose debugging ports:

| Service | Port(s) | Description |
|---------|---------|-------------|
| db      | 5432    | PostgreSQL database |
| admin   | 8080    | PostfixAdmin web interface |
| mua     | 8060    | Webmail interface |
| mda     | 110, 143, 993, 995, 4190, 12345 | Dovecot (POP3, IMAP, IMAPS, POP3S, ManageSieve, SASL) |
| mta     | 25, 465, 587 | Postfix (SMTP, SMTPS, Submission) |
| clamav  | 3310    | ClamAV antivirus |
| amavis  | 10024   | Amavis content filter |

### No Traefik
- No Traefik reverse proxy labels
- Access services directly via exposed ports

## Accessing Services

- **Webmail:** http://localhost:8060
- **Admin Interface:** http://localhost:8080
- **Database:** localhost:5432
  - User: `maild`
  - Database: `mailddb`
  - Password: From `env.sample` POSTGRES_PASSWORD

## Useful Commands

### Build Images
```bash
docker compose -f docker compose-dev.yml build
```

### Stop Services
```bash
docker compose -f docker compose-dev.yml down
```

### Clean Up (Remove all data)
```bash
# Stop and remove containers
docker compose -f docker compose-dev.yml down

# Remove local data
rm -rf ldata/
```

### Restart a Single Service
```bash
docker compose -f docker compose-dev.yml restart mta
```

### Shell into a Container
```bash
docker compose -f docker compose-dev.yml exec mta bash
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
   docker compose -f docker compose-dev.yml logs -f mta mda
   ```

3. **Inspect mailbox:**
   ```bash
   # Check vmail directory
   ls -la ldata/vmail/

   # Read mail files directly
   find ldata/vmail/ -type f -name "*" -exec cat {} \;
   ```

## Database Backups

The cron service automatically performs daily PostgreSQL backups with the following configuration:

### Backup Schedule
- **Time:** 3:00 AM EST/EDT (8:00 AM UTC, configured for UTC-5 server)
- **Retention:** 15 days
- **Format:** Compressed SQL dumps (`.sql.gz`)
- **Location:**
  - Production: Docker volume `db_backups` mounted at `/backups`
  - Development: Local directory `ldata/backups/db/`

### Manual Backup
To create a backup immediately:
```bash
# Trigger manual backup
docker compose -f docker compose-dev.yml exec cron /scripts/backup_db.sh

# Check backup logs
docker compose -f docker compose-dev.yml exec cron cat /backups/db/backup.log
```

### List Backups
```bash
# View all backups
docker compose -f docker compose-dev.yml exec cron ls -lh /backups/db/

# Or directly from local filesystem (dev only)
ls -lh ldata/backups/db/
```

### Restore from Backup
To restore the database from a backup:
```bash
# Stop services that use the database
docker compose -f docker compose-dev.yml stop mta mda admin mua amavis cron

# Restore backup (replace YYYYMMDD_HHMMSS with actual backup date)
gunzip -c ldata/backups/db/maild_backup_YYYYMMDD_HHMMSS.sql.gz | \
  docker compose -f docker compose-dev.yml exec -T db psql -U maild -d mailddb

# Restart all services
docker compose -f docker compose-dev.yml start
```

### Backup Notifications
After each backup, an email notification is sent to the mail admin with:
- Backup status (SUCCESS/FAILED)
- Backup file size
- Current backup count
- Total storage used
- List of recent backups

Check your admin mailbox at `${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}` for backup reports.

### Backup Disk Space
Monitor backup disk usage:
```bash
# Check backup directory size
du -sh ldata/backups/

# View backup statistics
docker compose -f docker compose-dev.yml exec cron tail -n 50 /backups/db/backup.log
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
docker compose -f docker compose-dev.yml ps db

# Check database logs
docker compose -f docker compose-dev.yml logs db

# Connect to database
docker compose -f docker compose-dev.yml exec db psql -U maild -d mailddb
```

### ClamAV Not Starting
ClamAV requires significant memory and time to start (virus database update):
```bash
# Check ClamAV logs
docker compose -f docker compose-dev.yml logs -f clamav

# ClamAV typically needs 2-3GB RAM and 5-10 minutes for first start
```

### Reset Everything
```bash
# Stop all services
docker compose -f docker compose-dev.yml down

# Remove all local data
rm -rf ldata/

# Start fresh
mkdir -p ldata/{db,vmail,spool,clamav,amavis,spamassassin,mua_web,logs,certs,backups}
docker compose -f docker compose-dev.yml up -d
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

1. Use `docker compose.yml` (not `docker compose-dev.yml`)
2. Create a proper `.env` file with production secrets
3. Use real SSL/TLS certificates (not self-signed)
4. Configure proper DNS records (MX, SPF, DKIM, DMARC)
5. Set up external Traefik reverse proxy
6. Configure proper backup strategy for volumes
7. Review and adjust resource limits
8. Enable syslog logging for centralized log management
