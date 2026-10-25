#!/usr/bin/env python3
"""First-boot provisioning self-test — runs inside the api container.

    docker compose --env-file env.dev -f docker-compose-dev.yml \\
        exec -T api python tests/test_provision.py

It exercises `app.provision` directly (no HTTP) against the dev catalogue, using a
throwaway domain, and asserts the contract `admin/seed.sh` used to provide:

  * the domain row, the superadmin (admin row + mailbox with the same password),
    the four default aliases and the maild_provision sentinel are written;
  * the password is hashed with PASSWORD_SCHEME (Argon2id by default) and verifies;
  * a second run is a no-op (fast path), PROVISION_FORCE re-asserts the password;
  * a missing schema raises ProvisionError instead of hanging or half-seeding.

The sentinel is a SINGLE global row (id=1) shared with the running stack, so the
test snapshots it first and restores it at the end — the boot gates keep seeing the
version the deployment was provisioned with.
"""

import sys
import unittest
from unittest import mock

import psycopg

from app import passwords, provision, settings
from app.db import connect

DOMAIN = "provision-selftest.test"
ADMIN = "provisioner"
ADMIN_ADDR = f"{ADMIN}@{DOMAIN}"
PASSWORD = "provision-self-test-secret"
ALIASES = ("postmaster", "abuse", "hostmaster", "webmaster")


