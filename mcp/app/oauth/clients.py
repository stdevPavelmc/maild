"""OAuth clients (proposal §8.2, D1): CIMD first, DCR as the fallback. Public clients only.

CIMD: the client_id IS an https URL of the client's metadata document. Fetching a URL the client
chose is an SSRF risk, so: https only, every resolved address must be public (no private,
loopback, link-local, multicast, reserved, CGNAT…), the connection goes to the address that was
checked (no second DNS lookup → no rebinding), 5 s timeout, 64 KB cap, no redirects followed,
cached by Cache-Control (5 min … 24 h, default 1 h). `MCP_CIMD_DEV_ALLOW` (dev compose only)
exempts listed URL prefixes from the scheme/address checks for the test fixture.

The fetch is reachable without authentication (GET /oauth/authorize), so it is also bounded as a
resource (2026-10 audit M-02): `admit()` caps uncached fetches per source IP and allows only a few
fetches at once — the rest fail fast instead of queueing (both per worker process, MCP_WORKERS
only scales them); a failed URL is remembered for FAILED_TTL in the shared `notice_throttle`
table (kind `cimd_failed`), so a repeat short-circuits on any worker. The view runs the fetch
off Django's shared sync thread. Every fetch failure reaches the browser as one generic message
(no status/liveness oracle); the detail is logged.
"""

import datetime as dt
import http.client
import ipaddress
import json
import logging
import re
import secrets
import socket
import ssl
import threading
import time
from collections import deque
from urllib.parse import urlsplit

from django.conf import settings
from django.utils import timezone

from mcpcore import audit
from oauth.errors import OAuthError
from mcpcore.models import NoticeThrottle, OAuthClient

log = logging.getLogger("mcp.oauth")

MAX_DOC = 64 * 1024
CONNECT_TIMEOUT, READ_TIMEOUT = 2, 3
FETCH_PER_IP, FETCH_PER_IP_WINDOW = 10, 600     # uncached CIMD fetches per source IP
FAILED_TTL = 300                                # a failed URL is not re-fetched for 5 min
FAILED_KIND = "cimd_failed"                     # its notice_throttle rows (shared by the workers)
MAX_CONCURRENT_FETCHES = 4                      # per worker; beyond that fail fast
_TRACK_MAX = 10000                              # bound on the per-IP map below
GENERIC_FETCH_ERROR = "unknown or unreachable client (its client_id metadata document could not be used)"


class FetchFailed(OAuthError):
    """A CIMD fetch/validation failure, already reduced to the generic message: the caller
    remembers the URL (`remember_failure`). Admission refusals (429/503) are plain OAuthErrors."""

    def __init__(self):
        super().__init__("invalid_client", GENERIC_FETCH_ERROR)
CACHE_MIN, CACHE_DEFAULT, CACHE_MAX = 300, 3600, 86400
DCR_PER_IP_PER_HOUR = 20
_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_SCHEME_RE = re.compile(r"^[a-z][a-z0-9+.-]*$")


def _dev_allowed(url: str) -> bool:
    return any(url.startswith(p) for p in settings.MCP_CIMD_DEV_ALLOW)


def is_public(ip: str) -> bool:
    addr = ipaddress.ip_address(ip)
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    return not (addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_multicast or
                addr.is_reserved or addr.is_unspecified or (addr.version == 4 and addr in _CGNAT))


def _resolve_public(host: str, port: int) -> str:
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror:
        raise OAuthError("invalid_client", f"cannot resolve {host}") from None
    ips = sorted({i[4][0] for i in infos})
    if not ips or not all(is_public(ip) for ip in ips):
        raise OAuthError("invalid_client", f"{host} resolves to a non-public address")
    return ips[0]


def check_url(url: str) -> None:
    """The deterministic URL policy (no I/O): its messages only echo the caller's own input."""
    parts = urlsplit(url)
    if parts.scheme != "https" and not (_dev_allowed(url) and parts.scheme == "http"):
        raise OAuthError("invalid_client", "a client_id metadata document must be served over https")
    if not parts.hostname or parts.username or parts.password or parts.fragment:
        raise OAuthError("invalid_client", "malformed client_id URL")


# ------------------------------------------------------- fetch admission (M-02) ---
_lock = threading.Lock()
_fetches_by_ip: dict[str, deque] = {}
_slots = threading.BoundedSemaphore(MAX_CONCURRENT_FETCHES)


def _trim(mapping: dict) -> None:
    while len(mapping) > _TRACK_MAX:
        mapping.pop(next(iter(mapping)))


