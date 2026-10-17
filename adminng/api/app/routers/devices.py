"""Device onboarding + the superadmin device panel (technical-draft §4.2)."""

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import audit, auth, devices
from ..auth import (
    Principal,
    device_header,
    get_principal,
    require_reauth,
    require_superadmin,
)
from ..errors import ApiError
from ..models import Page

router = APIRouter(tags=["devices"])


class HandshakeRequest(BaseModel):
    client_type: str = Field(default="web", max_length=40)
    device_name: str | None = Field(default=None, max_length=120)


class DeviceStateRequest(BaseModel):
    action: str = Field(pattern="^(APPROVE|REVOKE)$")


@router.post("/device/handshake", summary="Register this device (PENDING)")
def handshake(
    payload: HandshakeRequest, request: Request, device_id: str = Depends(device_header)
) -> dict:
    device = devices.register(
        device_id, payload.client_type, payload.device_name, audit.client_ip(request)
    )
    audit.record(
        actor="device",
        action="DEVICE_HANDSHAKE",
        device_id=device_id,
        ip=audit.client_ip(request),
        endpoint="POST /api/v1/device/handshake",
        client_type=payload.client_type,
    )
    return device


@router.get("/device/status", summary="Poll this device's authorization state")
def device_status(device_id: str = Depends(device_header)) -> dict:
    device = devices.get(device_id)
    if device is None:
        raise ApiError(404, "DEVICE_UNKNOWN", "run the handshake first", device_id=device_id)
    return {
        "device_id": device["device_id"],
        "authorization_state": device["authorization_state"],
    }


@router.get("/admin/devices", response_model=Page, summary="List devices (superadmin)")
def list_devices(
    state: str | None = None,
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(require_superadmin),
) -> dict:
    return devices.list_devices(state, limit, cursor)


@router.put(
    "/admin/devices/{device_id}/state",
    summary="Approve or revoke a device (superadmin, re-auth)",
)
def set_device_state(
    device_id: str,
    payload: DeviceStateRequest,
    request: Request,
    principal: Principal = Depends(require_superadmin),
) -> dict:
    state = {"APPROVE": "APPROVED", "REVOKE": "REVOKED"}[payload.action]
    result = devices.set_state(device_id, state, principal.username)
    audit.record(
        actor=principal.username,
        action="DEVICE_" + payload.action,
        device_id=device_id,
        ip=audit.client_ip(request),
        endpoint=f"PUT /api/v1/admin/devices/{device_id}/state",
        authorized_by=principal.username,
    )
    return result
