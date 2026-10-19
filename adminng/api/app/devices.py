"""Device registry: the browser identity, its approval, and the trust window.

Each browser mints two values on first run and keeps them in `localStorage`:
`X-Device-ID` (a UUID) and `X-Device-Secret` (32 random bytes, base64url). The
`device` row is the *browser identity*: it stores only `sha256(secret)` and is
never created by an anonymous caller — a device appears the first time a
`login-step1` verifies a real password.

Approval is **device-scoped**: the `device.state` column starts PENDING and
becomes APPROVED through the CLI or the superadmin panel. Once a browser is
APPROVED any admin whose password verifies may sign in from it. The
`device_grant` row is kept as a per-admin activity log (last seen / last IP) and
as the home of the 24h trust window (`trusted_until`) that lets a remembered
login skip the TOTP code.
"""

import hashlib
import hmac

import psycopg

from . import settings
from .db import connect
from .errors import ApiError, not_found, validation
from .pagination import clamp_limit, decode_cursor, encode_cursor

VALID_STATES = ("PENDING", "APPROVED", "REVOKED")
_DEVICE_COLUMNS = (
    "device_id, client_type, device_name, first_seen, last_seen, last_ip, "
    "secret_hash, state, approved_at, approved_by"
)


# ------------------------------------------------------------------- secrets
def hash_secret(secret: str) -> str:
    """Store/lookup form of the browser secret (high entropy ⇒ plain SHA-256)."""
    return hashlib.sha256(secret.encode()).hexdigest()


def secret_matches(secret_hash: str | None, secret: str | None) -> bool:
    if not secret_hash or not secret:
        return False
    return hmac.compare_digest(secret_hash, hash_secret(secret))


def fingerprint(secret_hash: str, device_id: str) -> str:
    """Short, display-only verification code derived from the bound secret.

    Shown on the lock screen and the devices panel so an admin can confirm
    out-of-band which browser is asking for access. Truncated hash: not
    reversible and not usable to authenticate.
    """
    digest = hashlib.sha256(f"{secret_hash}:{device_id}".encode()).hexdigest()[:12]
    return f"{digest[0:4]}-{digest[4:8]}-{digest[8:12]}"


# -------------------------------------------------------------------- output
def _device_out(row: dict) -> dict:
    secret_hash = row.get("secret_hash")
    usernames = list(row.get("usernames") or [])
    return {
        "device_id": str(row["device_id"]),
        # Kept for clients that still expect a single name: the first admin seen.
        "username": usernames[0] if usernames else "",
        "usernames": usernames,
        "client_type": row.get("client_type"),
        "device_name": row.get("device_name"),
        "authorization_state": row["state"],
        "fingerprint": (
            fingerprint(secret_hash, str(row["device_id"])) if secret_hash else None
        ),
        "first_seen": row["first_seen"],
        "last_seen": row["last_seen"],
        "approved_at": row.get("approved_at"),
        "approved_by": row.get("approved_by"),
        "last_ip": row.get("last_ip"),
    }


# -------------------------------------------------------------------- device
def device_row(device_id: str) -> dict | None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            f"SELECT {_DEVICE_COLUMNS} FROM device WHERE device_id = %s", (device_id,)
        )
        return cur.fetchone()


def device_authorized(device_id: str) -> bool:
    device = device_row(device_id)
    return bool(device and device["state"] == "APPROVED")


def register_device(
    device_id: str,
    client_type: str,
    device_name: str | None,
    secret_hash: str,
    ip: str | None,
) -> dict:
    """Create the browser identity (only called after credentials were verified)."""
    name = (device_name or "")[: settings.ADMINNG_DEVICE_NAME_MAX] or None
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO device (device_id, client_type, device_name, secret_hash, last_ip)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (device_id) DO UPDATE
               SET client_type = EXCLUDED.client_type,
                   device_name = COALESCE(EXCLUDED.device_name, device.device_name),
                   secret_hash = COALESCE(device.secret_hash, EXCLUDED.secret_hash),
                   last_ip = COALESCE(EXCLUDED.last_ip, device.last_ip),
                   last_seen = now()
            """,
            (device_id, client_type, name, secret_hash, ip),
        )
        conn.commit()
    return device_row(device_id)


def bind_secret(device_id: str, secret_hash: str) -> None:
    """Bind the secret to a pre-created (secretless) device row, exactly once."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE device SET secret_hash = %s, last_seen = now() "
            "WHERE device_id = %s AND secret_hash IS NULL",
            (secret_hash, device_id),
        )
        conn.commit()


def touch_device(device_id: str, ip: str | None = None) -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE device SET last_seen = now(), "
            "last_ip = COALESCE(%s, last_ip) WHERE device_id = %s",
            (ip, device_id),
        )
        conn.commit()


