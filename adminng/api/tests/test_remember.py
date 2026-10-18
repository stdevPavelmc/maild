#!/usr/bin/env python3
"""Remembered-session token policy tests."""

import unittest
from unittest.mock import patch

from app import auth, settings


class RememberedSessionPolicy(unittest.TestCase):
    @patch("app.auth._domains_of", return_value=[])
    @patch("app.auth._create_session", return_value="refresh-token")
    @patch("app.auth.tokens.access_token", return_value="access-token")
    def test_remembered_login_uses_configured_access_and_idle_ttl(
        self, access_token, create_session, _domains
    ):
        with patch.object(settings, "ADMINNG_ACCESS_TTL", 600), patch.object(
            settings, "ADMINNG_REFRESH_IDLE_TTL", 900
        ), patch.object(settings, "ADMINNG_REMEMBER_TTL", 86400):
            result = auth._issue(
                "admin@example.net",
                "device-id",
                {"superadmin": True},
                remember=True,
            )

        access_token.assert_called_once_with(
            "admin@example.net", "device-id", True, [], ttl=86400
        )
        create_session.assert_called_once_with("admin@example.net", "device-id", True)
        self.assertEqual(result["expires_in"], 86400)
        self.assertEqual(result["idle_timeout"], 86400)
        self.assertTrue(result["remember"])

    @patch("app.auth._domains_of", return_value=[])
    @patch("app.auth._create_session", return_value="refresh-token")
    @patch("app.auth.tokens.access_token", return_value="access-token")
    def test_regular_login_keeps_short_ttls(self, access_token, create_session, _domains):
        with patch.object(settings, "ADMINNG_ACCESS_TTL", 600), patch.object(
            settings, "ADMINNG_REFRESH_IDLE_TTL", 900
        ), patch.object(settings, "ADMINNG_REMEMBER_TTL", 86400):
            result = auth._issue(
                "admin@example.net",
                "device-id",
                {"superadmin": True},
            )

        access_token.assert_called_once_with(
            "admin@example.net", "device-id", True, [], ttl=600
        )
        create_session.assert_called_once_with("admin@example.net", "device-id", False)
        self.assertEqual(result["expires_in"], 600)
        self.assertEqual(result["idle_timeout"], 900)
        self.assertFalse(result["remember"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
