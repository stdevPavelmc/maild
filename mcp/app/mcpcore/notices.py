"""Notices mailed after a successful bearer authentication (proposal §7.3.3, D7; P3):

- PAT used from an IP/client pair never seen for that token → the account's main address
  (preference `notify_new_client`, default on); once per (token, IP, client).
- master token used on a mailbox → that mailbox (admin setting `master_notify_user`, default
  OFF, and the owner's `notify_master_access` if they have an MCP account); once per (token,
  mailbox) per day.

Both are throttled through `notice_throttle`; a mail failure never fails the request.
"""

import datetime as dt

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from mcpcore import mailer, policy, prefs
from mcpcore.models import AccountAddress, NoticeThrottle, Token


def _first_time(kind: str, key: str, every: dt.timedelta | None = None) -> bool:
    now = timezone.now()
    with transaction.atomic():
        row = NoticeThrottle.objects.select_for_update().filter(kind=kind, key=key[:512]).first()
        if row and (every is None or now - row.last_sent_at < every):
            return False
        try:
            NoticeThrottle.objects.update_or_create(kind=kind, key=key[:512], defaults={"last_sent_at": now})
        except IntegrityError:
            return False
    return True


def after_auth(p) -> None:
    tok = p.token
    try:
        if tok.kind == Token.PAT and p.account is not None:
            if _first_time("token_seen", f"{tok.id}|{p.ip}|{p.client}"):
                pr = prefs.get(p.account)
                if pr.get("notify_new_client", True):
                    mailer.send("new_client", p.account.main_email, pr.get("lang", "en"), name=tok.name,
                                main=p.account.main_email, ip=p.ip or "unknown", client=p.client or "unknown",
                                url=settings.MCP_PUBLIC_URL)
        elif tok.kind == Token.MASTER and policy.MASTER_NOTIFY_USER:
            act_as = getattr(p, "act_as", "")
            row = AccountAddress.objects.select_related("account").filter(email=act_as).first()
            wants = prefs.get(row.account).get("notify_master_access", True) if row else True
            lang = prefs.get(row.account).get("lang", "en") if row else "en"
            if wants and _first_time("master_access", f"{tok.id}|{act_as}", every=dt.timedelta(days=1)):
                mailer.send("master_access", act_as, lang, name=tok.name, address=act_as,
                            when=timezone.now().isoformat(timespec="minutes"))
    except mailer.MailError:
        pass
