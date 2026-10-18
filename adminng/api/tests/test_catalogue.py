#!/usr/bin/env python3
"""Phase-1 catalogue self-test — runs inside the api container.

    docker compose --env-file env.dev -f docker-compose-dev.yml \
        exec -T api python tests/test_catalogue.py

It exercises the catalogue layer directly (no HTTP) against the dev fixtures'
database, using a throwaway domain, and asserts the PostfixAdmin write
compatibility rules from technical-draft §3.1:

  * md5crypt hashes in mailbox/admin.password;
  * maildir = '<domain>/<local_part>/' (trailing slash);
  * quota in bytes (0 = unlimited);
  * domain counters (mailboxes/aliases) keep step;
  * admin.password mirrors the mailbox password (MailD convention);
  * tenant scoping rejects foreign domains;
  * deleting a domain cascades its mailboxes, aliases and admin scopes.

The HTTP + IMAP black-box checks live in test.sh (they need the fixtures'
plaintext passwords, which never enter this container).
"""

import sys
import unittest

from app import catalogue
from app.auth import Principal
from app.db import connect
from app.errors import ApiError
from app.md5crypt import hash_password, is_md5crypt, verify_password

DOMAIN = "adminng-selftest.test"
MAILBOX = f"e2e@{DOMAIN}"
PASSWORD = "self-test-secret"
DEVICE = "00000000-0000-4000-8000-000000000001"
SUPER = Principal("selftest", True, [], DEVICE)


