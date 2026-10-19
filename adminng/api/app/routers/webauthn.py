"""WebAuthn enrollment, device-bound sign-in, and destructive re-auth."""

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import audit, webauthn
from ..auth import Principal, device_header, device_secret_header, get_principal

router = APIRouter(prefix="/auth/webauthn", tags=["auth"])


class PasswordRequest(BaseModel):
    password: str = Field(min_length=1)


class LoginOptionsRequest(BaseModel):
    username: str = Field(min_length=3)
    remember: bool = False


class VerifyRequest(BaseModel):
    challenge_id: UUID
    credential: dict[str, Any]


class LoginVerifyRequest(VerifyRequest):
    username: str = Field(min_length=3)


@router.get("/status", summary="WebAuthn availability on this device")
def status(principal: Principal = Depends(get_principal)) -> dict:
    return webauthn.status(principal.username, principal.device_id)


@router.post("/register/options", summary="Prove password and start platform-credential setup")
def register_options(
    payload: PasswordRequest,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    return webauthn.registration_options(
        principal.username,
        payload.password,
        principal.device_id,
        request.headers.get("origin"),
    )


@router.post("/register/verify", summary="Verify and store the platform credential")
def register_verify(
    payload: VerifyRequest,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    return webauthn.registration_verify(
        payload.challenge_id,
        payload.credential,
        principal.username,
        principal.device_id,
        audit.client_ip(request),
    )


@router.delete("/credential", summary="Remove this device's biometric credential")
def remove_credential(
    payload: PasswordRequest,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    return webauthn.disable(
        principal.username,
        payload.password,
        principal.device_id,
        audit.client_ip(request),
    )


@router.post("/login/options", summary="Start biometric sign-in")
def login_options(
    payload: LoginOptionsRequest,
    request: Request,
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    return webauthn.login_options(
        payload.username,
        device_id,
        secret,
        audit.client_ip(request),
        request.headers.get("origin"),
        payload.remember,
    )


@router.post("/login/verify", summary="Verify biometric sign-in")
def login_verify(
    payload: LoginVerifyRequest,
    request: Request,
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    return webauthn.login_verify(
        payload.username,
        payload.challenge_id,
        payload.credential,
        device_id,
        secret,
        audit.client_ip(request),
    )


@router.post("/reauth/options", summary="Start biometric destructive-action re-auth")
def reauth_options(
    request: Request, principal: Principal = Depends(get_principal)
) -> dict:
    return webauthn.reauth_options(principal, request.headers.get("origin"))


@router.post("/reauth/verify", summary="Mint a destructive-action validation token")
def reauth_verify(
    payload: VerifyRequest,
    request: Request,
    principal: Principal = Depends(get_principal),
) -> dict:
    return webauthn.reauth_verify(
        principal,
        payload.challenge_id,
        payload.credential,
        audit.client_ip(request),
    )
