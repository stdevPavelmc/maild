"""Alias CRUD. `?goto=<mailbox>` backs the user editor's alias tags."""

from fastapi import APIRouter, Depends, Response

from .. import catalogue
from ..auth import Principal, get_principal
from ..models import AliasCreate, AliasOut, AliasUpdate, Page

router = APIRouter(prefix="/aliases", tags=["aliases"])


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
def create_alias(payload: AliasCreate, principal: Principal = Depends(get_principal)) -> dict:
    return catalogue.create_alias(principal, payload.model_dump())


@router.get("/{address}", response_model=AliasOut, summary="Get one alias")
def get_alias(address: str, principal: Principal = Depends(get_principal)) -> dict:
    return catalogue.get_alias(principal, address)


@router.put("/{address}", response_model=AliasOut, summary="Update an alias")
def update_alias(
    address: str, payload: AliasUpdate, principal: Principal = Depends(get_principal)
) -> dict:
    return catalogue.update_alias(principal, address, payload.model_dump())


@router.delete("/{address}", status_code=204, summary="Delete an alias")
def delete_alias(address: str, principal: Principal = Depends(get_principal)) -> Response:
    catalogue.delete_alias(principal, address)
    return Response(status_code=204)
