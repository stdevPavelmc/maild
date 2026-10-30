"""User preferences (proposal §7.3.3, send-related subset — decision 2026-10-30)."""

from mcpcore import policy
from mcpcore.accounts import AccountError
from mcpcore.models import Account, AccountAddress


def get(account: Account) -> dict:
    stored = account.prefs or {}
    out = {**policy.DEFAULT_PREFS, **{k: v for k, v in stored.items() if k in policy.DEFAULT_PREFS}}
    if out["confirm_send"] not in policy.CONFIRM_MODES:
        out["confirm_send"] = policy.DEFAULT_PREFS["confirm_send"]
    return out


def update(account: Account, data: dict) -> dict:
    current = get(account)
    for key, value in data.items():
        if key not in policy.DEFAULT_PREFS or value is None:
            continue
        if key == "lang" and value not in ("en", "es"):
            raise AccountError("invalid_lang", "Unsupported language.")
        if key == "confirm_send" and value not in policy.CONFIRM_MODES:
            raise AccountError("invalid_confirm_mode", "That confirmation mode is not available on this server.")
        if key == "default_sender":
            value = (value or "").strip().lower()
            if value and not account.addresses.filter(email=value).exclude(status=AccountAddress.PENDING).exists():
                raise AccountError("invalid_sender", "The default sender must be a confirmed address of this account.")
        if key == "signature":
            value = str(value)
            if len(value) > policy.MAX_SIGNATURE_CHARS:
                raise AccountError("signature_too_long", f"The signature is limited to {policy.MAX_SIGNATURE_CHARS} characters.")
        if key == "hidden_folders":
            names = [str(v).strip() for v in value if str(v).strip()]
            if len(names) > policy.MAX_HIDDEN_FOLDERS:
                raise AccountError("too_many_folders", f"At most {policy.MAX_HIDDEN_FOLDERS} hidden folders.")
            if any(n.upper() == "INBOX" for n in names):
                raise AccountError("inbox_not_hideable", "INBOX cannot be hidden from agents.")
            value = sorted(set(names))
        if key == "allow_attachments":
            value = bool(value)
        current[key] = value
    account.prefs = current
    account.save(update_fields=["prefs"])
    return current
