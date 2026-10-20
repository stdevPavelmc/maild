#!/usr/bin/env python3
"""Bootstrap (CSV bulk import) self-test — runs inside the api container.

    docker compose --env-file env.dev -f docker-compose-dev.yml \\
        exec -T api python tests/test_bootstrap.py

It exercises the import layer directly (no HTTP) against the dev fixtures'
database, using a throwaway domain, and asserts the rules of the "Carga
inicial" feature:

  * a valid file creates the mailboxes (Argon2id hashes, maildir layout,
    quota in bytes — i.e. exactly what `catalogue.create_mailbox` does);
  * a failing row never stops the import (the good rows are still created);
  * an account that already exists is never modified (USER_EXIST_ALREADY);
  * a whole-file error (bad base64, empty file, wrong headers) is a 422;
  * the report carries a per-row status and, when there are failures, a CSV
    with ONLY the failed rows plus the `problem` column.
"""

import base64
import csv
import io
import sys
import unittest

from app import bulk, catalogue
from app.auth import Principal
from app.db import connect
from app.errors import ApiError
from app.passwords import hash_password, verify_password

DOMAIN = "adminng-bootstrap-selftest.test"
PASSWORD = "Str0ng!Pass"
DEVICE = "00000000-0000-4000-8000-000000000003"
SUPER = Principal("bootstrap-selftest", True, [], DEVICE)
CUSTOM = Principal("custom-bootstrap-selftest", False, [DOMAIN], DEVICE)


def _b64(text: str) -> str:
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


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


def _failed_rows(report: dict) -> list[list[str]]:
    """Decode the failed-rows CSV of a report into its rows."""
    raw = base64.b64decode(report["failed_csv_base64"]).decode("utf-8")
    return list(csv.reader(io.StringIO(raw)))