def _wipe() -> None:
    """Remove every trace of the self-test domain (idempotent)."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT username FROM mailbox WHERE domain = %s", (DOMAIN,))
        usernames = [row["username"] for row in cur.fetchall()]
        if usernames:
            cur.execute("DELETE FROM quota  WHERE username = ANY(%s)", (usernames,))
            cur.execute("DELETE FROM quota2 WHERE username = ANY(%s)", (usernames,))
        cur.execute("DELETE FROM vacation      WHERE domain = %s", (DOMAIN,))
        cur.execute("DELETE FROM alias         WHERE domain = %s", (DOMAIN,))
        cur.execute("DELETE FROM domain_admins WHERE domain = %s", (DOMAIN,))
        cur.execute("DELETE FROM mailbox       WHERE domain = %s", (DOMAIN,))
        cur.execute("DELETE FROM domain        WHERE domain = %s", (DOMAIN,))
        cur.execute(
            "DELETE FROM admin WHERE username LIKE %s", (f"%@{DOMAIN}",)
        )
        conn.commit()


class Md5cryptTests(unittest.TestCase):
    def test_hash_shape_and_verification(self):
        hashed = hash_password(PASSWORD)
        self.assertTrue(is_md5crypt(hashed), hashed)
        self.assertEqual(len(hashed.split("$")[2]), 8)
        self.assertTrue(verify_password(PASSWORD, hashed))
        self.assertFalse(verify_password(PASSWORD + "x", hashed))

    def test_salt_is_preserved(self):
        hashed = hash_password(PASSWORD)
        salt = hashed.split("$")[2]
        self.assertEqual(hash_password(PASSWORD, salt), hashed)

    def test_rejects_non_md5crypt(self):
        self.assertFalse(verify_password(PASSWORD, "$2y$10$notamd5hash"))
        self.assertFalse(verify_password(PASSWORD, None))


class CatalogueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _wipe()
        catalogue.create_domain(
            SUPER,
            {
                "domain": DOMAIN,
                "description": "AdminNG self-test",
                "maxquota": 0,
                "quota": 0,
                "transport": "virtual",
                "backupmx": False,
                "active": True,
            },
        )

    @classmethod
    def tearDownClass(cls):
        _wipe()

    def test_01_mailbox_write_compat(self):
        created = catalogue.create_mailbox(
            SUPER,
            {
                "username": MAILBOX,
                "password": PASSWORD,
                "name": "E2E Probe",
                "quota_bytes": 50 * 1024 * 1024,
                "active": True,
            },
        )
        self.assertEqual(created["maildir"], f"{DOMAIN}/e2e/")
        self.assertEqual(created["local_part"], "e2e")
        self.assertEqual(created["domain"], DOMAIN)
        self.assertEqual(created["quota_bytes"], 50 * 1024 * 1024)

        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM mailbox WHERE username = %s", (MAILBOX,))
            stored = cur.fetchone()["password"]
        self.assertTrue(is_md5crypt(stored), stored)
        self.assertTrue(verify_password(PASSWORD, stored))

        self.assertEqual(catalogue.get_domain(SUPER, DOMAIN)["mailboxes"], 1)

    def test_02_admin_password_mirrors_mailbox(self):
        catalogue.create_admin(
            SUPER,
            {
                "username": MAILBOX,
                "password": "first",
                "superadmin": False,
                "active": True,
                "domains": [DOMAIN],
            },
        )
        catalogue.update_mailbox(SUPER, MAILBOX, {"password": "rotated"})
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM admin WHERE username = %s", (MAILBOX,))
            stored = cur.fetchone()["password"]
        self.assertTrue(verify_password("rotated", stored))
        self.assertEqual(catalogue.get_admin(MAILBOX)["domains"], [DOMAIN])

    def test_03_aliases_and_counters(self):
        alias = catalogue.create_alias(
            SUPER,
            {
                "address": f"sales@{DOMAIN}",
                "goto": f"{MAILBOX},other@{DOMAIN}",
                "active": True,
            },
        )
        self.assertEqual(alias["domain"], DOMAIN)

        tagged = catalogue.list_aliases(SUPER, None, MAILBOX, None, 50, None)
        self.assertEqual([row["address"] for row in tagged["items"]], [f"sales@{DOMAIN}"])

        catalogue.update_alias(SUPER, f"sales@{DOMAIN}", {"goto": MAILBOX})
        self.assertEqual(catalogue.get_alias(SUPER, f"sales@{DOMAIN}")["goto"], MAILBOX)
        self.assertEqual(catalogue.get_domain(SUPER, DOMAIN)["aliases"], 1)

    def test_04_tenant_scope_is_enforced(self):
        outsider = Principal("outsider", False, ["other.test"], DEVICE)
        with self.assertRaises(ApiError) as ctx:
            catalogue.get_mailbox(outsider, MAILBOX)
        self.assertEqual(ctx.exception.status_code, 403)
        self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")

        with self.assertRaises(ApiError):
            catalogue.list_mailboxes(outsider, DOMAIN, None, None, 50, None)

        scoped = Principal("scoped", False, [DOMAIN], DEVICE)
        self.assertEqual(catalogue.get_mailbox(scoped, MAILBOX)["username"], MAILBOX)

    def test_05_duplicates_conflict(self):
        with self.assertRaises(ApiError) as ctx:
            catalogue.create_mailbox(
                SUPER,
                {
                    "username": MAILBOX,
                    "password": "x",
                    "name": "",
                    "quota_bytes": 0,
                    "active": True,
                },
            )
        self.assertEqual(ctx.exception.status_code, 409)

    def test_06_search_is_tenant_scoped(self):
        hits = catalogue.search(SUPER, "e2e", 20)
        self.assertTrue(any(hit["id"] == MAILBOX for hit in hits["results"]))
        outsider = Principal("outsider", False, ["other.test"], DEVICE)
        self.assertEqual(catalogue.search(outsider, "e2e", 20)["results"], [])

    def test_07_mailbox_delete_revokes_and_recounts(self):
        catalogue.delete_mailbox(SUPER, MAILBOX)
        with self.assertRaises(ApiError) as ctx:
            catalogue.get_mailbox(SUPER, MAILBOX)
        self.assertEqual(ctx.exception.status_code, 404)
        self.assertEqual(catalogue.get_domain(SUPER, DOMAIN)["mailboxes"], 0)

    def test_08_domain_alias_scope_and_counts(self):
        source = "alias.adminng-selftest.test"
        secondary = "alt.adminng-selftest.test"
        for alias_domain in (source, secondary):
            catalogue.create_domain(
                SUPER,
                {
                    "domain": alias_domain,
                    "description": "Alias domain test",
                    "maxquota": 0,
                    "quota": 0,
                    "transport": "virtual",
                    "backupmx": False,
                    "active": True,
                },
            )
        try:
            alias = catalogue.create_domain_alias(
                SUPER,
                {
                    "alias_domain": source,
                    "target_domain": DOMAIN,
                    "active": True,
                },
            )
            self.assertEqual(alias["alias_domain"], source)
            self.assertEqual(catalogue.get_domain(SUPER, DOMAIN)["alias_domains"], 1)
            self.assertEqual(catalogue.get_domain(SUPER, source)["aliasing_to"], DOMAIN)
            self.assertEqual(
                [row["alias_domain"] for row in catalogue.list_domain_aliases(
                    SUPER, DOMAIN, 50, None
                )["items"]],
                [source],
            )

            target_only = Principal("target-only", False, [DOMAIN], DEVICE)
            with self.assertRaises(ApiError) as ctx:
                catalogue.get_domain_alias(target_only, source)
            self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")
            self.assertEqual(
                catalogue.list_domain_aliases(target_only, DOMAIN, 50, None)["items"],
                [],
            )
            retargeted = catalogue.update_domain_alias(
                SUPER, source, {"target_domain": secondary}
            )
            self.assertEqual(retargeted["target_domain"], secondary)
            self.assertEqual(catalogue.get_domain(SUPER, DOMAIN)["alias_domains"], 0)
            self.assertEqual(catalogue.get_domain(SUPER, secondary)["alias_domains"], 1)
            with self.assertRaises(ApiError) as ctx:
                catalogue.create_domain_alias(
                    SUPER,
                    {
                        "alias_domain": DOMAIN,
                        "target_domain": DOMAIN,
                        "active": True,
                    },
                )
            self.assertEqual(ctx.exception.code, "CONFLICT")

            inactive = catalogue.update_domain_alias(SUPER, source, {"active": False})
            self.assertFalse(inactive["active"])
            catalogue.delete_domain_alias(SUPER, source)
            self.assertEqual(catalogue.get_domain(SUPER, secondary)["alias_domains"], 0)
        finally:
            with connect() as conn, conn.cursor() as cur:
                cur.execute(
                    "DELETE FROM alias_domain WHERE alias_domain = %s OR target_domain = %s",
                    (source, secondary),
                )
                conn.commit()
            for alias_domain in (source, secondary):
                catalogue.delete_domain(SUPER, alias_domain)

    def test_09_domain_delete_cascades(self):
        catalogue.create_mailbox(
            SUPER,
            {
                "username": MAILBOX,
                "password": "x",
                "name": "",
                "quota_bytes": 0,
                "active": True,
            },
        )
        catalogue.create_alias(
            SUPER, {"address": f"info@{DOMAIN}", "goto": MAILBOX, "active": True}
        )
        catalogue.delete_domain(SUPER, DOMAIN)

        with connect() as conn, conn.cursor() as cur:
            for table in ("mailbox", "alias", "domain_admins", "domain"):
                cur.execute(f"SELECT count(*) AS n FROM {table} WHERE domain = %s", (DOMAIN,))
                self.assertEqual(cur.fetchone()["n"], 0, table)


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        try:
            _wipe()
        except Exception as exc:  # pragma: no cover - best-effort cleanup
            print(f"cleanup warning: {exc}", file=sys.stderr)
