"""Container start-up: wait for Postgres + the adminng DB, then migrate.

Invoked by entrypoint.sh before uvicorn. The adminng database is *created* by the
db container (`db/ensure_databases.sh` creates ADMINNG_DB on every boot), so this
module only waits for it and reports a clear error if the operator removed it
from the db's env.
"""

import logging
import sys

from . import settings
from .db import wait_for_db
from .migrate import apply_migrations

log = logging.getLogger("adminng.bootstrap")


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
    log.info(
        "waiting for PostgreSQL (catalogue=%s, adminng=%s)",
        settings.POSTGRES_DB,
        settings.ADMINNG_DB,
    )
    # `postgres` always exists; ADMINNG_DB is created by the db container.
    wait_for_db("postgres", timeout=120)
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
