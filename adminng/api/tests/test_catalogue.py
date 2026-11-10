#!/usr/bin/env python3
"""Phase-1 catalogue self-test — runs inside the api container.

    docker compose --env-file env.dev -f docker-compose-dev.yml \
        exec -T api python tests/test_catalogue.py

It exercises the catalogue layer directly (no HTTP) against the dev fixtures'
database, using a throwaway domain, and asserts the PostfixAdmin write
compatibility rules from technical-draft §3.1:

  * Argon2id hashes ({ARGON2ID}$argon2id$…, per PASSWORD_SCHEME) in
    mailbox/admin.password;
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
from unittest.mock import patch

from app import catalogue
from app.auth import Principal
from app.db import connect
from app.errors import ApiError
from app.passwords import hash_password, verify_password

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


class PasswordSchemeTests(unittest.TestCase):
    def test_hash_shape_and_verification(self):
        hashed = hash_password(PASSWORD)
        self.assertTrue(hashed.startswith("{ARGON2ID}$argon2id$"), hashed)
        self.assertTrue(verify_password(PASSWORD, hashed))
        self.assertFalse(verify_password(PASSWORD + "x", hashed))

    def test_rejects_unknown_formats(self):
        self.assertFalse(verify_password(PASSWORD, "$2y$10$notamd5hash"))
        self.assertFalse(verify_password(PASSWORD, "{BLF-CRYPT}$2y$10$whatever"))
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
                # the alias/counter assertions below count only what they create;
                # the default-alias behaviour has its own test (test_10)
                "default_aliases": False,
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
        self.assertTrue(stored.startswith("{ARGON2ID}$argon2id$"), stored)
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
        self.assertEqual(catalogue.get_admin(SUPER, MAILBOX)["domains"], [DOMAIN])

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

    def test_07b_domain_admin_cannot_set_reserved_domain_fields(self):
        """2026-10 audit L-01: transport/backupmx/maxquota/quota are superadmin-only."""
        tenant = Principal(f"tenant@{DOMAIN}", False, [DOMAIN], DEVICE)
        for field, value in (
            ("transport", "smtp:[attacker.example]:25"),
            ("backupmx", True),
            ("maxquota", 999999),
            ("quota", 999999),
        ):
            with self.subTest(field=field):
                with self.assertRaises(ApiError) as ctx:
                    catalogue.update_domain(tenant, DOMAIN, {field: value})
                self.assertEqual(ctx.exception.status_code, 403)
        current = catalogue.get_domain(SUPER, DOMAIN)
        self.assertEqual(current["transport"], "virtual")
        self.assertFalse(current["backupmx"])
        # the tenant fields stay editable, and an explicit None is "not sent"
        updated = catalogue.update_domain(
            tenant, DOMAIN, {"description": "tenant edit", "transport": None}
        )
        self.assertEqual(updated["description"], "tenant edit")
        # a superadmin still sets them
        self.assertEqual(
            catalogue.update_domain(SUPER, DOMAIN, {"maxquota": 0})["maxquota"], 0
        )

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


    def test_10_default_aliases_on_create(self):
        """A new domain gets PostfixAdmin's four default aliases; opt-out is honoured."""
        new_domain = "defaults.adminng-selftest.test"
        quiet_domain = "quiet.adminng-selftest.test"
        try:
            created = catalogue.create_domain(
                SUPER,
                {
                    "domain": new_domain,
                    "description": "Default aliases test",
                    "maxquota": 0,
                    "quota": 0,
                    "transport": "virtual",
                    "backupmx": False,
                    "active": True,
                },
            )
            self.assertEqual(created["aliases"], len(catalogue.DEFAULT_ALIASES))
            aliases = catalogue.list_aliases(SUPER, new_domain, None, None, 50, None)[
                "items"
            ]
            self.assertEqual(
                sorted(row["address"] for row in aliases),
                sorted(f"{part}@{new_domain}" for part in catalogue.DEFAULT_ALIASES),
            )
            self.assertTrue(all(row["goto"] == SUPER.username for row in aliases))

            quiet = catalogue.create_domain(
                SUPER,
                {
                    "domain": quiet_domain,
                    "description": "No default aliases",
                    "maxquota": 0,
                    "quota": 0,
                    "transport": "virtual",
                    "backupmx": False,
                    "active": True,
                    "default_aliases": False,
                },
            )
            self.assertEqual(quiet["aliases"], 0)
            self.assertEqual(
                catalogue.list_aliases(SUPER, quiet_domain, None, None, 50, None)["items"],
                [],
            )
        finally:
            for dom in (new_domain, quiet_domain):
                with connect() as conn, conn.cursor() as cur:
                    cur.execute("DELETE FROM alias WHERE domain = %s", (dom,))
                    conn.commit()
                try:
                    catalogue.delete_domain(SUPER, dom)
                except ApiError:
                    pass


