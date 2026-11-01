"""Functional audit trail (the `audit_event` table) — best effort, never fatal.

The Logs UI reads these rows: who did what, on which entity/domain, from which
device and IP, with which result. A failing insert is logged to stderr but does
not fail the operation it describes (an audit outage must not take the admin
interface down with it).
"""

import ipaddress
import json
import sys

from . import settings
from .db import connect

# Trusted proxies whose X-Forwarded-For is believed (2026-10 audit H-02). The
# socket peer is always appended to the chain by `client_ip`, so a direct caller
# can never impersonate somebody else by sending the header.
_TRUSTED = [
    ipaddress.ip_network(cidr, strict=False)
    for cidr in settings.ADMINNG_TRUSTED_PROXIES
]
# Inside the trusted subnets but never a proxy: the docker gateway (H-02 follow-up).
_UNTRUSTED = {ipaddress.ip_address(addr) for addr in settings.ADMINNG_UNTRUSTED_HOPS}


def _is_proxy(hop: str) -> bool:
    """Raises ValueError on an unparseable hop (the caller fails closed)."""
    address = ipaddress.ip_address(hop)
    return address not in _UNTRUSTED and any(address in net for net in _TRUSTED)


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
    """The client address of a request: the right-most X-Forwarded-For hop that
    is not a trusted proxy, else the socket peer.

    The *left-most* XFF value is always client-controlled (nginx appends, it does
    not replace), so trusting it let anyone rotate the login-lockout key and forge
    the IP in their own audit rows (2026-10 audit H-02). The chain is walked
    right-to-left — the same rule as the MCP (mcp/app/asgi.py) — with the socket
    peer appended, and every hop is validated: an unparseable hop fails closed to
    the socket peer, which is also what an empty trust set returns. The docker
    gateway is never a proxy (published-port / host traffic comes from there).
    """
    peer = request.client.host if request.client else None
    if not _TRUSTED:
        return peer
    hops = [
        hop.strip()
        for hop in request.headers.get("x-forwarded-for", "").split(",")
        if hop.strip()
    ]
    try:
        for hop in reversed(hops + ([peer] if peer else [])):
            if not _is_proxy(hop):
                return hop
        return hops[0] if hops else peer
    except ValueError:
        return peer
