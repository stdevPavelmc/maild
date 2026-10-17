"""In-process login rate limiting and lockout (technical-draft §4.6).

MailD runs a single api replica, so an in-memory counter is honest and simple;
every lockout is also written to the audit trail. The key is username+IP, so
one noisy source cannot lock an admin out from a different network.
"""

import time

from . import settings
from .errors import ApiError

_FAILURES: dict[str, list[float]] = {}
_LOCKED_UNTIL: dict[str, float] = {}


def _key(username: str, ip: str | None) -> str:
    return f"{username.strip().lower()}|{ip or '-'}"


def check(username: str, ip: str | None) -> None:
    """Raise 429 while the key is locked out."""
    key = _key(username, ip)
    now = time.time()
    until = _LOCKED_UNTIL.get(key)
    if until is None:
        return
    if until > now:
        retry = int(until - now)
        raise ApiError(
            429,
            "RATE_LIMITED",
            f"too many failed attempts, retry in {retry}s",
            retry_after=retry,
        )
    _LOCKED_UNTIL.pop(key, None)
    _FAILURES.pop(key, None)


def failure(username: str, ip: str | None) -> bool:
    """Record a failed attempt; True when this attempt triggered a lockout."""
    key = _key(username, ip)
    now = time.time()
    attempts = [
        stamp
        for stamp in _FAILURES.get(key, [])
        if now - stamp < settings.ADMINNG_LOCKOUT_SECONDS
    ]
    attempts.append(now)
    if len(attempts) >= settings.ADMINNG_LOGIN_MAX_FAILURES:
        _LOCKED_UNTIL[key] = now + settings.ADMINNG_LOCKOUT_SECONDS
        _FAILURES.pop(key, None)
        return True
    _FAILURES[key] = attempts
    return False


def success(username: str, ip: str | None) -> None:
    key = _key(username, ip)
    _FAILURES.pop(key, None)
    _LOCKED_UNTIL.pop(key, None)
