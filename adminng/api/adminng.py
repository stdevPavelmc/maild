#!/usr/bin/env python3
"""AdminNG management CLI — server-side device authorization and TOTP recovery.

Container access is root authority: this is how the FIRST device of a fresh
deployment is approved (there is no silent in-app auto-approval), and how a lost
authenticator is recovered. Approval is **device-scoped**: approving a browser
lets any admin sign in from it, so `--user` is now optional (it only records
which admin asked for it). See adminng/README.md for the operator how-to.

    docker compose exec api adminng.py --list-devices
    docker compose exec api adminng.py --approve-device '<uuid>'
    docker compose exec api adminng.py --revoke-device '<uuid>'
    docker compose exec api adminng.py --revoke-grant '<uuid>' --user '<admin>'
    docker compose exec api adminng.py --totp-reset '<username>'
"""

import argparse
import sys

import psycopg

from app import devices, settings
from app.db import connect
from app.errors import ApiError


def cmd_list_devices() -> int:
    page = devices.list_devices(None, None, 1000, None)
    rows = page["items"]
    if not rows:
        print("no devices registered yet")
        return 0

    print(
        f"{'DEVICE ID':<38} {'STATE':<9} {'ADMINS':<28} FINGERPRINT   DEVICE NAME"
    )
    for row in rows:
        admins = ",".join(row["usernames"]) or "(unclaimed)"
        print(
            f"{row['device_id']:<38} {row['authorization_state']:<9} "
            f"{admins[:28]:<28} {(row['fingerprint'] or '(unbound)'):<13} "
            f"{row['device_name'] or row['client_type'] or '-'}"
        )
    return 0


def cmd_approve_device(device_id: str, username: str | None, secret: str | None) -> int:
    """Approve a browser (idempotently); `username` only records the requester."""
    secret_hash = devices.hash_secret(secret) if secret else None
    if username:
        row = devices.ensure_grant(device_id, username, secret_hash, "cli")
    else:
        row = devices.approve_device(device_id, secret_hash, "cli")
    print(
        f"{device_id} -> {row['state']} (fingerprint: "
        f"{'bound' if secret_hash else 'binding pending first login'})"
    )
    return 0


def cmd_revoke_device(device_id: str) -> int:
    try:
        grants = devices.revoke_device(device_id)
    except ApiError:
        print(f"device {device_id} not found", file=sys.stderr)
        return 1
    print(f"{device_id} -> REVOKED ({grants} admin(s) logged, sessions destroyed)")
    return 0


def cmd_revoke_grant(device_id: str, username: str) -> int:
    row = devices.revoke_grant(device_id, username)
    print(
        f"{device_id} / {username} -> access revoked for this admin "
        f"({row['sessions_revoked']} session(s) destroyed, trust cleared)"
    )
    return 0


def cmd_purge_pending() -> int:
    removed = devices.purge_stale_pending(settings.ADMINNG_PENDING_TTL_DAYS)
    print(
        f"purged {removed} PENDING grant(s) older than "
        f"{settings.ADMINNG_PENDING_TTL_DAYS} day(s)"
    )
    return 0


def cmd_reset_ratelimit(username: str) -> int:
    """Clear a login lockout (testing/ops aid): every rate_limit row for the user."""
    from app import ratelimit

    removed = ratelimit.reset(username)
    label = "entry" if removed == 1 else "entries"
    print(f"rate limit for {username}: {removed} {label} cleared")
    return 0


def cmd_totp_reset(username: str) -> int:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM totp_credential WHERE username = %s", (username,))
        deleted = cur.rowcount
        # A factor reset invalidates any "skip the code" trust for this admin too.
        cur.execute(
            "UPDATE device_grant SET trusted_until = NULL WHERE username = %s",
            (username,),
        )
        conn.commit()

    print(
        f"TOTP credential for {username}: "
        f"{'deleted (the next login re-enrolls)' if deleted else 'not enrolled'}"
    )
    return 0


