"""Cursor pagination shared by every list route (technical-draft §5).

Cursors are opaque base64url blobs carrying the last sort key, so a page is
stable while the catalogue changes and the PWA's virtualized lists can request
the next page without offsets. Lists sort ascending by their natural key
(domain name, mailbox username, alias address...).
"""

import base64
import json

from .errors import validation

DEFAULT_LIMIT = 50
MAX_LIMIT = 200


def encode_cursor(value: str) -> str:
    raw = json.dumps({"k": value}, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(cursor: str) -> str:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        data = json.loads(base64.urlsafe_b64decode(padded.encode()))
        key = data["k"]
        if not isinstance(key, str):
            raise ValueError
        return key
    except (ValueError, KeyError, TypeError, json.JSONDecodeError):
        raise validation("invalid pagination cursor") from None


def clamp_limit(limit: int) -> int:
    if limit < 1:
        return DEFAULT_LIMIT
    return min(limit, MAX_LIMIT)


def page(items: list, key_field: str, limit: int) -> dict:
    """Build `{items, next_cursor}` from `limit + 1` fetched rows."""
    limit = clamp_limit(limit)
    has_more = len(items) > limit
    visible = items[:limit]
    next_cursor = encode_cursor(str(visible[-1][key_field])) if has_more and visible else None
    return {"items": visible, "next_cursor": next_cursor}
