"""Administrator CRUD — role-scoped (technical-draft §5 route table).

A superadmin manages every administrator. A domain admin is the full manager
of its tenant's administrators: it may list, create, update (disable, rotate
passwords, re-assign domains) and delete the non-super administrators whose
whole domain set *and own address* lie inside its own scope (the admin
password mirrors onto the same-named mailbox) — never a superadmin (create,
modify or delete), never an account outside its domains, and never itself.
The destructive DELETE additionally needs the 30-second re-auth token; the
role checks and the last-superadmin guards live in `catalogue` (single choke
point, behind the admin advisory lock so they cannot race).
"""

from fastapi import APIRouter, Depends, Request, Response

from .. import audit, catalogue, settings
from ..auth import Principal, get_principal, require_reauth
from ..models import AdminCreate, AdminOut, AdminUpdate, Page

router = APIRouter(prefix="/admins", tags=["admins"])


def _audit(request, principal, action, username, **details):
    audit.record(
        actor=principal.username,
        action=action,
        device_id=principal.device_id,
        entity_type="admin",
        entity_id=username,
        domain=None,
        ip=audit.client_ip(request),
        endpoint=f"{request.method} {request.url.path}",
        **details,
    )


@router.get("", response_model=Page, summary="List administrators (tenant-scoped)")
def list_admins(
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(get_principal),
) -> dict:
    return catalogue.list_admins(principal, limit, cursor)


@router.post("", response_model=AdminOut, status_code=201, summary="Create an administrator")
def create_admin(
    payload: AdminCreate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    created = catalogue.create_admin(principal, payload.model_dump())
    _audit(request, principal, "ADMIN_CREATE", created["username"],
           hash_scheme=settings.PASSWORD_SCHEME)
    return created


@router.get("/{username}", response_model=AdminOut, summary="Get one administrator")
def get_admin(username: str, principal: Principal = Depends(get_principal)) -> dict:
    return catalogue.get_admin(principal, username)


@router.put("/{username}", response_model=AdminOut, summary="Update an administrator")
def update_admin(
    username: str,
    payload: AdminUpdate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    updated = catalogue.update_admin(principal, username, payload.model_dump())
    _audit(request, principal, "ADMIN_UPDATE", updated["username"],
           **({"hash_scheme": settings.PASSWORD_SCHEME} if payload.password is not None else {}))
    return updated


@router.delete("/{username}", status_code=204, summary="Delete an administrator (re-auth)")
def delete_admin(
    username: str,
    request: Request,
    principal: Principal = Depends(require_reauth),
) -> Response:
    catalogue.delete_admin(principal, username)
    _audit(request, principal, "ADMIN_DELETE", username)
    return Response(status_code=204)
