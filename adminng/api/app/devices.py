"""Device registry: the zero-trust gate (technical-draft §4.1/§4.2).

Every client carries an `X-Device-ID` (UUID v4, generated client-side). A device
starts PENDING, becomes APPROVED through the CLI or the superadmin panel, and
REVOKED kills it and every session bound to it. Nothing operational works until
the device is APPROVED.
"""

import psycopg

from . import settings
from .db import connect
from .errors import ApiError, not_found
from .pagination import clamp_limit, decode_cursor, page

VALID_STATES = ("PENDING", "APPROVED", "REVOKED")
_DEVICE_COLUMNS = (
    "device_id, client_type, device_name, associated_user, state, first_seen, "
    "last_seen, approved_at, approved_by, last_ip"
)


def _out(row: dict) -> dict:
    return {
        "device_id": str(row["device_id"]),
        "client_type": row["client_type"],
        "device_name": row["device_name"],
        "associated_user": row["associated_user"],
        "authorization_state": row["state"],
        "first_seen": row["first_seen"],
        "last_seen": row["last_seen"],
        "approved_at": row["approved_at"],
        "approved_by": row["approved_by"],
        "last_ip": row["last_ip"],
    }


def get(device_id: str) -> dict | None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT {_DEVICE_COLUMNS} FROM device WHERE device_id = %s", (device_id,))
        row = cur.fetchone()
    return _out(row) if row else None


def register(device_id: str, client_type: str, device_name: str | None, ip: str | None) -> dict:
    """Handshake: create the device PENDING (or touch it). Revoked stays revoked."""
    name = (device_name or "")[: settings.ADMINNG_DEVICE_NAME_MAX] or None
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO device (device_id, client_type, device_name, state, last_ip)
            VALUES (%s, %s, %s, 'PENDING', %s)
            ON CONFLICT (device_id) DO UPDATE
               SET client_type = EXCLUDED.client_type,
                   device_name = COALESCE(EXCLUDED.device_name, device.device_name),
                   last_ip = COALESCE(EXCLUDED.last_ip, device.last_ip),
                   last_seen = now()
             RETURNING state
            """,
            (device_id, client_type, name, ip),
        )
        state = cur.fetchone()["state"]
        conn.commit()
    if state == "REVOKED":
        raise ApiError(
            403,
            "DEVICE_REVOKED",
            "this device was revoked; an administrator must re-approve it",
            device_id=device_id,
        )
    return get(device_id)


def bind_user(device_id: str, username: str, ip: str | None = None) -> None:
    """Remember which admin verified credentials on the device (the panel shows it)."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE device SET associated_user = %s, last_seen = now(), "
            "last_ip = COALESCE(%s, last_ip) WHERE device_id = %s",
            (username, ip, device_id),
        )
        conn.commit()


def revoke_sessions(device_id: str) -> int:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE session SET revoked_at = now() "
            "WHERE device_id = %s AND revoked_at IS NULL",
            (device_id,),
        )
        revoked = cur.rowcount
        conn.commit()
    return revoked


def set_state(device_id: str, state: str, approved_by: str) -> dict:
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
        conn.commit()
    if state == "REVOKED":
        revoke_sessions(device_id)
    return {"device_id": str(row["device_id"]), "new_state": row["state"], "authorized_by": approved_by}


def list_devices(state: str | None, limit: int, cursor: str | None) -> dict:
    conds, params = ["TRUE"], []
    if state:
        conds.append("state = %s")
        params.append(state)
    if cursor:
        conds.append("first_seen < (SELECT first_seen FROM device WHERE device_id = %s)")
        params.append(decode_cursor(cursor))

    limit = clamp_limit(limit)
    params.append(limit + 1)
    sql = (
        f"SELECT {_DEVICE_COLUMNS} FROM device WHERE {' AND '.join(conds)} "
        "ORDER BY first_seen DESC LIMIT %s"
    )
    try:
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            rows = [_out(row) for row in cur.fetchall()]
    except psycopg.errors.InvalidTextRepresentation:
        raise ApiError(422, "VALIDATION", "invalid cursor") from None
    # The natural key of this list is not unique (first_seen), so the cursor is
    # the last device id and the page helper is bypassed deliberately.
    has_more = len(rows) > limit
    visible = rows[:limit]
    next_cursor = None
    if has_more and visible:
        from .pagination import encode_cursor

        next_cursor = encode_cursor(visible[-1]["device_id"])
    return {"items": visible, "next_cursor": next_cursor}


def count_approved() -> int:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT count(*) AS n FROM device WHERE state = 'APPROVED'")
        return cur.fetchone()["n"]
