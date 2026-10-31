"""MailD MCP — root ASGI application (served by uvicorn), proposal §3.1.

- `/api/v1/mcp` → bearer wrapper → MCP SDK app (stateless Streamable HTTP)
- `/api/v1/mail/<tool>` → the same bearer wrapper → the REST mirror (restapi, P5; no OAuth tokens)
- `/api/v1/openapi.json`, `/api/v1/skill.md` → generated public documents
- everything else → Django (SPA, /webapi, /healthz, OAuth)
- lifespan → the SDK app's session manager + the hourly jobs loop
- every HTTP request → one access-log line (audit.access)

The bearer wrapper answers what the SDK cannot know (proposal §8.2):
  401 + WWW-Authenticate resource_metadata   missing / invalid / expired / idle token
  403 mcp_disabled                           the account's MCP switch is off
  403 insufficient_scope                     tools/call for a tool outside the token's scopes
  400 act_as_required / 403 act_as_denied / 403 ip_not_allowed   master tokens (D7, P3):
      X-MailD-Act-As names the one mailbox the request acts on; the CIDR allowlist is checked
and hands the Principal to the tools through the request state.
"""

import asyncio
import ipaddress
import json
import logging
import os
import time
import uuid

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "maild_mcp.settings")

from django.core.asgi import get_asgi_application  # noqa: E402

django_app = get_asgi_application()

from django.conf import settings  # noqa: E402
from django.db import connections  # noqa: E402

import restapi  # noqa: E402
from mcpcore import audit, authz, jobs, notices, tokens  # noqa: E402
from mcpserver.server import http_app  # noqa: E402

log = logging.getLogger("mcp.asgi")
mcp_app = http_app()
MCP_PATH = "/api/v1/mcp"
MAX_BODY = 4 * 1024 * 1024
_trusted = [ipaddress.ip_network(c, strict=False) for c in settings.MCP_TRUSTED_PROXIES]
log.info("X-Forwarded-For trusted from: %s", ", ".join(settings.MCP_TRUSTED_PROXIES) or "nobody (the TCP peer is the client)")


def client_ip(scope) -> str:
    peer = (scope.get("client") or ("", 0))[0]
    if not _trusted:
        return peer
    try:
        chain = [peer]
        for name, value in scope.get("headers", []):
            if name == b"x-forwarded-for":
                chain = [h.strip() for h in value.decode("latin-1").split(",")] + chain
        for hop in reversed(chain):  # rightmost address that is not a trusted proxy
            if not any(ipaddress.ip_address(hop) in n for n in _trusted):
                return hop
        return chain[0]
    except ValueError:
        return peer


def _header(scope, name: bytes) -> str:
    for k, v in scope.get("headers", []):
        if k == name:
            return v.decode("latin-1")
    return ""


async def _json(send, status: int, body: dict, headers: list | None = None):
    payload = json.dumps(body).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(payload)).encode()),
                            (b"cache-control", b"no-store")] + (headers or [])})
    await send({"type": "http.response.body", "body": payload})


def _www_authenticate(error: str = "", scope_needed: str = "") -> list:
    parts = [f'resource_metadata="{settings.MCP_PUBLIC_URL}/.well-known/oauth-protected-resource{MCP_PATH}"']
    if error:
        parts.append(f'error="{error}"')
    if scope_needed:
        parts.append(f'scope="{scope_needed}"')
    return [(b"www-authenticate", ("Bearer " + ", ".join(parts)).encode())]


def _bearer_lookup(raw: str):
    try:
        return tokens.check_bearer(raw)
    finally:
        connections.close_all()


def _scope_needed(body: bytes) -> list[str]:
    """Scopes the JSON-RPC request needs (tools/call only; batches are checked message by message)."""
    try:
        msg = json.loads(body or b"null")
    except ValueError:
        return []
    msgs = msg if isinstance(msg, list) else [msg]
    needed = []
    for m in msgs:
        if isinstance(m, dict) and m.get("method") == "tools/call":
            name = (m.get("params") or {}).get("name")
            needed.append(authz.TOOL_SCOPES.get(name, ""))
    return [n for n in needed if n]


def _touch(p: "authz.Principal"):
    try:
        tokens.touch(p.token, p.ip, p.client)
        if p.account is not None:
            # account + addresses are re-read per request (nothing cached in the token)
            p.account.refresh_from_db()
        notices.after_auth(p)
    finally:
        connections.close_all()


