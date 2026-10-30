import socket

from django.conf import settings
from django.db import connections
from django.http import JsonResponse


def _db_ok(alias: str) -> bool:
    try:
        with connections[alias].cursor() as cur:
            cur.execute("SELECT 1")
            return cur.fetchone() == (1,)
    except Exception:
        return False
    finally:
        connections[alias].close()


def _imap_ok() -> bool:
    """mda answers with an IMAP greeting (no login: the healthcheck holds no credentials)."""
    try:
        with socket.create_connection((settings.MCP_IMAP_HOST, settings.MCP_IMAP_PORT), timeout=3) as sock:
            sock.settimeout(3)
            greeting = sock.recv(256)
            sock.sendall(b"h LOGOUT\r\n")
        return greeting.startswith(b"* OK")
    except OSError:
        return False


def healthz(request):
    checks = {
        "db": _db_ok("default"),
        "catalogue": _db_ok("catalogue"),
        "imap": _imap_ok(),
    }
    healthy = all(checks.values())
    return JsonResponse(
        {"status": "ok" if healthy else "fail", "checks": checks},
        status=200 if healthy else 503,
    )


_CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
        "worker-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")


def spa(request, index=None):
    """index.html of the user SPA, never cached (the hashed assets under /assets/ are)."""
    from django.http import HttpResponse, HttpResponseNotAllowed

    if request.method not in ("GET", "HEAD"):
        return HttpResponseNotAllowed(["GET", "HEAD"])
    try:
        html = (index or settings.SPA_INDEX).read_bytes()
    except OSError:
        html = b"<!doctype html><title>MailD MCP</title><p>The web UI is not built into this image.</p>"
    resp = HttpResponse(html, content_type="text/html; charset=utf-8")
    resp["Cache-Control"] = "no-cache"
    resp["Content-Security-Policy"] = _CSP
    resp["Referrer-Policy"] = "no-referrer"
    return resp


def admin_spa(request):
    """The admin panel's own index.html (/adminmcp, /adminmcp/reset)."""
    return spa(request, settings.SPA_INDEX.parent / "adminmcp" / "index.html")
