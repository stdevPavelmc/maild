"""Alias CRUD. `?goto=<mailbox>` backs the user editor's alias tags."""

from fastapi import APIRouter, Depends, Request, Response

from .. import audit, catalogue
from ..auth import Principal, get_principal, require_reauth
from ..models import AliasCreate, AliasOut, AliasUpdate, Page

router = APIRouter(prefix="/aliases", tags=["aliases"])


def _audit(request, principal, action, address, domain):
    audit.record(
        actor=principal.username,
        action=action,
        device_id=principal.device_id,
        entity_type="alias",
        entity_id=address,
        domain=domain,
        ip=audit.client_ip(request),
        endpoint=f"{request.method} {request.url.path}",
    )


@router.get("", response_model=Page, summary="List aliases (cursor-paginated)")
def list_aliases(
    domain: str | None = None,
    goto: str | None = None,
    q: str | None = None,
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(get_principal),
) -> dict:
    return catalogue.list_aliases(
        principal, domain.lower() if domain else None, goto, q, limit, cursor
    )


@router.post("", response_model=AliasOut, status_code=201, summary="Create an alias")
def create_alias(
    payload: AliasCreate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    created = catalogue.create_alias(principal, payload.model_dump())
    _audit(request, principal, "ALIAS_CREATE", created["address"], created["domain"])
    return created


@router.get("/{address}", response_model=AliasOut, summary="Get one alias")
def get_alias(address: str, principal: Principal = Depends(get_principal)) -> dict:
    return catalogue.get_alias(principal, address)


@router.put("/{address}", response_model=AliasOut, summary="Update an alias")
def update_alias(
    address: str,
    payload: AliasUpdate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    updated = catalogue.update_alias(principal, address, payload.model_dump())
    _audit(request, principal, "ALIAS_UPDATE", updated["address"], updated["domain"])
    return updated


@router.delete("/{address}", status_code=204, summary="Delete an alias (re-auth)")
def delete_alias(
    address: str,
    request: Request,
    principal: Principal = Depends(require_reauth),
) -> Response:
    alias = catalogue.get_alias(principal, address)
    catalogue.delete_alias(principal, address)
    _audit(request, principal, "ALIAS_DELETE", address, alias["domain"])
    return Response(status_code=204)
