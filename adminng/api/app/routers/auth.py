"""Authentication routes (Phase 1: plain bearer tokens).

Phase 2 replaces these with login-step1/step2 (device-bound, TOTP) but keeps the
same Principal dependency underneath.
"""

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import auth as auth_service
from .. import settings
from ..auth import Principal, get_principal

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginRequest(BaseModel):
    username: str = Field(min_length=3)
    password: str = Field(min_length=1)


@router.post("/login", summary="Exchange catalogue credentials for a bearer token")
def login(payload: LoginRequest) -> dict:
    token, principal = auth_service.login(payload.username, payload.password)
    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_in": settings.ADMINNG_ACCESS_TTL,
        "user": {
            "username": principal.username,
            "superadmin": principal.superadmin,
            "domains": principal.domains,
        },
    }


@router.post("/logout", summary="Revoke the current session")
def logout(request: Request, principal: Principal = Depends(get_principal)) -> dict:
    authorization = request.headers.get("Authorization", "")
    token = authorization.split(" ", 1)[1].strip() if " " in authorization else ""
    if token:
        auth_service.logout(token)
    return {"status": "logged_out", "username": principal.username}


@router.get("/me", summary="The authenticated principal")
def me(principal: Principal = Depends(get_principal)) -> dict:
    return {
        "username": principal.username,
        "superadmin": principal.superadmin,
        "domains": principal.domains,
    }
