"""Mailbox (user) CRUD, quota usage and alias tags (deletes need re-auth)."""

from fastapi import APIRouter, Depends, Request, Response

from .. import audit, catalogue, quota, settings
from ..auth import Principal, get_principal, require_reauth
from ..models import MailboxCreate, MailboxOut, MailboxUpdate, Page, QuotaStatus

router = APIRouter(prefix="/mailboxes", tags=["mailboxes"])


def _audit(request, principal, action, username, domain, **details):
    audit.record(
        actor=principal.username,
        action=action,
        device_id=principal.device_id,
        entity_type="mailbox",
        entity_id=username,
        domain=domain,
        ip=audit.client_ip(request),
        endpoint=f"{request.method} {request.url.path}",
        **details,
    )


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
    payload: MailboxCreate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    created = catalogue.create_mailbox(principal, payload.model_dump())
    _audit(request, principal, "MAILBOX_CREATE", created["username"], created["domain"],
           quota_bytes=created["quota_bytes"], hash_scheme=settings.PASSWORD_SCHEME)
    return created


@router.get("/{username}", response_model=MailboxOut, summary="Get one mailbox")
def get_mailbox(username: str, principal: Principal = Depends(get_principal)) -> dict:
    return catalogue.get_mailbox(principal, username)


@router.put("/{username}", response_model=MailboxOut, summary="Update a mailbox")
def update_mailbox(
    username: str,
    payload: MailboxUpdate,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    updated = catalogue.update_mailbox(principal, username, payload.model_dump())
    if payload.quota_bytes is not None:
        quota.invalidate(updated["domain"], updated["local_part"])
    _audit(
        request,
        principal,
        "MAILBOX_UPDATE",
        updated["username"],
        updated["domain"],
        changed=sorted(k for k, v in payload.model_dump().items() if v is not None),
        **({"hash_scheme": settings.PASSWORD_SCHEME} if payload.password is not None else {}),
    )
    return updated


@router.delete(
    "/{username}",
    status_code=204,
    summary="Delete a mailbox (re-auth; sessions revoked, maildir stays)",
)
def delete_mailbox(
    username: str,
    request: Request,
    principal: Principal = Depends(require_reauth),
) -> Response:
    mailbox = catalogue.get_mailbox(principal, username)
    catalogue.delete_mailbox(principal, username)
    quota.invalidate(mailbox["domain"], mailbox["local_part"])
    _audit(request, principal, "MAILBOX_DELETE", username, mailbox["domain"])
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
