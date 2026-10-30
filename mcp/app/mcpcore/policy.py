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


def resend_delay(resends_so_far: int) -> int:
    return min(RESEND_BASE * (2 ** resends_so_far), RESEND_CAP)
