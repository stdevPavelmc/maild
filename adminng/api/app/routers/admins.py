"""Administrator CRUD — superadmin only (scope, not data, is the privilege)."""

from fastapi import APIRouter, Depends, Request, Response

from .. import audit, catalogue, settings
from ..auth import Principal, require_reauth, require_superadmin
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


@router.get("", response_model=Page, summary="List administrators")
def list_admins(
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(require_superadmin),
) -> dict:
    return catalogue.list_admins(limit, cursor)


@router.post("", response_model=AdminOut, status_code=201, summary="Create an administrator")
def create_admin(
    payload: AdminCreate,
    request: Request,
    principal: Principal = Depends(require_superadmin),
) -> dict:
    created = catalogue.create_admin(principal, payload.model_dump())
    _audit(request, principal, "ADMIN_CREATE", created["username"],
           hash_scheme=settings.PASSWORD_SCHEME)
    return created


@router.get("/{username}", response_model=AdminOut, summary="Get one administrator")
def get_admin(username: str, principal: Principal = Depends(require_superadmin)) -> dict:
    return catalogue.get_admin(username)


@router.put("/{username}", response_model=AdminOut, summary="Update an administrator")
def update_admin(
    username: str,
    payload: AdminUpdate,
    request: Request,
    principal: Principal = Depends(require_superadmin),
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
