"""IMAP access to mda (proposal §5.3).

- STARTTLS on mda:143 (`ssl = required` there). The server certificate is **pinned**: the leaf mda
  presents must be byte-identical to the first certificate in MCP_IMAP_CA_FILE (the same
  /certs/mail.crt both containers mount). Hostname verification cannot work here — the cert is
  issued for the public mail host, not for `mda` — and the pin is stricter than a chain check.
- User logins (web login, §7.3) use a fresh connection with the user's own credentials.
- Mailbox operations use the Dovecot master user (`user@domain*<master>`) through a small
  per-process pool: at most 3 connections per mailbox (`mail_max_userip_connections = 10` is per
  user per IP and every MCP session shares one IP), idle ones closed after 60 s.
"""

import contextlib
import hashlib
import ssl
import threading
import time

import imapclient
from imapclient.exceptions import IMAPClientError, LoginError
from django.conf import settings

MAX_PER_MAILBOX = 3
IDLE_CLOSE = 60.0
NOOP_AFTER = 20.0
TIMEOUT = 20.0


class ImapUnavailable(Exception):
    """mda unreachable, TLS pin mismatch or protocol failure (not a credential problem)."""


_pin_cache: tuple[float, bytes] | None = None


def _pinned_der() -> bytes:
    global _pin_cache
    path = settings.MCP_IMAP_CA_FILE
    try:
        import os

        mtime = os.stat(path).st_mtime
        if _pin_cache and _pin_cache[0] == mtime:
            return _pin_cache[1]
        pem = open(path).read()
    except OSError as exc:
        raise ImapUnavailable(f"cannot read {path}: {exc}") from None
    start = pem.find("-----BEGIN CERTIFICATE-----")
    end = pem.find("-----END CERTIFICATE-----", start)
    if start < 0 or end < 0:
        raise ImapUnavailable(f"{path} holds no PEM certificate")
    der = ssl.PEM_cert_to_DER_cert(pem[start:end + len("-----END CERTIFICATE-----")])
    _pin_cache = (mtime, der)
    return der


def _connect() -> imapclient.IMAPClient:
    pinned = _pinned_der()
    ctx = ssl.create_default_context()
    # the pin below replaces chain + hostname verification (see the module docstring)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        client = imapclient.IMAPClient(settings.MCP_IMAP_HOST, port=settings.MCP_IMAP_PORT,
                                       ssl=False, timeout=TIMEOUT)
        client.starttls(ctx)
        peer = client._imap.sock.getpeercert(binary_form=True)
    except (OSError, IMAPClientError, ssl.SSLError) as exc:
        raise ImapUnavailable(f"cannot reach {settings.MCP_IMAP_HOST}:{settings.MCP_IMAP_PORT}: {exc}") from None
    if not peer or hashlib.sha256(peer).digest() != hashlib.sha256(pinned).digest():
        with contextlib.suppress(Exception):
            client.shutdown()
        raise ImapUnavailable("mda TLS certificate does not match the pinned MCP_IMAP_CA_FILE")
    return client


def check_user_login(address: str, password: str) -> bool:
    """True when `address` + `password` log in over IMAP. ImapUnavailable on infrastructure
    errors, so a down mda is never reported as wrong credentials."""
    client = _connect()
    try:
        client.login(address, password)
        return True
    except LoginError:
        return False
    except IMAPClientError as exc:
        raise ImapUnavailable(str(exc)) from None
    finally:
        with contextlib.suppress(Exception):
            client.logout()


class _Slot:
    def __init__(self, client: imapclient.IMAPClient):
        self.client = client
        self.last_used = time.monotonic()


class _MailboxPool:
    def __init__(self):
        self.idle: list[_Slot] = []
        self.sem = threading.BoundedSemaphore(MAX_PER_MAILBOX)
        self.lock = threading.Lock()


_pools: dict[str, _MailboxPool] = {}
_pools_lock = threading.Lock()


def _pool(address: str) -> _MailboxPool:
    with _pools_lock:
        return _pools.setdefault(address, _MailboxPool())


def _master_login(address: str) -> imapclient.IMAPClient:
    client = _connect()
    try:
        client.login(f"{address}*{settings.MCP_DOVECOT_MASTER_USER}", settings.MCP_DOVECOT_MASTER_PASSWORD)
    except LoginError:
        with contextlib.suppress(Exception):
            client.logout()
        # inactive / deleted mailbox, or a master-user misconfiguration on mda
        raise ImapUnavailable(f"master login refused for {address}") from None
    except IMAPClientError as exc:
        raise ImapUnavailable(str(exc)) from None
    return client


@contextlib.contextmanager
def mailbox(address: str):
    """A logged-in IMAPClient for `address` (master user). Blocks while 3 are in use."""
    pool = _pool(address)
    if not pool.sem.acquire(timeout=TIMEOUT):
        raise ImapUnavailable(f"too many concurrent operations on {address}")
    slot = None
    try:
        with pool.lock:
            slot = pool.idle.pop() if pool.idle else None
        if slot and time.monotonic() - slot.last_used > NOOP_AFTER:
            try:
                slot.client.noop()
            except Exception:
                with contextlib.suppress(Exception):
                    slot.client.shutdown()
                slot = None
        if slot is None:
            slot = _Slot(_master_login(address))
        broken = False
        try:
            yield slot.client
        except (OSError, IMAPClientError):
            broken = True
            raise
        finally:
            if broken:
                with contextlib.suppress(Exception):
                    slot.client.shutdown()
            else:
                with contextlib.suppress(Exception):
                    if slot.client._imap.state == "SELECTED":
                        slot.client.unselect_folder()
                slot.last_used = time.monotonic()
                with pool.lock:
                    pool.idle.append(slot)
    finally:
        pool.sem.release()


def sweep() -> int:
    """Close connections idle for more than IDLE_CLOSE seconds."""
    closed = 0
    now = time.monotonic()
    with _pools_lock:
        pools = list(_pools.values())
    for pool in pools:
        with pool.lock:
            keep = []
            for slot in pool.idle:
                if now - slot.last_used > IDLE_CLOSE:
                    with contextlib.suppress(Exception):
                        slot.client.logout()
                    closed += 1
                else:
                    keep.append(slot)
            pool.idle = keep
    return closed


def drop(address: str) -> None:
    """Forget every pooled connection of a mailbox (e.g. it became inactive)."""
    with _pools_lock:
        pool = _pools.pop(address, None)
    if pool:
        with pool.lock:
            for slot in pool.idle:
                with contextlib.suppress(Exception):
                    slot.client.logout()
