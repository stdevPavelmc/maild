"""Device-scoped WebAuthn registration, sign-in, and re-authentication."""

import hashlib
import ipaddress
import json
import re
import uuid
from typing import NoReturn
from urllib.parse import urlsplit

import psycopg
from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes
from webauthn.helpers.bytes_to_base64url import bytes_to_base64url
from webauthn.helpers.exceptions import WebAuthnException
from webauthn.helpers.structs import (
    AuthenticatorAttachment,
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

from . import audit, auth, devices, ratelimit, settings, tokens
from .db import connect
from .errors import ApiError


def origin_config(origin: str | None) -> tuple[str, str]:
    """Validate the browser origin against the configured RP and origin allowlist."""
    rp_id = settings.ADMINNG_WEBAUTHN_RP_ID
    if not rp_id or not settings.ADMINNG_WEBAUTHN_ORIGINS:
        raise ApiError(
            503,
            "WEBAUTHN_NOT_CONFIGURED",
            "WebAuthn requires an RP ID and allowed origin configuration",
        )
    try:
        ipaddress.ip_address(rp_id)
        valid_rp_id = False
    except ValueError:
        valid_rp_id = rp_id == "localhost" or bool(
            re.fullmatch(
                r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}",
                rp_id,
            )
        )
    if not valid_rp_id:
        raise ApiError(503, "WEBAUTHN_NOT_CONFIGURED", "the WebAuthn RP ID must be a DNS name")
    if not origin or origin not in settings.ADMINNG_WEBAUTHN_ORIGINS:
        raise ApiError(403, "WEBAUTHN_ORIGIN_REJECTED", "the browser origin is not allowed")

    try:
        parsed = urlsplit(origin)
        hostname = (parsed.hostname or "").lower().rstrip(".")
        is_local_http = parsed.scheme == "http" and hostname in (
            "localhost",
            "127.0.0.1",
            "::1",
        )
        secure = parsed.scheme == "https" or is_local_http
        same_rp = hostname == rp_id or hostname.endswith("." + rp_id)
        valid_origin = (
            parsed.scheme in ("http", "https")
            and parsed.netloc
            and not parsed.username
            and not parsed.password
            and parsed.path == ""
            and not parsed.query
            and not parsed.fragment
        )
    except ValueError:
        valid_origin = secure = same_rp = False

    if not valid_origin or not secure or not same_rp:
        raise ApiError(
            403,
            "WEBAUTHN_ORIGIN_REJECTED",
            "the browser origin does not match the configured RP ID",
        )
    return origin, rp_id


def status(username: str, device_id: str) -> dict:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM webauthn_credential WHERE username = %s AND device_id = %s",
            (username, device_id),
        )
        enabled = cur.fetchone() is not None
    return {
        "configured": bool(
            settings.ADMINNG_WEBAUTHN_RP_ID and settings.ADMINNG_WEBAUTHN_ORIGINS
        ),
        "enabled": enabled,
    }


def _save_challenge(
    *,
    challenge_id: uuid.UUID,
    challenge: bytes,
    username: str,
    device_id: str,
    purpose: str,
    origin: str,
    rp_id: str,
    remember: bool = False,
) -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM webauthn_challenge WHERE expires_at <= now()")
        cur.execute(
            "DELETE FROM webauthn_challenge "
            "WHERE username = %s AND device_id = %s AND purpose = %s",
            (username, device_id, purpose),
        )
        cur.execute(
            """
            INSERT INTO webauthn_challenge
                   (challenge_id, challenge, username, device_id, purpose,
                    expected_origin, rp_id, remember, expires_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s,
                    now() + make_interval(secs => %s))
            """,
            (
                challenge_id,
                bytes_to_base64url(challenge),
                username,
                device_id,
                purpose,
                origin,
                rp_id,
                remember,
                settings.ADMINNG_WEBAUTHN_CHALLENGE_TTL,
            ),
        )
        conn.commit()


