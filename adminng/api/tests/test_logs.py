#!/usr/bin/env python3
"""Logs router self-test — runs inside the api container.

    docker compose --env-file env.dev -f docker-compose-dev.yml \\
        exec -T api python tests/test_logs.py

It exercises the tenant scoping shared by `GET /logs` and `GET /logs/facets`
(no HTTP): a custom admin only sees its own domains' events, the `Nobody`
sentinel (`__none__`) selects rows whose actor is not an existing admin, and
the facets stay scoped by domain/actor. Uses throwaway audit rows that are
wiped afterwards.
"""

import sys
import unittest

from app import audit, settings
from app.auth import Principal
from app.db import connect
from app.errors import ApiError
from app.routers import logs

DEVICE = "00000000-0000-4000-8000-000000000002"
SELFTEST_ADMIN = "selftest-logfilter@example.com"
SUPER = Principal(SELFTEST_ADMIN, True, [], DEVICE)
DOMAIN = "adminng-logs-selftest.test"
CUSTOM = Principal("custom-selftest", False, [DOMAIN], DEVICE)
FOREIGN = "foreign-logs-selftest.test"
GHOST = "ghost-selftest"
MARKER = "SELFTEST_LOGFILTER"


def _wipe() -> None:
    with connect(settings.ADMINNG_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM audit_event WHERE details->>'marker' = %s", (MARKER,))
        conn.commit()
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM domain_admins WHERE username = %s", (SELFTEST_ADMIN,))
        cur.execute("DELETE FROM admin WHERE username = %s", (SELFTEST_ADMIN,))
        conn.commit()


def _seed() -> None:
    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO admin (username, password, superadmin, active) "
            "VALUES (%s, 'x', false, true) ON CONFLICT (username) DO NOTHING",
            (SELFTEST_ADMIN,),
        )
        conn.commit()
    audit.record(actor=SELFTEST_ADMIN, action="LOGIN_OK", domain=DOMAIN, result="ok", marker=MARKER)
    audit.record(actor=GHOST, action="LOGIN_FAIL", domain=DOMAIN, result="denied", marker=MARKER)
    audit.record(actor=SELFTEST_ADMIN, action="LOGIN_OK", domain=FOREIGN, result="ok", marker=MARKER)


class LogFilterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _wipe()
        _seed()

    @classmethod
    def tearDownClass(cls):
        _wipe()

    def test_custom_admin_only_sees_own_domains(self):
        page = logs.list_logs(domain=DOMAIN, principal=CUSTOM)
        domains = {item["domain"] for item in page["items"]}
        self.assertIn(DOMAIN, domains)
        self.assertNotIn(FOREIGN, domains)

    def test_custom_admin_cannot_force_foreign_domain(self):
        with self.assertRaises(ApiError):
            logs.list_logs(domain=FOREIGN, principal=CUSTOM)

    def test_nobody_selects_non_admin_actors(self):
        page = logs.list_logs(domain=DOMAIN, actor=logs.NOBODY_ACTOR, principal=SUPER)
        actors = {item["actor"] for item in page["items"]}
        self.assertIn(GHOST, actors)
        self.assertNotIn(SELFTEST_ADMIN, actors)

    def test_nobody_respects_tenant_scope(self):
        with self.assertRaises(ApiError) as ctx:
            logs.list_logs(actor=logs.NOBODY_ACTOR, domain=FOREIGN, principal=CUSTOM)
        self.assertEqual(ctx.exception.code, "FORBIDDEN_TENANT")

    def test_facets_are_scoped_by_domain(self):
        facets = logs.log_facets(domain=DOMAIN, principal=SUPER)
        self.assertIn(SELFTEST_ADMIN, facets["actors"])
        self.assertIn(GHOST, facets["actors"])
        self.assertIn("LOGIN_OK", facets["actions"])

        foreign_facets = logs.log_facets(domain=FOREIGN, principal=SUPER)
        self.assertNotIn(GHOST, foreign_facets["actors"])

    def test_facets_respect_tenant_scope(self):
        with self.assertRaises(ApiError):
            logs.log_facets(domain=FOREIGN, principal=CUSTOM)

    def test_facets_actions_follow_actor(self):
        facets = logs.log_facets(domain=DOMAIN, actor=GHOST, principal=SUPER)
        self.assertEqual(facets["actions"], ["LOGIN_FAIL"])


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    sys.exit(0 if result.wasSuccessful() else 1)
