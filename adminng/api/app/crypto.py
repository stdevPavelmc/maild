"""Symmetric crypto for secrets at rest (TOTP seeds, future WebAuthn data).

The key is derived from the operator's `ADMINNG_SECRET_KEY` (never baked): a
SHA-256 of it is the 32-byte Fernet key, so the plaintext secret never touches
the database and rotating the operator secret invalidates stored seeds (admins
re-enroll — the CLI/TOTP policy allows that).
"""

import base64
import hashlib

from cryptography.fernet import Fernet, InvalidToken

from . import settings
from .errors import ApiError


def _fernet() -> Fernet:
    if not settings.ADMINNG_SECRET_KEY:
        raise ApiError(500, "MISCONFIGURED", "ADMINNG_SECRET_KEY is not set")
    key = base64.urlsafe_b64encode(
        hashlib.sha256(settings.ADMINNG_SECRET_KEY.encode()).digest()
    )
    return Fernet(key)


def encrypt(value: str) -> str:
    return _fernet().encrypt(value.encode()).decode()


def decrypt(value: str) -> str:
    try:
        return _fernet().decrypt(value.encode()).decode()
    except InvalidToken:
        raise ApiError(
            409,
            "SECRET_UNREADABLE",
            "the stored secret cannot be decrypted with the current ADMINNG_SECRET_KEY",
        ) from None
