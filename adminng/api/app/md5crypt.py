"""md5crypt ($1$) hashing — the PostfixAdmin/Dovecot common denominator.

MailD stores mailbox/admin passwords as md5crypt: `POSTFIXADMIN_ENCRYPT=md5crypt`
and Dovecot's `default_password_scheme` both verify it, and `admin/seed.sh`
produces it with PHP's crypt(). Python 3.13 removed the stdlib `crypt` module,
so this is a self-contained implementation of the FreeBSD md5crypt algorithm
(pure hashlib) with the same output format:

    $1$<8-char salt>$<22-char checksum>

Anything written to mailbox.password / admin.password MUST come from here (or be
produced by PostfixAdmin/seed.sh with the same scheme).
"""

import hashlib
import hmac
import secrets

_ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
_MAGIC = b"$1$"


def _to64(value: int, length: int) -> str:
    """Encode `length` base64-ish characters from `value` (md5crypt's alphabet)."""
    out = []
    while length > 0:
        out.append(_ITOA64[value & 0x3F])
        value >>= 6
        length -= 1
    return "".join(out)


def _make_salt() -> str:
    """8 random characters from md5crypt's alphabet."""
    return _to64(secrets.randbits(48), 8)


def hash_password(password: str, salt: str | None = None) -> str:
    """Return the md5crypt hash for `password` (optionally with a given salt)."""
    pwd = password.encode()
    salt = (salt or _make_salt())[:8]
    salt_b = salt.encode()

    ctx = hashlib.md5(pwd + _MAGIC + salt_b)
    final = hashlib.md5(pwd + salt_b + pwd).digest()

    # Digest sized to the password length, then the length's bits.
    remaining = len(pwd)
    while remaining > 0:
        ctx.update(final[: min(16, remaining)])
        remaining -= 16

    remaining = len(pwd)
    while remaining > 0:
        ctx.update(b"\0" if remaining & 1 else pwd[:1])
        remaining >>= 1

    final = ctx.digest()

    for i in range(1000):
        round_ctx = hashlib.md5()
        round_ctx.update(pwd if i & 1 else final)
        if i % 3:
            round_ctx.update(salt_b)
        if i % 7:
            round_ctx.update(pwd)
        round_ctx.update(final if i & 1 else pwd)
        final = round_ctx.digest()

    checksum = (
        _to64((final[0] << 16) | (final[6] << 8) | final[12], 4)
        + _to64((final[1] << 16) | (final[7] << 8) | final[13], 4)
        + _to64((final[2] << 16) | (final[8] << 8) | final[14], 4)
        + _to64((final[3] << 16) | (final[9] << 8) | final[15], 4)
        + _to64((final[4] << 16) | (final[10] << 8) | final[5], 4)
        + _to64(final[11], 2)
    )
    return f"{_MAGIC.decode()}{salt}${checksum}"


def is_md5crypt(hashed: str | None) -> bool:
    """True when `hashed` looks like an md5crypt entry."""
    if not hashed:
        return False
    parts = hashed.split("$")
    return len(parts) == 4 and parts[1] == "1" and len(parts[2]) == 8


def verify_password(password: str, hashed: str | None) -> bool:
    """Constant-time verification of `password` against a stored md5crypt hash."""
    if not is_md5crypt(hashed):
        return False
    salt = hashed.split("$")[2]
    return hmac.compare_digest(hash_password(password, salt), hashed)
