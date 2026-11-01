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


def attached_subnets(
    route4: str = "/proc/net/route", route6: str = "/proc/net/ipv6_route"
) -> list[str]:
    """The subnets of the networks this container is attached to: the directly
    connected routes (no gateway), IPv4 and IPv6, minus loopback, link-local and
    multicast. Default trust set for X-Forwarded-For (2026-10 audit H-02) — the
    same rule the MCP applies to MCP_TRUSTED_PROXIES (mcp/app/maild_mcp/settings.py).
    """
    import ipaddress
    import socket
    import struct

    nets: list[str] = []
    try:
        with open(route4) as fh:
            for line in fh.readlines()[1:]:
                f = line.split()
                if len(f) < 8 or f[0] == "lo" or int(f[2], 16) or not int(f[1], 16):
                    continue
                dest = socket.inet_ntoa(struct.pack("<I", int(f[1], 16)))
                mask = socket.inet_ntoa(struct.pack("<I", int(f[7], 16)))
                nets.append(str(ipaddress.ip_network(f"{dest}/{mask}", strict=False)))
    except OSError:
        pass
    try:
        with open(route6) as fh:
            for line in fh:
                f = line.split()
                if len(f) < 10 or f[9] == "lo":
                    continue
                try:
                    if int(f[4], 16):
                        continue
                    net = ipaddress.IPv6Network(
                        (ipaddress.IPv6Address(int(f[0], 16)), int(f[1], 16)),
                        strict=False,
                    )
                except ValueError:
                    continue
                if net.prefixlen and not (
                    net.is_link_local or net.is_multicast or net.is_loopback
                ):
                    nets.append(str(net))
    except OSError:
        pass
    return sorted(set(nets))


def attached_gateways(
    route4: str = "/proc/net/route", route6: str = "/proc/net/ipv6_route"
) -> list[str]:
    """The next-hop gateways of this container's routes (IPv4 and IPv6). The
    docker bridge gateway lies inside the attached subnet, yet it is never a
    proxy MailD runs: it is the source of every published-port (docker-proxy)
    or host-originated connection, whose X-Forwarded-For is client-controlled.
    Excluded from the default trust set (2026-10 audit H-02 follow-up)."""
    import ipaddress
    import socket
    import struct

    gateways: set[str] = set()
    try:
        with open(route4) as fh:
            for line in fh.readlines()[1:]:
                f = line.split()
                if len(f) < 8 or f[0] == "lo" or not int(f[2], 16):
                    continue
                gateways.add(socket.inet_ntoa(struct.pack("<I", int(f[2], 16))))
    except (OSError, ValueError):
        pass
    try:
        with open(route6) as fh:
            for line in fh:
                f = line.split()
                if len(f) < 10 or f[9] == "lo":
                    continue
                try:
                    hop = ipaddress.IPv6Address(int(f[4], 16))
                except ValueError:
                    continue
                if not (hop.is_unspecified or hop.is_link_local or hop.is_loopback):
                    gateways.add(str(hop))
    except OSError:
        pass
    return sorted(gateways)


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
# --- Client IP / proxy trust (2026-10 audit H-02) -------------------------------
# CIDRs whose X-Forwarded-For is believed. The right-most hop that is not a trusted
# proxy is the client (the same rule the MCP applies, mcp/app/asgi.py). Unset = the
# subnets of the networks this container is attached to: the api's only legitimate
# direct peer is the `adminng` nginx container, and in production the operator's
# ingress sits in front of it. `none` = trust no proxy (the TCP peer is always the
# client). Setting it explicitly is the escape hatch for unusual topologies.
_proxies = os.environ.get("ADMINNG_TRUSTED_PROXIES", "").strip()
ADMINNG_TRUSTED_PROXIES = (
    []
    if _proxies.lower() == "none"
    else [cidr.strip() for cidr in _proxies.split(",") if cidr.strip()]
    if _proxies
    else attached_subnets()
)
# Addresses inside the trusted subnets that are still never believed: with the
# computed default, the docker gateway(s) — a published-port or host-originated
# request arrives from there with a client-supplied X-Forwarded-For. An explicit
# ADMINNG_TRUSTED_PROXIES is taken verbatim (the operator owns that topology).
ADMINNG_UNTRUSTED_HOPS = [] if _proxies else attached_gateways()
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
