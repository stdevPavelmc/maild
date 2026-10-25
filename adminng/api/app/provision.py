"""First-boot catalogue provisioning — the port of the retired `admin/seed.sh`.

MailD used to let the PostfixAdmin container seed the catalogue (`admin/seed.sh`,
run by its entrypoint right after `public/upgrade.php`). That service is retired, so
the same work happens here, at `api` boot, before uvicorn starts:

  * `DEFAULT_DOMAIN` — the deployment's own domain;
  * `MAIL_ADMIN_USER@DEFAULT_DOMAIN` as a **superadmin** (`admin` row);
  * the matching **mailbox** with the same password (a real IMAP account);
  * postmaster/abuse/hostmaster/webmaster → the administrator;
  * the `maild_provision` **sentinel** row that amavis/mua/mta wait on.

Everything runs in one transaction guarded by the same transaction-scoped advisory
lock the shell seeder used (842019019) and every statement is idempotent
(`INSERT … ON CONFLICT DO NOTHING`), so swarm replicas and repeated boots converge
instead of racing. An existing password is never clobbered unless
`PROVISION_FORCE=yes`; `PROVISION_VERSION` re-asserts the defaults on the next boot.

`AUTO_PROVISION=no` disables the boot-time run: the operator then uses
`docker compose exec api adminng.py --provision`, the manual path that replaces
PostfixAdmin's `/setup.php` wizard.

The catalogue schema itself is NOT created here: it belongs to the `db` container
(`db/migrations/002_postfixadmin_catalogue.sql`). This module only writes rows, in
exactly the format PostfixAdmin/AdminNG write them, so Postfix, Dovecot, Amavis and
the MUA keep reading what they always have.
"""

from __future__ import annotations

import logging
import secrets
import time
from dataclasses import dataclass, field

import psycopg

from . import catalogue, passwords, settings
from .db import connect

log = logging.getLogger("adminng.provision")

# PostfixAdmin's `$CONF['default_aliases']`, which the admin container used to bake
# into config.local.php: every new deployment domain gets these pointing at the
# administrator, exactly like the "create domain" click used to do. The canonical
# tuple lives in `catalogue` because that module writes aliases too.
DEFAULT_ALIASES = catalogue.DEFAULT_ALIASES

# Same key as admin/seed.sh: a rolling upgrade that still runs the old shell seeder
# can never interleave with this one, whatever the deployment order.
ADVISORY_LOCK_KEY = 842019019


class ProvisionError(RuntimeError):
    """Provisioning cannot run (missing DEFAULT_DOMAIN, schema never appeared…)."""


@dataclass(frozen=True)
class ProvisionConfig:
    """Everything the seeder needs; built from the env by `config_from_env`."""

    default_domain: str
    admin_user: str = "sysadmin"
    admin_password: str | None = None
    version: int = 1
    force: bool = False
    wait_timeout: int = 180
    aliases: tuple[str, ...] = field(default=DEFAULT_ALIASES)

    @property
    def admin_address(self) -> str:
        return f"{self.admin_user}@{self.default_domain}"

    @property
    def maildir(self) -> str:
        """PostfixAdmin layout: '<domain>/<local_part>/' (trailing slash)."""
        return f"{self.default_domain}/{self.admin_user}/"


def config_from_env(*, respect_auto_provision: bool = True) -> ProvisionConfig | None:
    """Build the config from the environment; ``None`` when AUTO_PROVISION=no.

    The manual CLI path (`adminng.py --provision`) passes
    ``respect_auto_provision=False``: with AUTO_PROVISION=no the boot-time run is
    off exactly so the operator can seed by hand.
    """
    if respect_auto_provision and not settings.AUTO_PROVISION:
        return None
    domain = settings.DEFAULT_DOMAIN.strip().lower().rstrip(".")
    if not domain:
        raise ProvisionError(
            "DEFAULT_DOMAIN is empty: set it in the operator env file "
            "(env.dev in dev, .env in production)"
        )
    return ProvisionConfig(
        default_domain=domain,
        admin_user=settings.MAIL_ADMIN_USER,
        admin_password=settings.MAIL_ADMIN_PASSWORD or None,
        version=settings.PROVISION_VERSION,
        force=settings.PROVISION_FORCE,
        wait_timeout=settings.PROVISION_WAIT_TIMEOUT,
    )


# ------------------------------------------------------------------- helpers ---
def _sentinel_ok(cur, version: int) -> bool:
    """True when a previous run already provisioned this catalogue."""
    cur.execute(
        "SELECT 1 FROM maild_provision WHERE id = 1 AND version >= %s", (version,)
    )
    return cur.fetchone() is not None


