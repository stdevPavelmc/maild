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
