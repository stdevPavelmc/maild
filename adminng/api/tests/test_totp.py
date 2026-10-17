#!/usr/bin/env python3
"""TOTP unit tests — the RFC 6238 SHA-1 vectors plus replay protection."""

import base64
import time
import unittest

from app import settings, totp

SECRET_B32 = base64.b32encode(b"12345678901234567890").decode().rstrip("=")


class RfcVectors(unittest.TestCase):
    def setUp(self):
        self._digits = settings.ADMINNG_TOTP_DIGITS
        settings.ADMINNG_TOTP_DIGITS = 8

    def tearDown(self):
        settings.ADMINNG_TOTP_DIGITS = self._digits

    def test_rfc6238_sha1_vectors(self):
        vectors = [
            (59, "94287082"),
            (1111111109, "07081804"),
            (1111111111, "14050471"),
            (1234567890, "89005924"),
            (2000000000, "69279037"),
            (20000000000, "65353130"),
        ]
        for timestamp, expected in vectors:
            self.assertEqual(totp.code_at(SECRET_B32, timestamp), expected, timestamp)


class Verification(unittest.TestCase):
    def test_accepts_current_and_rejects_replay(self):
        code = totp.code_at(SECRET_B32)
        ok, step = totp.verify(SECRET_B32, code)
        self.assertTrue(ok)
        self.assertGreater(step, 0)
        replay_ok, _ = totp.verify(SECRET_B32, code, last_step=step)
        self.assertFalse(replay_ok, "a used step must not be accepted again")

    def test_rejects_wrong_and_malformed(self):
        code = totp.code_at(SECRET_B32)
        wrong = "000000" if code != "000000" else "111111"
        self.assertFalse(totp.verify(SECRET_B32, wrong)[0])
        self.assertFalse(totp.verify(SECRET_B32, "abc")[0])
        self.assertFalse(totp.verify(SECRET_B32, "")[0])

    def test_secret_length_and_provisioning_uri(self):
        secret = totp.generate_secret()
        self.assertGreaterEqual(len(secret), 32)
        uri = totp.provisioning_uri(secret, "admin@example.net", "MailD AdminNG")
        self.assertTrue(uri.startswith("otpauth://totp/"))
        self.assertIn(f"secret={secret}", uri)
        self.assertIn("issuer=MailD%20AdminNG", uri)


if __name__ == "__main__":
    unittest.main(verbosity=2)
