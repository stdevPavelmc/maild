# Mail User Agent (MUA) — SnappyMail Webmail for MailD

The `mua` container runs SnappyMail on Apache with PHP 8.5 (`php:8.5-apache`), providing a
fast, modern, mobile-friendly webmail interface for end users and an administrative panel
for webmail configuration.

## Overview

- **Webmail interface:** Web-based email client accessible to users at `webmail.<DEFAULT_DOMAIN>`.
- **Catalogue and contacts:** Connects to PostgreSQL (`db`) using `POSTGRES_PASSWORD`.
  The address book / contacts database is wired to `POSTGRES_EXTRA_DB` (`contacts`).
- **Configuration management (`config-setup.php`):** A custom PHP startup script patches
  SnappyMail's `application.ini` at startup, safely configuring branding titles, database
  connections, and admin credentials without clobbering foreign settings.
- **Admin panel:** Available at `https://webmail.<domain>/?admin`. Username defaults to
  `maild`. On first boot, a one-time random password is generated, printed in the container
  logs, and stored in the persistent data volume (or set explicitly via `MUA_ADMIN_PASSWORD`).
- **Built-in plugins:** Pre-installs baseline plugins defined in `MUA_PLUGINS`:
  - `add-x-originating-ip-header`: Appends originating client IP headers.
  - `change-password`: Allows users to update their mailbox password directly from webmail settings.
  - `two-factor-auth`: Supports TOTP 2FA for webmail users.
- **MailD password change driver:** MailD provides a custom driver for the `change-password`
  plugin (`mua/plugins/change-password-maild/`). It updates the PostgreSQL catalogue directly,
  hashing passwords according to `PASSWORD_SCHEME` (`argon2id` by default), ensuring immediate
  synchronization across IMAP, POP3, and SMTP.
- **Provisioning gate:** Waits for SnappyMail config generation and the `maild_provision`
  database sentinel before creating per-domain configurations.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 80   | HTTP     | Webmail HTTP port (published to port 8081 in development; routed via ingress proxy in production) |

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/var/www/html/data` | `ldata/mua_web` | SnappyMail configuration, user settings, cached data, and address book data (owned by `www-data:www-data`) |

## Variables

Every tunable defaults inside the image (`mua/Dockerfile`). The operator file (`.env` in
production, `env.dev` in development) overrides any value.

### Mandatory deployment variables
- `POSTGRES_PASSWORD`: Password for the PostgreSQL catalogue and contacts databases.

### Image defaults (overridable)
- `BANNER_TITLE=Webmail`: Header branding title shown in the webmail login and interface.
- `MTA=mta`: MTA service hostname for SMTP submission.
- `MDA=mda`: MDA service hostname for IMAP access.
- `POSTGRES_HOST=db`: Database hostname.
- `POSTGRES_DB=mailddb`: Primary catalogue database name.
- `POSTGRES_USER=maild`: Database username.
- `POSTGRES_EXTRA_DB=contacts`: Contacts address book database name.
- `PASSWORD_SCHEME=argon2id`: Hashing scheme used when users change password (`argon2id` default, `md5crypt` legacy).
- `MUA_ADMIN_USER=maild`: Username for the webmail admin panel.
- `MUA_CONFIG_WAIT_TIMEOUT=120`: Seconds to wait for SnappyMail's initial configuration files.
- `MUA_PLUGINS=add-x-originating-ip-header,change-password,two-factor-auth`: Enabled plugins.
- `AUTO_PROVISION=yes`: Await catalogue provisioning sentinel before applying domain settings.
- `PROVISION_VERSION=1`: Sentinel schema version expected.
- `PROVISION_WAIT_TIMEOUT=180`: Seconds to wait for catalogue provisioning sentinel.

### Optional overrides
- `MUA_ADMIN_PASSWORD`: Password for webmail admin panel (if omitted, generated and logged at boot).
- `MUA_DEBUG=1`: Enable debug output in container logs.

## Operational commands

```bash
# View live webmail logs
docker compose logs -f mua

# Retrieve the admin panel login password
docker compose logs mua | grep -A3 "admin panel"

# Inspect application settings
docker compose exec mua cat /var/www/html/data/_data_/_default_/configs/application.ini
```

> [!WARNING]
> Never change the container hostname from `mua` — other services in the stack rely on this hostname.

# Retrieve the admin panel login password
docker compose logs mua | grep -A3 "admin panel"

# Inspect application settings
docker compose exec mua cat /var/www/html/data/_data_/_default_/configs/application.ini
```

> [!WARNING]
> Never change the container hostname from `mua` — other services in the stack rely on this hostname.

