"""User-policy defaults (proposal §7.2 group 3).

The admin panel (P3) stores overrides in the `setting` table; until then these are the values.
Every reader goes through these functions, so P3 only changes this module.
"""

DAY = 86400

MAX_TOKENS_PER_ACCOUNT = 10
PAT_DEFAULT_LIFETIME = 30 * DAY
PAT_FOREVER_ALLOWED = True
PAT_IDLE_LIMIT = 30 * DAY          # D12: admin may lower it, never raise it or switch it off
MAGIC_LINK_TTL = DAY
RESEND_BASE = 60                   # 2^n × base, n = resends so far
RESEND_CAP = DAY
MAX_SECONDARY_ADDRESSES = 10
MAX_BODY_CHARS = 100_000           # text returned to agents per message
MAX_ATTACHMENT_BYTES = 5 * 1024 * 1024
LOGIN_MAX_FAILURES = 5
LOGIN_LOCKOUT = 15 * 60
CLAIM_NOTICE_INTERVAL = DAY        # D11: one postmaster notice per (claimer, address) per day

SCOPES = ("mail.read", "mail.modify", "mail.trash", "mail.send")

# --- sending (proposal §6; P3 moves the admin-side knobs into the settings table) ---
import os as _os


def _int_env(name: str, default: int) -> int:
    try:
        return int(_os.environ.get(name, "").strip() or default)
    except ValueError:
        return default


SEND_RATE_RECIPIENTS = _int_env("MCP_SEND_RATE_RECIPIENTS", 200)   # per window, per account AND per sender
SEND_RATE_WINDOW = _int_env("MCP_SEND_RATE_WINDOW", 3600)
MAX_MESSAGESIZE = _int_env("MAX_MESSAGESIZE", 34865152)           # same variable (and default) as the mta
CONFIRM_TTL = 300                  # confirmation handles: single use, bound to token + tool + arguments
ALLOW_EXTERNAL = True              # admin: allow sending outside the hosted domains
FORCE_CONFIRM = False              # admin: confirmation for every send, whatever the user prefers
ALLOW_NO_CONFIRM = False           # admin: offer the "never" mode (decision 2026-10-30: not before P3)
MAX_QUOTED_CHARS = 20_000          # original text quoted in replies / forwards

CONFIRM_MODES = ("always", "external") + (("never",) if ALLOW_NO_CONFIRM else ())

# user preferences (proposal §7.3.3) and their defaults
DEFAULT_PREFS = {
    "lang": "en",
    "confirm_send": "external",
    "default_sender": "",          # "" = the first usable address
    "signature": "",
    "hidden_folders": [],
    "allow_attachments": True,
}
MAX_SIGNATURE_CHARS = 2000
MAX_HIDDEN_FOLDERS = 50


def resend_delay(resends_so_far: int) -> int:
    return min(RESEND_BASE * (2 ** resends_so_far), RESEND_CAP)
