"""Personal access tokens (proposal §8.2, D12).

- `mdmcp_pat_` + 256 random bits; stored as HMAC-SHA256, shown once.
- Timed (default 30 days) or forever. EVERY PAT turns disabled after 30 days without use
  (anchor = last use, re-enable or creation, whichever is newest): rejected on the next request
  with reason `token_idle` and flipped by the hourly job; the main address gets one notice.
- Re-enabling is only possible from the web page (a fresh login); there is no API for it.
- `last_used_*` is written at most once per hour per token.
"""

import datetime as dt
from dataclasses import dataclass

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from mcpcore import audit, mailer, policy
from mcpcore.accounts import AccountError
from mcpcore.crypto import display, new_id, new_token, token_hash
from mcpcore.models import Account, AccountAddress, Token

PAT_PREFIX = "mdmcp_pat_"
MASTER_PREFIX = "mdmcp_mst_"
TOUCH_EVERY = 3600


def _idle_anchor(tok: Token):
    return max(t for t in (tok.created_at, tok.last_used_at, tok.reenabled_at) if t is not None)


def is_idle(tok: Token, now=None) -> bool:
    now = now or timezone.now()
    return tok.kind == Token.PAT and (now - _idle_anchor(tok)).total_seconds() > policy.PAT_IDLE_LIMIT


def serialize(tok: Token) -> dict:
    return {
        "id": tok.id, "public_id": tok.public_id, "kind": tok.kind, "name": tok.name,
        "display": tok.display, "scopes": tok.scopes, "addresses": tok.addresses,
        "status": tok.status, "disabled_reason": tok.disabled_reason,
        "created_at": tok.created_at, "expires_at": tok.expires_at,
        "last_used_at": tok.last_used_at, "last_used_ip": tok.last_used_ip,
        "last_used_client": tok.last_used_client,
    }


def create_pat(account: Account, name: str, lifetime: str, scopes: list[str], addresses: list[str] | None,
               ip: str) -> tuple[str, Token]:
    name = (name or "").strip()
    if not name or len(name) > 100:
        raise AccountError("invalid_name", "Give the token a name (up to 100 characters).")
    if not scopes or any(s not in policy.SCOPES for s in scopes):
        raise AccountError("invalid_scopes", f"Scopes must be a non-empty subset of {', '.join(policy.SCOPES)}.")
    if lifetime == "forever":
        if not policy.PAT_FOREVER_ALLOWED:
            raise AccountError("forever_not_allowed", "Tokens without expiry are not allowed on this server.")
        expires_at = None
    elif lifetime in (None, "", "default"):
        expires_at = timezone.now() + dt.timedelta(seconds=policy.PAT_DEFAULT_LIFETIME)
    else:
        try:
            days = int(str(lifetime).rstrip("d"))
        except ValueError:
            raise AccountError("invalid_lifetime", "Lifetime is a number of days or 'forever'.") from None
        if not 1 <= days <= 3650:
            raise AccountError("invalid_lifetime", "Lifetime must be between 1 and 3650 days.")
        expires_at = timezone.now() + dt.timedelta(days=days)
    if addresses is not None:
        addresses = sorted({a.strip().lower() for a in addresses if a.strip()})
        owned = set(account.addresses.exclude(status=AccountAddress.PENDING).values_list("email", flat=True))
        if not addresses or not set(addresses) <= owned:
            raise AccountError("invalid_addresses", "Addresses must be confirmed addresses of this account.")
    live = account.tokens.filter(kind=Token.PAT).exclude(status=Token.REVOKED).count()
    if live >= policy.MAX_TOKENS_PER_ACCOUNT:
        raise AccountError("too_many_tokens", "This account already has the maximum number of tokens.")
    raw = new_token(PAT_PREFIX)
    tok = Token.objects.create(
        public_id=new_id(8), kind=Token.PAT, account=account, name=name, hash=token_hash(raw),
        display=display(raw, PAT_PREFIX), scopes=list(scopes), addresses=addresses, expires_at=expires_at)
    audit.event("token.lifecycle", "token.created", actor={"type": "user", "account": account.id},
                token={"public_id": tok.public_id, "kind": tok.kind}, ip=ip,
                detail={"scopes": tok.scopes, "forever": expires_at is None})
    from mcpcore import prefs as prefs_mod

    p = prefs_mod.get(account)
    if p.get("notify_new_token", True):
        try:
            mailer.send("new_token", account.main_email, p.get("lang", "en"), name=name, scopes=", ".join(scopes),
                        main=account.main_email, ip=ip or "unknown", url=settings.MCP_PUBLIC_URL)
        except mailer.MailError:
            pass
    return raw, tok