ADM_DOMAIN = "admins.adminng-selftest.test"
OTHER_DOMAIN = "other.adminng-selftest.test"
TENANT = Principal(f"tenant@{ADM_DOMAIN}", False, [ADM_DOMAIN], DEVICE)
PEER = f"peer@{ADM_DOMAIN}"
BOSS = f"boss@{ADM_DOMAIN}"
FOREIGN = f"foreign@{OTHER_DOMAIN}"
VICTIM = f"victim@{OTHER_DOMAIN}"
OUTSIDER = f"outsider@{OTHER_DOMAIN}"


def _wipe_admins() -> None:
    """Remove every trace of the admin role self-test domains (idempotent)."""
    with connect() as conn, conn.cursor() as cur:
        for domain in (ADM_DOMAIN, OTHER_DOMAIN):
            cur.execute("DELETE FROM domain_admins WHERE domain = %s", (domain,))
            cur.execute(
                "DELETE FROM domain_admins WHERE username LIKE %s", (f"%@{domain}",)
            )
            cur.execute("DELETE FROM admin WHERE username LIKE %s", (f"%@{domain}",))
            cur.execute("DELETE FROM mailbox WHERE domain = %s", (domain,))
            cur.execute("DELETE FROM domain WHERE domain = %s", (domain,))
        conn.commit()


