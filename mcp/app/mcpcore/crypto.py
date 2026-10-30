"""Secrets, token hashing and server-minted opaque handles (proposal §8.1, §8.2).

Every key is derived from MCP_SECRET_KEY with a purpose label, so one leaked derived key never
opens another purpose.
"""

import base64
import hashlib
import hmac
import json
import secrets
import string
import time

from django.conf import settings

_B62 = string.ascii_letters + string.digits


def derived_key(purpose: str) -> bytes:
    return hmac.new(settings.SECRET_KEY.encode(), f"maild-mcp:{purpose}".encode(), hashlib.sha256).digest()


def token_hash(token: str) -> str:
    """HMAC-SHA256(MCP_SECRET_KEY-derived key, token), hex: what the DB stores."""
    return hmac.new(derived_key("token"), token.encode(), hashlib.sha256).hexdigest()


def new_token(prefix: str) -> str:
    """`<prefix>` + 43 base62 chars (≈256 bits)."""
    return prefix + "".join(secrets.choice(_B62) for _ in range(43))


def new_id(n: int = 16) -> str:
    return secrets.token_hex(n)


def display(token: str, prefix: str) -> str:
    return f"{prefix}…{token[-4:]}"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def mint_handle(kind: str, bind: str, payload: dict, ttl: int | None = None) -> str:
    """Opaque, tamper-proof handle (cursor, watermark…) bound to `bind` (the token's public id),
    so a handle minted for one token is useless with another."""
    body = {"k": kind, "b": bind, "p": payload}
    if ttl:
        body["e"] = int(time.time()) + ttl
    raw = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
    sig = hmac.new(derived_key("handle"), raw, hashlib.sha256).digest()[:16]
    return _b64(raw) + "." + _b64(sig)


def open_handle(handle: str, kind: str, bind: str) -> dict:
    """Payload of a valid handle; ValueError otherwise."""
    try:
        raw_b64, sig_b64 = handle.split(".", 1)
        raw = _unb64(raw_b64)
        sig = _unb64(sig_b64)
    except (ValueError, TypeError):
        raise ValueError("malformed handle") from None
    good = hmac.new(derived_key("handle"), raw, hashlib.sha256).digest()[:16]
    if not hmac.compare_digest(sig, good):
        raise ValueError("invalid handle")
    body = json.loads(raw)
    if body.get("k") != kind or body.get("b") != bind:
        raise ValueError("handle does not belong to this call")
    if "e" in body and body["e"] < time.time():
        raise ValueError("handle expired")
    return body["p"]


# ------------------------------------------------------- secrets at rest ---
# Fernet with a key derived from MCP_SECRET_KEY (proposal §3.2): the external SMTP password.
def _fernet():
    from cryptography.fernet import Fernet

    return Fernet(base64.urlsafe_b64encode(derived_key("fernet")))


def encrypt(value: str) -> str:
    return _fernet().encrypt(value.encode()).decode()


def decrypt(token: str) -> str:
    from cryptography.fernet import InvalidToken

    try:
        return _fernet().decrypt(token.encode()).decode()
    except (InvalidToken, ValueError):
        return ""   # MCP_SECRET_KEY rotated: the admin has to enter the password again
