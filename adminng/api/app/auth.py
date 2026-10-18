"""Phase-2 authentication: device trust + password + TOTP + re-auth tokens.

Flow (technical-draft §4.1-§4.5):

  handshake (X-Device-ID) -> PENDING
  login-step1 (password; device must be APPROVED) ->
      REQUIRES_TOTP_ENROLLMENT | REQUIRES_2FA | tokens (no TOTP required)
  totp-enroll / totp-confirm (enrollment token)
  login-step2 (flow token + code) -> access JWT (10 min) + opaque refresh token
  refresh (rotates the refresh jti) / logout / reauth-confirm (30 s token)

Sessions are bound to (username, device). Only the SHA-256 of a refresh token is
stored; access tokens are stateless JWTs carrying the device id, so a token
minted for one device cannot be used from another.
"""

import hashlib
import secrets
import uuid

from fastapi import Depends, Header, Request

from . import audit, crypto, devices, ratelimit, settings, tokens, totp
from .db import connect
from .errors import ApiError, forbidden_tenant
from .passwords import verify_password


class Principal:
    """The authenticated admin, its tenant scope and the device it came from."""

    __slots__ = ("username", "superadmin", "domains", "device_id")

    def __init__(self, username: str, superadmin: bool, domains: list[str], device_id: str):
        self.username = username
        self.superadmin = superadmin
        self.domains = domains
        self.device_id = device_id

    def allows(self, domain: str) -> bool:
        return self.superadmin or domain.lower() in self.domains

    def __repr__(self) -> str:
        return f"Principal({self.username!r}, superadmin={self.superadmin}, device={self.device_id})"


# ------------------------------------------------------------------- helpers
def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _admin_row(username: str) -> dict | None:
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT username, password, superadmin, active FROM admin WHERE username = %s",
            (username,),
        )
        return cur.fetchone()


def _domains_of(username: str, superadmin: bool) -> list[str]:
    if superadmin:
        return []
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT domain FROM domain_admins WHERE username = %s AND active ORDER BY domain",
            (username,),
        )
        return [row["domain"] for row in cur.fetchall()]


def _credential(username: str) -> dict | None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT username, secret, confirmed, last_used_step FROM totp_credential "
            "WHERE username = %s",
            (username,),
        )
        return cur.fetchone()


def _totp_required(superadmin: bool) -> bool:
    policy = settings.ADMINNG_TOTP_REQUIRED
    if policy == "all":
        return True
    if policy == "none":
        return False
    return superadmin


def _create_session(username: str, device_id: str, remember: bool = False) -> str:
    """Mint an opaque refresh token; only its hash is stored."""
    refresh = secrets.token_urlsafe(48)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO session (jti, username, device_id, remember) VALUES (%s, %s, %s, %s)",
            (token_hash(refresh), username, device_id, remember),
        )
        conn.commit()
    return refresh


def _issue(username: str, device_id: str, admin: dict, remember: bool = False) -> dict:
    domains = _domains_of(username, admin["superadmin"])
    ttl = settings.ADMINNG_REMEMBER_TTL if remember else settings.ADMINNG_ACCESS_TTL
    idle_timeout = (
        settings.ADMINNG_REMEMBER_TTL
        if remember
        else settings.ADMINNG_REFRESH_IDLE_TTL
    )
    return {
        "access_token": tokens.access_token(
            username, device_id, admin["superadmin"], domains, ttl=ttl
        ),
        "refresh_token": _create_session(username, device_id, remember),
        "token_type": "bearer",
        "expires_in": ttl,
        "remember": remember,
        "idle_timeout": idle_timeout,
        "user": {
            "username": username,
            "superadmin": admin["superadmin"],
            "domains": domains,
        },
    }


def _verify_credentials(username: str, password: str) -> dict:
    row = _admin_row(username)
    if row is None or not row["active"] or not verify_password(password, row["password"]):
        raise ApiError(401, "UNAUTHENTICATED", "invalid credentials")
    return row


def _device_or_error(device_id: str) -> dict:
    device = devices.get(device_id)
    if device is None:
        raise ApiError(
            403,
            "DEVICE_NOT_AUTHORIZED",
            "the device is not registered; run the handshake first",
            device_id=device_id,
        )
    if device["authorization_state"] == "REVOKED":
        raise ApiError(
            401, "DEVICE_REVOKED", "this device was revoked", device_id=device_id
        )
    return device


