# AGENTS.md - MailD Project Instructions for AI Agents

This document provides essential instructions for AI agents working on the MailD project, a Docker-based mail server system with database backend.

## Project Overview

MailD is a complete mail server solution built with Docker containers, replacing LDAP authentication with a PostgreSQL database backend. It provides a full-featured email system with spam filtering, antivirus scanning, and web-based administration.

### Core Services Architecture

```
MailD System
├── db (PostgreSQL)          # Database backend for user data
├── mta (Postfix)           # Mail Transport Agent - SMTP services
├── mda (Dovecot)           # Mail Delivery Agent - IMAP/POP3 services
├── admin (PostfixAdmin)    # Web-based administration interface
├── mua (SnappyMail)        # Webmail client
├── amavis                  # Content filtering (spam/antivirus)
├── clamav                  # Antivirus scanning engine
└── cron                    # Scheduled tasks and maintenance
```

## Development Environment Setup

### Prerequisites
- Docker & Docker Compose installed
- Git repository cloned locally
- Ports 25, 143, 993, 465, 587, 8060, 8080 available

### Quick Development Setup

1. **Initialize Development Environment**
```bash
# Create local data directories
mkdir -p ldata/{db,vmail,spool,clamav,amavis,spamassassin,mua_web,logs,certs,backups}

# Generate development certificates (self-signed)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout ldata/certs/mail.key \
  -out ldata/certs/mail.crt \
  -subj "/C=CU/ST=Camaguey/L=Camaguey/O=MailAD/OU=MAilD/CN=maild.cu"

# Generate DH parameters for Postfix
openssl dhparam -out ldata/certs/RSA2048.pem 2048
```

2. **Start Development Services**
```bash
# Build and start all services
docker compose -f docker compose-dev.yml up -d

# View logs
docker compose -f docker compose-dev.yml logs -f
```

3. **Access Development Services**
- Webmail: http://localhost:8060
- Admin Interface: http://localhost:8080
- Database: localhost:5432 (user: `maild`, database: `mailddb`)

### Key Development Differences

| Aspect | Development | Production |
|--------|-------------|------------|
| Config File | `env.sample` | `.env` (with secrets) |
| Image Tags | Fixed `:develop` | CI/CD managed |
| Network | Local bridge `maild-dev` | External `maild` |
| Volumes | Local `./ldata/` bind mounts | Docker named volumes |
| Ports | All exposed for debugging | Minimal exposure |
| Traefik | Disabled (direct access) | Enabled with SSL |

## Code Organization & Conventions

### Directory Structure

```
mails/
├── admin/          # PostfixAdmin web interface
├── amavis/         # Content filtering service
├── clamav/         # Antivirus service
├── cron/           # Scheduled tasks & maintenance
├── db/             # PostgreSQL database
├── mda/            # Dovecot IMAP/POP3 server
├── mta/            # Postfix SMTP server
├── mua/            # SnappyMail webmail client
├── vars/           # Service-specific environment variables
├── imgs/           # Documentation images
├── ldata/          # Development data (gitignored)
├── docker compose.yml      # Production configuration
├── docker compose-dev.yml  # Development configuration
└── env.sample      # Environment variable template
```

### Service Directory Pattern

Each service follows this structure:
```
service/
├── Dockerfile           # Container build definition
├── docker-entrypoint.sh # Runtime configuration script
├── check.sh            # Health check script
├── conf/               # Configuration templates
└── scripts/            # Service-specific scripts
```

### Configuration Patterns

1. **Environment Variable Substitution**
   - All configuration files use `_${VARIABLE}_` pattern
   - Templates are processed by entrypoint scripts at runtime
   - Never hardcode values; always use environment variables

2. **Service-Specific Environment Files**
   - Located in `vars/` directory (e.g., `vars/mta.env`)
   - Contains service-specific features/options configuration variables
   - Loaded by docker compose environment section

3. **Entry Point Scripts**
   - Named `docker-entrypoint.sh` in each service
   - Handle template processing and service startup
   - Always make them executable: `chmod +x docker-entrypoint.sh`

