"""Functional audit trail (the `audit_event` table) — best effort, never fatal.

The Logs UI reads these rows: who did what, on which entity/domain, from which
device and IP, with which result. A failing insert is logged to stderr but does
not fail the operation it describes (an audit outage must not take the admin
interface down with it).
"""

import json
import sys

from . import settings
from .db import connect


def record(
    *,
    actor: str,
    action: str,
    result: str = "ok",
    device_id: str | None = None,
    entity_type: str | None = None,
    entity_id: str | None = None,
    domain: str | None = None,
    ip: str | None = None,
    endpoint: str | None = None,
    **details,
) -> None:
    try:
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO audit_event
                       (actor, device_id, action, entity_type, entity_id, domain,
                        ip, endpoint, result, details)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    actor,
                    device_id,
                    action,
                    entity_type,
                    entity_id,
                    domain,
                    ip,
                    endpoint,
                    result,
                    json.dumps(details) if details else None,
                ),
            )
            conn.commit()
    except Exception as exc:  # pragma: no cover - audit must never break a request
        print(f"adminng-audit: WARNING - could not record event: {exc}", file=sys.stderr)


def client_ip(request) -> str | None:
    """Real client IP: the nginx proxy forwards X-Forwarded-For."""
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",", 1)[0].strip()
    return request.client.host if request.client else None
