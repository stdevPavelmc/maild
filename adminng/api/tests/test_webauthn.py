#!/usr/bin/env python3
"""WebAuthn origin policy tests."""

import unittest
from unittest.mock import patch

from app import settings, webauthn
from app.errors import ApiError


class OriginPolicy(unittest.TestCase):
    def test_accepts_only_configured_rp_origin(self):
        with (
            patch.object(settings, "ADMINNG_WEBAUTHN_RP_ID", "example.com"),
            patch.object(
                settings,
                "ADMINNG_WEBAUTHN_ORIGINS",
                ("https://adminng.example.com",),
            ),
        ):
            self.assertEqual(
                webauthn.origin_config("https://adminng.example.com"),
                ("https://adminng.example.com", "example.com"),
            )

    def test_rejects_unlisted_and_non_secure_origins(self):
        with (
            patch.object(settings, "ADMINNG_WEBAUTHN_RP_ID", "example.com"),
            patch.object(
                settings,
                "ADMINNG_WEBAUTHN_ORIGINS",
                ("https://adminng.example.com", "http://adminng.example.com"),
            ),
        ):
            for origin in (
                "https://adminng.example.com.attacker.test",
                "http://adminng.example.com",
            ):
                with self.subTest(origin=origin), self.assertRaises(ApiError):
                    webauthn.origin_config(origin)

    def test_allows_configured_http_localhost_for_development(self):
        with (
            patch.object(settings, "ADMINNG_WEBAUTHN_RP_ID", "localhost"),
            patch.object(
                settings,
                "ADMINNG_WEBAUTHN_ORIGINS",
                ("http://localhost:8083",),
            ),
        ):
            self.assertEqual(
                webauthn.origin_config("http://localhost:8083"),
                ("http://localhost:8083", "localhost"),
            )

    def test_requires_explicit_configuration(self):
        with (
            patch.object(settings, "ADMINNG_WEBAUTHN_RP_ID", ""),
            patch.object(settings, "ADMINNG_WEBAUTHN_ORIGINS", ()),
            self.assertRaises(ApiError) as ctx,
        ):
            webauthn.origin_config("https://adminng.example.com")
        self.assertEqual(ctx.exception.code, "WEBAUTHN_NOT_CONFIGURED")

    def test_rejects_ip_address_as_rp_id(self):
        with (
            patch.object(settings, "ADMINNG_WEBAUTHN_RP_ID", "192.0.2.10"),
            patch.object(
                settings,
                "ADMINNG_WEBAUTHN_ORIGINS",
                ("https://192.0.2.10",),
            ),
            self.assertRaises(ApiError) as ctx,
        ):
            webauthn.origin_config("https://192.0.2.10")
        self.assertEqual(ctx.exception.code, "WEBAUTHN_NOT_CONFIGURED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
