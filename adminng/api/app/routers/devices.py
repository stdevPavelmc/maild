"""Device onboarding + the superadmin device panel.

There is no anonymous handshake: a browser is registered lazily by the first
verified `login-step1`. This router exposes the per-browser status poll (proving
the client-minted secret) and the superadmin device panel. Approval is
**device-scoped** (`device.state`): one approval authorizes the browser, after
which any admin may sign in from it.
"""

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from .. import audit, devices
from ..auth import (
    Principal,
    device_header,
    device_secret_header,
    require_reauth,
    require_superadmin,
)
from ..errors import ApiError
from ..models import Page

router = APIRouter(tags=["devices"])


class DeviceStateRequest(BaseModel):
    action: str = Field(pattern="^(APPROVE|REVOKE)$")
    # Legacy field from the per-grant model; ignored now that approval is
    # device-scoped (kept so older clients keep working).
    username: str | None = Field(default=None, min_length=3)


@router.get("/device/status", summary="Poll this device's authorization state")
def device_status(
    username: str | None = Query(default=None),
    device_id: str = Depends(device_header),
    secret: str = Depends(device_secret_header),
) -> dict:
    """Only the browser holding the matching secret may read its own state.

    Any other caller (unknown device or wrong secret) gets the same 404, so a
    leaked device id reveals nothing.
    """
    device = devices.device_row(device_id)
    if device is None or not devices.secret_matches(device.get("secret_hash"), secret):
        raise ApiError(404, "DEVICE_UNKNOWN", "unknown device", device_id=device_id)
    return {
        "device_id": str(device["device_id"]),
        "username": username or "",
        "authorization_state": device["state"],
        # Only the holder of the secret sees the fingerprint: the admin compares
        # it out-of-band before approving.
        "fingerprint": (
            devices.fingerprint(device["secret_hash"], str(device["device_id"]))
            if device.get("secret_hash")
            else None
        ),
    }


@router.get("/admin/devices", response_model=Page, summary="List devices (superadmin)")
def list_devices(
    state: str | None = None,
    username: str | None = None,
    limit: int = 50,
    cursor: str | None = None,
    principal: Principal = Depends(require_superadmin),
) -> dict:
    return devices.list_devices(state, username, limit, cursor)


@router.put(
    "/admin/devices/{device_id}/state",
    summary="Approve or revoke a device (superadmin, re-auth)",
)
def set_device_state(
    device_id: str,
    payload: DeviceStateRequest,
    request: Request,
    principal: Principal = Depends(require_reauth),
) -> dict:
    if not principal.superadmin:
        raise ApiError(403, "FORBIDDEN", "superadmin only")
    state = {"APPROVE": "APPROVED", "REVOKE": "REVOKED"}[payload.action]
    result = devices.set_device_state(device_id, state, principal.username)
    audit.record(
        actor=principal.username,
        action="DEVICE_" + payload.action,
        device_id=device_id,
        ip=audit.client_ip(request),
        endpoint=f"PUT /api/v1/admin/devices/{device_id}/state",
        authorized_by=principal.username,
    )
    return result
