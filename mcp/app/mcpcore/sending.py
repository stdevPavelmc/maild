"""Sending (proposal §6, decisions D2/D13 and 2026-10-30): build, check and submit a message on
behalf of a caller, then file a copy in its Sent folder.

The amavis:10026 path skips Postfix's own controls, so the MCP enforces their equivalents:
- sender ownership: `From`/envelope = a usable address of the caller (active in the account,
  inside the token's subset, mailbox active, domain allowed) — the same rule as Postfix's
  reject_sender_login_mismatch (aliases are never account addresses, so they cannot send);
- rate limit: recipients per window per account AND per sender address (MCP_SEND_RATE_*);
- size limit: MAX_MESSAGESIZE, the mta's own variable;
- visibility: one `maild-mcp: sent user=… rcpts=… token=…` line per message on stdout (syslog in
  production), counted by cron's outbound_watch.sh.

`Bcc` is envelope-only on the wire and kept in the Sent copy. Amavis deferring (cold start,
clamd down) is reported as a retryable error; the MCP never queues.
"""

import datetime as dt
import email.policy
import logging
import smtplib
import uuid
from dataclasses import dataclass, field
from email.message import EmailMessage
from email.utils import formatdate, getaddresses, parseaddr

from django.conf import settings
from django.db import transaction
from django.db.models import F
from django.utils import timezone

from mcpcore import audit, catalogue, imap, mail, policy, prefs
from mcpcore.accounts import EMAIL_RE
from mcpcore.models import SendCounter

log = logging.getLogger("mcp.send")
VERSION = "0.2.0"
MAX_RECIPIENTS = 100


class SendError(Exception):
    def __init__(self, code: str, message: str, retryable: bool = False):
        super().__init__(message)
        self.code, self.message, self.retryable = code, message, retryable


@dataclass
class Outgoing:
    sender: str
    to: list[str]
    cc: list[str] = field(default_factory=list)
    bcc: list[str] = field(default_factory=list)
    subject: str = ""
    body_text: str = ""
    body_html: str | None = None
    attachments: list[tuple[str, str, bytes]] = field(default_factory=list)   # (filename, content type, bytes)
    in_reply_to: str = ""
    references: str = ""

    @property
    def recipients(self) -> list[str]:
        return list(dict.fromkeys(self.to + self.cc + self.bcc))


# ------------------------------------------------------------- validation ---
def parse_addresses(value, field_name: str) -> list[str]:
    """A list (or comma-separated string) of addresses → normalised bare addresses."""
    if value is None or value == "":
        return []
    items = value if isinstance(value, list) else [value]
    out = []
    for item in items:
        text = str(item)
        if "\r" in text or "\n" in text:
            raise SendError("invalid_address", f"'{field_name}' contains a line break")
        for _name, addr in getaddresses([text]):
            addr = addr.strip().lower()
            if not addr:
                continue
            if not EMAIL_RE.match(addr):
                raise SendError("invalid_address", f"'{addr}' in '{field_name}' is not a valid address")
            out.append(addr)
    return list(dict.fromkeys(out))


def choose_sender(principal, requested: str | None, hint: list[str] | None = None) -> str:
    """The `from` the caller asked for, or the default: a hinted address (reply), the account's
    default-sender preference, the first usable address."""
    usable = principal.usable()
    if requested:
        addr = parseaddr(requested)[1].strip().lower()
        if addr not in usable:
            raise SendError("sender_not_allowed",
                            f"'{addr}' is not an address this token may send from (use list_accounts)")
        return addr
    for addr in hint or []:
        if addr in usable:
            return addr
    preferred = prefs.get(principal.account).get("default_sender")
    if preferred in usable:
        return preferred
    if not usable:
        raise SendError("sender_not_allowed", "this token has no address it may send from")
    return usable[0]


def external_recipients(recipients: list[str]) -> list[str]:
    hosted = catalogue.hosted_domains()
    return [r for r in recipients if r.rsplit("@", 1)[1] not in hosted]


