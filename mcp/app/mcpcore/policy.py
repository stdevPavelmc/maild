"""User policy (proposal §7.2 group 3).

Fixed limits are plain constants. The admin-tunable ones (P3) are resolved on every access from
the `user_policy` settings group (mcpcore.settings_store, cached 10 s), through the module
`__getattr__` below — so callers keep writing `policy.SEND_RATE_RECIPIENTS` and get the admin's
current value. Until an admin saves the group, the defaults equal the P1/P2 behaviour.
"""

DAY = 86400

SCOPES = ("mail.read", "mail.modify", "mail.trash", "mail.send")
RESEND_CAP = DAY
MAX_BODY_CHARS = 100_000           # text returned to agents per message
LOGIN_MAX_FAILURES = 5
LOGIN_LOCKOUT = 15 * 60
CLAIM_NOTICE_INTERVAL = DAY        # D11: one postmaster notice per (claimer, address) per day
CONFIRM_TTL = 300                  # confirmation handles: single use, bound to token + tool + arguments
MAX_QUOTED_CHARS = 20_000          # original text quoted in replies / forwards
MAX_SIGNATURE_CHARS = 2000
MAX_HIDDEN_FOLDERS = 50
MASTER_TOKEN_DEFAULT_TTL = DAY     # proposal §7.2: default 24 h, at most MCP_MASTER_TOKEN_MAX_TTL, never forever

# user preferences (proposal §7.3.3) and their defaults
DEFAULT_PREFS = {
    "lang": "en",
    "confirm_send": "external",
    "default_sender": "",          # "" = the first usable address
    "signature": "",
    "hidden_folders": [],
    "allow_attachments": True,
    # P3 notifications (mailed to the account's main address)
    "notify_new_token": True,
    "notify_new_client": True,
    "notify_master_access": True,  # only effective when the admin enables master_notify_user (D7)
}

# name → (settings key, transform)
_TUNABLE = {
    "MAX_TOKENS_PER_ACCOUNT": ("max_tokens", int),
    "PAT_DEFAULT_LIFETIME": ("pat_default_days", lambda d: int(d) * DAY),
    "PAT_FOREVER_ALLOWED": ("pat_forever_allowed", bool),
    "PAT_IDLE_LIMIT": ("pat_idle_days", lambda d: min(int(d), 30) * DAY),   # D12: never above 30 days
    "MAGIC_LINK_TTL": ("magic_link_hours", lambda h: int(h) * 3600),
    "RESEND_BASE": ("resend_base_seconds", int),
    "MAX_SECONDARY_ADDRESSES": ("max_secondary", int),
    "MAX_ATTACHMENT_BYTES": ("max_attachment_bytes", int),
    "SEND_RATE_RECIPIENTS": ("send_rate_recipients", int),
    "SEND_RATE_WINDOW": ("send_rate_window", int),
    "MAX_MESSAGESIZE": ("max_message_size", int),
    "ALLOW_EXTERNAL": ("allow_external", bool),
    "FORCE_CONFIRM": ("force_confirm", bool),
    "ALLOW_NO_CONFIRM": ("allow_no_confirm", bool),
    "MASTER_NOTIFY_USER": ("master_notify_user", bool),
}


def __getattr__(name: str):
    if name in _TUNABLE:
        from mcpcore import settings_store

        key, transform = _TUNABLE[name]
        return transform(settings_store.get("user_policy")[key])
    if name == "CONFIRM_MODES":
        return ("always", "external") + (("never",) if __getattr__("ALLOW_NO_CONFIRM") else ())
    raise AttributeError(name)


def resend_delay(resends_so_far: int) -> int:
    return min(__getattr__("RESEND_BASE") * (2 ** resends_so_far), RESEND_CAP)
