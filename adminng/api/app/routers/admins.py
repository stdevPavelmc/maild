"""Administrator CRUD — superadmin only (scope, not data, is the privilege)."""

from fastapi import APIRouter, Depends, Response

from .. import catalogue
from ..auth import Principal, require_superadmin
from ..models import AdminCreate, AdminOut, AdminUpdate, Page

router = APIRouter(prefix="/admins", tags=["admins"])


@router.get("", response_model=Page, summary="List administrators")
def list_admins(
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(require_superadmin),
) -> dict:
    return catalogue.list_admins(limit, cursor)


@router.post("", response_model=AdminOut, status_code=201, summary="Create an administrator")
def create_admin(payload: AdminCreate, principal: Principal = Depends(require_superadmin)) -> dict:
    return catalogue.create_admin(principal, payload.model_dump())


@router.get("/{username}", response_model=AdminOut, summary="Get one administrator")
def get_admin(username: str, principal: Principal = Depends(require_superadmin)) -> dict:
    return catalogue.get_admin(username)


@router.put("/{username}", response_model=AdminOut, summary="Update an administrator")
def update_admin(
    username: str, payload: AdminUpdate, principal: Principal = Depends(require_superadmin)
) -> dict:
    return catalogue.update_admin(principal, username, payload.model_dump())


@router.delete("/{username}", status_code=204, summary="Delete an administrator")
def delete_admin(username: str, principal: Principal = Depends(require_superadmin)) -> Response:
    catalogue.delete_admin(principal, username)
    return Response(status_code=204)