def confirmation_reason(principal, recipients: list[str]) -> str:
    """Why this send needs the two-step confirmation, '' when it does not."""
    mode = prefs.get(principal.account)["confirm_send"]
    if policy.FORCE_CONFIRM or mode == "always":
        return "always"
    if mode == "external":
        ext = external_recipients(recipients)
        if ext:
            return "external recipients: " + ", ".join(ext[:10])
    return ""


# ---------------------------------------------------------------- building ---
def _with_signature(principal, text: str) -> str:
    sig = (prefs.get(principal.account).get("signature") or "").strip()
    return f"{text.rstrip()}\n\n-- \n{sig}\n" if sig else text


def build(principal, out: Outgoing, draft: bool = False) -> tuple[EmailMessage, bytes, bytes]:
    """→ (message, wire bytes without Bcc, Sent-copy bytes with Bcc). A draft may have no recipient."""
    if not out.recipients and not draft:
        raise SendError("no_recipients", "give at least one recipient in 'to', 'cc' or 'bcc'")
    if len(out.recipients) > MAX_RECIPIENTS:
        raise SendError("too_many_recipients", f"at most {MAX_RECIPIENTS} recipients per message")
    if "\r" in out.subject or "\n" in out.subject:
        raise SendError("invalid_subject", "the subject contains a line break")
    if not policy.ALLOW_EXTERNAL and external_recipients(out.recipients):
        raise SendError("external_not_allowed", "this server does not allow agents to send outside its domains")
    msg = EmailMessage(policy=email.policy.SMTP)
    msg["From"] = out.sender
    if out.to:
        msg["To"] = ", ".join(out.to)
    if out.cc:
        msg["Cc"] = ", ".join(out.cc)
    msg["Subject"] = out.subject
    msg["Date"] = formatdate(localtime=False)
    msg["Message-ID"] = f"<{uuid.uuid4().hex}@{out.sender.rsplit('@', 1)[1]}>"
    if out.in_reply_to:
        msg["In-Reply-To"] = out.in_reply_to
    if out.references:
        msg["References"] = out.references
    msg["User-Agent"] = f"MailD-MCP/{VERSION}"
    msg["X-MailD-MCP-Token"] = principal.token.public_id
    msg.set_content(_with_signature(principal, out.body_text or ""))
    if out.body_html:
        msg.add_alternative(out.body_html, subtype="html")
    for filename, ctype, payload in out.attachments:
        maintype, _, subtype = (ctype or "application/octet-stream").partition("/")
        msg.add_attachment(payload, maintype=maintype or "application", subtype=subtype or "octet-stream",
                           filename=filename)
    wire = msg.as_bytes()
    if out.bcc:
        msg["Bcc"] = ", ".join(out.bcc)
    sent_copy = msg.as_bytes()
    if len(sent_copy) > policy.MAX_MESSAGESIZE:
        raise SendError("too_large", f"the message is {len(sent_copy)} bytes, over the {policy.MAX_MESSAGESIZE}-byte limit")
    return msg, wire, sent_copy


# -------------------------------------------------------------- rate limit ---
def _window_start() -> dt.datetime:
    now = int(timezone.now().timestamp())
    return dt.datetime.fromtimestamp(now - now % policy.SEND_RATE_WINDOW, tz=dt.UTC)


def _subjects(principal, sender: str) -> list[str]:
    return [f"acct:{principal.account.id}", f"addr:{sender}"]


def check_rate(principal, sender: str, n: int) -> None:
    start = _window_start()
    for subject in _subjects(principal, sender):
        row = SendCounter.objects.filter(subject=subject, window_start=start).first()
        used = row.recipients if row else 0
        if used + n > policy.SEND_RATE_RECIPIENTS:
            log.warning("maild-mcp: throttled user=%s rcpts=%d token=%s", sender, n, principal.token.public_id)
            audit.event("security", "send.throttled", result="denied", actor=principal.audit_actor(),
                        token=principal.audit_token(), ip=principal.ip, level="warning",
                        detail={"sender": sender, "subject": subject, "used": used, "asked": n,
                                "limit": policy.SEND_RATE_RECIPIENTS, "window": policy.SEND_RATE_WINDOW})
            raise SendError("rate_limited",
                            f"send limit reached ({policy.SEND_RATE_RECIPIENTS} recipients per "
                            f"{policy.SEND_RATE_WINDOW // 60} min); try again later", retryable=True)


