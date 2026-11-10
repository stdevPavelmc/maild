"""Background jobs (proposal §12): hourly, advisory-locked so only one uvicorn worker (or one
`manage.py mcp_jobs --once`) runs them at a time; the IMAP pool sweep runs in every worker.
"""

import asyncio
import logging

from django.db import connections
from django.utils import timezone

from mcpcore import accounts, audit, imap, tokens, webauth
from mcpcore.models import AltchaUsed, WebSession

log = logging.getLogger("mcp.jobs")

JOBS_LOCK_ID = 0x6D63705F6A6F62  # "mcp_job"
HOURLY = 3600
SWEEP = 30


def run_once() -> dict | None:
    """Run every hourly job if no other process is; None when the lock is held elsewhere."""
    conn = connections["default"]
    with conn.cursor() as cur:
        cur.execute("SELECT pg_try_advisory_lock(%s)", [JOBS_LOCK_ID])
        if not cur.fetchone()[0]:
            return None
    try:
        now = timezone.now()
        done = {
            "tokens_idle_disabled": tokens.disable_idle_tokens(),
            "pending_addresses_expired": accounts.purge_expired_pending(),
            "altcha_purged": AltchaUsed.objects.filter(expires_at__lt=now).delete()[0],
            "sessions_purged": WebSession.objects.filter(expires_at__lt=now).delete()[0],
            "login_failures_purged": webauth.purge_failures(),
            "log_files_pruned": audit.prune(),
            # OAuth (P4): spent codes / stale requests, and access tokens dead for a day
            "oauth_cleanup": _oauth_cleanup(now),
        }
        log.info("hourly jobs: %s", done)
        return done
    finally:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_unlock(%s)", [JOBS_LOCK_ID])


def _oauth_cleanup(now) -> int:
    import datetime as dt

    from mcpcore.models import OAuthCode, OAuthRequest, Token

    n = OAuthCode.objects.filter(expires_at__lt=now).delete()[0]
    n += OAuthRequest.objects.filter(expires_at__lt=now).delete()[0]
    n += Token.objects.filter(kind=Token.OAUTH_ACCESS, expires_at__lt=now - dt.timedelta(days=1)).delete()[0]
    return n


def _hourly():
    try:
        return run_once()
    except Exception as exc:  # a failing job never kills the loop
        audit.error("jobs", str(exc))
    finally:
        connections.close_all()


async def loop():
    await asyncio.sleep(60)
    elapsed = HOURLY  # first hourly run one minute after start
    while True:
        await asyncio.to_thread(imap.sweep)
        if elapsed >= HOURLY:
            await asyncio.to_thread(_hourly)
            elapsed = 0
        await asyncio.sleep(SWEEP)
        elapsed += SWEEP