def change_status(account: Account, token_id: int, action: str, ip: str) -> Token:
    """enable | disable | revoke — from the web page only."""
    with transaction.atomic():
        tok = account.tokens.select_for_update().filter(id=token_id).first()
        if tok is None:
            raise AccountError("not_found", "No such token.", 404)
        if tok.kind == Token.OAUTH_REFRESH:
            # an OAuth grant: only revocation, and it takes the whole family (access + refresh)
            if action != "revoke":
                raise AccountError("invalid_action", "An app connection can only be revoked; the app can reconnect.")
            Token.objects.filter(family_id=tok.family_id).exclude(status=Token.REVOKED).update(
                status=Token.REVOKED, disabled_reason="user")
            tok.refresh_from_db()
            audit.event("token.lifecycle", "oauth.grant_revoked", actor={"type": "user", "account": account.id},
                        token={"public_id": tok.public_id, "kind": tok.kind, "client": tok.client_id}, ip=ip)
            return tok
        if tok.status == Token.REVOKED:
            raise AccountError("revoked", "A revoked token cannot change any more.", 409)
        if action == "revoke":
            tok.status = Token.REVOKED
        elif action == "disable":
            tok.status, tok.disabled_reason = Token.DISABLED, "user"
        elif action == "enable":
            if tok.expires_at and tok.expires_at <= timezone.now():
                raise AccountError("expired", "This token has expired; create a new one.", 409)
            tok.status, tok.disabled_reason = Token.ACTIVE, ""
            tok.reenabled_at = timezone.now()
        else:
            raise AccountError("invalid_action", "Unknown action.")
        tok.save()
    audit.event("token.lifecycle", f"token.{action}", actor={"type": "user", "account": account.id},
                token={"public_id": tok.public_id, "kind": tok.kind}, ip=ip)
    return tok


# ----------------------------------------------------------- bearer check ---
@dataclass
class BearerResult:
    token: Token | None
    reason: str = ""          # missing | invalid | expired | disabled | token_idle | revoked


def _disable_idle(tok: Token) -> bool:
    """Flip an idle PAT to disabled (once) and notify the account's main address."""
    with transaction.atomic():
        fresh = Token.objects.select_for_update().get(id=tok.id)
        if fresh.status != Token.ACTIVE or not is_idle(fresh):
            return False
        fresh.status, fresh.disabled_reason = Token.DISABLED, "idle"
        fresh.save(update_fields=["status", "disabled_reason"])
    audit.event("token.lifecycle", "token.idle_disabled", actor={"type": "system"},
                token={"public_id": tok.public_id, "kind": tok.kind})
    account = tok.account
    if account:
        try:
            mailer.send("token_idle", account.main_email, (account.prefs or {}).get("lang", "en"),
                        name=tok.name, main=account.main_email, url=settings.MCP_PUBLIC_URL)
        except mailer.MailError:
            pass
    return True


def check_bearer(raw: str) -> BearerResult:
    if not raw:
        return BearerResult(None, "missing")
    tok = Token.objects.select_related("account", "admin").filter(hash=token_hash(raw)).first()
    if tok is None or tok.kind not in (Token.PAT, Token.MASTER, Token.OAUTH_ACCESS):
        return BearerResult(None, "invalid")
    # OAuth access tokens are audience-bound (RFC 8707): only for this MCP endpoint
    if tok.kind == Token.OAUTH_ACCESS and tok.resource != settings.MCP_RESOURCE_URL:
        return BearerResult(None, "invalid")
    if tok.status == Token.REVOKED:
        return BearerResult(None, "revoked")
    if tok.status == Token.DISABLED:
        return BearerResult(None, "token_idle" if tok.disabled_reason == "idle" else "disabled")
    if tok.expires_at and tok.expires_at <= timezone.now():
        return BearerResult(None, "expired")
    if is_idle(tok):
        _disable_idle(tok)
        return BearerResult(None, "token_idle")
    return BearerResult(tok)


