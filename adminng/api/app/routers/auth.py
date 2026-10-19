"""Authentication routes — the Phase-2 two-step, device-bound flow."""

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import audit, auth, settings
from ..auth import Principal, device_header, device_secret_header, get_principal

router = APIRouter(prefix="/auth", tags=["auth"])


class Step1Request(BaseModel):
    username: str = Field(min_length=3)
    password: str = Field(min_length=1)
    # First contact from a browser registers it (and its grant) PENDING; the
    # metadata used to ride on the retired handshake, now on the login payload.
    client_type: str = Field(default="web", max_length=40)
    device_name: str | None = Field(default=None, max_length=120)
    # "Keep me signed in on this device": mints a 24h access token and a 24h
    # idle window for this session. Destructive actions still re-auth.
    remember: bool = False


class Step2Request(BaseModel):
    flow_token: str = Field(min_length=10)
    code: str = Field(min_length=6, max_length=10)


class EnrollRequest(BaseModel):
    enrollment_token: str = Field(min_length=10)


class EnrollConfirmRequest(EnrollRequest):
    code: str = Field(min_length=6, max_length=10)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=10)


class ReauthRequest(BaseModel):
    password: str = Field(min_length=1)


@router.post("/login-step1", summary="Password step: registers the device, returns state")
def login_step1(
    payload: Step1Request,
    request: Request,
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    return auth.login_step1(
        payload.username,
        payload.password,
        device_id,
        secret,
        audit.client_ip(request),
        client_type=payload.client_type,
        device_name=payload.device_name,
        remember=payload.remember,
    )


@router.post("/login-step2", summary="TOTP step: returns the token pair")
def login_step2(
    payload: Step2Request,
    request: Request,
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    return auth.login_step2(
        payload.flow_token, payload.code, device_id, secret, audit.client_ip(request)
    )


@router.post("/totp-enroll", summary="Start TOTP enrollment (QR/otpauth URI)")
def totp_enroll(
    payload: EnrollRequest,
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    return auth.enroll_start(payload.enrollment_token, device_id, secret)


@router.post("/totp-confirm", summary="Confirm the TOTP enrollment with a code")
def totp_confirm(
    payload: EnrollConfirmRequest,
    request: Request,
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    return auth.enroll_confirm(
        payload.enrollment_token, payload.code, device_id, secret, audit.client_ip(request)
    )


@router.post("/refresh", summary="Rotate the refresh token and mint a new access token")
def refresh(
    payload: RefreshRequest,
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    return auth.refresh_session(payload.refresh_token, device_id, secret)


@router.post("/logout", summary="Revoke the refresh token")
def logout(payload: RefreshRequest) -> dict:
    auth.logout_session(payload.refresh_token)
    return {"status": "logged_out"}


@router.post("/reauth-confirm", summary="Password re-auth for a destructive action")
def reauth_confirm(
    payload: ReauthRequest,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    return auth.reauth_confirm(payload.password, principal, audit.client_ip(request))


@router.get("/me", summary="The authenticated principal")
def me(principal: Principal = Depends(get_principal)) -> dict:
    return {
        "username": principal.username,
        "superadmin": principal.superadmin,
        "domains": principal.domains,
        "device_id": principal.device_id,
        "token_ttl": settings.ADMINNG_ACCESS_TTL,
    }
