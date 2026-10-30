"""Accounts and addresses (proposal §7.3, D11, decisions of 2026-10-29 in mcp/progress.md).

Login resolution for an address Z that just proved its IMAP password:
- unknown              → new account, Z is its main address
- active in account A  → lands on A (A proved Z's inbox with the magic link)
- disabled in A        → refused ("disabled in another account") until A acts
- pending in A         → owner wins: the pending row is dropped, A's main is notified,
                         Z gets its own account
"""

import datetime as dt
import logging
import re

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from mcpcore import audit, catalogue, domains, imap, mailer, policy
from mcpcore.crypto import new_token, token_hash
from mcpcore.models import Account, AccountAddress, NoticeThrottle

log = logging.getLogger("mcp.accounts")

EMAIL_RE = re.compile(r"^[a-z0-9._+-]+@[a-z0-9.-]+\.[a-z0-9-]+$")


class AccountError(Exception):
    """User-facing failure; `code` is stable for the SPA and the tests."""

    def __init__(self, code: str, message: str, status: int = 400, **extra):
        super().__init__(message)
        self.code, self.message, self.status, self.extra = code, message, status, extra


def normalize(email: str) -> str:
    return (email or "").strip().lower()


def _lang(account: Account) -> str:
    return (account.prefs or {}).get("lang", "en")


def _notify(template: str, to: str, lang: str, **values) -> None:
    try:
        mailer.send(template, to, lang, **values)
    except mailer.MailError:
        pass  # already in the error log; a notice never fails the action that caused it


# ------------------------------------------------------------------- login ---
def login(email: str, password: str, ip: str) -> Account:
    """Verify `email` + `password` over IMAP and return the account it lands on."""
    email = normalize(email)
    if not EMAIL_RE.match(email) or not password:
        raise AccountError("invalid_credentials", "Invalid email or password.", 401)
    if not domains.address_allowed(email):
        raise AccountError("domain_not_allowed", "MailD MCP is not enabled for this domain.", 403)
    if catalogue.mailbox_state(email) is not True:
        raise AccountError("invalid_credentials", "Invalid email or password.", 401)
    try:
        ok = imap.check_user_login(email, password)
    except imap.ImapUnavailable as exc:
        audit.error("web.login", f"IMAP unavailable: {exc}")
        raise AccountError("mail_unavailable", "The mail server is not reachable, try again later.", 503) from None
    if not ok:
        raise AccountError("invalid_credentials", "Invalid email or password.", 401)
    return _resolve(email)


def _resolve(email: str) -> Account:
    notify = None
    with transaction.atomic():
        row = AccountAddress.objects.select_for_update().select_related("account").filter(email=email).first()
        if row and row.status == AccountAddress.ACTIVE:
            account = row.account
        elif row and row.status == AccountAddress.DISABLED:
            raise AccountError("address_disabled_elsewhere",
                               "This address is disabled in another MailD MCP account.", 403)
        else:
            if row:  # pending in another account: the owner wins
                holder = row.account
                notify = ("pending_cancelled", holder.main_email, _lang(holder),
                          {"address": email, "main": holder.main_email})
                audit.event("security", "address_claim_cancelled_by_owner",
                            actor={"type": "user", "email": email},
                            target={"address": email, "holder": holder.main_email})
                row.delete()
            account = Account.objects.create(main_email=email)
            AccountAddress.objects.create(account=account, email=email, is_main=True,
                                          status=AccountAddress.ACTIVE, confirmed_at=timezone.now())
            audit.event("token.lifecycle", "account.created", actor={"type": "user", "email": email,
                                                                    "account": account.id})
        account.last_login_at = timezone.now()
        account.save(update_fields=["last_login_at"])
    if notify:
        _notify(notify[0], notify[1], notify[2], **notify[3])
    return account


# --------------------------------------------------------------- addresses ---
def _link(token: str) -> str:
    return f"{settings.MCP_PUBLIC_URL}/confirm#{token}"


def _arm_magic(row: AccountAddress) -> str:
    token = new_token("mdmcp_ml_")
    row.magic_hash = token_hash(token)
    row.magic_expires_at = timezone.now() + dt.timedelta(seconds=policy.MAGIC_LINK_TTL)
    row.next_resend_at = timezone.now() + dt.timedelta(seconds=policy.resend_delay(row.resend_count))
    return token


def add_address(account: Account, email: str, ip: str) -> AccountAddress:
    email = normalize(email)
    if not EMAIL_RE.match(email):
        raise AccountError("invalid_address", "That is not a valid email address.")
    if not domains.address_allowed(email):
        raise AccountError("domain_not_allowed", "MailD MCP is not enabled for that domain.", 403)
    # only real local mailboxes: the MCP reads them over IMAP and aliases cannot send (§6)
    if catalogue.mailbox_state(email) is not True:
        raise AccountError("not_a_mailbox", "That address is not an active mailbox on this server.")
    if account.addresses.exclude(is_main=True).count() >= policy.MAX_SECONDARY_ADDRESSES:
        raise AccountError("too_many_addresses", "This account already has the maximum number of addresses.")

    existing = AccountAddress.objects.select_related("account").filter(email=email).first()
    if existing:
        if existing.account_id == account.id:
            raise AccountError("already_yours", "That address is already in your account.", 409)
        _claim_conflict(account, email, existing.account, ip)
        raise AccountError("already_in_use", "Already in use.", 409)

    try:
        with transaction.atomic():
            row = AccountAddress(account=account, email=email, status=AccountAddress.PENDING)
            token = _arm_magic(row)
            row.save()
    except IntegrityError:  # raced with another claim
        raise AccountError("already_in_use", "Already in use.", 409) from None
    try:
        mailer.send("magic_link", email, _lang(account), address=email, main=account.main_email, link=_link(token))
    except mailer.MailError:
        row.delete()
        raise AccountError("mail_failed", "The confirmation mail could not be sent, try again later.", 503) from None
    audit.event("token.lifecycle", "address.added", actor={"type": "user", "account": account.id,
                                                          "email": account.main_email},
                target={"address": email}, ip=ip)
    return row