def _wipe() -> None:
    """Remove every trace of the self-test domain (idempotent)."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM alias WHERE domain = %s", (DOMAIN,))
        cur.execute("DELETE FROM mailbox WHERE domain = %s", (DOMAIN,))
        cur.execute("DELETE FROM admin WHERE username = %s", (ADMIN_ADDR,))
        cur.execute("DELETE FROM domain WHERE domain = %s", (DOMAIN,))
        conn.commit()


def _sentinel_snapshot() -> dict | None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM maild_provision WHERE id = 1")
        return cur.fetchone()


def _sentinel_restore(snapshot: dict | None) -> None:
    with connect() as conn, conn.cursor() as cur:
        if snapshot is None:
            cur.execute("DELETE FROM maild_provision WHERE id = 1")
        else:
            cur.execute(
                """
                UPDATE maild_provision
                   SET version = %s, default_domain = %s, admin_user = %s,
                       provisioned_at = %s, provisioned_by = %s
                 WHERE id = 1
                """,
                (
                    snapshot["version"],
                    snapshot["default_domain"],
                    snapshot["admin_user"],
                    snapshot["provisioned_at"],
                    snapshot["provisioned_by"],
                ),
            )
        conn.commit()


def _cfg(**overrides):
    base = dict(
        default_domain=DOMAIN,
        admin_user=ADMIN,
        admin_password=PASSWORD,
        version=999999,          # never collide with the deployment's version
        force=False,
        wait_timeout=5,
    )
    base.update(overrides)
    return provision.ProvisionConfig(**base)


class ProvisionSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._sentinel = _sentinel_snapshot()
        _wipe()

    @classmethod
    def tearDownClass(cls) -> None:
        _wipe()
        _sentinel_restore(cls._sentinel)

    def setUp(self) -> None:
        _wipe()
        # each test starts with no sentinel, so the fast path is predictable
        with connect() as conn, conn.cursor() as cur:
            cur.execute("DELETE FROM maild_provision WHERE id = 1")
            conn.commit()

    # ------------------------------------------------------------- the happy path
    def test_seeds_the_catalogue(self) -> None:
        report = provision.provision(_cfg())
        self.assertEqual(report["status"], "provisioned")
        self.assertEqual(report["admin"], ADMIN_ADDR)
        self.assertFalse(report["password_generated"])

        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT * FROM domain WHERE domain = %s", (DOMAIN,))
            domain = cur.fetchone()
            self.assertIsNotNone(domain)
            self.assertEqual(domain["transport"], "virtual")
            self.assertTrue(domain["active"])
            self.assertEqual(domain["mailboxes"], 1)
            self.assertEqual(domain["aliases"], len(ALIASES))

            cur.execute("SELECT * FROM mailbox WHERE username = %s", (ADMIN_ADDR,))
            mailbox = cur.fetchone()
            self.assertIsNotNone(mailbox)
            self.assertEqual(mailbox["maildir"], f"{DOMAIN}/{ADMIN}/")
            self.assertEqual(mailbox["local_part"], ADMIN)
            self.assertEqual(mailbox["domain"], DOMAIN)
            self.assertEqual(mailbox["quota"], 0)
            self.assertTrue(mailbox["active"])

            cur.execute(
                "SELECT password, superadmin FROM admin WHERE username = %s",
                (ADMIN_ADDR,),
            )
            admin = cur.fetchone()
            self.assertIsNotNone(admin)
            self.assertTrue(admin["superadmin"])
            # the MailD convention: admin.password == mailbox.password
            self.assertEqual(admin["password"], mailbox["password"])

            cur.execute(
                "SELECT address, goto FROM alias WHERE domain = %s ORDER BY address",
                (DOMAIN,),
            )
            aliases = cur.fetchall()
            self.assertEqual(
                [row["address"] for row in aliases],
                [f"{alias}@{DOMAIN}" for alias in sorted(ALIASES)],
            )
            self.assertTrue(all(row["goto"] == ADMIN_ADDR for row in aliases))

            cur.execute("SELECT * FROM maild_provision WHERE id = 1")
            sentinel = cur.fetchone()
            self.assertIsNotNone(sentinel)
            self.assertEqual(sentinel["version"], 999999)
            self.assertEqual(sentinel["default_domain"], DOMAIN)
            self.assertEqual(sentinel["admin_user"], ADMIN)

        # Argon2id by default (PASSWORD_SCHEME), and the plaintext must verify
        self.assertTrue(
            passwords.verify_password(PASSWORD, mailbox["password"]),
            "the seeded hash must verify with the plaintext password",
        )
        if settings.PASSWORD_SCHEME == "argon2id":
            self.assertTrue(mailbox["password"].startswith("{ARGON2ID}$argon2id$"))

    def test_second_run_is_a_noop(self) -> None:
        provision.provision(_cfg())
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM mailbox WHERE username = %s", (ADMIN_ADDR,))
            first = cur.fetchone()["password"]

        report = provision.provision(_cfg())
        self.assertEqual(report["status"], "already-provisioned")

        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM mailbox WHERE username = %s", (ADMIN_ADDR,))
            self.assertEqual(cur.fetchone()["password"], first, "password must not change")

    def test_force_reasserts_the_password(self) -> None:
        provision.provision(_cfg())
        report = provision.provision(_cfg(admin_password="rotated-secret", force=True))
        self.assertEqual(report["status"], "provisioned")
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM mailbox WHERE username = %s", (ADMIN_ADDR,))
            mailbox_pw = cur.fetchone()["password"]
            cur.execute("SELECT password FROM admin WHERE username = %s", (ADMIN_ADDR,))
            admin_pw = cur.fetchone()["password"]
        self.assertTrue(passwords.verify_password("rotated-secret", mailbox_pw))
        self.assertEqual(admin_pw, mailbox_pw)

    def test_generated_password_is_reported(self) -> None:
        report = provision.provision(_cfg(admin_password=None))
        self.assertTrue(report["password_generated"])
        self.assertTrue(report["password"])
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM mailbox WHERE username = %s", (ADMIN_ADDR,))
            stored = cur.fetchone()["password"]
        self.assertTrue(passwords.verify_password(report["password"], stored))

    # ------------------------------------------------------------ failure modes
    def test_disabled_config_is_a_noop(self) -> None:
        # AUTO_PROVISION=no is what makes provision() a no-op (cfg=None means
        # "read the environment", which is enabled by default).
        with mock.patch.object(settings, "AUTO_PROVISION", False):
            self.assertEqual(provision.provision(None)["status"], "disabled")

    def test_missing_schema_raises_instead_of_hanging(self) -> None:
        def boom(_dbname=None):
            raise psycopg.OperationalError("no schema for you")

        with mock.patch.object(provision, "connect", boom):
            with self.assertRaises(provision.ProvisionError):
                provision.provision(_cfg(wait_timeout=0))

    def test_config_from_env_respects_auto_provision(self) -> None:
        with mock.patch.object(settings, "AUTO_PROVISION", False):
            self.assertIsNone(provision.config_from_env())
            self.assertIsNotNone(provision.config_from_env(respect_auto_provision=False))
        with mock.patch.object(settings, "DEFAULT_DOMAIN", ""):
            with self.assertRaises(provision.ProvisionError):
                provision.config_from_env(respect_auto_provision=False)


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2))