def touch(tok: Token, ip: str, client: str) -> None:
    now = timezone.now()
    if tok.last_used_at and (now - tok.last_used_at).total_seconds() < TOUCH_EVERY:
        return
    Token.objects.filter(id=tok.id).update(last_used_at=now, last_used_ip=ip[:64], last_used_client=client[:255])


def disable_idle_tokens() -> int:
    """Hourly job: flip every idle active PAT."""
    count = 0
    for tok in Token.objects.select_related("account").filter(kind=Token.PAT, status=Token.ACTIVE):
        if is_idle(tok) and _disable_idle(tok):
            count += 1
    return count


# ------------------------------------------------------------ master tokens ---
def serialize_master(tok: Token) -> dict:
    return {**serialize(tok), "allowed_cidrs": tok.allowed_cidrs or [], "admin": tok.admin.username if tok.admin else ""}


def create_master(admin, name: str, ttl_hours: float | None, scopes: list[str], cidrs: list[str] | None,
                  ip: str) -> tuple[str, Token]:
    """Proposal §7.2 / D7: admin-created, timed (default 24 h, at most MCP_MASTER_TOKEN_MAX_TTL,
    never forever), optional source CIDR allowlist; every use requires X-MailD-Act-As."""
    import ipaddress

    name = (name or "").strip()
    if not name or len(name) > 100:
        raise AccountError("invalid_name", "Give the token a name (up to 100 characters).")
    if not scopes or any(s not in policy.SCOPES for s in scopes):
        raise AccountError("invalid_scopes", f"Scopes must be a non-empty subset of {', '.join(policy.SCOPES)}.")
    ttl = int(float(ttl_hours) * 3600) if ttl_hours else policy.MASTER_TOKEN_DEFAULT_TTL
    if ttl < 60 or ttl > settings.MCP_MASTER_TOKEN_MAX_TTL:
        raise AccountError("invalid_lifetime",
                           f"A master token lives between 1 minute and {settings.MCP_MASTER_TOKEN_MAX_TTL // 3600} hours; never forever.")
    clean = None
    if cidrs:
        try:
            clean = sorted({str(ipaddress.ip_network(c.strip(), strict=False)) for c in cidrs if c.strip()}) or None
        except ValueError as exc:
            raise AccountError("invalid_cidr", f"Not a CIDR: {exc}") from None
    raw = new_token(MASTER_PREFIX)
    tok = Token.objects.create(
        public_id=new_id(8), kind=Token.MASTER, admin=admin, name=name, hash=token_hash(raw),
        display=display(raw, MASTER_PREFIX), scopes=list(scopes), allowed_cidrs=clean,
        expires_at=timezone.now() + dt.timedelta(seconds=ttl))
    audit.event("token.lifecycle", "master.created", actor={"type": "admin", "admin": admin.username},
                token={"public_id": tok.public_id, "kind": tok.kind}, ip=ip,
                detail={"scopes": tok.scopes, "ttl": ttl, "cidrs": clean})
    return raw, tok


def change_master_status(admin, token_id: int, action: str, ip: str) -> Token:
    with transaction.atomic():
        tok = Token.objects.select_for_update().filter(id=token_id, kind=Token.MASTER).first()
        if tok is None:
            raise AccountError("not_found", "No such master token.", 404)
        if tok.status == Token.REVOKED:
            raise AccountError("revoked", "A revoked token cannot change any more.", 409)
        if action == "revoke":
            tok.status = Token.REVOKED
        elif action == "disable":
            tok.status, tok.disabled_reason = Token.DISABLED, "admin"
        elif action == "enable":
            if tok.expires_at and tok.expires_at <= timezone.now():
                raise AccountError("expired", "This token has expired; create a new one.", 409)
            tok.status, tok.disabled_reason = Token.ACTIVE, ""
        else:
            raise AccountError("invalid_action", "Unknown action.")
        tok.save()
    audit.event("token.lifecycle", f"master.{action}", actor={"type": "admin", "admin": admin.username},
                token={"public_id": tok.public_id, "kind": tok.kind}, ip=ip)
    return tok


def ip_allowed(tok: Token, ip: str) -> bool:
    import ipaddress

    if not tok.allowed_cidrs:
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in ipaddress.ip_network(c, strict=False) for c in tok.allowed_cidrs)
