#!/usr/bin/env python3
"""Password-scheme self-test — runs inside the api container.

    docker compose --env-file env.dev -f docker-compose-dev.yml \
        exec -T api python tests/test_passwords.py

Covers app/passwords.py: the Argon2id writer (current PASSWORD_SCHEME), the
scheme-dispatching verifier, fail-closed behaviour, and the 2027-02-01
weak-scheme removal deadline. Cross-engine vectors prove interoperability:
one Argon2id hash produced by PHP's password_hash() and one md5crypt hash
produced by Dovecot's doveadm pw — the api must verify both, because those
are the exact formats the webmail driver and the legacy catalogue rows use.
"""

import datetime as dt
import sys
import unittest
from unittest import mock

from app import passwords, settings

PASSWORD = "secret123"

# Produced by PHP password_hash(PASSWORD_ARGON2ID, m=65536,t=4,p=1) — the webmail
# change-password driver's exact output format (without the {ARGON2ID} prefix).
PHP_ARGON2ID = (
    "$argon2id$v=19$m=65536,t=4,p=1$b0ZudHlPaFZXUERrNWtMaA$"
    "f0e3Kg5+GnG1BTnOmKB6FkgXQ0KdgRZ9CRWwyclOSNQ"
)

# Produced by `doveadm pw -s MD5-CRYPT` — the legacy catalogue rows' format.
DOVECOT_MD5CRYPT = "$1$d0iuJ5F1$NqwjYVMSjhaSN16PekWvB1"


class Argon2idWriterTests(unittest.TestCase):
    def test_hash_format_and_verification(self):
        hashed = passwords.hash_password(PASSWORD)
        self.assertTrue(hashed.startswith("{ARGON2ID}$argon2id$v=19$m=65536,t=4,p=1$"), hashed)
        self.assertTrue(passwords.verify_password(PASSWORD, hashed))
        self.assertFalse(passwords.verify_password(PASSWORD + "x", hashed))

    def test_hashes_differ_across_calls(self):
        """Fresh random salt on every call (a repeated hash would mean a reused salt)."""
        self.assertNotEqual(passwords.hash_password(PASSWORD), passwords.hash_password(PASSWORD))


class DispatchVerifierTests(unittest.TestCase):
    def test_verifies_php_produced_hash(self):
        self.assertTrue(passwords.verify_password(PASSWORD, "{ARGON2ID}" + PHP_ARGON2ID))
        self.assertFalse(passwords.verify_password(PASSWORD + "x", "{ARGON2ID}" + PHP_ARGON2ID))

    def test_verifies_dovecot_produced_legacy_hash(self):
        self.assertTrue(passwords.verify_password(PASSWORD, DOVECOT_MD5CRYPT))
        self.assertFalse(passwords.verify_password(PASSWORD + "x", DOVECOT_MD5CRYPT))

    def test_fails_closed_on_unknown_formats(self):
        # wrong {SCHEME} prefixes: never verified, never a plaintext fallback
        self.assertFalse(passwords.verify_password(PASSWORD, "{BLF-CRYPT}$2y$10$whatever"))
        self.assertFalse(passwords.verify_password(PASSWORD, "{ARGON2I}$argon2i$..."))
        self.assertFalse(passwords.verify_password(PASSWORD, "{PLAIN}secret123"))
        # unprefixed non-legacy garbage
        self.assertFalse(passwords.verify_password(PASSWORD, "$2y$10$notamd5hash"))
        # empty/None
        self.assertFalse(passwords.verify_password(PASSWORD, None))
        self.assertFalse(passwords.verify_password(PASSWORD, ""))


class DeadlineTests(unittest.TestCase):
    """The 2027-02-01 weak-scheme removal, with the date pinned by monkeypatch."""

    def setUp(self):
        self._original_scheme = settings.PASSWORD_SCHEME
        self.addCleanup(setattr, settings, "PASSWORD_SCHEME", self._original_scheme)

    def test_legacy_verification_stops_at_deadline(self):
        with mock.patch.object(passwords, "MD5CRYPT_SUPPORT_ENDS", dt.date(2020, 1, 1)), \
             mock.patch.object(passwords, "_today", lambda: dt.date(2026, 10, 18)):
            self.assertFalse(passwords.verify_password(PASSWORD, DOVECOT_MD5CRYPT))

    def test_md5crypt_writer_refuses_after_deadline(self):
        with mock.patch.object(passwords, "MD5CRYPT_SUPPORT_ENDS", dt.date(2020, 1, 1)), \
             mock.patch.object(passwords, "_today", lambda: dt.date(2026, 10, 18)), \
             mock.patch.object(settings, "PASSWORD_SCHEME", "md5crypt"):
            with self.assertRaises(RuntimeError):
                passwords.hash_password(PASSWORD)

    def test_argon2id_still_works_after_deadline(self):
        with mock.patch.object(passwords, "MD5CRYPT_SUPPORT_ENDS", dt.date(2020, 1, 1)), \
             mock.patch.object(passwords, "_today", lambda: dt.date(2026, 10, 18)):
            hashed = passwords.hash_password(PASSWORD)
            self.assertTrue(passwords.verify_password(PASSWORD, hashed))


class SchemeValidationTests(unittest.TestCase):
    def test_unknown_scheme_is_refused_at_import(self):
        # _validate_scheme() runs at import: an unknown value must never boot.
        with mock.patch.object(settings, "PASSWORD_SCHEME", "blf-crypt"), \
             mock.patch.object(passwords, "_today", lambda: dt.date(2026, 10, 18)):
            with self.assertRaises(RuntimeError):
                passwords._validate_scheme()


if __name__ == "__main__":
    unittest.main(verbosity=2)