"""PostfixAdmin-compatible alias-domain CRUD (deletes need re-auth)."""

from fastapi import APIRouter, Depends, Request, Response

from .. import audit, catalogue
from ..auth import Principal, get_principal, require_reauth
from ..models import DomainAliasCreate, DomainAliasOut, DomainAliasUpdate, Page

router = APIRouter(prefix="/domain-aliases", tags=["domain aliases"])


def _audit(request, principal, action, alias_domain, target_domain, **details):
    audit.record(
        actor=principal.username,
        action=action,
        device_id=principal.device_id,
        entity_type="domain_alias",
        entity_id=alias_domain,
        domain=target_domain,
        ip=audit.client_ip(request),
        endpoint=f"{request.method} {request.url.path}",
        **details,
    )


@router.get("", response_model=Page, summary="List alias domains")
def list_domain_aliases(
    domain: str | None = None,
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(get_principal),
) -> dict:
    return catalogue.list_domain_aliases(
        principal, domain.lower() if domain else None, limit, cursor
    )


@router.post(
    "", response_model=DomainAliasOut, status_code=201, summary="Create an alias domain"
)
def create_domain_alias(
    payload: DomainAliasCreate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    created = catalogue.create_domain_alias(principal, payload.model_dump())
    _audit(
        request,
        principal,
        "DOMAIN_ALIAS_CREATE",
        created["alias_domain"],
        created["target_domain"],
        active=created["active"],
    )
    return created


@router.get("/{alias_domain}", response_model=DomainAliasOut, summary="Get an alias domain")
def get_domain_alias(
    alias_domain: str, principal: Principal = Depends(get_principal)
) -> dict:
    return catalogue.get_domain_alias(principal, alias_domain.lower())


@router.put("/{alias_domain}", response_model=DomainAliasOut, summary="Update an alias domain")
def update_domain_alias(
    alias_domain: str,
    payload: DomainAliasUpdate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    updated = catalogue.update_domain_alias(
        principal, alias_domain.lower(), payload.model_dump()
    )
    _audit(
        request,
        principal,
        "DOMAIN_ALIAS_UPDATE",
        updated["alias_domain"],
        updated["target_domain"],
        changed=sorted(key for key, value in payload.model_dump().items() if value is not None),
    )
    return updated


@router.delete(
    "/{alias_domain}",
    status_code=204,
    summary="Delete an alias domain (re-auth)",
)
def delete_domain_alias(
    alias_domain: str,
    request: Request,
    principal: Principal = Depends(require_reauth),
) -> Response:
    current = catalogue.get_domain_alias(principal, alias_domain.lower())
    catalogue.delete_domain_alias(principal, alias_domain.lower())
    _audit(
        request,
        principal,
        "DOMAIN_ALIAS_DELETE",
        current["alias_domain"],
        current["target_domain"],
    )
    return Response(status_code=204)
