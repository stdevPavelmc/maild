"""The /adminmcp administrator (proposal §7.2, decision 2026-10-30).

- Login: username + password + ALTCHA (web layer), then a 6-digit code mailed to the admin
  address (10 min, 5 attempts) at EVERY login.
- Recovery: "forgot password" mails a single-use link (30 min) to the admin address; the answer
  is neutral either way (no account oracle). CLI fallback: `manage.py mcp_admin_reset`.
- Email change: one code to the OLD and one to the NEW address, both required.
- Password change: current password + a code mailed to the current address.
A password change or reset revokes every other admin session.
"""

import datetime as dt
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import Argon2Error
from django.conf import settings
from django.db import transaction
from django.utils import timezone

from mcpcore import audit, mailer, webauth
from mcpcore.accounts import EMAIL_RE, AccountError
from mcpcore.crypto import new_id, token_hash
from mcpcore.models import AdminUser, OtpChallenge
from mcpcore.passwords import hash_password

CODE_TTL = 600
CODE_ATTEMPTS = 5
RECOVERY_TTL = 1800
MIN_PASSWORD = 12
_ph = PasswordHasher()


def verify_password(admin: AdminUser, password: str) -> bool:
    try:
        return _ph.verify(admin.password_hash, password or "")
    except (Argon2Error, ValueError):
        return False


def check_password_rules(password: str) -> None:
    if len(password or "") < MIN_PASSWORD:
        raise AccountError("weak_password", f"Use at least {MIN_PASSWORD} characters.")


