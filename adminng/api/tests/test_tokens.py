#!/usr/bin/env python3
"""JWT helper tests: purpose binding, device binding, expiry."""

import unittest

from app import tokens
from app.errors import ApiError

DEVICE = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"


class TokenTests(unittest.TestCase):
    def test_access_token_roundtrip(self):
        token = tokens.access_token("admin@example.net", DEVICE, True, [])
        claims = tokens.decode(token, "access")
        self.assertEqual(claims["sub"], "admin@example.net")
        self.assertEqual(claims["did"], DEVICE)
        self.assertEqual(claims["purpose"], "access")
        self.assertEqual(claims["role"], "superadmin")

    def test_purpose_is_enforced(self):
        access = tokens.access_token("admin@example.net", DEVICE, False, ["example.net"])
        with self.assertRaises(ApiError) as ctx:
            tokens.decode(access, "reauth")
        self.assertEqual(ctx.exception.status_code, 401)
        self.assertEqual(ctx.exception.code, "TOKEN_INVALID")

    def test_expired_token(self):
        expired = tokens.encode("access", "a@b.co", DEVICE, ttl=-5)
        with self.assertRaises(ApiError) as ctx:
            tokens.decode(expired, "access")
        self.assertEqual(ctx.exception.code, "TOKEN_EXPIRED")

    def test_flow_and_reauth_ttls(self):
        flow = tokens.flow_token("a@b.co", DEVICE)
        self.assertEqual(tokens.decode(flow, "2fa")["did"], DEVICE)
        remembered_flow = tokens.flow_token("a@b.co", DEVICE, remember=True)
        self.assertTrue(tokens.decode(remembered_flow, "2fa")["remember"])
        reauth = tokens.reauth_token("a@b.co", DEVICE)
        claims = tokens.decode(reauth, "reauth")
        self.assertEqual(claims["scope"], "destructive")

    def test_access_token_custom_ttl(self):
        token = tokens.access_token("a@b.co", DEVICE, False, [], ttl=86400)
        claims = tokens.decode(token, "access")
        self.assertEqual(claims["exp"] - claims["iat"], 86400)


if __name__ == "__main__":
    unittest.main(verbosity=2)
