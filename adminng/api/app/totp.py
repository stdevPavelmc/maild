"""TOTP (RFC 6238) — SHA-1, 6 digits, 30-second steps.

Implemented here instead of pulling a dependency: the algorithm is a dozen
lines of HMAC and this way the same code can be exercised by the container
tests (`tests/test_totp.py` covers the RFC test vectors).

Replay protection: `verify()` also returns the matched time step and refuses a
step at or below `last_step`, which the caller persists on the credential.
"""

import base64
import hashlib
import hmac
import secrets
import struct
import time
from urllib.parse import quote

from . import settings


def generate_secret() -> str:
    """A 160-bit seed, base32 (the format authenticator apps expect)."""
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def _decode_secret(secret: str) -> bytes:
    padded = secret + "=" * (-len(secret) % 8)
    return base64.b32decode(padded.upper())


def _hotp(secret: bytes, counter: int, digits: int) -> str:
    digest = hmac.new(secret, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(value % (10**digits)).zfill(digits)


def code_at(secret: str, timestamp: float | None = None) -> str:
    """The code for a given moment (tests and the dev helper use this)."""
    step = int((timestamp if timestamp is not None else time.time()) // settings.ADMINNG_TOTP_STEP)
    return _hotp(_decode_secret(secret), step, settings.ADMINNG_TOTP_DIGITS)


def verify(secret: str, code: str, last_step: int | None = None) -> tuple[bool, int]:
    """Verify a code within ±1 step. Returns (ok, matched_step)."""
    code = (code or "").strip().replace(" ", "")
    if not code.isdigit() or len(code) != settings.ADMINNG_TOTP_DIGITS:
        return False, last_step or 0
    decoded = _decode_secret(secret)
    current = int(time.time() // settings.ADMINNG_TOTP_STEP)
    for offset in (-1, 0, 1):
        step = current + offset
        if last_step is not None and step <= last_step:
            continue
        if hmac.compare_digest(_hotp(decoded, step, settings.ADMINNG_TOTP_DIGITS), code):
            return True, step
    return False, last_step or 0


def provisioning_uri(secret: str, username: str, issuer: str | None = None) -> str:
    issuer = issuer or settings.ADMINNG_TOTP_ISSUER
    label = quote(f"{issuer}:{username}")
    return (
        f"otpauth://totp/{label}?secret={secret}&issuer={quote(issuer)}"
        f"&algorithm=SHA1&digits={settings.ADMINNG_TOTP_DIGITS}"
        f"&period={settings.ADMINNG_TOTP_STEP}"
    )
