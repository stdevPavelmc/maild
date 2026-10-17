#!/usr/bin/env python3
"""Device lifecycle tests against the real adminng database (inside the api container)."""

import unittest
import uuid

from app import devices, settings
from app.db import connect
from app.errors import ApiError

DEVICE = "11111111-2222-4333-8444-555555555555"
USERNAME = "device-test@example.net"


def _cleanup() -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM session WHERE device_id = %s", (DEVICE,))
        cur.execute("DELETE FROM device WHERE device_id = %s", (DEVICE,))
        conn.commit()


class DeviceLifecycle(unittest.TestCase):
    def setUp(self):
        _cleanup()

    def tearDown(self):
        _cleanup()

    def test_register_is_pending_and_idempotent(self):
        first = devices.register(DEVICE, "web", "Unit test", "127.0.0.1")
        self.assertEqual(first["authorization_state"], "PENDING")
        again = devices.register(DEVICE, "web", "Unit test 2", "127.0.0.2")
        self.assertEqual(again["authorization_state"], "PENDING")
        self.assertEqual(again["device_name"], "Unit test 2")
        self.assertEqual(again["last_ip"], "127.0.0.2")

    def test_approve_then_revoke_kills_sessions(self):
        devices.register(DEVICE, "web", "Unit test", None)
        approved = devices.set_state(DEVICE, "APPROVED", "unit-test")
        self.assertEqual(approved["new_state"], "APPROVED")
        self.assertEqual(devices.get(DEVICE)["approved_by"], "unit-test")
        self.assertGreaterEqual(devices.count_approved(), 1)

        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO session (jti, username, device_id) VALUES (%s, %s, %s)",
                (uuid.uuid4().hex, USERNAME, DEVICE),
            )
            conn.commit()

        revoked = devices.set_state(DEVICE, "REVOKED", "unit-test")
        self.assertEqual(revoked["new_state"], "REVOKED")
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT revoked_at FROM session WHERE device_id = %s", (DEVICE,)
            )
            rows = cur.fetchall()
        self.assertEqual(len(rows), 1)
        self.assertIsNotNone(rows[0]["revoked_at"])

    def test_revoked_device_cannot_re_register(self):
        devices.register(DEVICE, "web", "Unit test", None)
        devices.set_state(DEVICE, "REVOKED", "unit-test")
        with self.assertRaises(ApiError) as ctx:
            devices.register(DEVICE, "web", "Unit test", None)
        self.assertEqual(ctx.exception.code, "DEVICE_REVOKED")

    def test_list_filters_by_state(self):
        devices.register(DEVICE, "android_pwa", "Pixel unit test", None)
        page = devices.list_devices("PENDING", 50, None)
        self.assertTrue(any(d["device_id"] == DEVICE for d in page["items"]))

    def test_approving_a_missing_device_is_404(self):
        with self.assertRaises(ApiError) as ctx:
            devices.set_state("99999999-9999-4999-8999-999999999999", "APPROVED", "unit-test")
        self.assertEqual(ctx.exception.status_code, 404)


if __name__ == "__main__":
    unittest.main(verbosity=2)
