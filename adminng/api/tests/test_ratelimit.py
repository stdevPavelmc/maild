#!/usr/bin/env python3
"""Login rate-limit / lockout unit tests (technical-draft §4.6)."""

import unittest

from app import ratelimit, settings
from app.errors import ApiError

USER = "ratelimit@example.net"
IP = "192.0.2.10"


class RateLimitTests(unittest.TestCase):
    def setUp(self):
        ratelimit.success(USER, IP)

    def tearDown(self):
        ratelimit.success(USER, IP)

    def test_lockout_after_max_failures(self):
        for attempt in range(settings.ADMINNG_LOGIN_MAX_FAILURES - 1):
            self.assertFalse(ratelimit.failure(USER, IP), attempt)
        self.assertTrue(ratelimit.failure(USER, IP), "the last allowed failure locks")
        with self.assertRaises(ApiError) as ctx:
            ratelimit.check(USER, IP)
        self.assertEqual(ctx.exception.status_code, 429)
        self.assertEqual(ctx.exception.code, "RATE_LIMITED")

    def test_success_clears_the_counter(self):
        for _ in range(settings.ADMINNG_LOGIN_MAX_FAILURES - 1):
            ratelimit.failure(USER, IP)
        ratelimit.success(USER, IP)
        ratelimit.check(USER, IP)  # must not raise

    def test_keyed_by_username_and_ip(self):
        for _ in range(settings.ADMINNG_LOGIN_MAX_FAILURES):
            ratelimit.failure(USER, IP)
        # Another username from the same IP is unaffected (no NAT-wide lockout)…
        ratelimit.check("other@example.net", IP)
        # …and the same username from another IP is unaffected too.
        ratelimit.check(USER, "192.0.2.99")
        with self.assertRaises(ApiError):
            ratelimit.check(USER, IP)


if __name__ == "__main__":
    unittest.main(verbosity=2)