def set_device_state(device_id: str, state: str, approved_by: str) -> dict:
    """Approve or revoke a browser (the whole device, not one admin)."""
    if state not in ("APPROVED", "REVOKED"):
        raise ApiError(422, "VALIDATION", "state must be APPROVED or REVOKED")
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE device
               SET state = %s,
                   approved_at = CASE WHEN %s = 'APPROVED' THEN now() ELSE approved_at END,
                   approved_by = %s,
                   last_seen = now()
             WHERE device_id = %s
         RETURNING device_id, state
            """,
            (state, state, approved_by, device_id),
        )
        row = cur.fetchone()
        if row is None:
            conn.rollback()
            raise not_found("device", device_id)
        if state == "REVOKED":
            cur.execute("DELETE FROM webauthn_challenge WHERE device_id = %s", (device_id,))
            cur.execute("DELETE FROM webauthn_credential WHERE device_id = %s", (device_id,))
            cur.execute(
                "UPDATE device_grant SET trusted_until = NULL WHERE device_id = %s",
                (device_id,),
            )
            cur.execute(
                "UPDATE session SET revoked_at = now() "
                "WHERE device_id = %s AND revoked_at IS NULL",
                (device_id,),
            )
        conn.commit()
    return {
        "device_id": str(row["device_id"]),
        "new_state": row["state"],
        "authorized_by": approved_by,
    }


def approve_device(
    device_id: str, secret_hash: str | None, approved_by: str
) -> dict:
    """Register (if needed) + APPROVE a browser, without logging an admin."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO device (device_id, client_type, device_name, secret_hash,
                                state, approved_at, approved_by)
            VALUES (%s, 'cli', 'pre-approved via CLI', %s, 'APPROVED', now(), %s)
            ON CONFLICT (device_id) DO UPDATE
               SET secret_hash = COALESCE(device.secret_hash, EXCLUDED.secret_hash),
                   state = 'APPROVED',
                   approved_at = COALESCE(device.approved_at, now()),
                   approved_by = EXCLUDED.approved_by,
                   last_seen = now()
            """,
            (device_id, secret_hash, approved_by),
        )
        conn.commit()
    return device_row(device_id)


def ensure_grant(
    device_id: str, username: str, secret_hash: str | None, approved_by: str
) -> dict:
    """Pre-approval (panel/CLI): APPROVE the browser and log `username` on it.

    The client binds the real secret on its first verified login; when the caller
    already knows it (`--secret`, dev fixtures) it is stored now.
    """
    approve_device(device_id, secret_hash, approved_by)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO device_grant (device_id, username)
            VALUES (%s, %s)
            ON CONFLICT (device_id, username) DO UPDATE
               SET state = 'APPROVED', trusted_until = NULL, last_seen = now()
            """,
            (device_id, username),
        )
        conn.commit()
    return device_row(device_id)


# --------------------------------------------------------------------- grant
def record_login(device_id: str, username: str, ip: str | None) -> None:
    """Touch the per-admin activity log on a verified login."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO device_grant (device_id, username, last_ip)
            VALUES (%s, %s, %s)
            ON CONFLICT (device_id, username) DO UPDATE
               SET last_seen = now(), last_ip = COALESCE(EXCLUDED.last_ip, device_grant.last_ip)
            """,
            (device_id, username, ip),
        )
        cur.execute(
            "UPDATE device SET last_seen = now(), "
            "last_ip = COALESCE(%s, last_ip) WHERE device_id = %s",
            (ip, device_id),
        )
        conn.commit()


def grant_row(device_id: str, username: str) -> dict | None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT device_id, username, state, first_seen, last_seen, "
            "approved_at, approved_by, last_ip, trusted_until FROM device_grant "
            "WHERE device_id = %s AND username = %s",
            (device_id, username),
        )
        return cur.fetchone()


def revoke_grant(device_id: str, username: str) -> dict:
    """Offboard one admin from a browser: deny-list + drop the trust window.

    The browser itself stays approved (device-scoped), but this `(device, admin)`
    row is marked REVOKED so the admin's access tokens stop working immediately
    (not merely when they expire) and its sessions are destroyed.
    """
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE device_grant SET state = 'REVOKED', trusted_until = NULL, "
            "last_seen = now() WHERE device_id = %s AND username = %s",
            (device_id, username),
        )
        if cur.rowcount == 0:
            conn.rollback()
            raise not_found("device user", f"{device_id}/{username}")
        cur.execute(
            "UPDATE session SET revoked_at = now() "
            "WHERE device_id = %s AND username = %s AND revoked_at IS NULL",
            (device_id, username),
        )
        revoked = cur.rowcount
        conn.commit()
    return {
        "device_id": device_id,
        "username": username,
        "sessions_revoked": revoked,
    }


