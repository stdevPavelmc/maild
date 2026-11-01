"""OAuth 2.1 authorization server endpoints (proposal §4, §8.2, D1).

  GET  /.well-known/oauth-protected-resource[/api/v1/mcp]   RFC 9728
  GET  /.well-known/oauth-authorization-server              RFC 8414
  GET  /oauth/authorize    → validates, stores the request, sends the browser to /consent
  POST /oauth/token        authorization_code (PKCE S256) | refresh_token  (form-urlencoded)
  POST /oauth/revoke       RFC 7009
  POST /oauth/register     RFC 7591 (DCR fallback; CIMD is preferred)

Errors before the redirect URI is trusted are shown to the user (never redirected to an
unverified URI); afterwards they go back to the client with `state` and `iss` (RFC 9207).
"""

import asyncio
import datetime as dt
import json
from urllib.parse import urlencode

from asgiref.sync import sync_to_async
from django.conf import settings
from django.http import HttpResponse, HttpResponseRedirect, JsonResponse
from django.utils import timezone
from django.utils.html import escape
from django.views.decorators.http import require_http_methods

from mcpcore import policy
from mcpcore.crypto import new_id
from mcpcore.models import OAuthRequest
from oauth import clients, grants
from oauth.errors import OAuthError

REQUEST_TTL = 600


def _ip(request) -> str:
    from webapi.api import _ip as web_ip

    return web_ip(request)


def _no_store(resp):
    resp["Cache-Control"] = "no-store"
    resp["Pragma"] = "no-cache"
    return resp


def _issuer() -> str:
    return settings.MCP_PUBLIC_URL


def protected_resource(request):
    return JsonResponse({
        "resource": settings.MCP_RESOURCE_URL,
        "authorization_servers": [_issuer()],
        "scopes_supported": list(policy.SCOPES),
        "bearer_methods_supported": ["header"],
        "resource_name": "MailD MCP",
        "resource_documentation": f"{settings.MCP_PUBLIC_URL}/",
    })


