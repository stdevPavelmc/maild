"""Authorization codes and tokens (proposal §8.2, D1, D12).

- Codes: HMAC stored, single use, 2 min, bound to client + redirect URI + PKCE (S256 only) +
  resource.
- Access tokens `mdmcp_oat_…`: opaque, 1 h, audience-bound to MCP_RESOURCE_URL (RFC 8707).
- Refresh tokens `mdmcp_ort_…`: 30 days *sliding* (the D12 idle rule for OAuth: a family unused
  for 30 days dies), rotated on every use; presenting a rotated one again revokes the whole family
  (reuse detection) and is logged as a security event.
"""

import base64
import datetime as dt
import hashlib
import hmac

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from mcpcore import audit, policy
from mcpcore.crypto import display, new_id, new_token, token_hash
from mcpcore.models import Account, OAuthClient, OAuthCode, Token
from oauth import clients
from oauth.errors import OAuthError

ACCESS_PREFIX, REFRESH_PREFIX, CODE_PREFIX = "mdmcp_oat_", "mdmcp_ort_", "mdmcp_oac_"
CODE_TTL = 120


def pkce_ok(verifier: str, challenge: str) -> bool:
    if not verifier or not 43 <= len(verifier) <= 128:
        return False
    digest = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return hmac.compare_digest(digest, challenge)


def new_code(client: OAuthClient, account: Account, scopes: list[str], addresses: list[str] | None,
             redirect_uri: str, resource: str, challenge: str) -> str:
    code = new_token(CODE_PREFIX)
    OAuthCode.objects.create(hash=token_hash(code), client=client, account=account, scopes=scopes, addresses=addresses,
                             redirect_uri=redirect_uri, resource=resource, code_challenge=challenge,
                             expires_at=timezone.now() + dt.timedelta(seconds=CODE_TTL))
    return code


def _pair(account: Account, client: OAuthClient, scopes: list[str], addresses, resource: str, family: str) -> dict:
    access, refresh = new_token(ACCESS_PREFIX), new_token(REFRESH_PREFIX)
    now = timezone.now()
    common = {"account": account, "name": clients.display_name(client), "scopes": scopes, "addresses": addresses,
              "family_id": family, "client_id": client.client_id[:255], "resource": resource}
    Token.objects.create(public_id=new_id(8), kind=Token.OAUTH_ACCESS, hash=token_hash(access),
                         display=display(access, ACCESS_PREFIX),
                         expires_at=now + dt.timedelta(seconds=settings.MCP_OAUTH_ACCESS_TTL), **common)
    Token.objects.create(public_id=new_id(8), kind=Token.OAUTH_REFRESH, hash=token_hash(refresh),
                         display=display(refresh, REFRESH_PREFIX),
                         expires_at=now + dt.timedelta(seconds=settings.MCP_OAUTH_REFRESH_TTL), **common)
    return {"access_token": access, "token_type": "Bearer", "expires_in": settings.MCP_OAUTH_ACCESS_TTL,
            "refresh_token": refresh, "scope": " ".join(scopes)}


def exchange_code(code: str, client_id: str, redirect_uri: str, verifier: str, resource: str, ip: str) -> dict:
    with transaction.atomic():
        row = OAuthCode.objects.select_for_update().select_related("client", "account").filter(
            hash=token_hash(code or "")).first()
        if row is None or row.used or row.expires_at <= timezone.now():
            raise OAuthError("invalid_grant", "the authorization code is invalid, used or expired")
        row.used = True
        row.save(update_fields=["used"])
    if row.client.client_id != client_id:
        raise OAuthError("invalid_grant", "the code was issued to another client")
    if row.redirect_uri != redirect_uri:
        raise OAuthError("invalid_grant", "redirect_uri differs from the authorization request")
    if not pkce_ok(verifier, row.code_challenge):
        raise OAuthError("invalid_grant", "PKCE verification failed")
    if resource and resource != row.resource:
        raise OAuthError("invalid_target", "resource differs from the authorization request")
    family = new_id(12)
    out = _pair(row.account, row.client, row.scopes, row.addresses, row.resource, family)
    audit.event("oauth", "token.issued", actor={"type": "user", "account": row.account_id},
                token={"kind": "oauth", "client": row.client.client_id}, ip=ip, detail={"scopes": row.scopes})
    return out