def revoke_device(device_id: str) -> int:
    """Revoke a browser: state REVOKED, every credential/trust/session destroyed."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE device SET state = 'REVOKED', last_seen = now() "
            "WHERE device_id = %s",
            (device_id,),
        )
        if cur.rowcount == 0:
            conn.rollback()
            raise not_found("device", device_id)
        cur.execute("SELECT count(*) AS n FROM device_grant WHERE device_id = %s", (device_id,))
        grants = cur.fetchone()["n"]
        cur.execute("DELETE FROM webauthn_challenge WHERE device_id = %s", (device_id,))
        cur.execute("DELETE FROM webauthn_credential WHERE device_id = %s", (device_id,))
        cur.execute(
            "UPDATE device_grant SET trusted_until = NULL WHERE device_id = %s",
            (device_id,),
        )
        cur.execute(
            "UPDATE session SET revoked_at = now() "
            "WHERE device_id = %s AND revoked_at IS NULL",
            (device_id,),
        )
        conn.commit()
    return grants


# ---------------------------------------------------------------------- trust
def arm_trust(device_id: str, username: str) -> int:
    """Remember this (device, admin) for ADMINNG_REMEMBER_TTL seconds."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE device_grant "
            "SET trusted_until = now() + make_interval(secs => %s), last_seen = now() "
            "WHERE device_id = %s AND username = %s",
            (settings.ADMINNG_REMEMBER_TTL, device_id, username),
        )
        updated = cur.rowcount
        conn.commit()
    return updated


def trust_valid(device_id: str, username: str) -> bool:
    """True while a remembered login on this (device, admin) skips the code."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM device_grant "
            "WHERE device_id = %s AND username = %s AND trusted_until > now()",
            (device_id, username),
        )
        return cur.fetchone() is not None


def clear_trust(device_id: str, username: str | None = None) -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        if username is None:
            cur.execute(
                "UPDATE device_grant SET trusted_until = NULL WHERE device_id = %s",
                (device_id,),
            )
        else:
            cur.execute(
                "UPDATE device_grant SET trusted_until = NULL "
                "WHERE device_id = %s AND username = %s",
                (device_id, username),
            )
        conn.commit()


# ---------------------------------------------------------------------- list
def list_devices(
    state: str | None, username: str | None, limit: int, cursor: str | None
) -> dict:
    conds, params = ["TRUE"], []
    if state:
        conds.append("d.state = %s")
        params.append(state)
    if username:
        conds.append(
            "EXISTS (SELECT 1 FROM device_grant gu "
            "WHERE gu.device_id = d.device_id AND gu.username = %s)"
        )
        params.append(username)
    if cursor:
        try:
            seen, device_id = decode_cursor(cursor).split("|", 1)
        except ValueError:
            raise validation("invalid pagination cursor") from None
        conds.append("(d.first_seen, d.device_id) < (%s, %s)")
        params.extend([seen, device_id])

    limit = clamp_limit(limit)
    params.append(limit + 1)
    sql = (
        "SELECT d.device_id, d.client_type, d.device_name, d.first_seen, d.last_seen, "
        "d.last_ip, d.secret_hash, d.state, d.approved_at, d.approved_by, "
        "COALESCE(array_agg(DISTINCT g.username) "
        "         FILTER (WHERE g.username IS NOT NULL), '{}') AS usernames "
        "FROM device d LEFT JOIN device_grant g ON g.device_id = d.device_id "
        f"WHERE {' AND '.join(conds)} "
        "GROUP BY d.device_id "
        "ORDER BY d.first_seen DESC, d.device_id DESC LIMIT %s"
    )
    try:
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            rows = [_device_out(row) for row in cur.fetchall()]
    except (psycopg.errors.InvalidTextRepresentation, psycopg.errors.DataError):
        raise validation("invalid pagination cursor") from None

    has_more = len(rows) > limit
    visible = rows[:limit]
    next_cursor = None
    if has_more and visible:
        last = visible[-1]
        next_cursor = encode_cursor(f"{last['first_seen'].isoformat()}|{last['device_id']}")
    return {"items": visible, "next_cursor": next_cursor}


def count_approved_devices() -> int:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT count(*) AS n FROM device WHERE state = 'APPROVED'")
        return cur.fetchone()["n"]


def purge_stale_pending(days: int) -> int:
    """Drop PENDING browsers older than `days` (their grants/sessions cascade)."""
    if days <= 0:
        return 0
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "DELETE FROM device WHERE state = 'PENDING' "
            "AND first_seen < now() - make_interval(days => %s)",
            (days,),
        )
        removed = cur.rowcount
        conn.commit()
    return removed
