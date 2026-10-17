"""Domain CRUD over the PostfixAdmin catalogue."""

from fastapi import APIRouter, Depends, Response

from .. import catalogue
from ..auth import Principal, get_principal
from ..models import DomainCreate, DomainCreated, DomainOut, DomainUpdate, Page

router = APIRouter(prefix="/domains", tags=["domains"])

# A domain created at runtime is invisible to the boot-time domain cachers
# (amavis DKIM keys, mua SnappyMail config, mta virtual aliases) until they
# restart. PostfixAdmin has the same caveat; here it is made explicit.
RESTART_ADVISORY = {
    "code": "RESTART_REQUIRED",
    "services": ["amavis", "mua", "mta"],
    "message": (
        "The domain was created. Restart amavis, mua and mta to generate its "
        "DKIM keys, webmail config and virtual aliases."
    ),
}


@router.get("", response_model=Page, summary="List domains (cursor-paginated)")
def list_domains(
    q: str | None = None,
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(get_principal),
) -> dict:
    return catalogue.list_domains(principal, q, limit, cursor)


@router.post("", response_model=DomainCreated, status_code=201, summary="Create a domain")
def create_domain(
    payload: DomainCreate, principal: Principal = Depends(get_principal)
) -> dict:
    created = catalogue.create_domain(principal, payload.model_dump())
    created["advisories"] = [RESTART_ADVISORY]
    return created


@router.get("/{domain}", response_model=DomainOut, summary="Get one domain")
def get_domain(domain: str, principal: Principal = Depends(get_principal)) -> dict:
    return catalogue.get_domain(principal, domain.lower())


@router.put("/{domain}", response_model=DomainOut, summary="Update a domain")
def update_domain(
    domain: str, payload: DomainUpdate, principal: Principal = Depends(get_principal)
) -> dict:
    return catalogue.update_domain(principal, domain.lower(), payload.model_dump())


@router.delete(
    "/{domain}",
    status_code=204,
    summary="Delete a domain (cascades to its mailboxes, aliases and scopes)",
)
def delete_domain(domain: str, principal: Principal = Depends(get_principal)) -> Response:
    catalogue.delete_domain(principal, domain.lower())
    return Response(status_code=204)
