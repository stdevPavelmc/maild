"""Persistent login rate limiting and lockout (technical-draft §4.6).

The state lives in the `adminng` database (`rate_limit`, migration 004) instead of
process memory, so it survives restarts, is shared by every api replica and can be
cleared from another process with `adminng.py --reset-ratelimit <username>`.

Key = username + IP: five failures lock that pair for
`ADMINNG_LOCKOUT_SECONDS`, while another user behind the same NAT (or the same
user from another network) is unaffected. A successful login clears the counter;
an expired lockout is discarded on the next check.
"""

from . import settings
from .db import connect
from .errors import ApiError


def _key(username: str, ip: str | None) -> tuple[str, str]:
    return username.strip().lower()[:255], (ip or "-")[:64]


def check(username: str, ip: str | None) -> None:
    """Raise 429 while the username+IP pair is locked out."""
    user, addr = _key(username, ip)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT locked_until, "
            "EXTRACT(EPOCH FROM (locked_until - now()))::int AS retry_after "
            "FROM rate_limit WHERE username = %s AND ip = %s",
            (user, addr),
        )
        row = cur.fetchone()
        if row is None or row["locked_until"] is None:
            return
        if row["retry_after"] and row["retry_after"] > 0:
            raise ApiError(
                429,
                "RATE_LIMITED",
                f"too many failed attempts, retry in {row['retry_after']}s",
                retry_after=row["retry_after"],
            )
        # The lockout expired: start from a clean slate.
        cur.execute("DELETE FROM rate_limit WHERE username = %s AND ip = %s", (user, addr))
        conn.commit()


def failure(username: str, ip: str | None) -> bool:
    """Record a failed attempt; True when this attempt triggered the lockout."""
    user, addr = _key(username, ip)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO rate_limit (username, ip, failures, updated_at)
            VALUES (%s, %s, 1, now())
            ON CONFLICT (username, ip) DO UPDATE
               SET failures = rate_limit.failures + 1,
                   updated_at = now()
            RETURNING failures
            """,
            (user, addr),
        )
        failures = cur.fetchone()["failures"]
        locked = failures >= settings.ADMINNG_LOGIN_MAX_FAILURES
        if locked:
            cur.execute(
                "UPDATE rate_limit "
                "SET failures = 0, "
                "    locked_until = now() + make_interval(secs => %s), "
                "    updated_at = now() "
                "WHERE username = %s AND ip = %s",
                (settings.ADMINNG_LOCKOUT_SECONDS, user, addr),
            )
        # Bound the table: entries that have not moved in a day are irrelevant.
        cur.execute("DELETE FROM rate_limit WHERE updated_at < now() - interval '1 day'")
        conn.commit()
    return locked


def success(username: str, ip: str | None) -> None:
    """A correct login clears the counter for this username+IP."""
    user, addr = _key(username, ip)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM rate_limit WHERE username = %s AND ip = %s", (user, addr))
        conn.commit()


def reset(username: str) -> int:
    """Clear every rate-limit row for a username (all IPs). Returns rows removed.

    Used by `adminng.py --reset-ratelimit` (testing/ops): it lifts the lockout
    immediately, no waiting for the 15-minute window.
    """
    user = username.strip().lower()
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM rate_limit WHERE username = %s", (user,))
        removed = cur.rowcount
        conn.commit()
    return removed