class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _wipe()
        catalogue.create_domain(
            SUPER,
            {
                "domain": DOMAIN,
                "description": "AdminNG bootstrap self-test",
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

    def test_01_valid_file_creates_the_accounts(self):
        csv_text = (
            "fullname,emailaddress,password,quota\n"
            f"One User,one@{DOMAIN},{PASSWORD},512\n"
            f"Two User,two@{DOMAIN},{PASSWORD},1G\n"
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["total"], 2)
        self.assertEqual(report["created"], 2)
        self.assertEqual(report["failed"], 0)
        self.assertNotIn("failed_csv_base64", report)
        self.assertTrue(all(item["ok"] for item in report["results"]))

        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT username, password, name, maildir, quota FROM mailbox "
                "WHERE domain = %s ORDER BY username",
                (DOMAIN,),
            )
            rows = cur.fetchall()
        self.assertEqual(len(rows), 2)
        first = rows[0]
        self.assertEqual(first["username"], f"one@{DOMAIN}")
        self.assertEqual(first["name"], "One User")
        self.assertEqual(first["maildir"], f"{DOMAIN}/one/")
        self.assertEqual(first["quota"], 512 * 1024 * 1024)
        self.assertTrue(verify_password(PASSWORD, first["password"]))

    def test_02_a_failing_row_does_not_stop_the_import(self):
        csv_text = (
            "fullname,emailaddress,password,quota\n"
            f"Good One,good@{DOMAIN},{PASSWORD},512\n"
            f"Weak Password,weak@{DOMAIN},weak,512\n"
            f"Unknown Domain,nobody@nowhere.invalid,{PASSWORD},512\n"
            f"Good Two,good2@{DOMAIN},{PASSWORD},512\n"
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["total"], 4)
        self.assertEqual(report["created"], 2)
        self.assertEqual(report["failed"], 2)

        codes = {item["email"]: item["code"] for item in report["results"]}
        self.assertEqual(codes[f"good@{DOMAIN}"], "OK")
        self.assertEqual(codes[f"weak@{DOMAIN}"], "WEAK_PASSWORD")
        self.assertEqual(codes["nobody@nowhere.invalid"], "WRONG_DOMAIN")

        # The good rows were really created.
        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) AS n FROM mailbox WHERE domain = %s", (DOMAIN,)
            )
            self.assertEqual(cur.fetchone()["n"], 4)

    def test_03_an_existing_account_is_never_modified(self):
        csv_text = (
            "fullname,emailaddress,password,quota\n"
            f"Renamed,good@{DOMAIN},Another!Pass9,999\n"
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["created"], 0)
        self.assertEqual(report["failed"], 1)
        self.assertEqual(report["results"][0]["code"], "USER_EXIST_ALREADY")

        # The mailbox kept its name and its quota.
        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT name, quota FROM mailbox WHERE username = %s",
                (f"good@{DOMAIN}",),
            )
            row = cur.fetchone()
        self.assertEqual(row["name"], "Good One")
        self.assertEqual(row["quota"], 512 * 1024 * 1024)

    def test_04_whole_file_errors_are_422(self):
        # Not base64.
        with self.assertRaises(ApiError) as ctx:
            bulk.import_users(SUPER, "not base64 !!!")
        self.assertEqual(ctx.exception.status_code, 422)

        # Empty file.
        with self.assertRaises(ApiError) as ctx:
            bulk.import_users(SUPER, _b64("   \n"))
        self.assertEqual(ctx.exception.status_code, 422)

        # Wrong headers.
        with self.assertRaises(ApiError) as ctx:
            bulk.import_users(SUPER, _b64("name,email\nfoo,bar@example.net\n"))
        self.assertEqual(ctx.exception.status_code, 422)

    def test_05_the_failed_csv_holds_only_the_failed_rows(self):
        csv_text = (
            "fullname,emailaddress,password,quota\n"
            f"Fine,fine@{DOMAIN},{PASSWORD},512\n"
            f"Broken,broken@{DOMAIN},short,512\n"
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["failed"], 1)
        self.assertIn("failed_csv_base64", report)

        rows = _failed_rows(report)
        self.assertEqual(rows[0], ["fullname", "emailaddress", "password", "quota", "problem"])
        self.assertEqual(len(rows), 2)  # header + the single failed row
        self.assertEqual(rows[1][:4], ["Broken", f"broken@{DOMAIN}", "short", "512"])
        self.assertTrue(rows[1][4])  # the reason

    def test_06_the_failed_csv_can_be_uploaded_again(self):
        csv_text = (
            "fullname,emailaddress,password,quota\n"
            f"Fine2,fine2@{DOMAIN},{PASSWORD},512\n"
            f"Broken2,broken2@{DOMAIN},short,512\n"
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        rows = _failed_rows(report)
        self.assertEqual(len(rows), 2)  # header + the single failed row

        # The admin fixes the password and uploads the downloaded file again.
        # The downloaded file carries the extra `problem` column, which the
        # import ignores.
        rows[1][2] = "Fix3d!Pass"
        buffer = io.StringIO()
        csv.writer(buffer, lineterminator="\n").writerows(rows)
        again = bulk.import_users(SUPER, _b64(buffer.getvalue()))
        self.assertEqual(again["created"], 1)
        self.assertEqual(again["failed"], 0)
        self.assertEqual(again["results"][0]["email"], f"broken2@{DOMAIN}")

    def test_07_a_custom_admin_only_manages_its_own_domains(self):
        csv_text = (
            "fullname,emailaddress,password,quota\n"
            f"Mine,mine@{DOMAIN},{PASSWORD},512\n"
            f"Other,other@adminng-bootstrap-foreign.test,{PASSWORD},512\n"
        )
        report = bulk.import_users(CUSTOM, _b64(csv_text))
        self.assertEqual(report["created"], 1)
        self.assertEqual(report["failed"], 1)
        codes = {item["email"]: item["code"] for item in report["results"]}
        self.assertEqual(codes["other@adminng-bootstrap-foreign.test"], "WRONG_DOMAIN")

    def test_08_quota_units(self):
        self.assertEqual(bulk.parse_quota(""), 0)
        self.assertEqual(bulk.parse_quota("512"), 512 * 1024**2)
        self.assertEqual(bulk.parse_quota("512MB"), 512 * 1024**2)
        self.assertEqual(bulk.parse_quota("512 MB"), 512 * 1024**2)
        self.assertEqual(bulk.parse_quota("1G"), 1024**3)
        self.assertEqual(bulk.parse_quota("1T"), 1024**4)
        with self.assertRaises(ValueError):
            bulk.parse_quota("12 apples")


    def test_09_passwordhash_argon2id_prefixed(self):
        hashed = hash_password("Str0ng!Pass")
        self.assertTrue(hashed.startswith("{ARGON2ID}$argon2id$"))
        csv_text = (
            "fullname,emailaddress,password,quota,passwordhash\n"
            f'Hash User,hash@{DOMAIN},,,"{hashed}",512\n'
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["created"], 1, report)
        self.assertEqual(report["failed"], 0, report)
        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT password FROM mailbox WHERE username = %s",
                (f"hash@{DOMAIN}",),
            )
            stored = cur.fetchone()["password"]
        self.assertEqual(stored, hashed)
        self.assertTrue(verify_password("Str0ng!Pass", stored))

    def test_10_passwordhash_argon2id_bare(self):
        hashed = hash_password("Str0ng!Pass")
        bare = hashed[len("{ARGON2ID}"):]
        csv_text = (
            "fullname,emailaddress,password,quota,passwordhash\n"
            f'Bare User,bare@{DOMAIN},,,"{bare}",512\n'
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["created"], 1, report)
        self.assertEqual(report["failed"], 0, report)
        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT password FROM mailbox WHERE username = %s",
                (f"bare@{DOMAIN}",),
            )
            stored = cur.fetchone()["password"]
        self.assertEqual(stored, "{ARGON2ID}" + bare)
        self.assertTrue(verify_password("Str0ng!Pass", stored))

    def test_11_passwordhash_md5crypt_pre_deadline(self):
        from app.passwords import _today as _orig_today
        bulk._today = lambda: __import__("datetime").date(2027, 1, 31)
        try:
            legacy = "$1$salt1234$" + "a" * 22
            csv_text = (
                "fullname,emailaddress,password,quota,passwordhash\n"
                f'Legacy User,legacy@{DOMAIN},,,"{legacy}",512\n'
            )
            report = bulk.import_users(SUPER, _b64(csv_text))
            self.assertEqual(report["created"], 1, report)
            self.assertEqual(report["failed"], 0, report)
            with connect() as conn, conn.cursor() as cur:
                cur.execute(
                    "SELECT password FROM mailbox WHERE username = %s",
                    (f"legacy@{DOMAIN}",),
                )
                stored = cur.fetchone()["password"]
            self.assertEqual(stored, legacy)
        finally:
            bulk._today = _orig_today



    def test_12_passwordhash_md5crypt_post_deadline(self):
        from app.passwords import _today as _orig_today
        bulk._today = lambda: __import__("datetime").date(2027, 2, 2)
        try:
            legacy = "$1$salt1234$" + "a" * 22
            csv_text = (
                "fullname,emailaddress,password,quota,passwordhash\n"
                f'Legacy User,legacy2@{DOMAIN},,,"{legacy}",512\n'
            )
            report = bulk.import_users(SUPER, _b64(csv_text))
            self.assertEqual(report["created"], 0, report)
            self.assertEqual(report["failed"], 1, report)
            self.assertEqual(
                report["results"][0]["code"], "WEAK_PASSWORD_ALGORITHM"
            )
        finally:
            bulk._today = _orig_today

    def test_13_passwordhash_malformed(self):
        csv_text = (
            "fullname,emailaddress,password,quota,passwordhash\n"
            f"Bad User,bad@{DOMAIN},,not-a-hash-at-all,512\n"
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["created"], 0, report)
        self.assertEqual(report["failed"], 1, report)
        self.assertEqual(
            report["results"][0]["code"], "MALFORMED_PASSWORD_HASH"
        )

    def test_14_passwordhash_both_present(self):
        csv_text = (
            "fullname,emailaddress,password,quota,passwordhash\n"
            f'Both User,both@{DOMAIN},{PASSWORD},512,"$1$fake$fake"\n'
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["created"], 1, report)
        self.assertEqual(report["failed"], 0, report)
        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT password FROM mailbox WHERE username = %s",
                (f"both@{DOMAIN}",),
            )
            stored = cur.fetchone()["password"]
        self.assertTrue(verify_password(PASSWORD, stored))

    def test_15_passwordhash_neither_present(self):
        csv_text = (
            "fullname,emailaddress,password,quota,passwordhash\n"
            f'None User,none@{DOMAIN},,,,512\n'
        )
        report = bulk.import_users(SUPER, _b64(csv_text))
        self.assertEqual(report["created"], 0, report)
        self.assertEqual(report["failed"], 1, report)
        self.assertEqual(
            report["results"][0]["code"], "MISSING_FIELD"
        )



if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        try:
            _wipe()
        except Exception as exc:  # pragma: no cover - best-effort cleanup
            print(f"cleanup warning: {exc}", file=sys.stderr)