def _require_approved(device: dict, username: str | None = None) -> None:
    if device["authorization_state"] != "APPROVED":
        raise ApiError(
            403,
            "DEVICE_NOT_AUTHORIZED",
            "this device has not been approved by an administrator yet",
            device_id=device["device_id"],
            associated_user=username or device["associated_user"],
        )


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

# --------------------------------------------------------------- dependencies
def device_header(x_device_id: str | None = Header(default=None, alias="X-Device-ID")) -> str:
    """Validate the mandatory device header (UUID format)."""
    if not x_device_id:
        raise ApiError(401, "DEVICE_REQUIRED", "missing X-Device-ID header")
    try:
        return str(uuid.UUID(x_device_id))
    except ValueError:
        raise ApiError(422, "VALIDATION", "X-Device-ID must be a UUID") from None


async def get_principal(
    authorization: str | None = Header(default=None, alias="Authorization"),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> Principal:
    """Resolve the access JWT and its device into a Principal."""
    if not x_device_id:
        raise ApiError(401, "DEVICE_REQUIRED", "missing X-Device-ID header")
    if not authorization or not authorization.lower().startswith("bearer "):
        raise ApiError(401, "UNAUTHENTICATED", "missing bearer token")
    device_id = device_header(x_device_id)
    claims = tokens.decode(authorization.split(" ", 1)[1].strip(), "access")
    if claims.get("did") != device_id:
        raise ApiError(401, "TOKEN_INVALID", "the token belongs to another device")

    device = _device_or_error(device_id)
    _require_approved(device)
    admin = _admin_row(claims["sub"])
    if admin is None or not admin["active"]:
        raise ApiError(401, "UNAUTHENTICATED", "account disabled")
    return Principal(
        admin["username"],
        admin["superadmin"],
        _domains_of(admin["username"], admin["superadmin"]),
        device_id,
    )


def require_superadmin(principal: Principal = Depends(get_principal)) -> Principal:
    if not principal.superadmin:
        raise ApiError(403, "FORBIDDEN", "superadmin only")
    return principal


def require_reauth(
    request: Request, principal: Principal = Depends(get_principal)
) -> Principal:
    """Destructive actions need the 30-second `X-Security-Validation-Token`."""
    token = request.headers.get("x-security-validation-token")
    if not token:
        raise ApiError(
            403, "OPERATION_NOT_VERIFIED", "a security validation token is required"
        )
    claims = tokens.decode(token, "reauth")
    if claims.get("did") != principal.device_id or claims.get("sub") != principal.username:
        raise ApiError(
            403,
            "OPERATION_NOT_VERIFIED",
            "the validation token does not match this device",
        )
    if claims.get("scope") != "destructive":
        raise ApiError(403, "OPERATION_NOT_VERIFIED", "the token scope does not match")
    return principal


def ensure_domain_allowed(principal: Principal, domain: str) -> None:
    if not principal.allows(domain):
        raise forbidden_tenant()

# --------------------------------------------------------------------- flows
def login_step1(
    username: str, password: str, device_id: str, ip: str | None, remember: bool = False
) -> dict:
    """Verify password + device state; decide enrollment / 2FA / direct issue."""
    ratelimit.check(username, ip)
    device = _device_or_error(device_id)

    try:
        admin = _verify_credentials(username, password)
    except ApiError:
        locked = ratelimit.failure(username, ip)
        audit.record(
            actor=username,
            action="LOGIN_LOCKOUT" if locked else "LOGIN_FAIL",
            result="denied",
            device_id=device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/login-step1",
        )
        if locked:
            raise ApiError(
                429,
                "RATE_LIMITED",
                "too many failed attempts, the account is temporarily locked",
            ) from None
        raise

    # First-device bootstrap: only a superadmin, only with TOTP already enrolled,
    # only while no device is approved, and only when the operator opted in.
    credential = _credential(username)
    if (
        device["authorization_state"] == "PENDING"
        and settings.ADMINNG_AUTO_APPROVE_FIRST
        and admin["superadmin"]
        and devices.count_approved() == 0
        and credential
        and credential["confirmed"]
    ):
        devices.set_state(device_id, "APPROVED", "auto-first")
        audit.record(
            actor=username,
            action="DEVICE_APPROVE",
            device_id=device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/login-step1",
            approved_by="auto-first",
        )
        device = _device_or_error(device_id)

    if device["authorization_state"] == "PENDING":
        devices.bind_user(device_id, username, ip)
        audit.record(
            actor=username,
            action="DEVICE_PENDING_LOGIN",
            result="denied",
            device_id=device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/login-step1",
        )
        raise ApiError(
            403,
            "DEVICE_NOT_AUTHORIZED",
            "this device has not been approved by an administrator yet",
            device_id=device_id,
            associated_user=username,
        )
    _require_approved(device, username)
    devices.bind_user(device_id, username, ip)

    if _totp_required(admin["superadmin"]) and not (credential and credential["confirmed"]):
        audit.record(
            actor=username,
            action="TOTP_ENROLL_REQUIRED",
            device_id=device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/login-step1",
        )
        return {
            "session_state": "REQUIRES_TOTP_ENROLLMENT",
            "enrollment_token": tokens.enroll_token(username, device_id),
            "user": {"username": username},
        }

    if credential and credential["confirmed"]:
        return {
            "session_state": "REQUIRES_2FA",
            "flow_token": tokens.flow_token(username, device_id, remember=remember),
        }

    ratelimit.success(username, ip)
    audit.record(
        actor=username,
        action="LOGIN_OK",
        device_id=device_id,
        ip=ip,
        endpoint="POST /api/v1/auth/login-step1",
    )
    return {"session_state": "AUTHENTICATED", **_issue(username, device_id, admin, remember=remember)}

def login_step2(flow_token: str, code: str, device_id: str, ip: str | None) -> dict:
    """Second factor: verify the TOTP code and mint the token pair."""
    claims = tokens.decode(flow_token, "2fa")
    if claims.get("did") != device_id:
        raise ApiError(401, "TOKEN_INVALID", "the flow token belongs to another device")
    remember = bool(claims.get("remember", False))
    device = _device_or_error(device_id)
    _require_approved(device)

    username = claims["sub"]
    admin = _admin_row(username)
    if admin is None or not admin["active"]:
        raise ApiError(401, "UNAUTHENTICATED", "account disabled")
    ratelimit.check(username, ip)

    credential = _credential(username)
    if credential is None or not credential["confirmed"]:
        raise ApiError(409, "TOTP_NOT_ENROLLED", "enroll an authenticator first")

    ok, step = totp.verify(
        crypto.decrypt(credential["secret"]), code, credential["last_used_step"]
    )
    if not ok:
        locked = ratelimit.failure(username, ip)
        audit.record(
            actor=username,
            action="TOTP_FAIL",
            result="denied",
            device_id=device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/login-step2",
        )
        if locked:
            raise ApiError(429, "RATE_LIMITED", "too many failed attempts")
        raise ApiError(401, "TOTP_INVALID", "invalid or already used code")

    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE totp_credential SET last_used_step = %s WHERE username = %s",
            (step, username),
        )
        conn.commit()

    ratelimit.success(username, ip)
    audit.record(
        actor=username,
        action="LOGIN_OK",
        device_id=device_id,
        ip=ip,
        endpoint="POST /api/v1/auth/login-step2",
    )
    return _issue(username, device_id, admin, remember=remember)


