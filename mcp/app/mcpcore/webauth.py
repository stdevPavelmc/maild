"""Web login plumbing (proposal §7.1): ALTCHA, lockout and sessions.

- ALTCHA v1 (SHA-256 proof-of-work, D3): HMAC key derived from MCP_SECRET_KEY, 10 min expiry,
  each solved challenge accepted once.
- Lockout: 5 failures per username+IP → 15 min (same policy as AdminNG), plus a
  username-independent per-IP cap (20 failures in 15 min → 15 min) so one address cannot spray
  a password across many accounts (2026-10 audit L-03). The MCP client IP is not spoofable.
- ALTCHA cost 1,000,000 (~0.5 s in a browser, ms were enough at 100,000) and at most
  CHALLENGES_PER_IP challenges per minute per IP (per worker).
- Session: access JWT (15 min, held in memory by the SPA, `Authorization: Bearer`) + refresh
  token in an HttpOnly cookie that rotates on every use; the `web_session` row carries the
  absolute lifetime (24 h user), and presenting a superseded refresh token revokes the session.
"""

import datetime as dt
import secrets
import threading
import time
from collections import deque

import altcha
import jwt
from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from mcpcore import policy
from mcpcore.crypto import derived_key, new_id, token_hash
from mcpcore.models import AltchaUsed, LoginFailure, WebSession

ALTCHA_MAX_NUMBER = 1_000_000
ALTCHA_TTL = 600
CHALLENGES_PER_IP = 30
CHALLENGE_WINDOW = 60
_CHALLENGE_TRACK_MAX = 10_000
# login_failure row counting every failed login from an IP, whatever the account ("*" is never a
# valid e-mail address nor an `admin:<name>` key)
IP_KEY = "*"
REFRESH_COOKIE = "mdmcp_refresh"
REFRESH_PATH = "/webapi"
ADMIN_REFRESH_COOKIE = "mdmcp_admin_refresh"
ADMIN_REFRESH_PATH = "/webapi/admin"


# ------------------------------------------------------------------- altcha ---
def _altcha_key() -> str:
    return derived_key("altcha").hex()


_challenge_lock = threading.Lock()
_challenges_by_ip: dict[str, deque] = {}


def challenge_allowed(ip: str | None) -> bool:
    """Sliding-window cap on challenge minting per source IP (in memory, per worker)."""
    if not ip:
        return True
    now = time.monotonic()
    with _challenge_lock:
        hits = _challenges_by_ip.setdefault(ip, deque())
        while hits and hits[0] <= now - CHALLENGE_WINDOW:
            hits.popleft()
        if len(hits) >= CHALLENGES_PER_IP:
            return False
        hits.append(now)
        while len(_challenges_by_ip) > _CHALLENGE_TRACK_MAX:
            _challenges_by_ip.pop(next(iter(_challenges_by_ip)))
    return True


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
    """The username+IP pair or the whole IP is locked out."""
    return LoginFailure.objects.filter(key__in=(key, IP_KEY), ip=ip,
                                       locked_until__gt=timezone.now()).exists()


def _count_failure(key: str, ip: str, limit: int, window: int | None = None) -> bool:
    """Count one failure on a row; True when it (re)armed the lockout. With `window`, a row
    idle for longer starts over (a NAT's occasional typos never add up to a lockout)."""
    with transaction.atomic():
        row, _ = LoginFailure.objects.select_for_update().get_or_create(key=key, ip=ip)
        now = timezone.now()
        expired = row.locked_until is not None and row.locked_until <= now
        stale = window is not None and row.count and row.updated_at < now - dt.timedelta(seconds=window)
        if expired or stale:
            row.count = 0
            row.locked_until = None
        row.count += 1
        armed = row.count >= limit
        if armed:
            row.locked_until = now + dt.timedelta(seconds=policy.LOGIN_LOCKOUT)
        row.save()
    return armed


def record_failure(key: str, ip: str) -> bool:
    """Count a failure for the username+IP and for the IP; True when either lockout armed."""
    armed = _count_failure(key, ip, policy.LOGIN_MAX_FAILURES)
    ip_armed = _count_failure(IP_KEY, ip, policy.LOGIN_IP_MAX_FAILURES, policy.LOGIN_IP_WINDOW)
    return armed or ip_armed


def clear_failures(key: str, ip: str) -> None:
    """A good login clears its own username+IP row only: the per-IP row must not be resettable
    by an attacker who owns one valid account."""
    LoginFailure.objects.filter(key=key, ip=ip).delete()


def purge_failures() -> int:
    """Hourly: rows idle for a day and not locked (spraying leaves one row per tried name)."""
    now = timezone.now()
    old = LoginFailure.objects.filter(updated_at__lt=now - dt.timedelta(days=1))
    return old.exclude(locked_until__gt=now).delete()[0]


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
    ttl = settings.MCP_ADMIN_SESSION_TTL if kind == "admin" else settings.MCP_USER_SESSION_TTL
    sess = WebSession.objects.create(
        jti=new_id(), kind=kind, subject_id=subject_id, refresh_hash=token_hash(refresh),
        expires_at=timezone.now() + dt.timedelta(seconds=ttl), login_email=login_email,
        ip=ip[:64], user_agent=ua[:255])
    return _access_token(sess), refresh, sess


def rotate(refresh: str, kind: str) -> tuple[str, str, WebSession] | None:
    """New (access, refresh) for a valid refresh token of a `kind` session (a token of the other
    kind is unknown here: it neither rotates nor revokes anything). Presenting the token that the last
    rotation superseded (a stolen copy racing the browser, or the other way round) revokes the
    session: both sides must log in again."""
    if not refresh:
        return None
    digest = token_hash(refresh)
    with transaction.atomic():
        sess = WebSession.objects.select_for_update().filter(refresh_hash=digest, kind=kind).first()
        if sess is None:
            reused = WebSession.objects.select_for_update().filter(prev_refresh_hash=digest, kind=kind,
                                                                    revoked_at__isnull=True).first()
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


def revoke_all(kind: str, subject_id: int, keep: str = "") -> int:
    """Revoke every live session of a subject (password reset / change), optionally keeping one."""
    return WebSession.objects.filter(kind=kind, subject_id=subject_id, revoked_at__isnull=True).exclude(
        jti=keep).update(revoked_at=timezone.now())


def revoke(sess: WebSession) -> None:
    if sess.revoked_at is None:
        sess.revoked_at = timezone.now()
        sess.save(update_fields=["revoked_at"])
