"""Admin settings groups (proposal §7.2), one `setting` row per group, validated here.

Every group has defaults (some from the environment, e.g. the send limits), so a fresh install
behaves exactly like P2 did. Reads are cached for 2 s per process (one primary-key query); a
write clears the local cache and the other workers follow within 2 s, while the admin panel's own
reads bypass the cache. The admin UI's "Restore" is client-side (drop the local edits, reload
these values); "Update" is `put()`.
"""

import time

from django.conf import settings as dj

from mcpcore import audit, crypto
from mcpcore.models import Setting

DAY = 86400
_TTL = 2.0
_cache: dict[str, tuple[float, dict]] = {}


class SettingsError(Exception):
    def __init__(self, field: str, message: str):
        super().__init__(message)
        self.field, self.message = field, message


def _env_int(name: str, default: int) -> int:
    import os

    try:
        return int(os.environ.get(name, "").strip() or default)
    except ValueError:
        return default


def env_max_messagesize() -> int:
    """The mta's limit: the MCP may be stricter, never looser."""
    return _env_int("MAX_MESSAGESIZE", 34865152)


CATEGORIES = ("web_login", "bearer_access", "mail_actions", "token_lifecycle", "admin_changes", "errors", "security")


def defaults(group: str) -> dict:
    if group == "logging":
        return {"enabled": True, "categories": {c: True for c in CATEGORIES}, "rotation": "day", "retention": 90}
    if group == "user_policy":
        return {
            "max_tokens": 10, "pat_default_days": 30, "pat_forever_allowed": True, "pat_idle_days": 30,
            "send_rate_recipients": _env_int("MCP_SEND_RATE_RECIPIENTS", 200),
            "send_rate_window": _env_int("MCP_SEND_RATE_WINDOW", 3600),
            "max_message_size": env_max_messagesize(), "max_attachment_bytes": 5 * 1024 * 1024,
            "allow_external": True, "force_confirm": False, "allow_no_confirm": False,
            "magic_link_hours": 24, "resend_base_seconds": 60, "max_secondary": 10,
            "master_notify_user": False,
        }
    if group == "service_email":
        return {"transport": "internal", "host": "", "port": 587, "tls": "starttls", "verify_tls": True,
                "user": "", "password": ""}
    raise KeyError(group)


GROUPS = ("logging", "user_policy", "service_email")
RETENTION_DEFAULTS = {"day": 90, "week": 26, "month": 12}


def _int(data: dict, key: str, lo: int, hi: int) -> int:
    try:
        value = int(data[key])
    except (TypeError, ValueError, KeyError):
        raise SettingsError(key, f"{key} must be a whole number") from None
    if not lo <= value <= hi:
        raise SettingsError(key, f"{key} must be between {lo} and {hi}")
    return value


def _bool(data: dict, key: str) -> bool:
    value = data.get(key)
    if not isinstance(value, bool):
        raise SettingsError(key, f"{key} must be true or false")
    return value


def _validate(group: str, data: dict, current: dict) -> dict:
    merged = {**current, **{k: v for k, v in data.items() if k in current}}
    if group == "logging":
        out = {"enabled": _bool(merged, "enabled")}
        cats = merged.get("categories") or {}
        out["categories"] = {c: bool(cats.get(c, True)) for c in CATEGORIES}
        if merged.get("rotation") not in RETENTION_DEFAULTS:
            raise SettingsError("rotation", "rotation must be day, week or month")
        out["rotation"] = merged["rotation"]
        out["retention"] = _int(merged, "retention", 1, 3650)
        return out
    if group == "user_policy":
        return {
            "max_tokens": _int(merged, "max_tokens", 1, 100),
            "pat_default_days": _int(merged, "pat_default_days", 1, 3650),
            "pat_forever_allowed": _bool(merged, "pat_forever_allowed"),
            # D12: the admin may lower the idle limit, never raise it above 30 days or switch it off
            "pat_idle_days": _int(merged, "pat_idle_days", 1, 30),
            "send_rate_recipients": _int(merged, "send_rate_recipients", 1, 100000),
            "send_rate_window": _int(merged, "send_rate_window", 60, 7 * DAY),
            "max_message_size": _int(merged, "max_message_size", 1024, env_max_messagesize()),
            "max_attachment_bytes": _int(merged, "max_attachment_bytes", 0, 100 * 1024 * 1024),
            "allow_external": _bool(merged, "allow_external"),
            "force_confirm": _bool(merged, "force_confirm"),
            "allow_no_confirm": _bool(merged, "allow_no_confirm"),
            "magic_link_hours": _int(merged, "magic_link_hours", 1, 168),
            "resend_base_seconds": _int(merged, "resend_base_seconds", 10, 3600),
            "max_secondary": _int(merged, "max_secondary", 0, 100),
            "master_notify_user": _bool(merged, "master_notify_user"),
        }
    if group == "service_email":
        transport = merged.get("transport")
        if transport not in ("internal", "external"):
            raise SettingsError("transport", "transport must be internal or external")
        out = {"transport": transport, "host": str(merged.get("host") or "").strip(),
               "port": _int(merged, "port", 1, 65535), "tls": merged.get("tls"),
               # opt-out (decision 2026-10-30): TLS stays on, only chain + hostname checks are skipped
               "verify_tls": _bool(merged, "verify_tls"),
               "user": str(merged.get("user") or "").strip(), "password": current.get("password", "")}
        if out["tls"] not in ("none", "starttls", "implicit"):
            raise SettingsError("tls", "tls must be none, starttls or implicit")
        if transport == "external" and not out["host"]:
            raise SettingsError("host", "an external SMTP server needs a host")
        # write-only secret: a non-empty value replaces it, "" keeps it; stored encrypted (Fernet)
        if data.get("password"):
            out["password"] = crypto.encrypt(str(data["password"]))
        if data.get("clear_password"):
            out["password"] = ""
        return out
    raise KeyError(group)


def get(group: str, fresh: bool = False) -> dict:
    hit = _cache.get(group)
    now = time.monotonic()
    if hit and not fresh and now - hit[0] < _TTL:
        return hit[1]
    row = Setting.objects.filter(key=group).first()
    value = {**defaults(group), **(row.value if row else {})}
    if group == "logging":
        value["categories"] = {**defaults(group)["categories"], **(value.get("categories") or {})}
    _cache[group] = (now, value)
    return value


def public(group: str) -> dict:
    """What the admin UI may see (never the SMTP password). Read fresh: the panel must show its own
    write right away, even when the reload lands on a worker whose cache is still warm."""
    value = dict(get(group, fresh=True))
    if group == "service_email":
        value["password_set"] = bool(value.pop("password", ""))
        value["sender"] = dj.MCP_SERVICE_EMAIL
    return value


def put(group: str, data: dict, admin) -> dict:
    if group not in GROUPS:
        raise KeyError(group)
    current = get(group)
    value = _validate(group, data, current)
    Setting.objects.update_or_create(key=group, defaults={"value": value, "updated_by": admin.username if admin else "cli"})
    _cache.pop(group, None)
    changed = sorted(k for k in value if k != "password" and value[k] != current.get(k))
    if value.get("password") != current.get("password"):
        changed.append("password")
    audit.event("admin.settings", f"settings.{group}", actor={"type": "admin", "admin": admin.username if admin else "cli"},
                detail={"changed": changed})
    return public(group)


def flush() -> None:
    _cache.clear()
