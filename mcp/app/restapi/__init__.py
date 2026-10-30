"""REST mirror of the MCP tools (proposal §4, P5).

  POST /api/v1/mail/<tool>   JSON body = the tool's arguments → 200 + the tool's structured result
  GET  /api/v1/openapi.json  OpenAPI 3.1, generated from the tools' own schemas
  GET  /api/v1/skill.md      SKILL.md for skill-based agents, generated from the same list

Every call goes through the SDK's tool manager, so arguments, validation, authorization and
auditing are the MCP tools' own: REST and MCP cannot drift apart. Authentication is asgi.py's
bearer check with personal access and master tokens only — OAuth access tokens are bound to the
MCP resource (RFC 8707) and refused here (decision 2026-10-30). `get_attachment` answers with the
file itself instead of an embedded resource.
"""

import base64
import json
from urllib.parse import quote

from mcp.server.mcpserver.exceptions import ToolError, UnexpectedToolError
from mcp.types import EmbeddedResource
from pydantic import ValidationError

from mcpcore import audit
from mcpserver.server import REST_PRINCIPAL, CodedToolError, server

from . import docs

PREFIX = "/api/v1/mail"


async def _send(send, status: int, body: bytes, ctype: bytes, headers: list | None = None):
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", ctype), (b"content-length", str(len(body)).encode()),
                            (b"cache-control", b"no-store")] + (headers or [])})
    await send({"type": "http.response.body", "body": body})


async def json_response(send, status: int, data, headers: list | None = None):
    await _send(send, status, json.dumps(data).encode(), b"application/json", headers)


def _failure(exc: ToolError) -> tuple[int, dict]:
    """HTTP status + body for a failed tool call (the SDK wraps what the tool raised)."""
    coded = exc if isinstance(exc, CodedToolError) else exc.__cause__
    if isinstance(coded, CodedToolError):
        body = {"error": coded.code, "message": str(coded)}
        if coded.retryable:
            body["retryable"] = True
        return coded.status, body
    if isinstance(exc.__cause__, ValidationError):
        errors = [{"field": ".".join(str(x) for x in e["loc"]), "message": e["msg"]}
                  for e in exc.__cause__.errors(include_url=False, include_input=False)]
        return 422, {"error": "invalid_arguments", "message": "the arguments do not match the tool's schema",
                     "details": errors}
    if isinstance(exc, UnexpectedToolError):
        audit.error("rest.tool", repr(exc.__cause__))
        return 500, {"error": "internal_error", "message": "unexpected failure, see the server error log"}
    message = str(exc).split(": ", 1)[1] if str(exc).startswith("Error executing tool") else str(exc)
    return 400, {"error": "tool_error", "message": message}


async def call(send, tool: str, args: dict, principal) -> None:
    marker = REST_PRINCIPAL.set(principal)
    try:
        result = await server.call_tool(tool, args)
    except ToolError as exc:
        status, body = _failure(exc)
        await json_response(send, status, body)
        return
    finally:
        REST_PRINCIPAL.reset(marker)
    if tool == "get_attachment":
        res = next((c for c in result.content if isinstance(c, EmbeddedResource)), None)
        if res is None:
            await json_response(send, 500, {"error": "internal_error", "message": "no attachment returned"})
            return
        filename = res.resource.uri.rsplit("/", 1)[-1]
        await _send(send, 200, base64.b64decode(res.resource.blob), (res.resource.mime_type or
                    "application/octet-stream").encode(),
                    [(b"content-disposition", f"attachment; filename*=UTF-8''{quote(filename)}".encode())])
        return
    await json_response(send, 200, result.structured_content or {})


async def public_document(path: str, send) -> bool:
    """Serve the generated OpenAPI / SKILL.md documents; False when `path` is neither."""
    if path == "/api/v1/openapi.json":
        await _send(send, 200, json.dumps(await docs.openapi()).encode(), b"application/json")
        return True
    if path == "/api/v1/skill.md":
        await _send(send, 200, (await docs.skill()).encode(), b"text/markdown; charset=utf-8")
        return True
    return False