def _act_as_check(p: "authz.MasterPrincipal") -> str:
    try:
        rows = p.addresses()
        return rows[0]["reason"]
    finally:
        connections.close_all()


def _rest_unauthorized(error: str = "") -> list:
    value = 'Bearer realm="MailD MCP REST"' + (f', error="{error}"' if error else "")
    return [(b"www-authenticate", value.encode())]


async def authenticate(scope, send, ip: str, ua: str, rest: bool = False):
    """The bearer checks shared by the MCP endpoint and the REST mirror → a Principal, or None after
    answering the request. The REST mirror refuses OAuth access tokens (bound to the MCP resource)."""
    auth = _header(scope, b"authorization")
    raw = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
    challenge = _rest_unauthorized if rest else _www_authenticate
    result = await asyncio.to_thread(_bearer_lookup, raw)
    if result.token is None:
        if raw:
            audit.event("bearer.access", "denied", result=result.reason, ip=ip, ua=ua, level="warning")
        await _json(send, 401, {"error": "invalid_token" if raw else "unauthorized", "reason": result.reason},
                    challenge("invalid_token" if raw else ""))
        return None
    tok = result.token
    if rest and tok.kind == tok.OAUTH_ACCESS:
        audit.event("bearer.access", "denied", result="wrong_audience", token={"public_id": tok.public_id,
                    "kind": tok.kind}, ip=ip, ua=ua, level="warning")
        await _json(send, 401, {"error": "invalid_token", "reason": "wrong_audience",
                                "error_description": "OAuth tokens are for /api/v1/mcp; the REST API takes a "
                                                     "personal access token"}, challenge("invalid_token"))
        return None
    if tok.kind == tok.MASTER:
        if not tokens.ip_allowed(tok, ip):
            audit.event("security", "master_token_use", result="ip_not_allowed", token={"public_id": tok.public_id,
                        "kind": tok.kind}, ip=ip, ua=ua, level="warning")
            await _json(send, 403, {"error": "ip_not_allowed", "error_description": "source address not in the token's allowlist"})
            return None
        act_as = _header(scope, b"x-maild-act-as").strip().lower()
        if not act_as:
            await _json(send, 400, {"error": "act_as_required",
                                    "error_description": "master tokens need the X-MailD-Act-As: <mailbox> header"})
            return None
        p = authz.MasterPrincipal(token=tok, account=None, ip=ip, client=ua,
                                  request_id=scope["state"]["request_id"], act_as=act_as)
        reason = await asyncio.to_thread(_act_as_check, p)
        if reason:
            audit.event("security", "master_token_use", result=reason, actor=p.audit_actor(), token=p.audit_token(),
                        ip=ip, ua=ua, level="warning")
            await _json(send, 403, {"error": "act_as_denied", "error_description": f"{act_as}: {reason}"})
            return None
        audit.event("security", "master_token_use", actor=p.audit_actor(), token=p.audit_token(), ip=ip, ua=ua,
                    request_id=p.request_id)
    else:
        p = authz.Principal(token=tok, account=tok.account, ip=ip, client=ua, request_id=scope["state"]["request_id"])
    await asyncio.to_thread(_touch, p)
    if p.account is not None and not p.account.mcp_enabled:
        audit.event("bearer.access", "denied", result="mcp_disabled", actor=p.audit_actor(),
                    token=p.audit_token(), ip=ip, ua=ua)
        await _json(send, 403, {"error": "mcp_disabled",
                                "error_description": "MCP access is switched off for this account"})
        return None
    return p


async def read_body(receive, send) -> bytes | None:
    """The whole request body (bounded), or None after a disconnect / a 413 answer."""
    body = b""
    more = True
    while more:
        message = await receive()
        if message["type"] == "http.disconnect":
            return None
        body += message.get("body", b"")
        more = message.get("more_body", False)
        if len(body) > MAX_BODY:
            await _json(send, 413, {"error": "request_too_large"})
            return None
    return body


def _scope_denied(p, ip: str, ua: str, needed: str):
    audit.event("security", "scope_denied", result="denied", actor=p.audit_actor(), token=p.audit_token(),
                ip=ip, ua=ua, detail={"needed": needed}, level="warning")