def enroll_start(enroll_token: str, device_id: str) -> dict:
    """Start (or resume) TOTP enrollment; returns the otpauth:// URI for the QR."""
    claims = tokens.decode(enroll_token, "enroll")
    if claims.get("did") != device_id:
        raise ApiError(401, "TOKEN_INVALID", "the enrollment token belongs to another device")
    _require_approved(_device_or_error(device_id))
    username = claims["sub"]

    credential = _credential(username)
    if credential and credential["confirmed"]:
        raise ApiError(
            409, "TOTP_ALREADY_ENROLLED", "this account already has a TOTP credential"
        )
    if credential:
        secret = crypto.decrypt(credential["secret"])
    else:
        secret = totp.generate_secret()
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO totp_credential (username, secret) VALUES (%s, %s)",
                (username, crypto.encrypt(secret)),
            )
            conn.commit()

    return {
        "secret": secret,
        "otpauth_uri": totp.provisioning_uri(secret, username),
        "issuer": settings.ADMINNG_TOTP_ISSUER,
        "digits": settings.ADMINNG_TOTP_DIGITS,
        "period": settings.ADMINNG_TOTP_STEP,
    }

def enroll_confirm(enroll_token: str, code: str, ip: str | None) -> dict:
    claims = tokens.decode(enroll_token, "enroll")
    username = claims["sub"]
    credential = _credential(username)
    if credential is None:
        raise ApiError(409, "TOTP_NOT_ENROLLED", "call /auth/totp-enroll first")
    if credential["confirmed"]:
        return {"enrolled": True, "username": username}

    ok, step = totp.verify(crypto.decrypt(credential["secret"]), code)
    if not ok:
        raise ApiError(401, "TOTP_INVALID", "the code does not match the secret")
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        # Enrollment proves possession but is not a login: leave the enrollment step
        # usable exactly once so the login that follows immediately (same 30 s
        # window) is not rejected as a replay. That login then consumes the step.
        cur.execute(
            "UPDATE totp_credential SET confirmed = true, last_used_step = %s "
            "WHERE username = %s",
            (max(step - 1, 0), username),
        )
        conn.commit()
    audit.record(
        actor=username,
        action="TOTP_ENROLL",
        device_id=claims.get("did"),
        ip=ip,
        endpoint="POST /api/v1/auth/totp-confirm",
    )
    return {"enrolled": True, "username": username}


