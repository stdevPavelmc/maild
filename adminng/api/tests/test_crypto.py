#!/usr/bin/env python3
"""Secret-at-rest tests (TOTP seeds are encrypted with ADMINNG_SECRET_KEY)."""

import unittest

from app import crypto, settings
from app.errors import ApiError


class CryptoTests(unittest.TestCase):
    def test_roundtrip(self):
        secret = "JBSWY3DPEHPK3PXP"
        stored = crypto.encrypt(secret)
        self.assertNotIn(secret, stored)
        self.assertEqual(crypto.decrypt(stored), secret)

    def test_tampered_ciphertext_is_rejected(self):
        stored = crypto.encrypt("JBSWY3DPEHPK3PXP")
        with self.assertRaises(ApiError) as ctx:
            crypto.decrypt(stored[:-4] + "AAAA")
        self.assertEqual(ctx.exception.code, "SECRET_UNREADABLE")

    def test_missing_key_is_a_clear_error(self):
        original = settings.ADMINNG_SECRET_KEY
        settings.ADMINNG_SECRET_KEY = ""
        try:
            with self.assertRaises(ApiError) as ctx:
                crypto.encrypt("x")
            self.assertEqual(ctx.exception.code, "MISCONFIGURED")
        finally:
            settings.ADMINNG_SECRET_KEY = original


if __name__ == "__main__":
    unittest.main(verbosity=2)
