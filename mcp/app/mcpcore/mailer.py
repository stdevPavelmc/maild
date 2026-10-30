"""Service mail (proposal §7.4): magic links and notices, sent as MCP_SERVICE_EMAIL.

Transport (admin "Service email" group, P3):
- internal (default): plain SMTP to amavis without auth (D2) on its INTERNAL listener
  (amavis:10026, D13): amavis scans, DKIM-signs (originating) and hands the message to the mta;
- external: the admin's SMTP server (host, port, none/STARTTLS/implicit TLS, optional AUTH; the
  password is stored Fernet-encrypted). `test_transport()` powers the admin's Test button.
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

CODE_PURPOSES = {"login": "sign in to the MailD MCP admin panel", "email_old": "confirm the admin email change",
                 "email_new": "confirm the admin email change", "password": "confirm the admin password change"}

_TEMPLATES = {
    "admin_code": {
        "en": ("MailD MCP admin code: {code}",
               "Your code to {purpose} is:\n\n    {code}\n\nIt is valid for {minutes} minutes. If you did not ask for it, "
               "someone knows the admin password: change it."),
        "es": ("Código de administración de MailD MCP: {code}",
               "Su código para {purpose} es:\n\n    {code}\n\nEs válido durante {minutes} minutos. Si no lo pidió, "
               "alguien conoce la contraseña de administración: cámbiela."),
    },
    "admin_recovery": {
        "en": ("MailD MCP admin password reset",
               "Open this link within {minutes} minutes to choose a new admin password:\n\n  {link}\n\n"
               "If you did not ask for it, ignore this message."),
        "es": ("Restablecer la contraseña de administración de MailD MCP",
               "Abra este enlace en los próximos {minutes} minutos para elegir una nueva contraseña:\n\n  {link}\n\n"
               "Si no lo pidió, ignore este mensaje."),
    },
    "admin_test": {
        "en": ("MailD MCP service email test", "This is the test message of the MailD MCP service email settings ({transport})."),
        "es": ("Prueba del correo de servicio de MailD MCP", "Este es el mensaje de prueba del correo de servicio de MailD MCP ({transport})."),
    },
    "new_token": {
        "en": ("MailD MCP: new access token \"{name}\"",
               "A new access token \"{name}\" (scopes: {scopes}) was created for {main} from {ip}.\n"
               "If it was not you, revoke it at {url} and change your mail password."),
        "es": ("MailD MCP: nuevo token de acceso \"{name}\"",
               "Se creó un nuevo token de acceso \"{name}\" (permisos: {scopes}) para {main} desde {ip}.\n"
               "Si no fue usted, revóquelo en {url} y cambie su contraseña de correo."),
    },
    "new_client": {
        "en": ("MailD MCP: token \"{name}\" used from a new place",
               "The access token \"{name}\" of {main} was used from a new address or client:\n\n"
               "  IP: {ip}\n  client: {client}\n\nIf that was not you, revoke it at {url}."),
        "es": ("MailD MCP: token \"{name}\" usado desde un lugar nuevo",
               "El token de acceso \"{name}\" de {main} se usó desde una dirección o cliente nuevo:\n\n"
               "  IP: {ip}\n  cliente: {client}\n\nSi no fue usted, revóquelo en {url}."),
    },
    "master_access": {
        "en": ("MailD MCP: administrator access to {address}",
               "The server administrator's master token \"{name}\" accessed the mailbox {address} through MailD MCP "
               "({when}). This is logged; you get at most one notice per token and day."),
        "es": ("MailD MCP: acceso del administrador a {address}",
               "El token maestro \"{name}\" del administrador del servidor accedió al buzón {address} mediante "
               "MailD MCP ({when}). Queda registrado; recibirá como máximo un aviso por token y día."),
    },
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


def _transport() -> dict:
    from mcpcore import settings_store

    return settings_store.get("service_email")


def _deliver(cfg: dict, sender: str, to: str, msg: EmailMessage, steps: list | None = None) -> None:
    """Submit through the configured transport; `steps` collects a transcript (Test button)."""
    def step(name: str, ok: bool = True, detail: str = ""):
        if steps is not None:
            steps.append({"step": name, "ok": ok, "detail": detail})

    if cfg.get("transport") != "external":
        with smtplib.SMTP(settings.MCP_SMTP_HOST, settings.MCP_SMTP_PORT, timeout=30) as smtp:
            step("connect", detail=f"{settings.MCP_SMTP_HOST}:{settings.MCP_SMTP_PORT} (internal, amavis)")
            smtp.ehlo("mcp")
            smtp.send_message(msg, from_addr=sender, to_addrs=[to])
            step("send", detail=f"accepted for {to}")
        return
    import ssl

    from mcpcore import crypto

    ctx = ssl.create_default_context()
    if not cfg.get("verify_tls", True):
        # admin opt-out (self-signed / private-CA server): still encrypted, not authenticated
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    host, port, tls = cfg["host"], int(cfg["port"]), cfg["tls"]
    cls = smtplib.SMTP_SSL if tls == "implicit" else smtplib.SMTP
    kwargs = {"context": ctx} if tls == "implicit" else {}
    with cls(host, port, timeout=30, **kwargs) as smtp:
        step("connect", detail=f"{host}:{port}" + (" (implicit TLS)" if tls == "implicit" else ""))
        smtp.ehlo("mcp")
        if tls == "starttls":
            smtp.starttls(context=ctx)
            smtp.ehlo("mcp")
            step("starttls", detail="TLS established, certificate verified" if cfg.get("verify_tls", True)
                 else "TLS established, certificate NOT verified (verification is switched off)")
        if cfg.get("user"):
            smtp.login(cfg["user"], crypto.decrypt(cfg.get("password", "")))
            step("auth", detail=f"authenticated as {cfg['user']}")
        smtp.send_message(msg, from_addr=sender, to_addrs=[to])
        step("send", detail=f"accepted for {to}")


def test_transport(to: str) -> dict:
    """Admin Test button: send the test message, return the transcript (never the password)."""
    cfg = _transport()
    steps: list = []
    try:
        msg, sender = _build("admin_test", to, "en", transport=cfg.get("transport", "internal"))
        _deliver(cfg, sender, to, msg, steps)
        ok, error = True, ""
    except (OSError, smtplib.SMTPException) as exc:
        ok, error = False, str(exc)[:300]
        steps.append({"step": "error", "ok": False, "detail": error})
    audit.event("admin.settings", "service_email.test", result="ok" if ok else "error",
                actor={"type": "admin"}, target={"to": to}, detail={"transport": cfg.get("transport")})
    return {"ok": ok, "transport": cfg.get("transport", "internal"), "steps": steps, "error": error}


def _build(template: str, to: str, lang: str, **values) -> tuple[EmailMessage, str]:
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
    return msg, sender


def send(template: str, to: str, lang: str = "en", **values) -> None:
    msg, sender = _build(template, to, lang, **values)
    try:
        _deliver(_transport(), sender, to, msg)
    except (OSError, smtplib.SMTPException) as exc:
        audit.error("mail.service", f"cannot send '{template}' to {to}: {exc}")
        raise MailError(str(exc)) from None
    audit.event("mail.send", "service_mail", target={"to": to}, detail={"template": template})
