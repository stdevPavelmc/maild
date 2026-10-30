"""JSON API for the user page (proposal §4 `/webapi/*`, §7.1, §7.3).

Auth: `Authorization: Bearer <access JWT>` (15 min, kept in memory by the SPA). The refresh token
lives in an HttpOnly; Secure; SameSite=Strict cookie scoped to /webapi and is only read by
/refresh and /logout, so no endpoint acts on a cookie alone (no CSRF surface).
"""

from django.conf import settings
from django.http import HttpRequest, JsonResponse
from ninja import NinjaAPI, Schema
from ninja.security import HttpBearer

from mcpcore import accounts, audit, tokens, webauth
from mcpcore.accounts import AccountError
from mcpcore.models import Account, AccountAddress

api = NinjaAPI(urls_namespace="webapi", docs_url=None, openapi_url=None, title="MailD MCP web API")


def _ip(request: HttpRequest) -> str:
    from asgi import client_ip

    scope = getattr(request, "scope", None)
    return client_ip(scope) if scope else request.META.get("REMOTE_ADDR", "")


def _ua(request: HttpRequest) -> str:
    return request.headers.get("User-Agent", "")[:255]


@api.exception_handler(AccountError)
def account_error(request, exc: AccountError):
    resp = JsonResponse({"error": exc.code, "message": exc.message, **exc.extra}, status=exc.status)
    if "retry_after" in exc.extra:
        resp["Retry-After"] = str(exc.extra["retry_after"])
    return resp


class UserAuth(HttpBearer):
    def authenticate(self, request, token):
        sess = webauth.verify_access(token, "user")
        if sess is None:
            return None
        account = Account.objects.filter(id=sess.subject_id).first()
        if account is None:
            return None
        request.web_session = sess
        request.account = account
        return account


user_auth = UserAuth()


# ------------------------------------------------------------------ altcha ---
@api.get("/altcha/challenge")
def altcha_challenge(request):
    resp = JsonResponse(webauth.altcha_challenge())
    resp["Cache-Control"] = "no-store"
    return resp


# ------------------------------------------------------------------- login ---
class LoginIn(Schema):
    email: str
    password: str
    altcha: str


def _set_refresh(resp, refresh: str):
    resp.set_cookie(webauth.REFRESH_COOKIE, refresh, max_age=settings.MCP_USER_SESSION_TTL, path=webauth.REFRESH_PATH,
                    secure=True, httponly=True, samesite="Strict")


def _session_payload(access: str, account: Account) -> dict:
    return {"access_token": access, "expires_in": settings.MCP_ACCESS_TTL, "account": _account(account)}


@api.post("/user/login")
def login(request, data: LoginIn):
    ip, ua = _ip(request), _ua(request)
    email = accounts.normalize(data.email)
    if not webauth.altcha_verify(data.altcha):
        audit.event("security", "captcha_fail", result="denied", actor={"type": "user", "email": email}, ip=ip, ua=ua)
        raise AccountError("captcha_failed", "The anti-robot check failed, try again.", 400)
    if webauth.locked(email, ip):
        audit.event("security", "lockout", result="denied", actor={"type": "user", "email": email}, ip=ip, ua=ua)
        raise AccountError("locked", "Too many failed attempts, try again in 15 minutes.", 429)
    try:
        account = accounts.login(email, data.password, ip)
    except AccountError as exc:
        if exc.code == "invalid_credentials":
            if webauth.record_failure(email, ip):
                audit.event("security", "lockout_armed", result="denied", actor={"type": "user", "email": email},
                            ip=ip, ua=ua, level="warning")
        audit.event("web.login", "user.login", result=exc.code, actor={"type": "user", "email": email}, ip=ip, ua=ua)
        raise
    webauth.clear_failures(email, ip)
    access, refresh, _sess = webauth.open_session("user", account.id, email, ip, ua)
    audit.event("web.login", "user.login", actor={"type": "user", "email": email, "account": account.id}, ip=ip, ua=ua)
    resp = JsonResponse(_session_payload(access, account))
    _set_refresh(resp, refresh)
    return resp


@api.post("/user/refresh")
def refresh(request):
    rotated = webauth.rotate(request.COOKIES.get(webauth.REFRESH_COOKIE, ""))
    if rotated is None:
        resp = JsonResponse({"error": "session_expired", "message": "Please sign in again."}, status=401)
        resp.delete_cookie(webauth.REFRESH_COOKIE, path=webauth.REFRESH_PATH)
        return resp
    access, new_refresh, sess = rotated
    account = Account.objects.filter(id=sess.subject_id).first()
    if account is None:
        return JsonResponse({"error": "session_expired", "message": "Please sign in again."}, status=401)
    resp = JsonResponse(_session_payload(access, account))
    _set_refresh(resp, new_refresh)
    return resp