def wait_for_schema(timeout: int) -> None:
    """Block (bounded) until the catalogue's `domain` table exists.

    `db` applies its migrations on its own boot and this container can win the
    race, so this mirrors seed.sh's wait loop instead of failing on the first
    missing table. Same bounded-timeout philosophy: a broken db degrades to a
    clear error, never a deadlock.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
                cur.execute(
                    "SELECT 1 FROM information_schema.tables "
                    "WHERE table_schema = 'public' AND table_name = 'domain'"
                )
                if cur.fetchone() is not None:
                    return
        except psycopg.Error:
            pass  # db still starting, or the catalogue database is not created yet
        if time.monotonic() >= deadline:
            raise ProvisionError(
                f"the catalogue schema did not appear within {timeout}s (is the db "
                "container applying db/migrations/002_postfixadmin_catalogue.sql?)"
            )
        time.sleep(2)


def _admin_password(cfg: ProvisionConfig) -> tuple[str, bool]:
    """Return (password, generated); a generated one is printed OTP-style."""
    if cfg.admin_password:
        return cfg.admin_password, False
    # 18 random bytes = 36 hex chars, the same shape seed.sh generated.
    generated = secrets.token_hex(18)
    log.warning("#################### !!! #############################")
    log.warning("GENERATED ADMIN PASSWORD for %s: %s", cfg.admin_address, generated)
    log.warning("#################### !!! #############################")
    return generated, True


# ---------------------------------------------------------------------- run ----
def provision(cfg: ProvisionConfig | None = None) -> dict:
    """Seed the catalogue (idempotent) and return a small report.

    `cfg=None` reads the environment; when AUTO_PROVISION=no the call is a no-op
    reporting ``{"status": "disabled"}``. Raises ProvisionError when the schema
    never shows up — the caller decides whether that is fatal (the boot path only
    warns, so the API stays reachable and a manual `--provision` can fix it).
    """
    cfg = cfg or config_from_env()
    if cfg is None:
        log.info(
            "AUTO_PROVISION=no: skipping first-boot provisioning "
            "(run `adminng.py --provision` to seed the catalogue by hand)"
        )
        return {"status": "disabled"}

    wait_for_schema(cfg.wait_timeout)

    with connect(settings.POSTGRES_DB) as conn, conn.cursor() as cur:
        # Serialise replicas *before* generating a password, so only the leader logs one.
        cur.execute("SELECT pg_advisory_xact_lock(%s)", (ADVISORY_LOCK_KEY,))

        if not cfg.force and _sentinel_ok(cur, cfg.version):
            conn.rollback()
            log.info(
                "catalogue already provisioned (version >= %s); nothing to do",
                cfg.version,
            )
            return {
                "status": "already-provisioned",
                "domain": cfg.default_domain,
                "admin": cfg.admin_address,
            }

        password, generated = _admin_password(cfg)
        hashed = passwords.hash_password(password)

        cur.execute(
            """
            INSERT INTO domain (domain, description, aliases, mailboxes, maxquota,
                                quota, transport, backupmx, active)
            VALUES (%s, 'MailD deployment domain (DEFAULT_DOMAIN)', 0, 0, 0, 0,
                    'virtual', false, true)
            ON CONFLICT DO NOTHING
            """,
            (cfg.default_domain,),
        )
        cur.execute(
            """
            INSERT INTO mailbox (username, password, name, maildir, quota, domain,
                                 local_part, active)
            VALUES (%s, %s, 'Mail administrator', %s, 0, %s, %s, true)
            ON CONFLICT DO NOTHING
            """,
            (
                cfg.admin_address,
                hashed,
                cfg.maildir,
                cfg.default_domain,
                cfg.admin_user,
            ),
        )
        cur.executemany(
            "INSERT INTO alias (address, goto, domain, active) "
            "VALUES (%s, %s, %s, true) ON CONFLICT DO NOTHING",
            [
                (f"{alias}@{cfg.default_domain}", cfg.admin_address, cfg.default_domain)
                for alias in cfg.aliases
            ],
        )
        cur.execute(
            "INSERT INTO admin (username, password, superadmin, active) "
            "VALUES (%s, %s, true, true) ON CONFLICT DO NOTHING",
            (cfg.admin_address, hashed),
        )

        # PROVISION_FORCE=yes re-asserts the password; otherwise the inserts above are
        # do-nothing, so an operator-edited password survives a restart.
        if cfg.force:
            cur.execute(
                "UPDATE mailbox SET password = %s, active = true WHERE username = %s",
                (hashed, cfg.admin_address),
            )
            cur.execute(
                "UPDATE admin SET password = %s, superadmin = true, active = true "
                "WHERE username = %s",
                (hashed, cfg.admin_address),
            )

        # AdminNG keeps domain.mailboxes/aliases in step on every write; do the same
        # for the rows just seeded (PostfixAdmin's counters are advisory, but a stale
        # zero after first boot is exactly the kind of drift this project hates).
        catalogue.recount_domain(cur, cfg.default_domain)

        cur.execute(
            """
            INSERT INTO maild_provision (id, version, default_domain, admin_user,
                                         provisioned_by)
            VALUES (1, %s, %s, %s, current_user)
            ON CONFLICT (id) DO UPDATE
                SET version = EXCLUDED.version,
                    default_domain = EXCLUDED.default_domain,
                    admin_user = EXCLUDED.admin_user,
                    provisioned_at = now(),
                    provisioned_by = current_user
            """,
            (cfg.version, cfg.default_domain, cfg.admin_user),
        )
        conn.commit()

    log.info(
        "catalogue provisioned: domain=%s admin=%s version=%s",
        cfg.default_domain,
        cfg.admin_address,
        cfg.version,
    )
    return {
        "status": "provisioned",
        "domain": cfg.default_domain,
        "admin": cfg.admin_address,
        "version": cfg.version,
        "aliases": [f"{alias}@{cfg.default_domain}" for alias in cfg.aliases],
        "password_generated": generated,
        "password": password if generated else None,
    }

