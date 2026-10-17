#!/usr/bin/env python3
"""Regression: the code used to enroll must work once for the login that follows.

`totp-confirm` used to store the enrollment time-step as `last_used_step`, so a
login within the same 30-second window submitted the same step and was rejected
as a replay ("invalid or already used code"). Enrollment now leaves the step
usable exactly once; the successful login consumes it.
"""

import unittest

from app import auth, crypto, settings, tokens, totp
from app.db import connect

USER = "enroll-test@example.net"
DEVICE = "99999999-9999-4999-8999-999999999999"


def _cleanup() -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM totp_credential WHERE username = %s", (USER,))
        conn.commit()


class EnrollmentFlow(unittest.TestCase):
    def setUp(self):
        _cleanup()
        self.secret = totp.generate_secret()
        with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO totp_credential (username, secret) VALUES (%s, %s)",
                (USER, crypto.encrypt(self.secret)),
            )
            conn.commit()

    def tearDown(self):
        _cleanup()

    def test_enrollment_code_is_usable_once_for_the_immediate_login(self):
        code = totp.code_at(self.secret)
        auth.enroll_confirm(tokens.enroll_token(USER, DEVICE), code, "127.0.0.1")

        credential = auth._credential(USER)
        self.assertTrue(credential["confirmed"])
        ok, step = totp.verify(self.secret, code, credential["last_used_step"])
        self.assertTrue(ok, "the enrollment step must be accepted by the next login")

        # Once that login stores the step, the same code is a replay.
        replay_ok, _ = totp.verify(self.secret, code, step)
        self.assertFalse(replay_ok)


if __name__ == "__main__":
    unittest.main(verbosity=2)