def cmd_legacy_hashes() -> int:
    """Report catalogue rows still on legacy md5crypt ($1$) hashes.

    Reads the catalogue (mailddb): the legacy rows are the ones the
    2027-02-01 weak-scheme removal will lock out — a password change
    (webmail or this API) rehashes them with the current PASSWORD_SCHEME.
    """
    from app.passwords import MD5CRYPT_SUPPORT_ENDS, is_legacy

    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT username, 'mailbox' AS kind FROM mailbox WHERE password LIKE '$1$%' "
            "UNION ALL "
            "SELECT username, 'admin' FROM admin WHERE password LIKE '$1$%' "
            "ORDER BY kind, username"
        )
        rows = cur.fetchall()

    if not rows:
        print("no legacy md5crypt hashes: the catalogue is fully migrated")
        return 0

    print(
        f"{len(rows)} legacy md5crypt hash(es) remain — weak-scheme support "
        f"ends {MD5CRYPT_SUPPORT_ENDS.isoformat()}:"
    )
    for row in rows:
        print(f"  {row['kind']:<8} {row['username']}")
    print(
        "migrate them with a password change (webmail Settings → Password, "
        "or the API) before the deadline; rehash-on-login migrates them as "
        "users authenticate."
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="adminng.py",
        description="AdminNG management CLI (device authorization, TOTP recovery)",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--list-devices",
        action="store_true",
        help="list registered devices and their authorization state",
    )
    group.add_argument(
        "--approve-device",
        metavar="DEVICE_ID",
        help="authorize a browser (optional --user records who requested it)",
    )
    group.add_argument(
        "--revoke-device",
        metavar="DEVICE_ID",
        help="revoke a browser: destroys its credentials and every session",
    )
    group.add_argument(
        "--revoke-grant",
        metavar="DEVICE_ID",
        help="revoke one admin on a browser (needs --user): sessions + trust",
    )
    group.add_argument(
        "--purge-pending",
        action="store_true",
        help="delete PENDING grants older than ADMINNG_PENDING_TTL_DAYS",
    )
    group.add_argument(
        "--reset-ratelimit",
        metavar="USERNAME",
        help="clear the login rate limit/lockout for a username (testing aid)",
    )
    group.add_argument(
        "--totp-reset",
        metavar="USERNAME",
        help="delete a TOTP credential so the next login re-enrolls",
    )
    group.add_argument(
        "--legacy-hashes",
        action="store_true",
        help="report mailbox/admin rows still on legacy md5crypt ($1$) hashes; "
        "weak-scheme support ends 2027-02-01 — those rows must be migrated "
        "(password change/rehash-on-login) before then",
    )
    parser.add_argument(
        "--user",
        metavar="USERNAME",
        help="admin for --approve-device (optional) / --revoke-grant (required)",
    )
    parser.add_argument(
        "--secret",
        metavar="SECRET",
        help="optional browser secret to pre-bind (dev fixtures; normally the "
        "client mints it and it binds on first login)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.list_devices:
            return cmd_list_devices()
        if args.approve_device:
            return cmd_approve_device(args.approve_device, args.user, args.secret)
        if args.revoke_device:
            return cmd_revoke_device(args.revoke_device)
        if args.revoke_grant:
            if not args.user:
                print("--revoke-grant requires --user", file=sys.stderr)
                return 2
            return cmd_revoke_grant(args.revoke_grant, args.user)
        if args.purge_pending:
            return cmd_purge_pending()
        if args.reset_ratelimit:
            return cmd_reset_ratelimit(args.reset_ratelimit)
        if args.totp_reset:
            return cmd_totp_reset(args.totp_reset)
        if args.legacy_hashes:
            return cmd_legacy_hashes()
    except psycopg.errors.InvalidTextRepresentation:
        print("invalid device id: expected a UUID (e.g. DE793C1A-...) ", file=sys.stderr)
        return 2
    except ApiError as exc:
        print(f"{exc.code}: {exc.message}", file=sys.stderr)
        return 1
    except psycopg.Error as exc:
        print(f"database error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
