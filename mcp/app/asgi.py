"""MailD MCP — root ASGI application (served by uvicorn), proposal §3.1.

- `/api/v1/mcp` → bearer wrapper → MCP SDK app (stateless Streamable HTTP)
- everything else → Django (SPA, /webapi, /healthz)
- lifespan → the SDK app's session manager + the hourly jobs loop
- every HTTP request → one access-log line (audit.access)

The bearer wrapper answers what the SDK cannot know (proposal §8.2):
  401 + WWW-Authenticate resource_metadata   missing / invalid / expired / idle token
  403 mcp_disabled                           the account's MCP switch is off
  403 insufficient_scope                     tools/call for a tool outside the token's scopes
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

from mcpcore import audit, authz, jobs, tokens  # noqa: E402
from mcpserver.server import http_app  # noqa: E402

log = logging.getLogger("mcp.asgi")
mcp_app = http_app()
MCP_PATH = "/api/v1/mcp"
MAX_BODY = 4 * 1024 * 1024
_trusted = [ipaddress.ip_network(c, strict=False) for c in settings.MCP_TRUSTED_PROXIES]


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
        # account + addresses are re-read per request (nothing cached in the token)
        p.account.refresh_from_db()
    finally:
        connections.close_all()


async def mcp_endpoint(scope, receive, send):
    ip = client_ip(scope)
    ua = _header(scope, b"user-agent")[:255]
    auth = _header(scope, b"authorization")
    raw = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
    result = await asyncio.to_thread(_bearer_lookup, raw)
    if result.token is None:
        if raw:
            audit.event("bearer.access", "denied", result=result.reason, ip=ip, ua=ua, level="warning")
        await _json(send, 401, {"error": "invalid_token" if raw else "unauthorized", "reason": result.reason},
                    _www_authenticate("invalid_token" if raw else ""))
        return
    tok = result.token
    p = authz.Principal(token=tok, account=tok.account, ip=ip, client=ua, request_id=scope["state"]["request_id"])
    await asyncio.to_thread(_touch, p)
    if not p.account.mcp_enabled:
        audit.event("bearer.access", "denied", result="mcp_disabled", actor=p.audit_actor(),
                    token=p.audit_token(), ip=ip, ua=ua)
        await _json(send, 403, {"error": "mcp_disabled",
                                "error_description": "MCP access is switched off for this account"})
        return

    # buffer the body (bounded) to read the JSON-RPC method, then replay it downstream
    body = b""
    more = True
    while more:
        message = await receive()
        if message["type"] == "http.disconnect":
            return
        body += message.get("body", b"")
        more = message.get("more_body", False)
        if len(body) > MAX_BODY:
            await _json(send, 413, {"error": "request_too_large"})
            return
    missing = [s for s in _scope_needed(body) if s not in p.scopes]
    if missing:
        audit.event("security", "scope_denied", result="denied", actor=p.audit_actor(), token=p.audit_token(),
                    ip=ip, ua=ua, detail={"needed": missing[0]}, level="warning")
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
        else:
            await django_app(scope, receive, logged_send)
    finally:
        if path != "/healthz":
            audit.access({"method": scope.get("method"), "path": path, "status": status["code"],
                          "ms": int((time.monotonic() - started) * 1000), "ip": client_ip(scope),
                          "ua": _header(scope, b"user-agent")[:255], "request_id": request_id})
