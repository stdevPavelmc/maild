"""Web login plumbing (proposal §7.1): ALTCHA, lockout and sessions.

- ALTCHA v1 (SHA-256 proof-of-work, D3): HMAC key derived from MCP_SECRET_KEY, 10 min expiry,
  each solved challenge accepted once.
- Lockout: 5 failures per username+IP → 15 min (same policy as AdminNG).
- Session: access JWT (15 min, held in memory by the SPA, `Authorization: Bearer`) + refresh
  token in an HttpOnly cookie that rotates on every use; the `web_session` row carries the
  absolute lifetime (24 h user), and presenting a superseded refresh token revokes the session.
"""

import datetime as dt
import secrets

import altcha
import jwt
from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from mcpcore import policy
from mcpcore.crypto import derived_key, new_id, token_hash
from mcpcore.models import AltchaUsed, LoginFailure, WebSession

ALTCHA_MAX_NUMBER = 100_000
ALTCHA_TTL = 600
REFRESH_COOKIE = "mdmcp_refresh"
REFRESH_PATH = "/webapi"


# ------------------------------------------------------------------- altcha ---
def _altcha_key() -> str:
    return derived_key("altcha").hex()


def altcha_challenge() -> dict:
    ch = altcha.create_challenge_v1(altcha.ChallengeOptionsV1(
        hmac_key=_altcha_key(), max_number=ALTCHA_MAX_NUMBER,
        expires=dt.datetime.now() + dt.timedelta(seconds=ALTCHA_TTL)))
    return {"algorithm": ch.algorithm, "challenge": ch.challenge, "maxnumber": ch.max_number,
            "salt": ch.salt, "signature": ch.signature}


def altcha_verify(payload: str) -> bool:
    """Valid, unexpired and never used before."""
    if not payload or len(payload) > 4096:
        return False
    try:
        ok, _err = altcha.verify_solution_v1(payload, _altcha_key(), True)
    except Exception:
        return False
    if not ok:
        return False
    import base64
    import json

    try:
        sig = json.loads(base64.b64decode(payload))["signature"]
    except Exception:
        return False
    AltchaUsed.objects.filter(expires_at__lt=timezone.now()).delete()
    try:
        with transaction.atomic():
            AltchaUsed.objects.create(signature=sig[:128],
                                      expires_at=timezone.now() + dt.timedelta(seconds=ALTCHA_TTL))
    except IntegrityError:
        return False  # replay
    return True


# ------------------------------------------------------------------ lockout ---
def locked(key: str, ip: str) -> bool:
    row = LoginFailure.objects.filter(key=key, ip=ip).first()
    return bool(row and row.locked_until and row.locked_until > timezone.now())


def record_failure(key: str, ip: str) -> bool:
    """Count a failure; True when it (re)armed the lockout."""
    with transaction.atomic():
        row, _ = LoginFailure.objects.select_for_update().get_or_create(key=key, ip=ip)
        if row.locked_until and row.locked_until <= timezone.now():
            row.count = 0
            row.locked_until = None
        row.count += 1
        armed = row.count >= policy.LOGIN_MAX_FAILURES
        if armed:
            row.locked_until = timezone.now() + dt.timedelta(seconds=policy.LOGIN_LOCKOUT)
        row.save()
    return armed


def clear_failures(key: str, ip: str) -> None:
    LoginFailure.objects.filter(key=key, ip=ip).delete()


# ------------------------------------------------------------------ session ---
def _jwt_key() -> bytes:
    return derived_key("web-jwt")


def _access_token(sess: WebSession) -> str:
    now = int(timezone.now().timestamp())
    claims = {"sid": sess.jti, "sub": str(sess.subject_id), "knd": sess.kind, "iat": now,
              "exp": now + settings.MCP_ACCESS_TTL, "iss": settings.MCP_PUBLIC_URL}
    return jwt.encode(claims, _jwt_key(), algorithm="HS256")


def open_session(kind: str, subject_id: int, login_email: str, ip: str, ua: str) -> tuple[str, str, WebSession]:
    """→ (access JWT, refresh token, row)."""
    refresh = secrets.token_urlsafe(32)
    ttl = settings.MCP_USER_SESSION_TTL
    sess = WebSession.objects.create(
        jti=new_id(), kind=kind, subject_id=subject_id, refresh_hash=token_hash(refresh),
        expires_at=timezone.now() + dt.timedelta(seconds=ttl), login_email=login_email,
        ip=ip[:64], user_agent=ua[:255])
    return _access_token(sess), refresh, sess


def rotate(refresh: str) -> tuple[str, str, WebSession] | None:
    """New (access, refresh) for a valid refresh token. Presenting the token that the last
    rotation superseded (a stolen copy racing the browser, or the other way round) revokes the
    session: both sides must log in again."""
    if not refresh:
        return None
    digest = token_hash(refresh)
    with transaction.atomic():
        sess = WebSession.objects.select_for_update().filter(refresh_hash=digest).first()
        if sess is None:
            reused = WebSession.objects.select_for_update().filter(prev_refresh_hash=digest, revoked_at__isnull=True).first()
            if reused:
                reused.revoked_at = timezone.now()
                reused.save(update_fields=["revoked_at"])
            return None
        if sess.revoked_at or sess.expires_at <= timezone.now():
            return None
        new_refresh = secrets.token_urlsafe(32)
        sess.prev_refresh_hash = digest
        sess.refresh_hash = token_hash(new_refresh)
        sess.save(update_fields=["refresh_hash", "prev_refresh_hash"])
    return _access_token(sess), new_refresh, sess


def verify_access(token: str, kind: str) -> WebSession | None:
    try:
        claims = jwt.decode(token, _jwt_key(), algorithms=["HS256"], issuer=settings.MCP_PUBLIC_URL,
                            options={"require": ["exp", "sid", "sub"]})
    except jwt.PyJWTError:
        return None
    if claims.get("knd") != kind:
        return None
    sess = WebSession.objects.filter(jti=claims["sid"], kind=kind).first()
    if sess is None or sess.revoked_at or sess.expires_at <= timezone.now():
        return None
    return sess


def revoke(sess: WebSession) -> None:
    if sess.revoked_at is None:
        sess.revoked_at = timezone.now()
        sess.save(update_fields=["revoked_at"])
