"""Mailbox (user) CRUD, quota usage and the user's alias tags."""

from fastapi import APIRouter, Depends, Response

from .. import catalogue, quota
from ..auth import Principal, get_principal
from ..models import MailboxCreate, MailboxOut, MailboxUpdate, Page, QuotaStatus

router = APIRouter(prefix="/mailboxes", tags=["mailboxes"])


@router.get("", response_model=Page, summary="List mailboxes (cursor-paginated)")
def list_mailboxes(
    domain: str | None = None,
    q: str | None = None,
    active: bool | None = None,
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(get_principal),
) -> dict:
    return catalogue.list_mailboxes(
        principal, domain.lower() if domain else None, q, active, limit, cursor
    )


@router.post("", response_model=MailboxOut, status_code=201, summary="Create a mailbox")
def create_mailbox(
    payload: MailboxCreate, principal: Principal = Depends(get_principal)
) -> dict:
    return catalogue.create_mailbox(principal, payload.model_dump())


@router.get("/{username}", response_model=MailboxOut, summary="Get one mailbox")
def get_mailbox(username: str, principal: Principal = Depends(get_principal)) -> dict:
    return catalogue.get_mailbox(principal, username)


@router.put("/{username}", response_model=MailboxOut, summary="Update a mailbox")
def update_mailbox(
    username: str, payload: MailboxUpdate, principal: Principal = Depends(get_principal)
) -> dict:
    updated = catalogue.update_mailbox(principal, username, payload.model_dump())
    if payload.quota_bytes is not None:
        quota.invalidate(updated["domain"], updated["local_part"])
    return updated


@router.delete(
    "/{username}",
    status_code=204,
    summary="Delete a mailbox (its sessions are revoked; the maildir stays)",
)
def delete_mailbox(username: str, principal: Principal = Depends(get_principal)) -> Response:
    catalogue.delete_mailbox(principal, username)
    local_part, _, domain = username.rpartition("@")
    quota.invalidate(domain, local_part)
    return Response(status_code=204)


@router.get(
    "/{username}/quota",
    response_model=QuotaStatus,
    summary="Quota usage from the Maildir++ .maildirsize accounting",
)
def get_quota(username: str, principal: Principal = Depends(get_principal)) -> dict:
    mailbox = catalogue.get_mailbox(principal, username)
    return quota.quota_status(
        mailbox["username"],
        mailbox["domain"],
        mailbox["local_part"],
        mailbox["quota_bytes"],
    )