class AdminPermissionTests(unittest.TestCase):
    """H-01 + the admin role model: a domain admin fully manages the non-super
    administrators of its own domains only; nobody deletes themselves; at
    least one superadmin row always survives."""

    @classmethod
    def setUpClass(cls):
        _wipe_admins()
        for domain in (ADM_DOMAIN, OTHER_DOMAIN):
            catalogue.create_domain(
                SUPER,
                {
                    "domain": domain,
                    "description": "Admin role self-test",
                    "maxquota": 0,
                    "quota": 0,
                    "transport": "virtual",
                    "backupmx": False,
                    "active": True,
                    "default_aliases": False,
                },
            )
        catalogue.create_admin(
            SUPER,
            {
                "username": FOREIGN,
                "password": "foreign-secret",
                "superadmin": False,
                "active": True,
                "domains": [OTHER_DOMAIN],
            },
        )

    @classmethod
    def tearDownClass(cls):
        _wipe_admins()

    def test_01_tenant_creates_a_scoped_peer(self):
        peer = catalogue.create_admin(
            TENANT,
            {
                "username": PEER,
                "password": "peer-secret",
                "superadmin": False,
                "active": True,
                "domains": [ADM_DOMAIN],
            },
        )
        self.assertEqual(peer["domains"], [ADM_DOMAIN])
        self.assertFalse(peer["superadmin"])

    def test_02_tenant_cannot_create_superadmins_or_leave_its_scope(self):
        base = {"username": f"evil@{ADM_DOMAIN}", "password": "x", "active": True}
        with self.assertRaises(ApiError) as ctx:
            catalogue.create_admin(
                TENANT, {**base, "superadmin": True, "domains": [ADM_DOMAIN]}
            )
        self.assertEqual(ctx.exception.code, "FORBIDDEN")

        with self.assertRaises(ApiError) as ctx:
            catalogue.create_admin(
                TENANT, {**base, "superadmin": False, "domains": [OTHER_DOMAIN]}
            )
        self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")

        with self.assertRaises(ApiError) as ctx:
            catalogue.create_admin(TENANT, {**base, "superadmin": False, "domains": []})
        self.assertEqual(ctx.exception.status_code, 422)

    def test_03_superadmins_are_invisible_to_tenants(self):
        boss = catalogue.create_admin(
            SUPER,
            {
                "username": BOSS,
                "password": "boss-secret",
                "superadmin": True,
                "active": True,
                "domains": [],
            },
        )
        try:
            with self.assertRaises(ApiError) as ctx:
                catalogue.get_admin(TENANT, BOSS)
            self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")

            listed = catalogue.list_admins(TENANT, 50, None)["items"]
            names = [admin["username"] for admin in listed]
            self.assertIn(PEER, names)
            self.assertNotIn(BOSS, names)
            with connect() as conn, conn.cursor() as cur:
                cur.execute("SELECT username FROM admin WHERE superadmin")
                for row in cur.fetchall():
                    self.assertNotIn(row["username"], names)
        finally:
            catalogue.delete_admin(SUPER, BOSS)

    def test_04_tenant_updates_its_peers_but_cannot_escalate(self):
        updated = catalogue.update_admin(TENANT, PEER, {"active": False})
        self.assertFalse(updated["active"])
        updated = catalogue.update_admin(
            TENANT, PEER, {"password": "rotated", "domains": [ADM_DOMAIN]}
        )
        self.assertEqual(updated["domains"], [ADM_DOMAIN])

        with self.assertRaises(ApiError) as ctx:
            catalogue.update_admin(TENANT, PEER, {"superadmin": True})
        self.assertEqual(ctx.exception.code, "FORBIDDEN")

        with self.assertRaises(ApiError) as ctx:
            catalogue.update_admin(TENANT, PEER, {"domains": [OTHER_DOMAIN]})
        self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")

        # a foreign-tenant peer is neither visible nor manageable
        with self.assertRaises(ApiError) as ctx:
            catalogue.get_admin(TENANT, FOREIGN)
        self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")
        with self.assertRaises(ApiError) as ctx:
            catalogue.update_admin(TENANT, FOREIGN, {"active": False})
        self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")

    def test_05_nobody_deletes_themselves_or_escalates_by_delete(self):
        with self.assertRaises(ApiError) as ctx:
            catalogue.delete_admin(TENANT, TENANT.username)
        self.assertEqual(ctx.exception.status_code, 403)

        with self.assertRaises(ApiError) as ctx:
            catalogue.delete_admin(SUPER, SUPER.username)
        self.assertEqual(ctx.exception.status_code, 403)

        boss = catalogue.create_admin(
            SUPER,
            {
                "username": BOSS,
                "password": "boss-secret",
                "superadmin": True,
                "active": True,
                "domains": [],
            },
        )
        try:
            with self.assertRaises(ApiError) as ctx:
                catalogue.delete_admin(TENANT, BOSS)
            self.assertEqual(ctx.exception.code, "FORBIDDEN")

            with self.assertRaises(ApiError) as ctx:
                catalogue.delete_admin(TENANT, FOREIGN)
            self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")

            catalogue.delete_admin(SUPER, BOSS)  # a superadmin peer is deletable
            with self.assertRaises(ApiError) as ctx:
                catalogue.get_admin(SUPER, BOSS)
            self.assertEqual(ctx.exception.status_code, 404)
        finally:
            with connect() as conn, conn.cursor() as cur:
                cur.execute("DELETE FROM admin WHERE username = %s", (BOSS,))
                conn.commit()

    def test_06_tenant_deletes_its_peer_and_the_last_superadmin_survives(self):
        catalogue.delete_admin(TENANT, PEER)
        with self.assertRaises(ApiError) as ctx:
            catalogue.get_admin(SUPER, PEER)
        self.assertEqual(ctx.exception.status_code, 404)

        boss = catalogue.create_admin(
            SUPER,
            {
                "username": BOSS,
                "password": "boss-secret",
                "superadmin": True,
                "active": True,
                "domains": [],
            },
        )
        try:
            # Simulate "this is the last superadmin row" without touching the
            # fixture superadmins: every guard must refuse (409).
            with patch("app.catalogue._superadmin_rows", return_value=0):
                for attempt in (
                    lambda: catalogue.delete_admin(SUPER, BOSS),
                    lambda: catalogue.update_admin(SUPER, BOSS, {"superadmin": False}),
                    lambda: catalogue.update_admin(SUPER, BOSS, {"active": False}),
                ):
                    with self.assertRaises(ApiError) as ctx:
                        attempt()
                    self.assertEqual(ctx.exception.status_code, 409)
        finally:
            catalogue.delete_admin(SUPER, BOSS)

    def test_07_tenant_cannot_name_an_admin_after_a_foreign_mailbox(self):
        """Admin passwords mirror onto the same-named mailbox: a tenant naming a
        new admin after another tenant's mailbox would take that mailbox over."""
        catalogue.create_mailbox(
            SUPER,
            {
                "username": VICTIM,
                "password": "victim-secret",
                "name": "Cross-tenant victim",
                "quota_bytes": 0,
                "active": True,
            },
        )
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM mailbox WHERE username = %s", (VICTIM,))
            before = cur.fetchone()["password"]

        with self.assertRaises(ApiError) as ctx:
            catalogue.create_admin(
                TENANT,
                {
                    "username": VICTIM,
                    "password": "attacker-chosen",
                    "superadmin": False,
                    "active": True,
                    "domains": [ADM_DOMAIN],
                },
            )
        self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT password FROM mailbox WHERE username = %s", (VICTIM,))
            self.assertEqual(cur.fetchone()["password"], before)
            cur.execute("SELECT 1 FROM admin WHERE username = %s", (VICTIM,))
            self.assertIsNone(cur.fetchone())

    def test_08_a_peer_with_a_foreign_address_stays_superadmin_only(self):
        """A superadmin may scope an admin with a foreign address to the
        tenant's domain; the tenant still cannot rotate (mirror), disable or
        delete it."""
        catalogue.create_admin(
            SUPER,
            {
                "username": OUTSIDER,
                "password": "outsider-secret",
                "superadmin": False,
                "active": True,
                "domains": [ADM_DOMAIN],
            },
        )
        for attempt in (
            lambda: catalogue.update_admin(TENANT, OUTSIDER, {"password": "x"}),
            lambda: catalogue.update_admin(TENANT, OUTSIDER, {"active": False}),
            lambda: catalogue.delete_admin(TENANT, OUTSIDER),
        ):
            with self.assertRaises(ApiError) as ctx:
                attempt()
            self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")
        catalogue.delete_admin(SUPER, OUTSIDER)

    def test_09_list_scope_ignores_domain_case(self):
        shouting = Principal(TENANT.username, False, [ADM_DOMAIN.upper()], DEVICE)
        catalogue.create_admin(
            SUPER,
            {
                "username": PEER,
                "password": "peer-secret",
                "superadmin": False,
                "active": True,
                "domains": [ADM_DOMAIN],
            },
        )
        try:
            names = [a["username"] for a in catalogue.list_admins(shouting, 50, None)["items"]]
            self.assertIn(PEER, names)
        finally:
            catalogue.delete_admin(SUPER, PEER)


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        try:
            _wipe()
        except Exception as exc:  # pragma: no cover - best-effort cleanup
            print(f"cleanup warning: {exc}", file=sys.stderr)
