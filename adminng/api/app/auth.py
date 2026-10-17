"""Phase-1 authentication: plain bearer tokens backed by the adminng DB.

The full security model (device trust, TOTP, re-auth tokens, audit trail) is
Phase 2. Until then:

  * `POST /auth/login` verifies the PostfixAdmin `admin` row (md5crypt) and mints
    an opaque random token; only its SHA-256 is stored in `session.jti`, so a
    database leak does not hand out working tokens;
  * every authenticated request looks the session up, enforces the idle purge
    (`ADMINNG_REFRESH_IDLE_TTL`) and the account's `active` flag;
  * the principal carries the admin's tenant scope (superadmin = all domains,
    custom admin = its active `domain_admins` rows).

Phase 2 replaces the issuance flow (login-step1/2 + device binding + jti
rotation) but keeps this dependency surface.
"""

import hashlib
import secrets

from fastapi import Depends, Header

from . import settings
from .db import connect
from .errors import ApiError, forbidden_tenant
from .md5crypt import verify_password


class Principal:
    """The authenticated admin and its tenant scope."""

    __slots__ = ("username", "superadmin", "domains")

    def __init__(self, username: str, superadmin: bool, domains: list[str]):
        self.username = username
        self.superadmin = superadmin
        self.domains = domains

    def allows(self, domain: str) -> bool:
        return self.superadmin or domain.lower() in self.domains

    def __repr__(self) -> str:
        return f"Principal({self.username!r}, superadmin={self.superadmin})"


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _domains_of(username: str, superadmin: bool) -> list[str]:
    if superadmin:
        return []
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT domain FROM domain_admins WHERE username = %s AND active ORDER BY domain",
            (username,),
        )
        return [row["domain"] for row in cur.fetchall()]


def login(username: str, password: str) -> tuple[str, Principal]:
    """Verify catalogue credentials and create a session. Returns (token, principal)."""
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT username, password, superadmin, active FROM admin WHERE username = %s",
            (username,),
        )
        row = cur.fetchone()

    # Same response shape whether the admin is missing, disabled or the password
    # is wrong: no user-enumeration oracle (technical-draft §4.4).
    if row is None or not row["active"] or not verify_password(password, row["password"]):
        raise ApiError(401, "UNAUTHENTICATED", "invalid credentials")

    token = secrets.token_urlsafe(32)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO session (jti, username, device_id) VALUES (%s, %s, NULL)",
            (token_hash(token), row["username"]),
        )
        conn.commit()

    principal = Principal(
        row["username"], row["superadmin"], _domains_of(row["username"], row["superadmin"])
    )
    return token, principal


def logout(token: str) -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE session SET revoked_at = now() WHERE jti = %s AND revoked_at IS NULL",
            (token_hash(token),),
        )
        conn.commit()


def revoke_user_sessions(username: str) -> int:
    """Revoke every active session of an admin (delete/disable)."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE session SET revoked_at = now() "
            "WHERE username = %s AND revoked_at IS NULL",
            (username,),
        )
        revoked = cur.rowcount
        conn.commit()
    return revoked

def principal_from_token(token: str) -> Principal:
    jti = token_hash(token)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT jti, username, revoked_at,
                   EXTRACT(EPOCH FROM (now() - last_used_at))::int AS idle_seconds
              FROM session
             WHERE jti = %s
            """,
            (jti,),
        )
        session = cur.fetchone()
        if session is None or session["revoked_at"] is not None:
            raise ApiError(401, "UNAUTHENTICATED", "session not found or revoked")
        if session["idle_seconds"] > settings.ADMINNG_REFRESH_IDLE_TTL:
            cur.execute("UPDATE session SET revoked_at = now() WHERE jti = %s", (jti,))
            conn.commit()
            raise ApiError(401, "SESSION_EXPIRED", "session expired from inactivity")
        cur.execute("UPDATE session SET last_used_at = now() WHERE jti = %s", (jti,))
        conn.commit()

    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT username, superadmin, active FROM admin WHERE username = %s",
            (session["username"],),
        )
        admin = cur.fetchone()
    if admin is None or not admin["active"]:
        raise ApiError(401, "UNAUTHENTICATED", "account disabled")

    return Principal(
        admin["username"], admin["superadmin"], _domains_of(admin["username"], admin["superadmin"])
    )


async def get_principal(
    authorization: str | None = Header(default=None, alias="Authorization"),
) -> Principal:
    """FastAPI dependency: resolve the bearer token into a Principal."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise ApiError(401, "UNAUTHENTICATED", "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise ApiError(401, "UNAUTHENTICATED", "missing bearer token")
    return principal_from_token(token)


def require_superadmin(principal: Principal = Depends(get_principal)) -> Principal:
    if not principal.superadmin:
        raise ApiError(403, "FORBIDDEN", "superadmin only")
    return principal


def ensure_domain_allowed(principal: Principal, domain: str) -> None:
    if not principal.allows(domain):
        raise forbidden_tenant()