def record_rate(principal, sender: str, n: int) -> None:
    start = _window_start()
    with transaction.atomic():
        for subject in _subjects(principal, sender):
            row, _ = SendCounter.objects.select_for_update().get_or_create(subject=subject, window_start=start)
            SendCounter.objects.filter(id=row.id).update(recipients=F("recipients") + n)
    SendCounter.objects.filter(window_start__lt=start - dt.timedelta(seconds=policy.SEND_RATE_WINDOW)).delete()


# ------------------------------------------------------------------ submit ---
def submit(principal, out: Outgoing) -> dict:
    """Check, submit to amavis, file the Sent copy. Returns the result for the tool."""
    msg, wire, sent_copy = build(principal, out)
    rcpts = out.recipients
    check_rate(principal, out.sender, len(rcpts))
    try:
        with smtplib.SMTP(settings.MCP_SMTP_HOST, settings.MCP_SMTP_PORT, timeout=60) as smtp:
            smtp.ehlo("mcp")
            refused = smtp.sendmail(out.sender, rcpts, wire)
    except smtplib.SMTPRecipientsRefused as exc:
        raise SendError("recipients_refused", f"every recipient was refused: {', '.join(exc.recipients)}") from None
    except smtplib.SMTPResponseException as exc:
        retry = 400 <= exc.smtp_code < 500
        raise SendError("send_failed" if not retry else "send_deferred",
                        f"the mail server answered {exc.smtp_code}: {exc.smtp_error.decode(errors='replace')[:200]}"
                        + (" (temporary, retry later)" if retry else ""), retryable=retry) from None
    except (OSError, smtplib.SMTPException) as exc:
        audit.error("mail.send", f"cannot reach {settings.MCP_SMTP_HOST}:{settings.MCP_SMTP_PORT}: {exc}")
        raise SendError("send_unavailable", "the mail server is not reachable right now, retry later", retryable=True) from None
    accepted = [r for r in rcpts if r not in refused]
    record_rate(principal, out.sender, len(accepted))
    log.info("maild-mcp: sent user=%s rcpts=%d token=%s", out.sender, len(accepted), principal.token.public_id)
    result = {"status": "sent", "message_id": msg["Message-ID"], "sender": out.sender, "accepted": accepted,
              "refused": sorted(refused), "sent_folder": None, "warning": ""}
    try:
        result["sent_folder"] = mail.append(out.sender, "sent", sent_copy, [b"\\Seen"])
    except (mail.MailError, imap.ImapUnavailable) as exc:
        result["warning"] = f"sent, but the copy could not be filed in Sent: {exc}"
    audit.event("mail.send", "send", actor=principal.audit_actor(), token=principal.audit_token(), ip=principal.ip,
                target={"account": out.sender}, detail={"recipients": len(accepted), "refused": len(refused),
                                                         "bcc": len(out.bcc), "attachments": len(out.attachments)})
    return result


# ------------------------------------------------------------ replies, fwd ---
def quote(original: dict, body: str) -> str:
    quoted = "\n".join("> " + line for line in body[: policy.MAX_QUOTED_CHARS].splitlines())
    return f"On {original.get('date') or 'an earlier date'}, {original.get('from') or 'someone'} wrote:\n{quoted}\n"


def reply_subject(subject: str) -> str:
    return subject if subject.lower().startswith("re:") else f"Re: {subject}".strip()


def forward_subject(subject: str) -> str:
    return subject if subject.lower().startswith(("fwd:", "fw:")) else f"Fwd: {subject}".strip()
