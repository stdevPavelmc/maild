"""JWT helpers: access tokens and the short-lived flow/reauth tokens.

One signing key (ADMINNG_SECRET_KEY), one algorithm (HS256) and a `purpose`
claim that makes a token unusable outside the flow it was minted for:

  access   — 10 min, bound to (username, device_id)
  2fa      — login-step1 -> login-step2, `ADMINNG_FLOW_TTL`
  enroll   — TOTP enrollment window, `ADMINNG_ENROLL_TTL`
  reauth   — destructive-action validation, `ADMINNG_REAUTH_TTL` (30 s)

Every token also carries `did` (the device UUID), so a leaked token cannot be
replayed from another device.
"""

import time
import uuid

import jwt

from . import settings
from .errors import ApiError

ALGORITHM = "HS256"


def _key() -> str:
    if not settings.ADMINNG_SECRET_KEY:
        raise ApiError(500, "MISCONFIGURED", "ADMINNG_SECRET_KEY is not set")
    return settings.ADMINNG_SECRET_KEY


def encode(purpose: str, username: str, device_id: str, ttl: int, **claims) -> str:
    now = int(time.time())
    payload = {
        "sub": username,
        "did": device_id,
        "purpose": purpose,
        "iat": now,
        "exp": now + ttl,
        "jti": uuid.uuid4().hex,
        **claims,
    }
    return jwt.encode(payload, _key(), algorithm=ALGORITHM)


def decode(token: str, purpose: str) -> dict:
    try:
        payload = jwt.decode(token, _key(), algorithms=[ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise ApiError(401, "TOKEN_EXPIRED", f"the {purpose} token expired") from None
    except jwt.InvalidTokenError:
        raise ApiError(401, "TOKEN_INVALID", f"invalid {purpose} token") from None
    if payload.get("purpose") != purpose:
        raise ApiError(401, "TOKEN_INVALID", f"expected a {purpose} token")
    return payload


def access_token(username: str, device_id: str, superadmin: bool, domains: list[str]) -> str:
    return encode(
        "access",
        username,
        device_id,
        settings.ADMINNG_ACCESS_TTL,
        role="superadmin" if superadmin else "domain_admin",
        domains=domains,
    )


def flow_token(username: str, device_id: str) -> str:
    return encode("2fa", username, device_id, settings.ADMINNG_FLOW_TTL)


def enroll_token(username: str, device_id: str) -> str:
    return encode("enroll", username, device_id, settings.ADMINNG_ENROLL_TTL)


def reauth_token(username: str, device_id: str, scope: str = "destructive") -> str:
    return encode(
        "reauth", username, device_id, settings.ADMINNG_REAUTH_TTL, scope=scope
    )