def _claim_conflict(claimer: Account, email: str, holder: Account, ip: str) -> None:
    audit.event("security", "address_claim_conflict", result="denied",
                actor={"type": "user", "account": claimer.id, "email": claimer.main_email},
                target={"address": email, "holder": holder.main_email}, ip=ip, level="warning")
    key = f"{claimer.main_email}|{email}"
    now = timezone.now()
    with transaction.atomic():
        row = NoticeThrottle.objects.select_for_update().filter(kind="claim_conflict", key=key).first()
        if row and (now - row.last_sent_at).total_seconds() < policy.CLAIM_NOTICE_INTERVAL:
            return
        NoticeThrottle.objects.update_or_create(kind="claim_conflict", key=key, defaults={"last_sent_at": now})
    _notify("claim_conflict", f"postmaster@{settings.DEFAULT_DOMAIN}", "en", claimer=claimer.main_email,
            address=email, holder=holder.main_email, ip=ip or "unknown", when=now.isoformat(timespec="seconds"))


def _own(account: Account, address_id: int, *, secondary: bool = True) -> AccountAddress:
    row = account.addresses.filter(id=address_id).first()
    if row is None:
        raise AccountError("not_found", "No such address in this account.", 404)
    if secondary and row.is_main:
        raise AccountError("main_address", "The main address cannot be changed here.")
    return row


def resend(account: Account, address_id: int, ip: str) -> AccountAddress:
    row = _own(account, address_id)
    if row.status != AccountAddress.PENDING:
        raise AccountError("not_pending", "This address is already confirmed.")
    now = timezone.now()
    if row.next_resend_at and row.next_resend_at > now:
        wait = int((row.next_resend_at - now).total_seconds()) + 1
        raise AccountError("resend_too_soon", f"Wait {wait} s before resending.", 429, retry_after=wait)
    row.resend_count += 1
    token = _arm_magic(row)
    row.save()
    try:
        mailer.send("magic_link", row.email, _lang(account), address=row.email, main=account.main_email, link=_link(token))
    except mailer.MailError:
        raise AccountError("mail_failed", "The confirmation mail could not be sent, try again later.", 503) from None
    audit.event("token.lifecycle", "address.resent", actor={"type": "user", "account": account.id},
                target={"address": row.email}, ip=ip, detail={"resends": row.resend_count})
    return row


def confirm(token: str, ip: str) -> AccountAddress:
    if not token or not token.startswith("mdmcp_ml_"):
        raise AccountError("invalid_link", "This confirmation link is not valid.", 404)
    with transaction.atomic():
        row = AccountAddress.objects.select_for_update().select_related("account").filter(
            magic_hash=token_hash(token), status=AccountAddress.PENDING).first()
        if row is None or not row.magic_expires_at or row.magic_expires_at <= timezone.now():
            raise AccountError("invalid_link", "This confirmation link is not valid or has expired.", 404)
        row.status = AccountAddress.ACTIVE
        row.confirmed_at = timezone.now()
        row.magic_hash = ""
        row.magic_expires_at = None
        row.next_resend_at = None
        row.save()
    audit.event("token.lifecycle", "address.confirmed", actor={"type": "magic_link"},
                target={"address": row.email, "account": row.account_id}, ip=ip)
    return row


def set_address_status(account: Account, address_id: int, enabled: bool, ip: str) -> AccountAddress:
    row = _own(account, address_id)
    if row.status == AccountAddress.PENDING:
        raise AccountError("not_confirmed", "Confirm the address first.")
    target = AccountAddress.ACTIVE if enabled else AccountAddress.DISABLED
    if row.status != target:
        row.status = target
        row.save(update_fields=["status"])
        if not enabled:
            imap.drop(row.email)
        audit.event("token.lifecycle", "address.enabled" if enabled else "address.disabled",
                    actor={"type": "user", "account": account.id}, target={"address": row.email}, ip=ip)
        _notify("address_enabled" if enabled else "address_disabled", account.main_email, _lang(account),
                address=row.email, main=account.main_email)
    return row


def remove_address(account: Account, address_id: int, ip: str) -> None:
    row = _own(account, address_id)
    email = row.email
    row.delete()
    imap.drop(email)
    audit.event("token.lifecycle", "address.removed", actor={"type": "user", "account": account.id},
                target={"address": email}, ip=ip)
    _notify("address_removed", account.main_email, _lang(account), address=email, main=account.main_email)


def set_mcp_enabled(account: Account, enabled: bool, ip: str) -> None:
    account.mcp_enabled = enabled
    account.save(update_fields=["mcp_enabled"])
    audit.event("token.lifecycle", "account.mcp_on" if enabled else "account.mcp_off",
                actor={"type": "user", "account": account.id}, ip=ip)


def set_lang(account: Account, lang: str) -> None:
    if lang not in ("en", "es"):
        raise AccountError("invalid_lang", "Unsupported language.")
    account.prefs = {**(account.prefs or {}), "lang": lang}
    account.save(update_fields=["prefs"])


def purge_expired_pending() -> int:
    deleted, _ = AccountAddress.objects.filter(status=AccountAddress.PENDING,
                                               magic_expires_at__lt=timezone.now()).delete()
    return deleted
