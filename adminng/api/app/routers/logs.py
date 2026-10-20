"""Audit trail read model (superadmin: all; custom admins: their domains)."""

from fastapi import APIRouter, Depends

from .. import settings
from ..auth import Principal, get_principal
from ..db import connect
from ..models import Page
from ..pagination import clamp_limit, decode_cursor

router = APIRouter(tags=["logs"])

# Sentinel value for the "Nobody" actor filter: audit rows whose actor is not
# an existing admin (cli/system/attempted unknown user/deleted admin). The
# `audit_event.actor` column is NOT NULL, so this cannot be `IS NULL`; it is
# resolved in Python to `actor <> ALL(admin usernames)` because the `admin`
# table lives in the catalogue DB while `audit_event` lives in the adminng DB.
NOBODY_ACTOR = "__none__"

FACET_LIMIT = 200


def _admin_usernames() -> list[str]:
    """All usernames in the catalogue `admin` table (for the Nobody filter)."""
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("SELECT username FROM admin ORDER BY 1")
        return [row["username"] for row in cur.fetchall()]


def _tenant_conds(principal: Principal) -> tuple[list[str], list]:
    if principal.superadmin:
        return [], []
    # Domain admins only see their domains' events (global events stay hidden).
    return ["domain = ANY(%s)"], [principal.domains]


def _apply_actor(conds: list[str], params: list, actor: str | None) -> None:
    if not actor:
        return
    if actor == NOBODY_ACTOR:
        # `<> ALL('{}')` is TRUE for every non-null actor, which is exactly
        # the Nobody semantics when the admin table is empty.
        conds.append("actor <> ALL(%s)")
        params.append(_admin_usernames())
    else:
        conds.append("actor = %s")
        params.append(actor)


def _apply_domain(
    conds: list[str], params: list, domain: str | None, principal: Principal
) -> None:
    if not domain:
        return
    if not principal.allows(domain):
        from ..errors import forbidden_tenant

        raise forbidden_tenant()
    conds.append("domain = %s")
    params.append(domain)


@router.get("/logs/facets", summary="Distinct actors/actions for the log filters")
def log_facets(
    domain: str | None = None,
    actor: str | None = None,
    principal: Principal = Depends(get_principal),
) -> dict:
    """Dropdown options for the Logs UI, tenant-scoped like `list_logs`.

    - `actors`: distinct actors visible under the selected `domain`.
    - `actions`: distinct actions visible under `domain` + `actor`.
    """
    tenant_conds, tenant_params = _tenant_conds(principal)

    actor_conds = [*tenant_conds]
    actor_params = [*tenant_params]
    _apply_domain(actor_conds, actor_params, domain, principal)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            f"SELECT DISTINCT actor FROM audit_event WHERE {' AND '.join(['TRUE', *actor_conds])} "
            "ORDER BY 1 LIMIT %s",
            (*actor_params, FACET_LIMIT),
        )
        actors = [row["actor"] for row in cur.fetchall()]

    action_conds = [*actor_conds]
    action_params = [*actor_params]
    _apply_actor(action_conds, action_params, actor)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            f"SELECT DISTINCT action FROM audit_event WHERE {' AND '.join(['TRUE', *action_conds])} "
            "ORDER BY 1 LIMIT %s",
            (*action_params, FACET_LIMIT),
        )
        actions = [row["action"] for row in cur.fetchall()]

    return {"actors": actors, "actions": actions}


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
    tenant_conds, tenant_params = _tenant_conds(principal)
    conds.extend(tenant_conds)
    params.extend(tenant_params)
    _apply_actor(conds, params, actor)
    _apply_domain(conds, params, domain, principal)
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
