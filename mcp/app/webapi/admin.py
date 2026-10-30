"""JSON API for the admin panel (proposal §4 `/webapi/admin/*`, §7.2; P3).

Auth: admin access JWT (15 min, memory) + `mdmcp_admin_refresh` cookie (HttpOnly, Secure,
SameSite=Strict, Path=/webapi/admin), 72 h absolute (MCP_ADMIN_SESSION_TTL). Login = password +
ALTCHA, then the code mailed to the admin address (decision 2026-10-30).
"""

from django.conf import settings
from django.http import JsonResponse
from ninja import Body, Router, Schema
from ninja.security import HttpBearer

from mcpcore import adminauth, audit, catalogue, domains, mailer, settings_store, tokens, webauth
from mcpcore.accounts import AccountError
from mcpcore.models import AdminUser, Token

router = Router()


def _ip(request) -> str:
    from webapi.api import _ip as user_ip

    return user_ip(request)


class AdminAuth(HttpBearer):
    def authenticate(self, request, token):
        sess = webauth.verify_access(token, "admin")
        if sess is None:
            return None
        admin = AdminUser.objects.filter(id=sess.subject_id).first()
        if admin is None:
            return None
        request.web_session = sess
        request.admin = admin
        return admin


admin_auth = AdminAuth()


def _set_refresh(resp, refresh: str):
    resp.set_cookie(webauth.ADMIN_REFRESH_COOKIE, refresh, max_age=settings.MCP_ADMIN_SESSION_TTL,
                    path=webauth.ADMIN_REFRESH_PATH, secure=True, httponly=True, samesite="Strict")


