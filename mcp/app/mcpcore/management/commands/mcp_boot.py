"""Boot sequence run by docker-entrypoint.sh before uvicorn (proposal §12):

1. wait (bounded) for the db and the `maild_provision` sentinel;
2. `migrate` the MCP database under an advisory lock;
3. seed the admin user on first boot only (MCP_ADMIN_* are ignored once a row exists);
4. ensure the service mailbox (D9): create it when missing, never touch an existing one.

Generated passwords are printed once, OTP-style, with the same banner as the api seeder.
"""

import logging
import os
import time

from django.conf import settings
from django.core.management import call_command
from django.core.management.base import BaseCommand, CommandError
from django.db import OperationalError, connections, transaction

from mcpcore import catalogue
from mcpcore.models import AdminUser
from mcpcore.passwords import dovecot_hash, generate_password, hash_password

log = logging.getLogger("mcp.boot")

# arbitrary, constant: serialises migrate across containers/replicas booting together
MIGRATE_LOCK_ID = 0x6D63705F6D6967  # "mcp_mig"

# env.sample ships `change-me-openssl-rand-hex-NN` placeholders (2026-10 audit L-07).
PLACEHOLDER_PREFIX = "change-me"
# A known value of these is a full compromise, so the MCP refuses to start with one:
# MCP_SECRET_KEY derives the web-session JWT key, the token-hash HMAC, the handle and ALTCHA
# keys and the Fernet key of stored SMTP passwords; the master password opens every mailbox.
FATAL_PLACEHOLDERS = ("MCP_SECRET_KEY", "MCP_DOVECOT_MASTER_PASSWORD")
# The db role is internal-only: warned, not fatal.
WARN_PLACEHOLDERS = ("MCP_DB_PASSWORD",)
MIN_SECRET_KEY_LEN = 32


def check_secrets(env: dict) -> list[str]:
    """→ the fatal problems (empty = boot). Warnings are logged here."""
    fatal = [name for name in FATAL_PLACEHOLDERS
             if (env.get(name) or "").startswith(PLACEHOLDER_PREFIX)]
    for name in WARN_PLACEHOLDERS:
        if (env.get(name) or "").startswith(PLACEHOLDER_PREFIX):
            log.warning("%s still holds the env.sample placeholder: generate one with "
                        "`openssl rand -hex 18` (db role and the operator file together)", name)
    key = env.get("MCP_SECRET_KEY") or ""
    if key and not key.startswith(PLACEHOLDER_PREFIX) and len(key) < MIN_SECRET_KEY_LEN:
        log.warning("MCP_SECRET_KEY is only %d characters: use `openssl rand -hex 32`", len(key))
    return fatal


def _banner(label: str, who: str, password: str) -> None:
    log.warning("#################### !!! #############################")
    log.warning("GENERATED %s: %s  PASSWORD: %s", label, who, password)
    log.warning("#################### !!! #############################")


class Command(BaseCommand):
    help = "MailD MCP boot: wait for the catalogue, migrate, seed the admin, ensure the service mailbox."

    def handle(self, *args, **options):
        fatal = check_secrets(dict(os.environ))
        if fatal:
            raise CommandError(
                f"{', '.join(fatal)} still hold(s) the env.sample placeholder, a publicly known "
                "value: generate real ones (`openssl rand -hex 32` / `-hex 18`), set them in the "
                "operator env file and recreate the stack (the master password is shared with mda)")
        self.wait_for_catalogue()
        self.migrate()
        self.seed_admin()
        self.ensure_service_mailbox()
        log.info("boot sequence complete")

    # ------------------------------------------------------------------ 1 ----
    def wait_for_catalogue(self) -> None:
        deadline = time.monotonic() + settings.PROVISION_WAIT_TIMEOUT
        last_error = ""
        while True:
            try:
                if catalogue.provisioned():
                    log.info("catalogue provisioned (maild_provision sentinel present)")
                    return
                last_error = "maild_provision sentinel not written yet"
            except OperationalError as exc:  # db down, role not created yet, wrong password…
                last_error = str(exc).strip().splitlines()[0] if str(exc).strip() else repr(exc)
            except Exception as exc:  # table missing before migrate.sh ran
                last_error = str(exc).strip().splitlines()[0] if str(exc).strip() else repr(exc)
            finally:
                connections["catalogue"].close()
            if time.monotonic() >= deadline:
                raise CommandError(
                    f"catalogue not ready after {settings.PROVISION_WAIT_TIMEOUT}s: {last_error}"
                )
            log.info("waiting for the catalogue: %s", last_error)
            time.sleep(3)

    # ------------------------------------------------------------------ 2 ----
    def migrate(self) -> None:
        conn = connections["default"]
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_lock(%s)", [MIGRATE_LOCK_ID])
        try:
            call_command("migrate", interactive=False, verbosity=1)
        finally:
            with conn.cursor() as cur:
                cur.execute("SELECT pg_advisory_unlock(%s)", [MIGRATE_LOCK_ID])

    # ------------------------------------------------------------------ 3 ----
    def seed_admin(self) -> None:
        with transaction.atomic():
            if AdminUser.objects.select_for_update().exists():
                log.info("admin user already present: MCP_ADMIN_USER/PASSWORD/EMAIL are ignored")
                return
            password = settings.MCP_ADMIN_PASSWORD
            generated = not password
            if generated:
                password = generate_password()
            AdminUser.objects.create(
                username=settings.MCP_ADMIN_USER,
                email=settings.MCP_ADMIN_EMAIL,
                password_hash=hash_password(password),
            )
        log.info("admin user '%s' created (%s)", settings.MCP_ADMIN_USER, settings.MCP_ADMIN_EMAIL)
        if generated:
            _banner("MCP ADMIN", settings.MCP_ADMIN_USER, password)

    # ------------------------------------------------------------------ 4 ----
    def ensure_service_mailbox(self) -> None:
        address = settings.MCP_SERVICE_EMAIL
        local_part, _, domain = address.rpartition("@")
        if not local_part or not domain:
            raise CommandError(f"MCP_SERVICE_EMAIL '{address}' is not an email address")

        state = catalogue.mailbox_state(address)
        if state is True:
            log.info("service mailbox %s present and active", address)
            return
        if state is False:
            # amavis needs no auth, so service mail still goes out; replies and bounces do not
            log.warning("service mailbox %s exists but is INACTIVE: replies/bounces to service mail are lost", address)
            return

        domain_active = catalogue.domain_state(domain)
        if domain_active is None:
            raise CommandError(
                f"MCP_SERVICE_EMAIL '{address}': domain '{domain}' is not in the catalogue "
                "(create the domain first or point MCP_SERVICE_EMAIL to a hosted domain)"
            )
        if not domain_active:
            raise CommandError(f"MCP_SERVICE_EMAIL '{address}': domain '{domain}' is inactive")

        password = settings.MCP_SERVICE_PASSWORD
        generated = not password
        if generated:
            password = generate_password()
        created = catalogue.ensure_service_mailbox(address, dovecot_hash(password), "MailD MCP service")
        if not created:  # a concurrent boot won the race
            log.info("service mailbox %s present", address)
            return
        log.info("service mailbox %s created", address)
        if generated:
            _banner("MCP SERVICE MAILBOX", address, password)
