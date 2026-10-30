"""MailD MCP — Django settings.

Every tunable comes from the environment (defaults baked in mcp/Dockerfile `ENV`, the
operator's env file wins). Secrets are never baked: MCP_SECRET_KEY and MCP_DB_PASSWORD are
mandatory and the process refuses to start without them. An empty variable counts as unset,
so a compose `${VAR:-}` passthrough falls back to the default here.
"""

import os
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent


def env(name: str, default: str = "") -> str:
    value = os.environ.get(name, "").strip()
    return value or default


def env_required(name: str) -> str:
    value = env(name)
    if not value:
        raise ImproperlyConfigured(f"{name} must be set (see env.sample)")
    return value


def env_bool(name: str) -> bool:
    return env(name).lower() in {"1", "yes", "true", "on"}


_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def env_duration(name: str, default: str) -> int:
    """Seconds from `90`, `15m`, `24h`, `7d` (the proposal's §9.5 notation)."""
    raw = env(name, default).lower()
    try:
        if raw[-1] in _UNITS:
            return int(raw[:-1]) * _UNITS[raw[-1]]
        return int(raw)
    except (ValueError, IndexError):
        raise ImproperlyConfigured(f"{name}='{raw}' is not a duration (e.g. 900, 15m, 24h, 7d)") from None


DEFAULT_DOMAIN = env_required("DEFAULT_DOMAIN").lower()
MAIL_ADMIN_USER = env("MAIL_ADMIN_USER", "sysadmin")

SECRET_KEY = env_required("MCP_SECRET_KEY")
DEBUG = env_bool("MCP_DEBUG")

MCP_HOSTNAME = env("MCP_HOSTNAME", f"mcp.{DEFAULT_DOMAIN}").lower()
# absolute base for the links the MCP mails (magic links, later recovery links); never taken
# from request headers
MCP_PUBLIC_URL = env("MCP_PUBLIC_URL", f"https://{MCP_HOSTNAME}").rstrip("/")
MCP_RESOURCE_URL = f"{MCP_PUBLIC_URL}/api/v1/mcp"
# Proxies whose X-Forwarded-For is believed (comma-separated CIDRs, e.g. the `maild` network the
# ingress shares). Empty = the TCP peer is the client.
MCP_TRUSTED_PROXIES = [c.strip() for c in env("MCP_TRUSTED_PROXIES").split(",") if c.strip()]
# `mcp` is the stack hostname, localhost/127.0.0.1 serve the in-image healthcheck and the
# dev port mapping
ALLOWED_HOSTS = [MCP_HOSTNAME, "mcp", "localhost", "127.0.0.1"]

INSTALLED_APPS = [
    "mcpcore",
]

# the SPA bundle (built into /app/ui-dist by the Dockerfile's node stage), served by WhiteNoise
STATIC_URL = "/assets/"
STATIC_ROOT = BASE_DIR / "ui-dist" / "assets"
WHITENOISE_ROOT = BASE_DIR / "ui-dist" / "root"
SPA_INDEX = BASE_DIR / "ui-dist" / "index.html"
# Vite names assets `<name>-<8-char hash>.<ext>`: WhiteNoise may cache those for ever
WHITENOISE_IMMUTABLE_FILE_TEST = r"^.+-[A-Za-z0-9_-]{8}\.[a-z0-9]+$"

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "maild_mcp.urls"
ASGI_APPLICATION = "asgi.application"

_DB_COMMON = {
    "ENGINE": "django.db.backends.postgresql",
    "HOST": env("POSTGRES_HOST", "db"),
    "PORT": env("POSTGRES_PORT", "5432"),
    # the restricted MCP role (db/ensure_roles.sh); the mcp never receives POSTGRES_PASSWORD
    "USER": env("MCP_DB_USER", "maild_mcp"),
    "PASSWORD": env_required("MCP_DB_PASSWORD"),
    "OPTIONS": {"connect_timeout": 5},
    "CONN_MAX_AGE": 0,
}

DATABASES = {
    # the MCP's own database: Django models and migrations
    "default": {**_DB_COMMON, "NAME": env("MCP_DB", "mcp")},
    # the PostfixAdmin catalogue: raw read-only SQL through column grants, never migrated
    "catalogue": {**_DB_COMMON, "NAME": env("POSTGRES_DB", "mailddb")},
}
DATABASE_ROUTERS = ["maild_mcp.routers.CatalogueRouter"]

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

USE_TZ = True
TIME_ZONE = "UTC"
LANGUAGE_CODE = "en"
USE_I18N = False

# first-boot seeds (mcp_boot)
MCP_ADMIN_USER = env("MCP_ADMIN_USER", "admin")
MCP_ADMIN_PASSWORD = env("MCP_ADMIN_PASSWORD")
MCP_ADMIN_EMAIL = env("MCP_ADMIN_EMAIL", f"{MAIL_ADMIN_USER}@{DEFAULT_DOMAIN}").lower()
MCP_SERVICE_EMAIL = env("MCP_SERVICE_EMAIL", f"mcp@{DEFAULT_DOMAIN}").lower()
MCP_SERVICE_PASSWORD = env("MCP_SERVICE_PASSWORD")
PROVISION_WAIT_TIMEOUT = int(env("PROVISION_WAIT_TIMEOUT", "180"))

# Service mail (magic links, notices): plain SMTP to amavis, no auth (D2), on the INTERNAL
# listener 10026 (D13: 10024 only admits the mta).
MCP_SMTP_HOST = env("MCP_SMTP_HOST", "amavis")
MCP_SMTP_PORT = int(env("MCP_SMTP_PORT", "10026"))

# web sessions (proposal §7.1): short access JWT + rotating refresh cookie
MCP_ACCESS_TTL = env_duration("MCP_ACCESS_TTL", "15m")
MCP_USER_SESSION_TTL = env_duration("MCP_USER_SESSION_TTL", "24h")

# logs (proposal §11)
MCP_LOG_DIR = env("MCP_LOG_DIR", "/var/log/maild-mcp")

# mailbox access (Dovecot master user over IMAP STARTTLS)
MCP_IMAP_HOST = env("MCP_IMAP_HOST", "mda")
MCP_IMAP_PORT = int(env("MCP_IMAP_PORT", "143"))
MCP_IMAP_CA_FILE = env("MCP_IMAP_CA_FILE", "/certs/mail.crt")
MCP_DOVECOT_MASTER_USER = env("MCP_DOVECOT_MASTER_USER", "mcp")
MCP_DOVECOT_MASTER_PASSWORD = env_required("MCP_DOVECOT_MASTER_PASSWORD")

SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = "DENY"

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {"plain": {"format": "mcp: %(levelname)s - %(message)s"}},
    "handlers": {"stdout": {"class": "logging.StreamHandler", "formatter": "plain"}},
    "root": {"handlers": ["stdout"], "level": "DEBUG" if DEBUG else "INFO"},
    "loggers": {"django": {"level": "INFO", "propagate": True}},
}
