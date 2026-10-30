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


DEFAULT_DOMAIN = env_required("DEFAULT_DOMAIN").lower()
MAIL_ADMIN_USER = env("MAIL_ADMIN_USER", "sysadmin")

SECRET_KEY = env_required("MCP_SECRET_KEY")
DEBUG = env_bool("MCP_DEBUG")

MCP_HOSTNAME = env("MCP_HOSTNAME", f"mcp.{DEFAULT_DOMAIN}").lower()
# `mcp` is the stack hostname, localhost/127.0.0.1 serve the in-image healthcheck and the
# dev port mapping
ALLOWED_HOSTS = [MCP_HOSTNAME, "mcp", "localhost", "127.0.0.1"]

INSTALLED_APPS = [
    "mcpcore",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
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

# mailbox access (Dovecot master user over IMAP STARTTLS)
MCP_IMAP_HOST = env("MCP_IMAP_HOST", "mda")
MCP_IMAP_PORT = int(env("MCP_IMAP_PORT", "143"))
MCP_IMAP_CA_FILE = env("MCP_IMAP_CA_FILE", "/certs/mail.crt")
MCP_DOVECOT_MASTER_USER = env("MCP_DOVECOT_MASTER_USER", "mcp")

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