def _revoke_family(family: str) -> int:
    return Token.objects.filter(family_id=family).exclude(status=Token.REVOKED).update(
        status=Token.REVOKED, disabled_reason="family_revoked")


def refresh(raw: str, client_id: str, scope: str | None, resource: str, ip: str) -> dict:
    reused = _rotated_family(raw)
    if reused:
        # outside the rotation transaction: an error raised inside it would roll the revocation back
        n = _revoke_family(reused.family_id)
        audit.event("security", "oauth.refresh_reuse", result="family_revoked", level="warning",
                    actor={"type": "user", "account": reused.account_id},
                    token={"kind": "oauth", "client": reused.client_id}, ip=ip, detail={"revoked": n})
        raise OAuthError("invalid_grant", "refresh token reuse detected: every token of this grant is revoked")
    with transaction.atomic():
        # lock only the token row: `account` is a nullable FK (outer join), which FOR UPDATE refuses
        tok = Token.objects.select_for_update(of=("self",)).select_related("account").filter(
            hash=token_hash(raw or ""), kind=Token.OAUTH_REFRESH).first()
        if tok is None:
            raise OAuthError("invalid_grant", "unknown refresh token")
        if tok.status != Token.ACTIVE or (tok.expires_at and tok.expires_at <= timezone.now()):
            raise OAuthError("invalid_grant", "the refresh token is no longer valid: authorize again")
        if tok.client_id != client_id[:255]:
            raise OAuthError("invalid_grant", "the refresh token belongs to another client")
        if resource and resource != tok.resource:
            raise OAuthError("invalid_target", "resource differs from the grant")
        scopes = tok.scopes
        if scope:
            asked = scope.split()
            if not set(asked) <= set(tok.scopes):
                raise OAuthError("invalid_scope", "a refresh cannot widen the granted scopes")
            scopes = asked
        tok.status, tok.disabled_reason = Token.REVOKED, "rotated"
        tok.save(update_fields=["status", "disabled_reason"])
        client = OAuthClient.objects.filter(client_id=tok.client_id).first()
        if client is None:
            raise OAuthError("invalid_client", "the client is gone")
        return _pair(tok.account, client, scopes, tok.addresses, tok.resource, tok.family_id)


def _rotated_family(raw: str) -> Token | None:
    """The token, when `raw` is a refresh token that an earlier rotation already replaced."""
    return Token.objects.filter(hash=token_hash(raw or ""), kind=Token.OAUTH_REFRESH, status=Token.REVOKED,
                                disabled_reason="rotated").first()


def revoke(raw: str, ip: str) -> None:
    """RFC 7009: always succeeds from the caller's point of view. A refresh token takes its whole
    family with it; an access token only itself."""
    tok = Token.objects.filter(hash=token_hash(raw or ""), kind__in=(Token.OAUTH_ACCESS, Token.OAUTH_REFRESH)).first()
    if tok is None:
        return
    if tok.kind == Token.OAUTH_REFRESH:
        _revoke_family(tok.family_id)
    else:
        Token.objects.filter(id=tok.id).update(status=Token.REVOKED, disabled_reason="revoked")
    audit.event("oauth", "token.revoked", actor={"type": "client"}, token={"kind": "oauth", "client": tok.client_id}, ip=ip)


def scopes_from(raw: str | None) -> list[str]:
    asked = (raw or "mail.read").split()
    bad = [s for s in asked if s not in policy.SCOPES]
    if bad:
        raise OAuthError("invalid_scope", f"unknown scope(s): {', '.join(bad)}")
    return list(dict.fromkeys(asked))
