#!/usr/bin/env python3
"""Login rate-limit / lockout tests against the adminng database (migration 004)."""

import unittest
from unittest.mock import patch

from app import auth, ratelimit, settings
from app.auth import Principal
from app.errors import ApiError

USER = "ratelimit@example.net"
OTHER = "ratelimit-other@example.net"
IP = "192.0.2.10"
OTHER_IP = "192.0.2.99"


class RateLimitTests(unittest.TestCase):
    def setUp(self):
        ratelimit.reset(USER)
        ratelimit.reset(OTHER)

    def tearDown(self):
        ratelimit.reset(USER)
        ratelimit.reset(OTHER)

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
        ratelimit.check(OTHER, IP)
        # …and the same username from another IP is unaffected too.
        ratelimit.check(USER, OTHER_IP)
        with self.assertRaises(ApiError):
            ratelimit.check(USER, IP)

    def test_reset_clears_the_lockout(self):
        for _ in range(settings.ADMINNG_LOGIN_MAX_FAILURES):
            ratelimit.failure(USER, IP)
        with self.assertRaises(ApiError):
            ratelimit.check(USER, IP)
        removed = ratelimit.reset(USER)
        self.assertGreaterEqual(removed, 1)
        ratelimit.check(USER, IP)  # unlocked


class ReauthThrottleTests(unittest.TestCase):
    """2026-10 audit L-02: reauth-confirm shares the login lockout."""

    def setUp(self):
        ratelimit.reset(USER)
        self.principal = Principal(USER, False, [], "00000000-0000-4000-8000-0000000000aa")
        self.audit = patch.object(auth.audit, "record").start()
        self.addCleanup(patch.stopall)
        self.addCleanup(ratelimit.reset, USER)

    def _wrong(self):
        return patch.object(
            auth, "_verify_credentials",
            side_effect=ApiError(401, "INVALID_CREDENTIALS", "bad"),
        )

    def test_reauth_failures_arm_the_lockout(self):
        with self._wrong():
            for _ in range(settings.ADMINNG_LOGIN_MAX_FAILURES - 1):
                with self.assertRaises(ApiError) as ctx:
                    auth.reauth_confirm("guess", self.principal, IP)
                self.assertEqual(ctx.exception.status_code, 401)
            with self.assertRaises(ApiError) as ctx:
                auth.reauth_confirm("guess", self.principal, IP)
            self.assertEqual(ctx.exception.status_code, 429)
        # locked: even the right password is refused without being checked…
        with patch.object(auth, "_verify_credentials") as verify:
            with self.assertRaises(ApiError) as ctx:
                auth.reauth_confirm("right", self.principal, IP)
            self.assertEqual(ctx.exception.status_code, 429)
            verify.assert_not_called()
        # …and the shared key also locks the login form for that username+IP
        with self.assertRaises(ApiError):
            ratelimit.check(USER, IP)
        actions = [c.kwargs["action"] for c in self.audit.call_args_list]
        self.assertIn("REAUTH_LOCKOUT", actions)

    def test_reauth_success_clears_the_counter(self):
        with self._wrong():
            for _ in range(settings.ADMINNG_LOGIN_MAX_FAILURES - 1):
                with self.assertRaises(ApiError):
                    auth.reauth_confirm("guess", self.principal, IP)
        with patch.object(auth, "_verify_credentials"), patch.object(
            auth.tokens, "reauth_token", return_value="t"
        ):
            out = auth.reauth_confirm("right", self.principal, IP)
        self.assertEqual(out["security_validation_token"], "t")
        with self._wrong(), self.assertRaises(ApiError) as ctx:
            auth.reauth_confirm("guess", self.principal, IP)
        self.assertEqual(ctx.exception.status_code, 401, "the counter restarted")


if __name__ == "__main__":
    unittest.main(verbosity=2)
