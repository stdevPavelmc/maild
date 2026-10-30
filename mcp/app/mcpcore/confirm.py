"""Two-step confirmation handles (proposal §8.3, "Confirmation pattern").

The first call of a confirmable tool returns a preview plus a handle; the second call, with the
same arguments and `confirm=<handle>`, executes. A handle is single use, expires after
policy.CONFIRM_TTL seconds and is bound to the token, the tool and a digest of every other
argument, so it can neither be replayed, nor used by another token, nor stretched to cover
different ids or recipients. Only its HMAC is stored.
"""

import datetime as dt
import hashlib
import json
import secrets

from django.db import transaction
from django.utils import timezone

from mcpcore import policy
from mcpcore.crypto import token_hash
from mcpcore.models import ConfirmHandle, Token

PREFIX = "mdmcp_cf_"


class ConfirmError(Exception):
    pass


def digest(tool: str, args: dict) -> str:
    clean = {k: v for k, v in sorted(args.items()) if k != "confirm"}
    raw = json.dumps({"tool": tool, "args": clean}, sort_keys=True, default=str, separators=(",", ":"))
    return hashlib.sha256(raw.encode()).hexdigest()


def issue(token: Token, tool: str, args: dict) -> str:
    handle = PREFIX + secrets.token_urlsafe(24)
    ConfirmHandle.objects.filter(expires_at__lt=timezone.now()).delete()
    ConfirmHandle.objects.create(hash=token_hash(handle), token=token, tool=tool, args_digest=digest(tool, args),
                                 expires_at=timezone.now() + dt.timedelta(seconds=policy.CONFIRM_TTL))
    return handle


def redeem(token: Token, tool: str, args: dict, handle: str) -> None:
    """Consume a handle for exactly this call; ConfirmError otherwise."""
    if not handle or not handle.startswith(PREFIX):
        raise ConfirmError("'confirm' must be the handle returned by the previous call")
    with transaction.atomic():
        row = ConfirmHandle.objects.select_for_update().filter(hash=token_hash(handle)).first()
        if row is None or row.used:
            raise ConfirmError("this confirmation handle is unknown or was already used: call again without 'confirm'")
        if row.expires_at <= timezone.now():
            raise ConfirmError("this confirmation handle expired: call again without 'confirm'")
        if row.token_id != token.id or row.tool != tool:
            raise ConfirmError("this confirmation handle belongs to another call")
        if row.args_digest != digest(tool, args):
            raise ConfirmError("the arguments differ from the confirmed preview: call again without 'confirm'")
        row.used = True
        row.save(update_fields=["used"])
