"""Container start-up: wait for Postgres, seed the catalogue, then migrate.

Invoked by entrypoint.sh before uvicorn. Both databases are *created* by the db
container (`db/ensure_databases.sh` creates the catalogue and ADMINNG_DB on every
boot) and the catalogue schema is applied there too (`db/migrations/`), so this
module only waits, runs MailD's first-boot provisioning (this container is the
leader: `admin/seed.sh` is retired, see app/provision.py) and applies AdminNG's own
migrations.

A provisioning failure never aborts the boot: the API must stay reachable so an
operator can finish by hand with `docker compose exec api adminng.py --provision`.
"""

import logging
import sys

from . import provision as provisioner
from . import settings
from .db import wait_for_db
from .migrate import apply_migrations

log = logging.getLogger("adminng.bootstrap")

# The value env.sample/env.sample_gitlab ship. A missing key is fatal (below), but a
# *placeholder* one is worse than missing: it looks configured while the JWT signing key
# is public (anybody could mint administrator tokens). Warning only — the operator may be
# mid-deploy and the stack still has to come up so `adminng.py --provision`/the UI work.
PLACEHOLDER_SECRET_KEYS = frozenset({"change-me-openssl-rand-hex-32"})


def warn_placeholder_secret(key: str) -> bool:
    """Log an OTP-style warning when the operator kept env.sample's placeholder."""
    if key not in PLACEHOLDER_SECRET_KEYS:
        return False
    log.warning("#################### !!! #############################")
    log.warning(
        "ADMINNG_SECRET_KEY still holds the env.sample placeholder (%s...): it is a "
        "publicly known value, so administrator tokens can be forged. Generate your own "
        "with `openssl rand -hex 32` and restart this container (live sessions and "
        "enrolled authenticators are invalidated).",
        key[:12],
    )
    log.warning("#################### !!! #############################")
    return True


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="api: %(levelname)s - %(message)s",
        stream=sys.stderr,
    )
    if not settings.ADMINNG_SECRET_KEY:
        log.error(
            "FATAL - ADMINNG_SECRET_KEY is not set: it signs the JWTs and encrypts "
            "TOTP seeds. Set it in the operator env file (env.dev / .env), e.g. "
            "`openssl rand -hex 32`."
        )
        return 2
    warn_placeholder_secret(settings.ADMINNG_SECRET_KEY)
    log.info(
        "waiting for PostgreSQL (catalogue=%s, adminng=%s)",
        settings.POSTGRES_DB,
        settings.ADMINNG_DB,
    )
    # `postgres` always exists; the catalogue and ADMINNG_DB are created by the db
    # container, and the catalogue schema is applied by its migrate.sh.
    wait_for_db("postgres", timeout=120)
    wait_for_db(settings.POSTGRES_DB, timeout=120)

    # First-boot provisioning (leader): DEFAULT_DOMAIN, the superadmin + its mailbox,
    # the default aliases and the maild_provision sentinel. Idempotent; the fast path
    # on every later boot is one SELECT.
    try:
        report = provisioner.provision()
    except provisioner.ProvisionError as exc:
        log.error("provisioning did not run: %s", exc)
    else:
        if report["status"] == "provisioned":
            log.info(
                "catalogue seeded: domain=%s admin=%s aliases=%s",
                report["domain"],
                report["admin"],
                ", ".join(report["aliases"]),
            )

    wait_for_db(settings.ADMINNG_DB, timeout=60)

    applied = apply_migrations()
    log.info(
        "migrations applied: %s",
        ", ".join(applied) if applied else "none (schema up to date)",
    )

    # Stale PENDING grants (browsers that asked for access, never approved).
    from . import devices

    purged = devices.purge_stale_pending(settings.ADMINNG_PENDING_TTL_DAYS)
    if purged:
        log.info("purged %s stale PENDING device grant(s)", purged)
    return 0


if __name__ == "__main__":
    sys.exit(main())