async def mcp_endpoint(scope, receive, send):
    ip = client_ip(scope)
    ua = _header(scope, b"user-agent")[:255]
    p = await authenticate(scope, send, ip, ua)
    if p is None:
        return

    # buffer the body (bounded) to read the JSON-RPC method, then replay it downstream
    body = await read_body(receive, send)
    if body is None:
        return
    missing = [s for s in _scope_needed(body) if s not in p.scopes]
    if missing:
        _scope_denied(p, ip, ua, missing[0])
        await _json(send, 403, {"error": "insufficient_scope", "scope": missing[0]},
                    _www_authenticate("insufficient_scope", missing[0]))
        return
    audit.event("bearer.access", "mcp", actor=p.audit_actor(), token=p.audit_token(), ip=ip, ua=ua,
                request_id=p.request_id)

    sent = False

    async def replay():
        nonlocal sent
        if not sent:
            sent = True
            return {"type": "http.request", "body": body, "more_body": False}
        return await receive()

    scope["state"]["principal"] = p
    await mcp_app(scope, replay, send)


async def rest_endpoint(scope, receive, send):
    """POST /api/v1/mail/<tool>: the same checks as the MCP endpoint, then the tool itself."""
    tool = scope["path"][len(restapi.PREFIX) + 1:]
    if scope.get("method") != "POST":
        await _json(send, 405, {"error": "method_not_allowed", "error_description": "use POST"}, [(b"allow", b"POST")])
        return
    ip = client_ip(scope)
    ua = _header(scope, b"user-agent")[:255]
    p = await authenticate(scope, send, ip, ua, rest=True)
    if p is None:
        return
    if tool not in authz.TOOL_SCOPES:
        await _json(send, 404, {"error": "unknown_tool", "error_description": "see /api/v1/openapi.json"})
        return
    body = await read_body(receive, send)
    if body is None:
        return
    try:
        args = json.loads(body or b"{}")
    except ValueError:
        args = None
    if not isinstance(args, dict):
        await _json(send, 400, {"error": "invalid_json", "error_description": "the body must be a JSON object"})
        return
    needed = authz.TOOL_SCOPES[tool]
    if needed not in p.scopes:
        _scope_denied(p, ip, ua, needed)
        await _json(send, 403, {"error": "insufficient_scope", "scope": needed},
                    _rest_unauthorized("insufficient_scope"))
        return
    audit.event("bearer.access", "rest", actor=p.audit_actor(), token=p.audit_token(), ip=ip, ua=ua,
                request_id=p.request_id, detail={"tool": tool})
    await restapi.call(send, tool, args, p)


async def lifespan(scope, receive, send):
    """Run the SDK app's lifespan (session manager) and the jobs loop for the process lifetime."""
    task = None
    inner_q: asyncio.Queue = asyncio.Queue()
    outer_q: asyncio.Queue = asyncio.Queue()

    async def inner_receive():
        return await inner_q.get()

    async def inner_send(message):
        await outer_q.put(message)

    mcp_task = asyncio.create_task(mcp_app(scope, inner_receive, inner_send))
    while True:
        message = await receive()
        if message["type"] == "lifespan.startup":
            await inner_q.put(message)
            reply = await outer_q.get()
            if reply["type"] == "lifespan.startup.complete":
                task = asyncio.create_task(jobs.loop())
            await send(reply)
        elif message["type"] == "lifespan.shutdown":
            if task:
                task.cancel()
            await inner_q.put(message)
            reply = await outer_q.get()
            await send(reply)
            await mcp_task
            return


async def application(scope, receive, send):
    if scope["type"] == "lifespan":
        await lifespan(scope, receive, send)
        return
    if scope["type"] != "http":
        await django_app(scope, receive, send)
        return

    request_id = uuid.uuid4().hex[:16]
    scope.setdefault("state", {})["request_id"] = request_id
    started = time.monotonic()
    status = {"code": 0}

    async def logged_send(message):
        if message["type"] == "http.response.start":
            status["code"] = message["status"]
            message.setdefault("headers", [])
            message["headers"] = list(message["headers"]) + [(b"x-request-id", request_id.encode())]
        await send(message)

    path = scope.get("path", "")
    try:
        if path == MCP_PATH or path.startswith(MCP_PATH + "/"):
            await mcp_endpoint(scope, receive, logged_send)
        elif path.startswith(restapi.PREFIX + "/"):
            await rest_endpoint(scope, receive, logged_send)
        elif scope.get("method") in ("GET", "HEAD") and await restapi.public_document(path, logged_send):
            pass
        else:
            await django_app(scope, receive, logged_send)
    finally:
        if path != "/healthz":
            audit.access({"method": scope.get("method"), "path": path, "status": status["code"],
                          "ms": int((time.monotonic() - started) * 1000), "ip": client_ip(scope),
                          "ua": _header(scope, b"user-agent")[:255], "request_id": request_id})
