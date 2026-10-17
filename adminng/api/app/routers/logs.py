"""Audit trail read model (superadmin: all; custom admins: their domains)."""

from fastapi import APIRouter, Depends

from .. import settings
from ..auth import Principal, get_principal
from ..db import connect
from ..models import Page
from ..pagination import clamp_limit, decode_cursor

router = APIRouter(tags=["logs"])


@router.get("/logs", response_model=Page, summary="Security/audit events")
def list_logs(
    actor: str | None = None,
    domain: str | None = None,
    action: str | None = None,
    entity_type: str | None = None,
    entity_id: str | None = None,
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(get_principal),
) -> dict:
    conds, params = ["TRUE"], []
    if not principal.superadmin:
        # Domain admins only see their domains' events (global events stay hidden).
        conds.append("domain = ANY(%s)")
        params.append(principal.domains)
    if actor:
        conds.append("actor = %s")
        params.append(actor)
    if domain:
        if not principal.allows(domain):
            from ..errors import forbidden_tenant

            raise forbidden_tenant()
        conds.append("domain = %s")
        params.append(domain)
    if action:
        conds.append("action = %s")
        params.append(action)
    if entity_type:
        conds.append("entity_type = %s")
        params.append(entity_type)
    if entity_id:
        conds.append("entity_id = %s")
        params.append(entity_id)
    if cursor:
        conds.append("id < %s")
        params.append(int(decode_cursor(cursor)))

    limit = clamp_limit(limit)
    params.append(limit + 1)
    sql = (
        "SELECT id, ts, actor, device_id, action, entity_type, entity_id, domain, "
        "ip, endpoint, result, details FROM audit_event "
        f"WHERE {' AND '.join(conds)} ORDER BY id DESC LIMIT %s"
    )
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = []
        for row in cur.fetchall():
            item = dict(row)
            item["device_id"] = str(item["device_id"]) if item["device_id"] else None
            rows.append(item)

    has_more = len(rows) > limit
    visible = rows[:limit]
    next_cursor = None
    if has_more and visible:
        from ..pagination import encode_cursor

        next_cursor = encode_cursor(str(visible[-1]["id"]))
    return {"items": visible, "next_cursor": next_cursor}
