#!/usr/bin/env python3
"""AdminNG management CLI — server-side device authorization and TOTP recovery.

Container access is root authority: this is how the FIRST device of a fresh
deployment is approved (there is no silent in-app auto-approval), and how a lost
authenticator is recovered. See adminng/README.md for the operator how-to.

    docker compose exec api adminng.py --list-devices
    docker compose exec api adminng.py --approve-device '<uuid>'
    docker compose exec api adminng.py --revoke-device '<uuid>'
    docker compose exec api adminng.py --totp-reset '<username>'
"""

import argparse
import sys

import psycopg

from app import settings
from app.db import connect


def _load_row(cur, sql: str, params: tuple):
    cur.execute(sql, params)
    return cur.fetchone()


def cmd_list_devices() -> int:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT device_id, state, associated_user, client_type, device_name,
                   first_seen, approved_by
              FROM device
             ORDER BY first_seen DESC
            """
        )
        rows = cur.fetchall()

    if not rows:
        print("no devices registered yet")
        return 0

    print(f"{'DEVICE ID':<38} {'STATE':<9} {'USER':<28} {'CLIENT':<12} DEVICE NAME")
    for row in rows:
        print(
            f"{str(row['device_id']):<38} {row['state']:<9} "
            f"{(row['associated_user'] or '-'):<28} "
            f"{(row['client_type'] or '-'):<12} {row['device_name'] or '-'}"
        )
    return 0


def cmd_set_state(device_id: str, state: str) -> int:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        row = _load_row(
            cur,
            """
            UPDATE device
               SET state = %s,
                   approved_at = CASE WHEN %s = 'APPROVED' THEN now() ELSE approved_at END,
                   approved_by = %s,
                   last_seen = now()
             WHERE device_id = %s
         RETURNING device_id, state
            """,
            (state, state, "cli", device_id),
        )
        if row is None:
            conn.rollback()
            print(f"device {device_id} not found", file=sys.stderr)
            return 1
        if state == "REVOKED":
            # Revocation is immediate: every session bound to the device dies now.
            cur.execute(
                "UPDATE session SET revoked_at = now() "
                "WHERE device_id = %s AND revoked_at IS NULL",
                (device_id,),
            )
        conn.commit()

    print(f"{row['device_id']} -> {row['state']}")
    return 0


def cmd_add_device(device_id: str) -> int:
    """Register a device row from the server side (PENDING), idempotently."""
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO device (device_id, client_type, device_name, state) "
            "VALUES (%s, 'cli', 'registered via CLI', 'PENDING') "
            "ON CONFLICT (device_id) DO NOTHING",
            (device_id,),
        )
        cur.execute("SELECT device_id, state FROM device WHERE device_id = %s", (device_id,))
        row = cur.fetchone()
        conn.commit()
    print(
        f"{row['device_id']} -> {row['state']} (registered; "
        f"run --approve-device {row['device_id']} to authorize)"
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
        "--add-device",
        metavar="DEVICE_ID",
        help="register a device (PENDING) from the server side, idempotently",
    )
    group.add_argument(
        "--approve-device",
        metavar="DEVICE_ID",
        help="authorize a PENDING device (the first-device bootstrap)",
    )
    group.add_argument(
        "--revoke-device",
        metavar="DEVICE_ID",
        help="revoke a device and destroy every session bound to it",
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
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.list_devices:
            return cmd_list_devices()
        if args.add_device:
            return cmd_add_device(args.add_device)
        if args.approve_device:
            return cmd_set_state(args.approve_device, "APPROVED")
        if args.revoke_device:
            return cmd_set_state(args.revoke_device, "REVOKED")
        if args.reset_ratelimit:
            return cmd_reset_ratelimit(args.reset_ratelimit)
        if args.totp_reset:
            return cmd_totp_reset(args.totp_reset)
        if args.legacy_hashes:
            return cmd_legacy_hashes()
    except psycopg.errors.InvalidTextRepresentation:
        print("invalid device id: expected a UUID (e.g. DE793C1A-...) ", file=sys.stderr)
        return 2
    except psycopg.Error as exc:
        print(f"database error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