def _code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def _issue(admin: AdminUser, purpose: str, email: str, group: str = "", payload: dict | None = None) -> OtpChallenge:
    code = _code()
    ch = OtpChallenge.objects.create(
        id=new_id(), purpose=purpose, admin=admin, group=group, target_email=email, code_hash=token_hash(code),
        payload=payload or {}, expires_at=timezone.now() + dt.timedelta(seconds=CODE_TTL))
    try:
        mailer.send("admin_code", email, "en", code=code, purpose=mailer.CODE_PURPOSES.get(purpose, purpose),
                    minutes=CODE_TTL // 60)
    except mailer.MailError:
        ch.delete()
        raise AccountError("mail_failed", "The code could not be mailed, try again later (or use the CLI reset).", 503) from None
    return ch


def _check(ch_id: str, purpose: str, code: str, admin: AdminUser | None = None) -> OtpChallenge:
    return _check_all([(ch_id, purpose, code)], admin)[0]


def _check_all(items: list[tuple[str, str, str]], admin: AdminUser | None = None) -> list[OtpChallenge]:
    """Verify several codes together and consume them only if ALL match (the email change needs
    both: a wrong second code must not burn the first). Every wrong code counts an attempt."""
    with transaction.atomic():
        rows, wrong = [], False
        for ch_id, purpose, code in items:
            ch = OtpChallenge.objects.select_for_update().select_related("admin").filter(id=ch_id, purpose=purpose).first()
            if ch is None or ch.used or ch.expires_at <= timezone.now() or (admin and ch.admin_id != admin.id):
                raise AccountError("invalid_code", "This code is not valid any more: start again.", 400)
            if ch.attempts >= CODE_ATTEMPTS:
                raise AccountError("too_many_attempts", "Too many wrong codes: start again.", 429)
            if token_hash((code or "").strip()) != ch.code_hash:
                ch.attempts += 1
                ch.save(update_fields=["attempts"])
                wrong = True
            rows.append(ch)
        if wrong:
            raise AccountError("wrong_code", "Wrong code.", 400)
        for ch in rows:
            ch.attempts += 1
            ch.used = True
            ch.save(update_fields=["attempts", "used"])
    return rows


# ------------------------------------------------------------------- login ---
def start_login(username: str, password: str) -> OtpChallenge:
    admin = AdminUser.objects.filter(username=username).first()
    if admin is None or not verify_password(admin, password):
        raise AccountError("invalid_credentials", "Invalid username or password.", 401)
    return _issue(admin, "login", admin.email)


def finish_login(challenge_id: str, code: str) -> AdminUser:
    ch = _check(challenge_id, "login", code)
    admin = ch.admin
    admin.last_login_at = timezone.now()
    admin.save(update_fields=["last_login_at"])
    return admin


# ---------------------------------------------------------------- recovery ---
def start_recovery(email: str, ip: str) -> None:
    """Always returns normally (neutral answer); mails a link only for the admin address."""
    email = (email or "").strip().lower()
    admin = AdminUser.objects.filter(email=email).first()
    audit.event("security", "admin.recovery_requested", result="sent" if admin else "unknown_address",
                actor={"type": "anonymous"}, ip=ip, level="warning")
    if admin is None:
        return
    token = "mdmcp_rc_" + secrets.token_urlsafe(32)
    OtpChallenge.objects.create(id=new_id(), purpose="recovery", admin=admin, target_email=email,
                                code_hash=token_hash(token),
                                expires_at=timezone.now() + dt.timedelta(seconds=RECOVERY_TTL))
    try:
        mailer.send("admin_recovery", email, "en", link=f"{settings.MCP_PUBLIC_URL}/adminmcp/reset#{token}",
                    minutes=RECOVERY_TTL // 60)
    except mailer.MailError:
        pass   # neutral answer anyway; the error log has it


def finish_recovery(token: str, new_password: str, ip: str) -> AdminUser:
    check_password_rules(new_password)
    with transaction.atomic():
        ch = OtpChallenge.objects.select_for_update().select_related("admin").filter(
            purpose="recovery", code_hash=token_hash(token or ""), used=False).first()
        if ch is None or ch.expires_at <= timezone.now():
            raise AccountError("invalid_link", "This reset link is not valid or has expired.", 404)
        ch.used = True
        ch.save(update_fields=["used"])
        admin = ch.admin
        admin.password_hash = hash_password(new_password)
        admin.save(update_fields=["password_hash", "updated_at"])
    webauth.revoke_all("admin", admin.id)
    audit.event("admin.settings", "admin.password_reset", actor={"type": "admin", "admin": admin.username}, ip=ip)
    return admin


def cli_reset(admin: AdminUser, new_password: str) -> None:
    admin.password_hash = hash_password(new_password)
    admin.save(update_fields=["password_hash", "updated_at"])
    webauth.revoke_all("admin", admin.id)
    audit.event("admin.settings", "admin.password_reset", actor={"type": "cli"}, detail={"admin": admin.username})


# ------------------------------------------------------- email / password ---
def start_email_change(admin: AdminUser, new_email: str) -> str:
    new_email = (new_email or "").strip().lower()
    if not EMAIL_RE.match(new_email) or new_email == admin.email:
        raise AccountError("invalid_address", "Give a new, valid email address.")
    group = new_id(8)
    _issue(admin, "email_old", admin.email, group=group, payload={"new": new_email})
    _issue(admin, "email_new", new_email, group=group, payload={"new": new_email})
    return group


def finish_email_change(admin: AdminUser, group: str, code_old: str, code_new: str, ip: str) -> AdminUser:
    old = OtpChallenge.objects.filter(group=group, purpose="email_old", admin=admin).first()
    new = OtpChallenge.objects.filter(group=group, purpose="email_new", admin=admin).first()
    if old is None or new is None:
        raise AccountError("invalid_code", "This change is not pending any more: start again.", 400)
    _check_all([(old.id, "email_old", code_old), (new.id, "email_new", code_new)], admin)
    previous = admin.email
    admin.email = new.payload["new"]
    admin.save(update_fields=["email", "updated_at"])
    audit.event("admin.settings", "admin.email_changed", actor={"type": "admin", "admin": admin.username}, ip=ip,
                detail={"from": previous, "to": admin.email})
    return admin


def start_password_change(admin: AdminUser, current: str, new_password: str) -> str:
    if not verify_password(admin, current):
        raise AccountError("invalid_credentials", "The current password is wrong.", 401)
    check_password_rules(new_password)
    ch = _issue(admin, "password", admin.email, payload={"hash": hash_password(new_password)})
    return ch.id


def finish_password_change(admin: AdminUser, challenge_id: str, code: str, keep_session: str, ip: str) -> None:
    ch = _check(challenge_id, "password", code, admin)
    admin.password_hash = ch.payload["hash"]
    admin.save(update_fields=["password_hash", "updated_at"])
    ch.payload = {}
    ch.save(update_fields=["payload"])
    webauth.revoke_all("admin", admin.id, keep=keep_session)
    audit.event("admin.settings", "admin.password_changed", actor={"type": "admin", "admin": admin.username}, ip=ip)
