"""Quota usage from the mail store (technical-draft §7).

Dovecot's `quota-status` speaks the Postfix policy protocol and answers only
pass/reject — it carries no numbers — so the API reads the Maildir++ accounting
Dovecot already maintains: the `.maildirsize` file in the maildir root. When it
does not exist yet (a mailbox that never received mail, or unlimited quota) a
size walk provides the value. Results are cached for `ADMINNG_QUOTA_CACHE_TTL`.

The `vmail` volume is mounted READ-ONLY in the api container and the process runs
as the vmail uid (5000), the only uid that can traverse the 0700 maildirs.
"""

import os
import time
from pathlib import Path

from . import settings
from .errors import ApiError

_cache: dict[str, tuple[float, int]] = {}


def _maildir_path(domain: str, local_part: str) -> Path:
    # Defensive: never let a crafted name escape the mail root.
    for part in (domain, local_part):
        if not part or "/" in part or "\\" in part or part in (".", ".."):
            raise ApiError(422, "VALIDATION", "invalid mailbox path component")
    return Path(settings.VMAIL_ROOT) / domain / local_part


def _parse_maildirsize(path: Path) -> int | None:
    """First line is '<size>S[,<count>C]'; the rest are per-mailbox deltas."""
    try:
        with path.open("r", encoding="ascii", errors="replace") as handle:
            first = handle.readline().strip()
    except OSError:
        return None
    if not first:
        return None
    size_token = first.split(",", 1)[0]
    if not size_token.endswith("S"):
        return None
    try:
        return max(int(size_token[:-1]), 0)
    except ValueError:
        return None


def _walk_size(root: Path) -> int:
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root, onerror=lambda _e: None):
        for name in filenames:
            try:
                total += os.stat(os.path.join(dirpath, name), follow_symlinks=False).st_size
            except OSError:
                continue
    return total


def usage_bytes(domain: str, local_part: str) -> tuple[int, str]:
    """Return (used_bytes, source) with `source` in maildirsize|du|unavailable."""
    path = _maildir_path(domain, local_part)
    key = f"{domain}/{local_part}"
    now = time.monotonic()

    cached = _cache.get(key)
    if cached and now - cached[0] < settings.ADMINNG_QUOTA_CACHE_TTL:
        return cached[1], "maildirsize"

    if not path.is_dir():
        return 0, "unavailable"

    size = _parse_maildirsize(path / ".maildirsize")
    source = "maildirsize"
    if size is None:
        size = _walk_size(path)
        source = "du"

    _cache[key] = (now, size)
    return size, source


def quota_status(username: str, domain: str, local_part: str, quota_bytes: int) -> dict:
    used, source = usage_bytes(domain, local_part)
    unlimited = quota_bytes <= 0
    percentage = None
    if not unlimited:
        percentage = round(used * 100 / quota_bytes, 1)
    return {
        "username": username,
        "quota_bytes": quota_bytes,
        "used_bytes": used,
        "percentage": percentage,
        "unlimited": unlimited,
        "source": source,
    }


def invalidate(domain: str, local_part: str) -> None:
    _cache.pop(f"{domain}/{local_part}", None)
