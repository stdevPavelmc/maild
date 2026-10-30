"""Password hashing — Argon2id only (AGENTS.md: never add a new md5crypt path).

Same parameters as adminng/api/app/passwords.py, so a hash written here verifies the same
way everywhere in the stack.
"""

import secrets

from argon2 import PasswordHasher

_ARGON2ID = PasswordHasher(time_cost=4, memory_cost=65536, parallelism=1, hash_len=32)


def hash_password(password: str) -> str:
    """Plain `$argon2id$…` hash (the MCP's own tables)."""
    return _ARGON2ID.hash(password)


def dovecot_hash(password: str) -> str:
    """`{ARGON2ID}$argon2id$…`, the catalogue format Dovecot's SQL passdb verifies."""
    return "{ARGON2ID}" + _ARGON2ID.hash(password)


def generate_password() -> str:
    """18 random bytes = 36 hex chars, the shape the api seeder generates."""
    return secrets.token_hex(18)