def refresh_session(refresh_token: str, device_id: str) -> dict:
    """Rotate the refresh jti and mint a new access token (reuse detection)."""
    jti = token_hash(refresh_token)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT jti, username, device_id, revoked_at, remember,
                   EXTRACT(EPOCH FROM (now() - last_used_at))::int AS idle_seconds
              FROM session WHERE jti = %s
            """,
            (jti,),
        )
        session = cur.fetchone()
        if session is None or session["revoked_at"] is not None:
            raise ApiError(401, "TOKEN_INVALID", "refresh token unknown or revoked")
        if str(session["device_id"]) != device_id:
            raise ApiError(401, "TOKEN_INVALID", "the session belongs to another device")
        # A remembered session tolerates the remember window (24h), an ordinary
        # one the short idle TTL (15 min).
        idle_limit = (
            settings.ADMINNG_REMEMBER_TTL
            if session["remember"]
            else settings.ADMINNG_REFRESH_IDLE_TTL
        )
        if session["idle_seconds"] > idle_limit:
            cur.execute("UPDATE session SET revoked_at = now() WHERE jti = %s", (jti,))
            conn.commit()
            raise ApiError(401, "SESSION_EXPIRED", "session expired from inactivity")
        cur.execute("UPDATE session SET revoked_at = now() WHERE jti = %s", (jti,))
        conn.commit()

    device = _device_or_error(device_id)
    _require_approved(device)
    admin = _admin_row(session["username"])
    if admin is None or not admin["active"]:
        raise ApiError(401, "UNAUTHENTICATED", "account disabled")
    return _issue(session["username"], device_id, admin, remember=session["remember"])


def logout_session(refresh_token: str) -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE session SET revoked_at = now() WHERE jti = %s AND revoked_at IS NULL",
            (token_hash(refresh_token),),
        )
        conn.commit()


def reauth_confirm(password: str, principal: Principal, ip: str | None) -> dict:
    """Re-authenticate for a destructive action: 30-second scoped token."""
    try:
        _verify_credentials(principal.username, password)
    except ApiError:
        audit.record(
            actor=principal.username,
            action="REAUTH_FAIL",
            result="denied",
            device_id=principal.device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/reauth-confirm",
        )
        raise
    audit.record(
        actor=principal.username,
        action="REAUTH_OK",
        device_id=principal.device_id,
        ip=ip,
        endpoint="POST /api/v1/auth/reauth-confirm",
    )
    return {
        "security_validation_token": tokens.reauth_token(
            principal.username, principal.device_id
        ),
        "expires_in": settings.ADMINNG_REAUTH_TTL,
    }