def authorization_server(request):
    base = settings.MCP_PUBLIC_URL
    return JsonResponse({
        "issuer": _issuer(),
        "authorization_endpoint": f"{base}/oauth/authorize",
        "token_endpoint": f"{base}/oauth/token",
        "registration_endpoint": f"{base}/oauth/register",
        "revocation_endpoint": f"{base}/oauth/revoke",
        "response_types_supported": ["code"],
        "response_modes_supported": ["query"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none"],
        "revocation_endpoint_auth_methods_supported": ["none"],
        "scopes_supported": list(policy.SCOPES),
        "client_id_metadata_document_supported": True,
        "authorization_response_iss_parameter_supported": True,
    })


def _error_page(message: str, status: int = 400):
    html = (f"<!doctype html><meta charset=utf-8><title>MailD MCP — authorization error</title>"
            f"<body style='font-family:sans-serif;background:#0f172a;color:#e2e8f0;padding:2rem'>"
            f"<h1>Authorization error</h1><p>{escape(message)}</p><p>Close this window and try again from your app.</p>")
    resp = HttpResponse(html, status=status, content_type="text/html; charset=utf-8")
    resp["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
    return resp


def redirect_with(redirect_uri: str, params: dict) -> str:
    params = {**params, "iss": _issuer()}
    sep = "&" if "?" in redirect_uri else "?"
    return redirect_uri + sep + urlencode({k: v for k, v in params.items() if v not in (None, "")})


@require_http_methods(["GET"])
async def authorize(request):
    """Async on purpose (2026-10 audit M-02): an uncached CIMD client_id means a network fetch
    to a URL the anonymous caller chose. Run on Django's shared sync thread it froze every sync
    view of the worker for its whole duration; here it runs in a worker thread, gated by
    `clients.admit` (per-IP budget, fail-fast concurrency cap); a failed URL is remembered in the
    shared notice_throttle table, so `clients.cached` short-circuits its repeats on any worker."""
    client_id = request.GET.get("client_id", "")
    try:
        client = await sync_to_async(clients.cached)(client_id)
        if client is None:
            try:
                meta, ttl = await asyncio.to_thread(clients.fetch_validated, client_id, _ip(request))
            except clients.FetchFailed:
                await sync_to_async(clients.remember_failure)(client_id)
                raise
            client = await sync_to_async(clients.store)(client_id, meta, ttl)
    except OAuthError as exc:
        return _error_page(exc.message, exc.status)
    return await sync_to_async(_authorize_request)(request, client)


def _authorize_request(request, client):
    q = request.GET
    redirect_uri = q.get("redirect_uri", "")
    if not redirect_uri or not clients.redirect_matches(client, redirect_uri):
        return _error_page("The redirect URI is not registered for this client.")
    state = q.get("state", "")
    try:
        if q.get("response_type") != "code":
            raise OAuthError("unsupported_response_type", "only response_type=code is supported")
        if q.get("code_challenge_method") != "S256" or not q.get("code_challenge"):
            raise OAuthError("invalid_request", "PKCE with code_challenge_method=S256 is required")
        resource = q.get("resource") or settings.MCP_RESOURCE_URL
        if resource != settings.MCP_RESOURCE_URL:
            raise OAuthError("invalid_target", f"this server only issues tokens for {settings.MCP_RESOURCE_URL}")
        scopes = grants.scopes_from(q.get("scope"))
    except OAuthError as exc:
        return HttpResponseRedirect(redirect_with(redirect_uri, {"error": exc.code, "error_description": exc.message,
                                                                 "state": state}))
    OAuthRequest.objects.filter(expires_at__lt=timezone.now()).delete()
    req = OAuthRequest.objects.create(
        id=new_id(), client=client, redirect_uri=redirect_uri, state=state[:1024],
        code_challenge=q["code_challenge"][:128], scopes=scopes, resource=resource,
        expires_at=timezone.now() + dt.timedelta(seconds=REQUEST_TTL))
    # the SPA consent page (login + scopes + addresses); the id in the fragment never reaches a log
    return HttpResponseRedirect(f"/consent#{req.id}")


def _form(request) -> dict:
    if request.content_type != "application/x-www-form-urlencoded":
        raise OAuthError("invalid_request", "use application/x-www-form-urlencoded")
    return request.POST


@require_http_methods(["POST"])
def token(request):
    try:
        f = _form(request)
        grant = f.get("grant_type")
        if grant == "authorization_code":
            out = grants.exchange_code(f.get("code", ""), f.get("client_id", ""), f.get("redirect_uri", ""),
                                       f.get("code_verifier", ""), f.get("resource", ""), _ip(request))
        elif grant == "refresh_token":
            out = grants.refresh(f.get("refresh_token", ""), f.get("client_id", ""), f.get("scope"),
                                 f.get("resource", ""), _ip(request))
        else:
            raise OAuthError("unsupported_grant_type", "authorization_code or refresh_token")
    except OAuthError as exc:
        return _no_store(JsonResponse(exc.as_dict(), status=exc.status))
    return _no_store(JsonResponse(out))


@require_http_methods(["POST"])
def revoke(request):
    try:
        f = _form(request)
    except OAuthError as exc:
        return _no_store(JsonResponse(exc.as_dict(), status=exc.status))
    grants.revoke(f.get("token", ""), _ip(request))
    return _no_store(HttpResponse(status=200))


@require_http_methods(["POST"])
def register(request):
    try:
        data = json.loads(request.body or b"{}")
        client = clients.register(data, _ip(request))
    except ValueError:
        return _no_store(JsonResponse({"error": "invalid_client_metadata", "error_description": "body is not JSON"}, status=400))
    except OAuthError as exc:
        return _no_store(JsonResponse(exc.as_dict(), status=exc.status))
    return _no_store(JsonResponse({"client_id": client.client_id, "client_id_issued_at": int(client.created_at.timestamp()),
                                   **client.metadata}, status=201))
