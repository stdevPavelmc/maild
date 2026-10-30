"""Service mail (proposal §7.4): magic links and notices, sent as MCP_SERVICE_EMAIL.

Plain SMTP to amavis without auth (D2) on its INTERNAL listener (amavis:10026, D13): amavis
scans, DKIM-signs (originating) and hands the message to the mta. The listener's ACL admits
only cron and mcp.
External SMTP (admin setting) arrives in P3.
"""

import smtplib
import uuid
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import formatdate

from django.conf import settings

from mcpcore import audit

USER_AGENT = "MailD-MCP"

_TEMPLATES = {
    "magic_link": {
        "en": ("Confirm {address} for MailD MCP",
               "Someone signed in to MailD MCP as {main} asked to add {address} to that account.\n\n"
               "If that was you, open this link within 24 hours to confirm you can read this mailbox:\n\n"
               "  {link}\n\n"
               "If it was not you, ignore this message: nothing happens without the link."),
        "es": ("Confirme {address} en MailD MCP",
               "Alguien con sesión en MailD MCP como {main} pidió añadir {address} a esa cuenta.\n\n"
               "Si fue usted, abra este enlace en las próximas 24 horas para confirmar que puede leer este buzón:\n\n"
               "  {link}\n\n"
               "Si no fue usted, ignore este mensaje: sin el enlace no ocurre nada."),
    },
    "address_disabled": {
        "en": ("MailD MCP: {address} disabled", "{address} was disabled in your MailD MCP account ({main}). "
               "Tokens can no longer use it until you enable it again."),
        "es": ("MailD MCP: {address} desactivada", "{address} se desactivó en su cuenta de MailD MCP ({main}). "
               "Los tokens no podrán usarla hasta que la vuelva a activar."),
    },
    "address_enabled": {
        "en": ("MailD MCP: {address} enabled", "{address} was enabled again in your MailD MCP account ({main})."),
        "es": ("MailD MCP: {address} activada", "{address} se volvió a activar en su cuenta de MailD MCP ({main})."),
    },
    "address_removed": {
        "en": ("MailD MCP: {address} removed", "{address} was removed from your MailD MCP account ({main})."),
        "es": ("MailD MCP: {address} eliminada", "{address} se eliminó de su cuenta de MailD MCP ({main})."),
    },
    "pending_cancelled": {
        "en": ("MailD MCP: {address} claimed by its owner",
               "Your pending request to add {address} to {main} was cancelled: the owner of {address} "
               "signed in to MailD MCP with that address."),
        "es": ("MailD MCP: {address} reclamada por su titular",
               "Su solicitud pendiente para añadir {address} a {main} se canceló: el titular de {address} "
               "inició sesión en MailD MCP con esa dirección."),
    },
    "token_idle": {
        "en": ("MailD MCP: token \"{name}\" disabled after 30 idle days",
               "The access token \"{name}\" of {main} was not used for 30 days and is now disabled.\n"
               "Re-enable it from the MailD MCP page ({url}) if you still need it."),
        "es": ("MailD MCP: token \"{name}\" desactivado tras 30 días sin uso",
               "El token de acceso \"{name}\" de {main} no se usó en 30 días y quedó desactivado.\n"
               "Reactívelo desde la página de MailD MCP ({url}) si todavía lo necesita."),
    },
    "claim_conflict": {
        "en": ("MailD MCP: address claim conflict for {address}",
               "{claimer} (from {ip}, {when}) tried to add {address} to their MailD MCP account, "
               "but {address} already belongs to the account of {holder}.\n"
               "The attempt was refused. This notice is sent at most once a day per claimer and address."),
        "es": ("MailD MCP: conflicto al reclamar {address}",
               "{claimer} (desde {ip}, {when}) intentó añadir {address} a su cuenta de MailD MCP, "
               "pero {address} ya pertenece a la cuenta de {holder}.\n"
               "El intento fue rechazado. Este aviso se envía como máximo una vez al día por solicitante y dirección."),
    },
}


class MailError(Exception):
    pass


def send(template: str, to: str, lang: str = "en", **values) -> None:
    lang = lang if lang in ("en", "es") else "en"
    subject, body = _TEMPLATES[template][lang]
    msg = EmailMessage(policy=SMTP)
    sender = settings.MCP_SERVICE_EMAIL
    msg["From"] = f"MailD MCP <{sender}>"
    msg["To"] = to
    msg["Subject"] = subject.format(**values)
    msg["Date"] = formatdate(localtime=False)
    msg["Message-ID"] = f"<{uuid.uuid4().hex}@{sender.rsplit('@', 1)[1]}>"
    msg["Auto-Submitted"] = "auto-generated"
    msg["User-Agent"] = USER_AGENT
    msg.set_content(body.format(**values) + "\n\n-- \nMailD MCP\n")
    try:
        with smtplib.SMTP(settings.MCP_SMTP_HOST, settings.MCP_SMTP_PORT, timeout=30) as smtp:
            smtp.ehlo("mcp")
            smtp.send_message(msg, from_addr=sender, to_addrs=[to])
    except (OSError, smtplib.SMTPException) as exc:
        audit.error("mail.service", f"cannot send '{template}' to {to}: {exc}")
        raise MailError(str(exc)) from None
    audit.event("mail.send", "service_mail", target={"to": to}, detail={"template": template})
