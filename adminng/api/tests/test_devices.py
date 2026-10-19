#!/usr/bin/env python3
"""Device registry tests against the real adminng database (inside the api container).

The model under test: a `device` row is the browser identity and binds a
client-minted secret; authorization is **device-scoped** (`device.state`), and
`device_grant` is a per-admin activity log that also carries the 24h trust
window (`trusted_until`). Nothing is created by an anonymous caller.
"""

import unittest
import uuid

from app import devices, settings
from app.db import connect
from app.errors import ApiError

DEVICE = "11111111-2222-4333-8444-555555555555"
USERNAME = "device-test@example.net"
SECRET = "unit-test-secret-0123456789abcdef"
SECRET_HASH = devices.hash_secret(SECRET)


def _cleanup() -> None:
    # device_grant / session / webauthn_* cascade from the device row.
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM device WHERE device_id = %s", (DEVICE,))
        conn.commit()


class DeviceLifecycle(unittest.TestCase):
    def setUp(self):
        _cleanup()

    def tearDown(self):
        _cleanup()

    def test_secret_hash_and_fingerprint(self):
        self.assertTrue(devices.secret_matches(SECRET_HASH, SECRET))
        self.assertFalse(devices.secret_matches(SECRET_HASH, "another-secret-000"))
        self.assertFalse(devices.secret_matches(None, SECRET))
        fp = devices.fingerprint(SECRET_HASH, DEVICE)
        self.assertRegex(fp, r"^[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}$")
        self.assertEqual(fp, devices.fingerprint(SECRET_HASH, DEVICE))
        self.assertNotEqual(fp, devices.fingerprint(devices.hash_secret("x" * 20), DEVICE))

    def test_register_device_is_pending(self):
        device = devices.register_device(DEVICE, "web", "Unit test", SECRET_HASH, "127.0.0.1")
        self.assertEqual(str(device["device_id"]), DEVICE)
        self.assertEqual(device["secret_hash"], SECRET_HASH)
        self.assertEqual(device["state"], "PENDING")
        self.assertFalse(devices.device_authorized(DEVICE))

        # Re-registering keeps the bound secret and refreshes metadata.
        again = devices.register_device(DEVICE, "web", "Unit test 2", "x" * 64, "127.0.0.2")
        self.assertEqual(again["device_name"], "Unit test 2")
        self.assertEqual(again["last_ip"], "127.0.0.2")
        self.assertEqual(again["secret_hash"], SECRET_HASH)  # not overwritten

    def test_approve_device_is_device_scoped_and_idempotent(self):
        # The suite runs against the live adminng database, where the dev fixtures
        # already hold approved devices: compare against the current total.
        before = devices.count_approved_devices()
        row = devices.approve_device(DEVICE, None, "cli")
        self.assertEqual(row["state"], "APPROVED")
        self.assertEqual(devices.count_approved_devices(), before + 1)
        # Idempotent: the same call keeps one approved device.
        devices.approve_device(DEVICE, SECRET_HASH, "cli")
        self.assertEqual(devices.count_approved_devices(), before + 1)
        device = devices.device_row(DEVICE)
        self.assertEqual(device["secret_hash"], SECRET_HASH)
        self.assertTrue(devices.device_authorized(DEVICE))

    def test_revoke_device_kills_sessions_and_credentials(self):
        devices.ensure_grant(DEVICE, USERNAME, SECRET_HASH, "unit-test")
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO session (jti, username, device_id) VALUES (%s, %s, %s)",
                (uuid.uuid4().hex, USERNAME, DEVICE),
            )
            cur.execute(
                "INSERT INTO webauthn_credential "
                "(credential_id, username, device_id, public_key) VALUES (%s, %s, %s, %s)",
                (uuid.uuid4().hex, USERNAME, DEVICE, b"test-public-key"),
            )
            conn.commit()

        revoked = devices.set_device_state(DEVICE, "REVOKED", "unit-test")
        self.assertEqual(revoked["new_state"], "REVOKED")
        self.assertEqual(devices.device_row(DEVICE)["state"], "REVOKED")
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute("SELECT revoked_at FROM session WHERE device_id = %s", (DEVICE,))
            rows = cur.fetchall()
            self.assertEqual(len(rows), 1)
            self.assertIsNotNone(rows[0]["revoked_at"])
            cur.execute(
                "SELECT count(*) AS n FROM webauthn_credential WHERE device_id = %s",
                (DEVICE,),
            )
            self.assertEqual(cur.fetchone()["n"], 0)

    def test_revoke_device_marks_it_revoked(self):
        devices.ensure_grant(DEVICE, USERNAME, SECRET_HASH, "unit-test")
        self.assertEqual(devices.revoke_device(DEVICE), 1)
        self.assertEqual(devices.device_row(DEVICE)["state"], "REVOKED")

    def test_list_devices_filters_by_state_and_user(self):
        devices.ensure_grant(DEVICE, USERNAME, SECRET_HASH, "unit-test")
        other = devices.register_device(
            "22222222-2222-4222-8222-222222222222", "web", "other", None, None
        )
        pending = devices.list_devices("PENDING", None, 50, None)
        self.assertTrue(
            any(d["device_id"] == str(other["device_id"]) for d in pending["items"])
        )
        self.assertTrue(all(d["authorization_state"] == "PENDING" for d in pending["items"]))

        page = devices.list_devices(None, USERNAME, 50, None)
        self.assertEqual([d["device_id"] for d in page["items"]], [DEVICE])
        self.assertEqual(page["items"][0]["usernames"], [USERNAME])
        self.assertEqual(page["items"][0]["fingerprint"], devices.fingerprint(SECRET_HASH, DEVICE))

    def test_trust_window_follows_a_remembered_login(self):
        devices.ensure_grant(DEVICE, USERNAME, SECRET_HASH, "unit-test")
        devices.record_login(DEVICE, USERNAME, "127.0.0.1")
        self.assertFalse(devices.trust_valid(DEVICE, USERNAME))
        self.assertEqual(devices.arm_trust(DEVICE, USERNAME), 1)
        self.assertTrue(devices.trust_valid(DEVICE, USERNAME))
        # A fixed window: once it lapses the code is required again.
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "UPDATE device_grant SET trusted_until = now() - interval '1 second' "
                "WHERE device_id = %s AND username = %s",
                (DEVICE, USERNAME),
            )
            conn.commit()
        self.assertFalse(devices.trust_valid(DEVICE, USERNAME))
        devices.clear_trust(DEVICE, USERNAME)
        self.assertFalse(devices.trust_valid(DEVICE, USERNAME))

    def test_revoke_grant_clears_trust_and_sessions(self):
        devices.ensure_grant(DEVICE, USERNAME, SECRET_HASH, "unit-test")
        devices.record_login(DEVICE, USERNAME, None)
        devices.arm_trust(DEVICE, USERNAME)
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO session (jti, username, device_id) VALUES (%s, %s, %s)",
                (uuid.uuid4().hex, USERNAME, DEVICE),
            )
            conn.commit()
        result = devices.revoke_grant(DEVICE, USERNAME)
        self.assertEqual(result["sessions_revoked"], 1)
        self.assertFalse(devices.trust_valid(DEVICE, USERNAME))
        # The browser itself stays approved, but this admin is deny-listed.
        self.assertTrue(devices.device_authorized(DEVICE))
        self.assertEqual(devices.grant_row(DEVICE, USERNAME)["state"], "REVOKED")
        # An explicit re-approval of that admin clears the deny-list.
        devices.ensure_grant(DEVICE, USERNAME, SECRET_HASH, "unit-test")
        self.assertEqual(devices.grant_row(DEVICE, USERNAME)["state"], "APPROVED")

    def test_purge_stale_pending(self):
        # A pending browser (registered by a first verified login) is dropped
        # once it is older than the retention window; nothing was approved.
        devices.register_device(DEVICE, "web", "purge test", SECRET_HASH, "127.0.0.1")
        devices.record_login(DEVICE, USERNAME, None)
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "UPDATE device SET first_seen = now() - interval '10 days' "
                "WHERE device_id = %s",
                (DEVICE,),
            )
            conn.commit()
        removed = devices.purge_stale_pending(3)
        self.assertGreaterEqual(removed, 1)
        self.assertIsNone(devices.device_row(DEVICE))

    def test_set_device_state_on_missing_device_is_404(self):
        with self.assertRaises(ApiError) as ctx:
            devices.set_device_state("33333333-3333-4333-8333-333333333333", "APPROVED", "u")
        self.assertEqual(ctx.exception.status_code, 404)


if __name__ == "__main__":
    unittest.main(verbosity=2)