def _new_challenge(
    *,
    options,
    username: str,
    device_id: str,
    purpose: str,
    origin: str,
    rp_id: str,
    remember: bool = False,
) -> dict:
    challenge_id = uuid.uuid4()
    _save_challenge(
        challenge_id=challenge_id,
        challenge=options.challenge,
        username=username,
        device_id=device_id,
        purpose=purpose,
        origin=origin,
        rp_id=rp_id,
        remember=remember,
    )
    return {"challenge_id": str(challenge_id), "public_key": json.loads(options_to_json(options))}


def _consume_challenge(
    challenge_id: uuid.UUID, username: str, device_id: str, purpose: str
) -> dict:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            DELETE FROM webauthn_challenge
             WHERE challenge_id = %s AND username = %s AND device_id = %s
               AND purpose = %s AND expires_at > now()
         RETURNING challenge, expected_origin, rp_id, remember
            """,
            (challenge_id, username, device_id, purpose),
        )
        row = cur.fetchone()
        conn.commit()
    if row is None:
        raise ApiError(401, "WEBAUTHN_CHALLENGE_INVALID", "the challenge is expired or already used")
    return row


def _invalid_login(username: str, device_id: str, ip: str | None) -> NoReturn:
    locked = ratelimit.failure(username, ip)
    audit.record(
        actor=username,
        action="WEBAUTHN_LOGIN_FAIL",
        result="denied",
        device_id=device_id,
        ip=ip,
        endpoint="POST /api/v1/auth/webauthn/login/verify",
    )
    if locked:
        raise ApiError(429, "RATE_LIMITED", "too many failed attempts")
    raise ApiError(401, "WEBAUTHN_INVALID", "biometric sign-in could not be verified")


def registration_options(
    username: str, password: str, device_id: str, origin_header: str | None
) -> dict:
    origin, rp_id = origin_config(origin_header)
    auth._verify_credentials(username, password)
    _require_approved(device_id)
    if status(username, device_id)["enabled"]:
        raise ApiError(409, "WEBAUTHN_ALREADY_ENABLED", "biometric sign-in is already enabled")

    options = generate_registration_options(
        rp_id=rp_id,
        rp_name="MailD AdminNG",
        user_id=hashlib.sha256(username.lower().encode()).digest(),
        user_name=username,
        user_display_name=username,
        authenticator_selection=AuthenticatorSelectionCriteria(
            authenticator_attachment=AuthenticatorAttachment.PLATFORM,
            resident_key=ResidentKeyRequirement.DISCOURAGED,
            user_verification=UserVerificationRequirement.REQUIRED,
        ),
    )
    return _new_challenge(
        options=options,
        username=username,
        device_id=device_id,
        purpose="register",
        origin=origin,
        rp_id=rp_id,
    )


def registration_verify(
    challenge_id: uuid.UUID,
    credential: dict,
    username: str,
    device_id: str,
    ip: str | None,
) -> dict:
    challenge = _consume_challenge(challenge_id, username, device_id, "register")
    _require_approved(device_id)
    try:
        verified = verify_registration_response(
            credential=credential,
            expected_challenge=base64url_to_bytes(challenge["challenge"]),
            expected_rp_id=challenge["rp_id"],
            expected_origin=challenge["expected_origin"],
            require_user_verification=True,
        )
    except (WebAuthnException, ValueError, TypeError, KeyError):
        audit.record(
            actor=username,
            action="WEBAUTHN_REGISTER_FAIL",
            result="denied",
            device_id=device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/webauthn/register/verify",
        )
        raise ApiError(401, "WEBAUTHN_INVALID", "biometric registration could not be verified") from None

    transports = credential.get("response", {}).get("transports", [])
    transports = [item for item in transports if isinstance(item, str)]
    try:
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO webauthn_credential
                       (credential_id, username, device_id, public_key, sign_count, transports)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (
                    bytes_to_base64url(verified.credential_id),
                    username,
                    device_id,
                    verified.credential_public_key,
                    verified.sign_count,
                    transports,
                ),
            )
            conn.commit()
    except psycopg.errors.UniqueViolation:
        raise ApiError(
            409,
            "WEBAUTHN_CREDENTIAL_IN_USE",
            "this credential is already registered to another device",
        ) from None

    audit.record(
        actor=username,
        action="WEBAUTHN_REGISTER",
        device_id=device_id,
        ip=ip,
        endpoint="POST /api/v1/auth/webauthn/register/verify",
    )
    return {"enabled": True}


def login_options(
    username: str,
    device_id: str,
    ip: str | None,
    origin_header: str | None,
    remember: bool,
) -> dict:
    origin, rp_id = origin_config(origin_header)
    ratelimit.check(username, ip)
    device = devices.get(device_id)
    if device is None:
        raise ApiError(403, "DEVICE_NOT_AUTHORIZED", "run the device handshake first")
    auth._require_approved(device, username)
    admin = auth._admin_row(username)
    if admin is None or not admin["active"]:
        raise ApiError(401, "WEBAUTHN_UNAVAILABLE", "biometric sign-in is not enabled on this device")

    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT credential_id, transports FROM webauthn_credential "
            "WHERE username = %s AND device_id = %s",
            (username, device_id),
        )
        credential = cur.fetchone()
    if credential is None:
        raise ApiError(401, "WEBAUTHN_UNAVAILABLE", "biometric sign-in is not enabled on this device")

    options = generate_authentication_options(
        rp_id=rp_id,
        allow_credentials=[
            PublicKeyCredentialDescriptor(id=base64url_to_bytes(credential["credential_id"]))
        ],
        user_verification=UserVerificationRequirement.REQUIRED,
    )
    return _new_challenge(
        options=options,
        username=username,
        device_id=device_id,
        purpose="login",
        origin=origin,
        rp_id=rp_id,
        remember=remember,
    )


def _verify_assertion(
    challenge: dict, credential_id: str, credential: dict, stored: dict
) -> int:
    if credential_id != stored["credential_id"]:
        raise ApiError(401, "WEBAUTHN_INVALID", "biometric sign-in could not be verified")
    try:
        verified = verify_authentication_response(
            credential=credential,
            expected_challenge=base64url_to_bytes(challenge["challenge"]),
            expected_rp_id=challenge["rp_id"],
            expected_origin=challenge["expected_origin"],
            credential_public_key=bytes(stored["public_key"]),
            credential_current_sign_count=stored["sign_count"],
            require_user_verification=True,
        )
    except (WebAuthnException, ValueError, TypeError, KeyError):
        raise ApiError(401, "WEBAUTHN_INVALID", "biometric sign-in could not be verified") from None
    return verified.new_sign_count


def login_verify(
    username: str,
    challenge_id: uuid.UUID,
    credential: dict,
    device_id: str,
    ip: str | None,
) -> dict:
    challenge = _consume_challenge(challenge_id, username, device_id, "login")
    device = devices.get(device_id)
    if device is None:
        raise ApiError(403, "DEVICE_NOT_AUTHORIZED", "run the device handshake first")
    auth._require_approved(device, username)
    admin = auth._admin_row(username)
    if admin is None or not admin["active"]:
        _invalid_login(username, device_id, ip)

    raw_id = credential.get("rawId")
    if not isinstance(raw_id, str):
        _invalid_login(username, device_id, ip)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT credential_id, public_key, sign_count FROM webauthn_credential "
            "WHERE username = %s AND device_id = %s AND credential_id = %s",
            (username, device_id, raw_id),
        )
        stored = cur.fetchone()
    if stored is None:
        _invalid_login(username, device_id, ip)

    try:
        new_sign_count = _verify_assertion(challenge, raw_id, credential, stored)
    except ApiError:
        _invalid_login(username, device_id, ip)

    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE webauthn_credential SET sign_count = %s, last_used_at = now() "
            "WHERE credential_id = %s",
            (new_sign_count, stored["credential_id"]),
        )
        conn.commit()
    devices.bind_user(device_id, username, ip)
    ratelimit.success(username, ip)
    audit.record(
        actor=username,
        action="LOGIN_OK",
        device_id=device_id,
        ip=ip,
        endpoint="POST /api/v1/auth/webauthn/login/verify",
        method="webauthn",
    )
    return {"session_state": "AUTHENTICATED", **auth._issue(
        username, device_id, admin, remember=challenge["remember"]
    )}


def reauth_options(principal: auth.Principal, origin_header: str | None) -> dict:
    origin, rp_id = origin_config(origin_header)
    result = _credential_for(principal.username, principal.device_id)
    if result is None:
        raise ApiError(409, "WEBAUTHN_UNAVAILABLE", "biometric sign-in is not enabled on this device")
    options = generate_authentication_options(
        rp_id=rp_id,
        allow_credentials=[
            PublicKeyCredentialDescriptor(id=base64url_to_bytes(result["credential_id"]))
        ],
        user_verification=UserVerificationRequirement.REQUIRED,
    )
    return _new_challenge(
        options=options,
        username=principal.username,
        device_id=principal.device_id,
        purpose="reauth",
        origin=origin,
        rp_id=rp_id,
    )


def reauth_verify(
    principal: auth.Principal,
    challenge_id: uuid.UUID,
    credential: dict,
    ip: str | None,
) -> dict:
    challenge = _consume_challenge(
        challenge_id, principal.username, principal.device_id, "reauth"
    )
    stored = _credential_for(principal.username, principal.device_id)
    if stored is None:
        raise ApiError(409, "WEBAUTHN_UNAVAILABLE", "biometric sign-in is not enabled on this device")
    raw_id = credential.get("rawId")
    if not isinstance(raw_id, str):
        raise ApiError(401, "WEBAUTHN_INVALID", "biometric re-authentication could not be verified")
    try:
        new_sign_count = _verify_assertion(challenge, raw_id, credential, stored)
    except ApiError:
        audit.record(
            actor=principal.username,
            action="REAUTH_FAIL",
            result="denied",
            device_id=principal.device_id,
            ip=ip,
            endpoint="POST /api/v1/auth/webauthn/reauth/verify",
            method="webauthn",
        )
        raise

    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE webauthn_credential SET sign_count = %s, last_used_at = now() "
            "WHERE credential_id = %s",
            (new_sign_count, stored["credential_id"]),
        )
        conn.commit()
    audit.record(
        actor=principal.username,
        action="REAUTH_OK",
        device_id=principal.device_id,
        ip=ip,
        endpoint="POST /api/v1/auth/webauthn/reauth/verify",
        method="webauthn",
    )
    return {
        "security_validation_token": tokens.reauth_token(
            principal.username, principal.device_id
        ),
        "expires_in": settings.ADMINNG_REAUTH_TTL,
    }


def _credential_for(username: str, device_id: str) -> dict | None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT credential_id, public_key, sign_count FROM webauthn_credential "
            "WHERE username = %s AND device_id = %s",
            (username, device_id),
        )
        return cur.fetchone()


def disable(username: str, password: str, device_id: str, ip: str | None) -> dict:
    auth._verify_credentials(username, password)
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "DELETE FROM webauthn_challenge WHERE username = %s AND device_id = %s",
            (username, device_id),
        )
        cur.execute(
            "DELETE FROM webauthn_credential WHERE username = %s AND device_id = %s",
            (username, device_id),
        )
        removed = cur.rowcount
        conn.commit()
    audit.record(
        actor=username,
        action="WEBAUTHN_DISABLE",
        device_id=device_id,
        ip=ip,
        endpoint="DELETE /api/v1/auth/webauthn/credential",
    )
    return {"enabled": False, "removed": removed > 0}


def _require_approved(device_id: str) -> None:
    device = devices.get(device_id)
    if device is None:
        raise ApiError(403, "DEVICE_NOT_AUTHORIZED", "run the device handshake first")
    auth._require_approved(device)