def admit(ip: str | None) -> None:
    """Gate an uncached fetch: OAuthError when the source IP spent its budget or every fetch slot
    is busy. On success the caller holds a slot and MUST call `release()` once the fetch is over."""
    now = time.monotonic()
    with _lock:
        if ip:
            hits = _fetches_by_ip.setdefault(ip, deque())
            while hits and hits[0] <= now - FETCH_PER_IP_WINDOW:
                hits.popleft()
            if len(hits) >= FETCH_PER_IP:
                raise OAuthError("invalid_client", "too many client lookups from this address, try later",
                                 status=429)
        if not _slots.acquire(blocking=False):
            raise OAuthError("temporarily_unavailable", "the authorization server is busy, try again shortly",
                             status=503)
        if ip:
            hits.append(now)
            _trim(_fetches_by_ip)


def release() -> None:
    _slots.release()


def recently_failed(url: str) -> bool:
    since = timezone.now() - dt.timedelta(seconds=FAILED_TTL)
    return NoticeThrottle.objects.filter(kind=FAILED_KIND, key=url[:512], last_sent_at__gt=since).exists()


def remember_failure(url: str) -> None:
    now = timezone.now()
    NoticeThrottle.objects.filter(kind=FAILED_KIND, last_sent_at__lt=now - dt.timedelta(seconds=FAILED_TTL)).delete()
    NoticeThrottle.objects.update_or_create(kind=FAILED_KIND, key=url[:512], defaults={"last_sent_at": now})


def _reset_guards() -> None:
    """Tests only."""
    global _slots
    with _lock:
        _fetches_by_ip.clear()
        _slots = threading.BoundedSemaphore(MAX_CONCURRENT_FETCHES)


def fetch_document(url: str) -> tuple[dict, int]:
    """→ (metadata, cache seconds). OAuthError on any policy or protocol failure. Network only
    (no ORM): the view runs it in a worker thread."""
    check_url(url)
    parts = urlsplit(url)
    dev = _dev_allowed(url)
    port = parts.port or (443 if parts.scheme == "https" else 80)
    ip = socket.gethostbyname(parts.hostname) if dev else _resolve_public(parts.hostname, port)
    path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
    try:
        conn = http.client.HTTPConnection(ip, port, timeout=CONNECT_TIMEOUT)
        # connect to the checked ADDRESS (no second lookup); a separate, short read deadline
        raw = socket.create_connection((ip, port), timeout=CONNECT_TIMEOUT)
        raw.settimeout(READ_TIMEOUT)
        if parts.scheme == "https":
            # verify the certificate for the NAME
            conn.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=parts.hostname)
        else:
            conn.sock = raw
        conn.request("GET", path, headers={"Host": parts.netloc, "Accept": "application/json",
                                           "User-Agent": "MailD-MCP CIMD fetcher"})
        resp = conn.getresponse()
        if resp.status != 200:
            raise OAuthError("invalid_client", f"client metadata document answered HTTP {resp.status}")
        body = resp.read(MAX_DOC + 1)
        cache_control = resp.getheader("Cache-Control", "")
    except (OSError, http.client.HTTPException, ssl.SSLError) as exc:
        raise OAuthError("invalid_client", f"cannot fetch the client metadata document: {exc}") from None
    finally:
        try:
            conn.close()
        except Exception:
            pass
    if len(body) > MAX_DOC:
        raise OAuthError("invalid_client", "client metadata document too large")
    try:
        doc = json.loads(body)
    except ValueError:
        raise OAuthError("invalid_client", "client metadata document is not JSON") from None
    m = re.search(r"max-age=(\d+)", cache_control or "")
    ttl = min(max(int(m.group(1)), CACHE_MIN), CACHE_MAX) if m else CACHE_DEFAULT
    if "no-store" in (cache_control or ""):
        ttl = CACHE_MIN
    return doc, ttl


def _check_redirect_uri(uri: str) -> None:
    parts = urlsplit(uri)
    if parts.fragment:
        raise OAuthError("invalid_redirect_uri", "redirect URIs may not carry a fragment")
    if parts.scheme == "https" and parts.hostname:
        return
    if parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost", "::1"):
        return
    # private-use URI scheme of a native app (reverse domain, RFC 8252 §7.1)
    if "." in parts.scheme and _SCHEME_RE.match(parts.scheme):
        return
    raise OAuthError("invalid_redirect_uri", f"redirect URI not allowed: {uri}")


