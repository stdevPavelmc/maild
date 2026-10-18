"""Runtime settings for the AdminNG API.

MailD's env schema: every tunable has a default baked in this image's Dockerfile
(ENV block); a same-named variable in the operator file (env.dev / .env) always
wins because compose injects it with env_file:. Nothing here reads a config file,
so the deployment stays a single-env-file affair.

POSTGRES_PASSWORD is mandatory and never baked (compose passes it with a
`${POSTGRES_PASSWORD:?}` guard so a missing value fails at `compose config`).
"""

import os

APP_VERSION = "0.1.0"
SERVICE_NAME = "maild-adminng-api"


def _int(name: str, default: int) -> int:
    """Read an int env var, falling back to the default on absent/garbage values."""
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _bool(name: str, default: bool = False) -> bool:
    """Read a MailD-style yes/no toggle (yes/true/1/on are truthy)."""
    return os.environ.get(name, "yes" if default else "no").strip().lower() in (
        "yes",
        "true",
        "1",
        "on",
    )


# --- PostgreSQL: the PostfixAdmin catalogue + AdminNG's own database -----------
POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "db")
POSTGRES_PORT = _int("POSTGRES_PORT", 5432)
POSTGRES_USER = os.environ.get("POSTGRES_USER", "maild")
POSTGRES_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")
POSTGRES_DB = os.environ.get("POSTGRES_DB", "mailddb")
ADMINNG_DB = os.environ.get("ADMINNG_DB", "adminng")

# --- API knobs (see .agents/services/configuration.md) -------------------------
ADMINNG_API_PORT = _int("ADMINNG_API_PORT", 8080)
ADMINNG_ACCESS_TTL = _int("ADMINNG_ACCESS_TTL", 600)
ADMINNG_REFRESH_IDLE_TTL = _int("ADMINNG_REFRESH_IDLE_TTL", 900)
# A "remember this device" login opts into a 24h window: both the access-token
# TTL and the refresh idle purge use it; ordinary sessions keep 600/900.
ADMINNG_REMEMBER_TTL = _int("ADMINNG_REMEMBER_TTL", 86400)
ADMINNG_REAUTH_TTL = _int("ADMINNG_REAUTH_TTL", 30)
ADMINNG_AUTO_APPROVE_FIRST = _bool("ADMINNG_AUTO_APPROVE_FIRST", False)
ADMINNG_TOTP_REQUIRED = os.environ.get("ADMINNG_TOTP_REQUIRED", "superadmin")
ADMINNG_SEARCH_LIMIT = _int("ADMINNG_SEARCH_LIMIT", 20)
ADMINNG_QUOTA_CACHE_TTL = _int("ADMINNG_QUOTA_CACHE_TTL", 300)

# --- Auth / device trust (Phase 2) ---------------------------------------------
# Shared secret for JWT signing and TOTP-secret encryption. Mandatory: the api
# refuses to start without it (compose passes it with a `${ADMINNG_SECRET_KEY:?}`
# guard, so `compose config` fails fast when it is missing).
ADMINNG_SECRET_KEY = os.environ.get("ADMINNG_SECRET_KEY", "")
ADMINNG_TOTP_ISSUER = os.environ.get("ADMINNG_TOTP_ISSUER", "MailD AdminNG")
ADMINNG_TOTP_DIGITS = _int("ADMINNG_TOTP_DIGITS", 6)
ADMINNG_TOTP_STEP = _int("ADMINNG_TOTP_STEP", 30)
ADMINNG_FLOW_TTL = _int("ADMINNG_FLOW_TTL", 300)        # login-step1 -> step2
ADMINNG_ENROLL_TTL = _int("ADMINNG_ENROLL_TTL", 600)    # TOTP enrollment window
ADMINNG_LOGIN_MAX_FAILURES = _int("ADMINNG_LOGIN_MAX_FAILURES", 5)
ADMINNG_LOCKOUT_SECONDS = _int("ADMINNG_LOCKOUT_SECONDS", 900)
ADMINNG_DEVICE_NAME_MAX = _int("ADMINNG_DEVICE_NAME_MAX", 120)

VMAIL_ROOT = os.environ.get("VMAIL_ROOT", "/home/vmail")

# Migrations shipped in the image next to the app package.
MIGRATIONS_DIR = os.environ.get(
    "ADMINNG_MIGRATIONS_DIR",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "migrations"),
)
