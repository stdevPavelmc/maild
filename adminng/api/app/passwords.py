"""Catalogue password hashing — one writer, one verifier, scheme-dispatched.

MailD stores mailbox/admin passwords in the legacy PostfixAdmin catalogue
(`mailbox.password`, mirrored into `admin.password`). Since the 2026-10
security audit (F-18: MD5-CRYPT is a 1990s scheme with no memory hardness)
the stack moves to Argon2id. Two stored formats are legal and may mix freely
in the same column:

  * legacy:  $1$<8-char-salt>$<22-char-checksum>           (md5crypt, weak)
  * current: {ARGON2ID}$argon2id$v=19$m=65536,t=4,p=1$...  (the {SCHEME} prefix
             is mandatory for Dovecot's SQL passdb; the parameters are
             self-encoded in the hash body, so any writer's output verifies)

Everything that reads the column dispatches on the format, so a deployment
mid-migration works with both:
  * Dovecot (IMAP/POP3 and, via Dovecot SASL, Postfix SMTP AUTH) verifies
    the legacy format through default_password_scheme = MD5-CRYPT (enabled
    by auth_allow_weak_schemes = yes) and the prefixed format through its
    explicit {SCHEME} dispatch;
  * this module is the ONLY API-side writer (mailbox/admin create+update)
    and the verifier for AdminNG's own logins.

DEPRECATION DEADLINE: weak-scheme support is removed stack-wide on
2027-02-01. From that date PASSWORD_SCHEME=md5crypt refuses to boot, legacy
$1$ hashes stop verifying here, and Dovecot's auth_allow_weak_schemes goes
back to 'no' (legacy mailboxes stop authenticating). Rehash-on-login and
natural password rotation must have migrated every mailbox before then;
`adminng.py --legacy-hashes` reports the rows that still need attention.

PostfixAdmin (deprecated dev-only fallback) cannot verify Argon2id — its
logins only work for accounts still on legacy hashes. Accepted by design;
nothing here supports it.
"""

import datetime as dt

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from . import settings
from .md5crypt import hash_password as _md5crypt_hash
from .md5crypt import is_md5crypt as is_legacy
from .md5crypt import verify_password as _md5crypt_verify

# Weak-scheme (md5crypt) support ends here — see the module docstring,
# .agents/services/configuration.md and the mda's 10-auth.conf. Test-only
# monkeypatch point (`_today`), never an environment variable.
MD5CRYPT_SUPPORT_ENDS = dt.date(2027, 2, 1)

# Writer parameters mirror PHP's PASSWORD_ARGON2ID defaults (so the webmail
# change-password driver and this API produce byte-identical formats for the
# same password). Parameters are self-encoded per hash; verification of any
# Argon2id parameter set still works.
_ARGON2ID = PasswordHasher(time_cost=4, memory_cost=65536, parallelism=1, hash_len=32)

_SCHEMES = ("argon2id", "md5crypt")


def _today() -> dt.date:
    """Today's date (monkeypatch point for the deadline self-tests)."""
    return dt.date.today()


def _deadline_error() -> RuntimeError:
    return RuntimeError(
        "PASSWORD_SCHEME=md5crypt is no longer supported: weak-scheme (md5crypt) "
        f"support was removed on {MD5CRYPT_SUPPORT_ENDS.isoformat()}. Set "
        "PASSWORD_SCHEME=argon2id and migrate the remaining legacy hashes "
        "(adminng.py --legacy-hashes lists them)."
    )


def _validate_scheme() -> None:
    """Boot-time guard: unknown schemes and post-deadline md5crypt never start."""
    scheme = settings.PASSWORD_SCHEME
    if scheme not in _SCHEMES:
        raise RuntimeError(
            f"unsupported PASSWORD_SCHEME {scheme!r} (expected one of {_SCHEMES})"
        )
    if scheme == "md5crypt" and _today() >= MD5CRYPT_SUPPORT_ENDS:
        raise _deadline_error()


_validate_scheme()


def hash_password(password: str) -> str:
    """Hash `password` with the configured PASSWORD_SCHEME.

    argon2id (default): '{ARGON2ID}' prefix + $argon2id$ body — the format
    Dovecot's SQL passdb expects for anything that is not the default scheme.
    md5crypt (legacy): raw $1$ — PostfixAdmin-compatible escape hatch,
    refuses after the 2027-02-01 deadline.
    """
    scheme = settings.PASSWORD_SCHEME
    if scheme == "argon2id":
        return "{ARGON2ID}" + _ARGON2ID.hash(password)
    if scheme == "md5crypt":
        if _today() >= MD5CRYPT_SUPPORT_ENDS:
            raise _deadline_error()
        return _md5crypt_hash(password)
    raise RuntimeError(
        f"unsupported PASSWORD_SCHEME {scheme!r} (expected one of {_SCHEMES})"
    )


def verify_password(password: str, hashed: str | None) -> bool:
    """Verify `password` against any stored hash format (scheme-dispatched).

    Dispatches on the leading {SCHEME} prefix when present, on the raw $1$
    shape for legacy md5crypt, and fails closed for anything else (never a
    plaintext comparison). Legacy hashes stop verifying after the deadline.
    """
    if not hashed:
        return False
    if hashed.startswith("{"):
        prefix = "{ARGON2ID}"
        if not hashed.startswith(prefix):
            return False  # unknown/unsupported prefixed scheme: fail closed
        try:
            return _ARGON2ID.verify(hashed[len(prefix):], password)
        except (VerifyMismatchError, VerificationError, InvalidHashError):
            return False
    if is_legacy(hashed):
        if _today() >= MD5CRYPT_SUPPORT_ENDS:
            return False  # weak-scheme support removed: fail closed
        return _md5crypt_verify(password, hashed)
    return False