## Development Workflows

### Building Services

```bash
# Build all services
docker compose -f docker compose-dev.yml build

# Build specific service (faster for iterative development)
docker compose -f docker compose-dev.yml build mta

# Rebuild without cache
docker compose -f docker compose-dev.yml build --no-cache mta
```

### Service Management

```bash
# Start/stop services
docker compose -f docker compose-dev.yml up -d mta
docker compose -f docker compose-dev.yml stop mta

# Restart service
docker compose -f docker compose-dev.yml restart mta

# Access container shell
docker compose -f docker compose-dev.yml exec mta bash

# View service logs
docker compose -f docker compose-dev.yml logs -f mta
```

### Debugging Procedures

1. **Check Service Health**
```bash
# All services
docker compose -f docker compose-dev.yml ps

# Specific service health
docker compose -f docker compose-dev.yml exec mta ./check.sh
```

2. **Analyze Logs**
```bash
# Real-time logs
docker compose -f docker compose-dev.yml logs -f mta

# Recent logs
docker compose -f docker compose-dev.yml logs --tail=100 mta

# Multiple services
docker compose -f docker compose-dev.yml logs -f mta mda amavis
```

3. **Debug Variables**
```bash
# Check environment variables
docker compose -f docker compose-dev.yml exec mta env | grep -E "(POSTFIX|DATABASE)"
```

## Testing Procedures

### Comprehensive Test Suite

The project includes a comprehensive test script (`test.sh`) that validates all mail server functionality:

```bash
# Run full test suite
./test.sh

# Test specific functionality (manual testing with swaks)
swaks --to user@example.com \
      --from test@localhost \
      --server localhost:587 \
      --tls \
      --auth-user user@example.com \
      --auth-password yourpassword
```

### Test Coverage Areas

1. **SMTP Protocol Testing**
   - Port 25: Standard SMTP delivery
   - Port 465: SMTPS (SSL/TLS)
   - Port 587: Submission with authentication
   - Open relay protection
   - Authentication bypass attempts

2. **Message Handling**
   - Message size limits (10MB default)
   - Invalid recipient handling
   - Identity spoofing protection
   - Attachment scanning

3. **Content Filtering**
   - Spam filtering effectiveness
   - Antivirus scanning
   - DKIM signing verification

4. **Service Integration**
   - Database connectivity
   - Inter-service communication
   - SSL/TLS certificate validation

### Database Testing

```bash
# Connect to database
docker compose -f docker compose-dev.yml exec db psql -U maild -d mailddb

# Test user/mailbox creation
docker compose -f docker compose-dev.yml exec admin php -f /usr/local/bin/setup_user.php
```

## Common Development Tasks

### Adding Configuration Options

1. **Add to `env.sample`**
```bash
NEW_FEATURE_ENABLED=true
NEW_FEATURE_THRESHOLD=100
```

2. **Add to Service Environment File**
```bash
# vars/mta.env
NEW_FEATURE_ENABLED=${NEW_FEATURE_ENABLED}
NEW_FEATURE_THRESHOLD=${NEW_FEATURE_THRESHOLD}
```

3. **Use in Configuration Template**
```bash
# conf/main.cf.template
new_feature_enabled = _NEW_FEATURE_ENABLED_
new_feature_threshold = _NEW_FEATURE_THRESHOLD_
```

### Modifying Service Behavior

1. **Edit Dockerfile** for dependencies or base image changes
2. **Modify `docker-entrypoint.sh`** for startup behavior
3. **Update configuration templates** in `conf/` directory
4. **Test with specific service build** before full deployment

### Database Schema Changes

1. **Create migration script** in `db/` directory
2. **Test migration on development data**
3. **Update entrypoint scripts** if needed
4. **Verify backwards compatibility**

### SSL Certificate Management

```bash
# Development: Generate self-signed certificates
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout ldata/certs/mail.key \
  -out ldata/certs/mail.crt \
  -subj "/C=JM/ST=Kingston/L=Kingston/O=MailD/OU=Dev/CN=mail.localhost"

# Production: Certificates should be mounted at /certs
# Never commit certificates to version control
```