def _validate_metadata(doc: dict, client_id: str | None) -> dict:
    if not isinstance(doc, dict):
        raise OAuthError("invalid_client_metadata", "metadata must be a JSON object")
    if client_id is not None and doc.get("client_id") != client_id:
        raise OAuthError("invalid_client", "the document's client_id differs from its URL")
    uris = doc.get("redirect_uris")
    if not isinstance(uris, list) or not uris or not all(isinstance(u, str) for u in uris):
        raise OAuthError("invalid_redirect_uri", "redirect_uris must be a non-empty list")
    for u in uris:
        _check_redirect_uri(u)
    method = doc.get("token_endpoint_auth_method", "none")
    if method != "none":
        raise OAuthError("invalid_client_metadata", "only public clients (token_endpoint_auth_method=none) are supported")
    grants = doc.get("grant_types", ["authorization_code"])
    if not set(grants) <= {"authorization_code", "refresh_token"}:
        raise OAuthError("invalid_client_metadata", "grant_types: authorization_code and refresh_token only")
    name = str(doc.get("client_name") or "")[:100]
    out = {"client_name": name, "redirect_uris": uris[:20], "token_endpoint_auth_method": "none",
           "grant_types": grants, "response_types": ["code"]}
    for k in ("client_uri", "logo_uri", "software_id", "software_version"):
        if isinstance(doc.get(k), str):
            out[k] = doc[k][:512]
    return out


def cached(client_id: str) -> OAuthClient | None:
    """The known client (DCR, or a CIMD document still fresh), or None when it must be fetched.
    OAuthError when the client_id can never be fetched."""
    if not client_id:
        raise OAuthError("invalid_client", "client_id is required")
    row = OAuthClient.objects.filter(client_id=client_id).first()
    if row and (row.kind == OAuthClient.DCR or (row.expires_at and row.expires_at > timezone.now())):
        return row
    if not (client_id.startswith("https://") or _dev_allowed(client_id)):
        raise OAuthError("invalid_client", "unknown client (register it, or use a client_id metadata document URL)")
    check_url(client_id)
    if recently_failed(client_id):
        raise FetchFailed()
    return None


def fetch_validated(client_id: str, ip: str | None) -> tuple[dict, int]:
    """Admission + fetch + validation of a CIMD document → (metadata, ttl). Network only (no ORM):
    safe to run in a worker thread. Every failure past admission is logged with its real cause
    and raised as FetchFailed (the generic message); the caller then `remember_failure`s it."""
    admit(ip)
    try:
        doc, ttl = fetch_document(client_id)
        return _validate_metadata(doc, client_id), ttl
    except OAuthError as exc:
        log.info("CIMD fetch refused: client_id=%s ip=%s cause=%s", client_id, ip, exc.message)
        raise FetchFailed() from None
    except Exception:
        log.exception("CIMD fetch crashed: client_id=%s ip=%s", client_id, ip)
        raise FetchFailed() from None
    finally:
        release()


def store(client_id: str, meta: dict, ttl: int) -> OAuthClient:
    now = timezone.now()
    row, _ = OAuthClient.objects.update_or_create(client_id=client_id, defaults={
        "kind": OAuthClient.CIMD, "metadata": meta, "fetched_at": now, "expires_at": now + dt.timedelta(seconds=ttl)})
    return row


def resolve(client_id: str, ip: str | None = None) -> OAuthClient:
    """The client for an authorize/token call: DCR from the DB, CIMD from the cache or the web
    (synchronous composition of cached → fetch_validated → store; the authorize view runs the
    same steps with the fetch off the shared sync thread)."""
    row = cached(client_id)
    if row is not None:
        return row
    try:
        meta, ttl = fetch_validated(client_id, ip)
    except FetchFailed:
        remember_failure(client_id)
        raise
    return store(client_id, meta, ttl)


def register(data: dict, ip: str) -> OAuthClient:
    """RFC 7591 dynamic registration (public clients only), rate-limited per source address."""
    hour_ago = timezone.now() - dt.timedelta(hours=1)
    if OAuthClient.objects.filter(kind=OAuthClient.DCR, registration_ip=ip, created_at__gte=hour_ago).count() >= DCR_PER_IP_PER_HOUR:
        raise OAuthError("invalid_client_metadata", "too many registrations from this address, try later", status=429)
    meta = _validate_metadata(data, None)
    row = OAuthClient.objects.create(client_id="mdmcp_dcr_" + secrets.token_urlsafe(18), kind=OAuthClient.DCR,
                                     metadata=meta, registration_ip=ip[:64])
    audit.event("oauth", "client.registered", target={"client": row.client_id, "name": meta["client_name"]}, ip=ip)
    return row


def redirect_matches(client: OAuthClient, uri: str) -> bool:
    """Exact match, except a loopback redirect whose port may differ (RFC 8252 §7.3)."""
    registered = client.metadata.get("redirect_uris", [])
    if uri in registered:
        return True
    p = urlsplit(uri)
    if p.scheme == "http" and p.hostname in ("127.0.0.1", "localhost", "::1"):
        for r in registered:
            q = urlsplit(r)
            if q.scheme == "http" and q.hostname == p.hostname and q.path == p.path and q.query == p.query:
                return True
    return False


def display_name(client: OAuthClient) -> str:
    return client.metadata.get("client_name") or urlsplit(client.client_id).hostname or client.client_id