def _me(admin: AdminUser) -> dict:
    svc = settings.MCP_SERVICE_EMAIL
    return {"username": admin.username, "email": admin.email, "last_login_at": admin.last_login_at,
            "service_mailbox": {"address": svc, "active": catalogue.mailbox_state(svc)},
            "master_token_max_hours": settings.MCP_MASTER_TOKEN_MAX_TTL // 3600}


# ------------------------------------------------------------------- login ---
class LoginIn(Schema):
    username: str
    password: str
    altcha: str


@router.post("/login")
def login(request, data: LoginIn):
    ip = _ip(request)
    key = f"admin:{data.username.strip()}"
    if not webauth.altcha_verify(data.altcha):
        audit.event("security", "captcha_fail", result="denied", actor={"type": "admin", "admin": data.username}, ip=ip)
        raise AccountError("captcha_failed", "The anti-robot check failed, try again.", 400)
    if webauth.locked(key, ip):
        audit.event("security", "lockout", result="denied", actor={"type": "admin", "admin": data.username}, ip=ip)
        raise AccountError("locked", "Too many failed attempts, try again in 15 minutes.", 429)
    try:
        ch = adminauth.start_login(data.username.strip(), data.password)
    except AccountError as exc:
        if exc.code == "invalid_credentials" and webauth.record_failure(key, ip):
            audit.event("security", "lockout_armed", result="denied", actor={"type": "admin", "admin": data.username},
                        ip=ip, level="warning")
        audit.event("admin.login", "admin.login", result=exc.code, actor={"type": "admin", "admin": data.username}, ip=ip)
        raise
    webauth.clear_failures(key, ip)
    return {"step": "code", "challenge_id": ch.id, "sent_to": _mask(ch.target_email)}


def _mask(email: str) -> str:
    local, _, dom = email.partition("@")
    return (local[:2] + "…" if len(local) > 2 else local) + "@" + dom


class CodeIn(Schema):
    challenge_id: str
    code: str


@router.post("/login/verify")
def login_verify(request, data: CodeIn):
    ip, ua = _ip(request), request.headers.get("User-Agent", "")[:255]
    admin = adminauth.finish_login(data.challenge_id, data.code)
    access, refresh, _ = webauth.open_session("admin", admin.id, admin.email, ip, ua)
    audit.event("admin.login", "admin.login", actor={"type": "admin", "admin": admin.username}, ip=ip, ua=ua)
    resp = JsonResponse({"access_token": access, "expires_in": settings.MCP_ACCESS_TTL, "admin": _me(admin)})
    _set_refresh(resp, refresh)
    return resp


@router.post("/refresh")
def refresh(request):
    rotated = webauth.rotate(request.COOKIES.get(webauth.ADMIN_REFRESH_COOKIE, ""))
    if rotated is None or rotated[2].kind != "admin":
        resp = JsonResponse({"error": "session_expired", "message": "Please sign in again."}, status=401)
        resp.delete_cookie(webauth.ADMIN_REFRESH_COOKIE, path=webauth.ADMIN_REFRESH_PATH)
        return resp
    access, new_refresh, sess = rotated
    admin = AdminUser.objects.filter(id=sess.subject_id).first()
    if admin is None:
        return JsonResponse({"error": "session_expired", "message": "Please sign in again."}, status=401)
    resp = JsonResponse({"access_token": access, "expires_in": settings.MCP_ACCESS_TTL, "admin": _me(admin)})
    _set_refresh(resp, new_refresh)
    return resp


@router.post("/logout", auth=admin_auth)
def logout(request):
    webauth.revoke(request.web_session)
    audit.event("admin.login", "admin.logout", actor={"type": "admin", "admin": request.admin.username}, ip=_ip(request))
    resp = JsonResponse({"ok": True})
    resp.delete_cookie(webauth.ADMIN_REFRESH_COOKIE, path=webauth.ADMIN_REFRESH_PATH)
    return resp


# ---------------------------------------------------------------- recovery ---
class RecoverIn(Schema):
    email: str
    altcha: str


@router.post("/recover")
def recover(request, data: RecoverIn):
    if not webauth.altcha_verify(data.altcha):
        raise AccountError("captcha_failed", "The anti-robot check failed, try again.", 400)
    adminauth.start_recovery(data.email, _ip(request))
    return {"ok": True, "message": "If that is the admin address, a reset link is on its way."}


class ResetIn(Schema):
    token: str
    password: str
    altcha: str


@router.post("/reset")
def reset(request, data: ResetIn):
    if not webauth.altcha_verify(data.altcha):
        raise AccountError("captcha_failed", "The anti-robot check failed, try again.", 400)
    adminauth.finish_recovery(data.token, data.password, _ip(request))
    return {"ok": True}


# -------------------------------------------------------------- admin user ---
@router.get("/me", auth=admin_auth)
def me(request):
    return _me(request.admin)


class EmailStartIn(Schema):
    new_email: str


@router.post("/email/start", auth=admin_auth)
def email_start(request, data: EmailStartIn):
    group = adminauth.start_email_change(request.admin, data.new_email)
    return {"group": group, "old": _mask(request.admin.email), "new": data.new_email.strip().lower()}


class EmailConfirmIn(Schema):
    group: str
    code_old: str
    code_new: str


@router.post("/email/confirm", auth=admin_auth)
def email_confirm(request, data: EmailConfirmIn):
    return _me(adminauth.finish_email_change(request.admin, data.group, data.code_old, data.code_new, _ip(request)))


class PasswordStartIn(Schema):
    current: str
    new: str


@router.post("/password/start", auth=admin_auth)
def password_start(request, data: PasswordStartIn):
    return {"challenge_id": adminauth.start_password_change(request.admin, data.current, data.new),
            "sent_to": _mask(request.admin.email)}


@router.post("/password/confirm", auth=admin_auth)
def password_confirm(request, data: CodeIn):
    adminauth.finish_password_change(request.admin, data.challenge_id, data.code, request.web_session.jti, _ip(request))
    return {"ok": True}


# ---------------------------------------------------------------- settings ---
@router.get("/settings/{group}", auth=admin_auth)
def get_settings(request, group: str):
    if group not in settings_store.GROUPS:
        raise AccountError("not_found", "No such settings group.", 404)
    return settings_store.public(group)


@router.put("/settings/{group}", auth=admin_auth)
def put_settings(request, group: str, data: dict = Body(...)):
    if group not in settings_store.GROUPS:
        raise AccountError("not_found", "No such settings group.", 404)
    try:
        return settings_store.put(group, data, request.admin)
    except settings_store.SettingsError as exc:
        raise AccountError("invalid_setting", exc.message, 400, field=exc.field) from None


@router.get("/domains", auth=admin_auth)
def list_domains(request):
    return {"domains": domains.listing()}


class DomainsIn(Schema):
    allowed: list[str]


@router.put("/domains", auth=admin_auth)
def put_domains(request, data: DomainsIn):
    """The dual list: everything in `allowed` is allowed, every other catalogue domain denied."""
    wanted = {d.strip().lower() for d in data.allowed}
    actor = {"type": "admin", "admin": request.admin.username}
    known = {row["domain"] for row in domains.listing()}
    unknown = wanted - known
    if unknown:
        raise AccountError("unknown_domain", f"Not catalogue domains: {', '.join(sorted(unknown))}", 400)
    for row in domains.listing():
        if (row["domain"] in wanted) != row["allowed"]:
            domains.set_allowed(row["domain"], row["domain"] in wanted, actor)
    return {"domains": domains.listing()}


@router.post("/service-email/test", auth=admin_auth)
def service_email_test(request):
    return mailer.test_transport(request.admin.email)


# ----------------------------------------------------------- master tokens ---
@router.get("/master-tokens", auth=admin_auth)
def list_master(request):
    rows = Token.objects.select_related("admin").filter(kind=Token.MASTER).order_by("-created_at")
    return {"tokens": [tokens.serialize_master(t) for t in rows]}


class MasterIn(Schema):
    name: str
    ttl_hours: float | None = None
    scopes: list[str]
    allowed_cidrs: list[str] | None = None


@router.post("/master-tokens", auth=admin_auth)
def create_master(request, data: MasterIn):
    raw, tok = tokens.create_master(request.admin, data.name, data.ttl_hours, data.scopes, data.allowed_cidrs, _ip(request))
    return {"token": raw, **tokens.serialize_master(tok)}


@router.post("/master-tokens/{token_id}/{action}", auth=admin_auth)
def master_action(request, token_id: int, action: str):
    return tokens.serialize_master(tokens.change_master_status(request.admin, token_id, action, _ip(request)))


# ------------------------------------------------------------- logs viewer ---
@router.get("/logs", auth=admin_auth)
def logs(request, kind: str = "audit", q: str = "", limit: int = 200):
    if kind not in audit.KINDS:
        raise AccountError("invalid_kind", "kind is audit, access or errors.", 400)
    return {"kind": kind, "items": audit.tail(kind, q, max(1, min(limit, 1000)))}