## Critical Constraints & Warnings

### ⚠️ NEVER CHANGE THESE
- **Service Hostnames**: `mta`, `mda`, `amavis`, `clamav`, `db`, `admin`, `mua`, `cron`
- **Database Schema**: Core tables structure without proper migration
- **Environment Variable Names**: Breaking changes will break all services
- **Volume Mount Points**: Changing paths will cause data loss

### 🔧 Development Safety Rules

1. **Always Use Development Environment**
   - Use `docker compose-dev.yml` for local work
   - Never use production configuration locally

2. **Environment Variable Chain**
   - `env.sample` → `vars/*.env` → service containers
   - Maintain variable substitution patterns

3. **Service Dependencies**
   - Database (`db`) must be operational before other services
   - Amavis depends on both `db` and `clamav`
   - MTA depends on `mda`, `amavis`, and `clamav`

4. **Volume Management**
   - Development uses local `ldata/` directory
   - Never delete `ldata/` without backup
   - Permissions: vmail data owned by UID 5000

5. **Security Considerations**
   - Never commit passwords or secrets
   - Use self-signed certificates only for development
   - Validate all user inputs in configuration

## Debugging Common Issues

### Service Startup Problems

1. **Database Connection Issues**
```bash
# Check database status
docker compose -f docker compose-dev.yml exec db pg_isready

# Test database connectivity
docker compose -f docker compose-dev.yml exec mta ping -c 3 db
```

2. **Permission Issues**
```bash
# Fix vmail permissions
sudo chown -R 5000:5000 ldata/vmail/
```

3. **Port Conflicts**
```bash
# Check port usage
netstat -tulpn | grep -E "(25|587|465|993|995|8060|8080)"
```

### Performance Issues

1. **ClamAV Startup**
   - Requires 2-3GB RAM
   - First startup takes 5-10 minutes (virus database update)
   - Monitor with: `docker compose -f docker compose-dev.yml logs -f clamav`

2. **Database Performance**
```bash
# Check database connections
docker compose -f docker compose-dev.yml exec db psql -U maild -d mailddb -c "SELECT count(*) FROM pg_stat_activity;"

# Monitor query performance
docker compose -f docker compose-dev.yml exec db psql -U maild -d mailddb -c "SELECT query, calls, total_time FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;"
```

### Email Flow Testing

1. **Test SMTP Delivery**
```bash
# Send test email
swaks --to test@localhost --from admin@localhost --server localhost:25

# Check mail logs
docker compose -f docker compose-dev.yml logs -f mta mda
```

2. **Check Mailbox**
```bash
# Inspect mailbox directory
find ldata/vmail/ -name "*.maildir" -type d

# View email content
find ldata/vmail/ -type f -name "*" -exec cat {} \;
```

## Development Best Practices

### Code Style Guidelines
- Use shell scripts for configuration and automation
- Follow existing Dockerfile patterns
- Maintain consistent environment variable naming (UPPER_CASE)
- Use template files for configuration with variable substitution

### Testing Strategy
- Always test with development environment first
- Validate service dependencies after changes
- Run comprehensive test suite before committing
- Test email flow with real messages

### Documentation Updates
- Update `DEV-SETUP.md` for development workflow changes
- Modify `README.md` for architectural changes
- Update this `AGENTS.md` for new agent workflows

### Git Workflow
- Feature branches for significant changes
- Commit and/or push only when explicitly instructed
- If implicit, ask for user input
- Clear commit messages describing service impact
- Never commit sensitive data or certificates, warn the user
- Test across all affected services before merging

## Getting Help

- **Project Documentation**: `README.md` and `DEV-SETUP.md`
- **Telegram Group**: https://t.me/MailAD_dev
- **Issue Tracking**: Use GitLab issues for bugs and feature requests
- **Configuration Reference**: Check `vars/` directory for all environment variables

Remember: This is a production mail server system. Always test thoroughly and follow security best practices when making changes.