@api.post("/user/logout", auth=user_auth)
def logout(request):
    webauth.revoke(request.web_session)
    audit.event("web.logout", "user.logout", actor={"type": "user", "account": request.account.id}, ip=_ip(request))
    resp = JsonResponse({"ok": True})
    resp.delete_cookie(webauth.REFRESH_COOKIE, path=webauth.REFRESH_PATH)
    return resp


# ----------------------------------------------------------------- account ---
def _address(a: AccountAddress) -> dict:
    return {"id": a.id, "email": a.email, "main": a.is_main, "status": a.status,
            "confirmed_at": a.confirmed_at, "magic_expires_at": a.magic_expires_at,
            "next_resend_at": a.next_resend_at, "resend_count": a.resend_count}


def _account(account: Account) -> dict:
    return {"id": account.id, "main_email": account.main_email, "mcp_enabled": account.mcp_enabled,
            "lang": (account.prefs or {}).get("lang", "en"),
            "addresses": [_address(a) for a in account.addresses.order_by("-is_main", "email")],
            "mcp_url": settings.MCP_RESOURCE_URL}


@api.get("/user/me", auth=user_auth)
def me(request):
    data = _account(request.account)
    data["login_email"] = request.web_session.login_email
    return data


class SwitchIn(Schema):
    enabled: bool


@api.put("/user/mcp", auth=user_auth)
def switch(request, data: SwitchIn):
    accounts.set_mcp_enabled(request.account, data.enabled, _ip(request))
    return _account(request.account)


class PrefsIn(Schema):
    lang: str


@api.put("/user/prefs", auth=user_auth)
def prefs(request, data: PrefsIn):
    accounts.set_lang(request.account, data.lang)
    return _account(request.account)


class AddressIn(Schema):
    email: str


@api.post("/user/addresses", auth=user_auth)
def add_address(request, data: AddressIn):
    return _address(accounts.add_address(request.account, data.email, _ip(request)))


@api.post("/user/addresses/{address_id}/resend", auth=user_auth)
def resend(request, address_id: int):
    return _address(accounts.resend(request.account, address_id, _ip(request)))


class AddressStatusIn(Schema):
    enabled: bool
    confirm: str


def _confirmed(account: Account, address_id: int, typed: str) -> None:
    row = account.addresses.filter(id=address_id).first()
    if row is None or accounts.normalize(typed) != row.email:
        raise AccountError("confirmation_mismatch", "Type the address exactly to confirm.")


@api.post("/user/addresses/{address_id}/status", auth=user_auth)
def address_status(request, address_id: int, data: AddressStatusIn):
    _confirmed(request.account, address_id, data.confirm)
    return _address(accounts.set_address_status(request.account, address_id, data.enabled, _ip(request)))


class ConfirmIn(Schema):
    confirm: str


@api.post("/user/addresses/{address_id}/remove", auth=user_auth)
def remove_address(request, address_id: int, data: ConfirmIn):
    _confirmed(request.account, address_id, data.confirm)
    accounts.remove_address(request.account, address_id, _ip(request))
    return {"ok": True}


class MagicIn(Schema):
    token: str


@api.post("/confirm")
def confirm(request, data: MagicIn):
    row = accounts.confirm(data.token, _ip(request))
    return {"address": row.email, "account": row.account.main_email}


# ------------------------------------------------------------------ tokens ---
@api.get("/user/tokens", auth=user_auth)
def list_tokens(request):
    return {"tokens": [tokens.serialize(t) for t in request.account.tokens.order_by("-created_at")]}


class TokenIn(Schema):
    name: str
    lifetime: str = "default"         # "default" (30 d) | "<n>d" | "forever"
    scopes: list[str]
    addresses: list[str] | None = None


@api.post("/user/tokens", auth=user_auth)
def create_token(request, data: TokenIn):
    raw, tok = tokens.create_pat(request.account, data.name, data.lifetime, data.scopes, data.addresses, _ip(request))
    return {"token": raw, **tokens.serialize(tok)}


@api.post("/user/tokens/{token_id}/{action}", auth=user_auth)
def token_action(request, token_id: int, action: str):
    return tokens.serialize(tokens.change_status(request.account, token_id, action, _ip(request)))
