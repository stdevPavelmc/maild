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

# --- First-boot provisioning (see .agents/services/provisioning.md) ------------
# The api is the provisioning leader now that the PostfixAdmin container is
# retired: at boot it seeds DEFAULT_DOMAIN, the superadmin (plus its mailbox) and
# the default aliases, then writes the maild_provision sentinel that amavis/mua/mta
# wait on. AUTO_PROVISION=no disables the boot-time run; the manual path is
# `docker compose exec api adminng.py --provision`.
DEFAULT_DOMAIN = os.environ.get("DEFAULT_DOMAIN", "").strip().lower().rstrip(".")
MAIL_ADMIN_USER = os.environ.get("MAIL_ADMIN_USER", "sysadmin").strip()
# Empty ⇒ generated and printed OTP-style in the api log. Never baked into an image.
MAIL_ADMIN_PASSWORD = os.environ.get("MAIL_ADMIN_PASSWORD", "")
AUTO_PROVISION = _bool("AUTO_PROVISION", True)
PROVISION_VERSION = _int("PROVISION_VERSION", 1)
PROVISION_WAIT_TIMEOUT = _int("PROVISION_WAIT_TIMEOUT", 180)
PROVISION_FORCE = _bool("PROVISION_FORCE", False)

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
# Swagger UI + OpenAPI contract (/api/v1/docs, /api/v1/openapi.json): OFF by
# default so production never hands the full API map to anonymous callers
# (F-04 of the 2026-10 security audit); env.dev flips it to yes for local work.
ADMINNG_API_DOCS = _bool("ADMINNG_API_DOCS", False)

# --- Password hashing (2026-10 audit F-18) --------------------------------------
# Scheme for NEW mailbox/admin password hashes: 'argon2id' (default,
# {ARGON2ID}-prefixed) or 'md5crypt' (legacy raw $1$, the PostfixAdmin-compatible
# escape hatch). Weak-scheme support is REMOVED on 2027-02-01: from that date
# PASSWORD_SCHEME=md5crypt refuses to boot and legacy $1$ rows stop verifying
# (Dovecot's auth_allow_weak_schemes goes back to 'no' too). See
# app/passwords.py and .agents/services/configuration.md.
PASSWORD_SCHEME = os.environ.get("PASSWORD_SCHEME", "argon2id").strip().lower()

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
# Stale PENDING device grants (a browser that asked for access but was never
# approved) are purged after this many days (audit F-11): the client re-enrolls
# from zero. 0 disables the sweep.
ADMINNG_PENDING_TTL_DAYS = _int("ADMINNG_PENDING_TTL_DAYS", 3)
ADMINNG_WEBAUTHN_RP_ID = os.environ.get(
    "ADMINNG_WEBAUTHN_RP_ID", "localhost"
).strip().lower().rstrip(".")
ADMINNG_WEBAUTHN_ORIGINS = tuple(
    origin.strip().rstrip("/")
    for origin in os.environ.get(
        "ADMINNG_WEBAUTHN_ORIGINS",
        "http://localhost:8083,https://localhost:8084",
    ).split(",")
    if origin.strip()
)
ADMINNG_WEBAUTHN_CHALLENGE_TTL = _int("ADMINNG_WEBAUTHN_CHALLENGE_TTL", 300)

VMAIL_ROOT = os.environ.get("VMAIL_ROOT", "/home/vmail")

# Migrations shipped in the image next to the app package.
MIGRATIONS_DIR = os.environ.get(
    "ADMINNG_MIGRATIONS_DIR",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "migrations"),
)
