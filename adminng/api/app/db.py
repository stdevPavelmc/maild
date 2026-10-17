"""PostgreSQL helpers for the AdminNG API.

Two databases live on the same server:
  * POSTGRES_DB  — the PostfixAdmin catalogue (read/write, ZERO DDL from here);
  * ADMINNG_DB   — AdminNG's own state (we own the schema, migrate it at boot).
"""

import time

import psycopg
from psycopg.rows import dict_row

from . import settings


def dsn(dbname: str) -> str:
    """Build the libpq DSN for a database on the MailD catalogue server."""
    return (
        f"host={settings.POSTGRES_HOST} port={settings.POSTGRES_PORT} "
        f"user={settings.POSTGRES_USER} password={settings.POSTGRES_PASSWORD} "
        f"dbname={dbname}"
    )


def connect(dbname: str | None = None):
    """Open a dict-row connection (short connect_timeout so waits fail fast)."""
    return psycopg.connect(
        dsn(dbname or settings.POSTGRES_DB),
        row_factory=dict_row,
        connect_timeout=5,
    )


def wait_for_db(dbname: str, timeout: int = 60) -> None:
    """Block (bounded) until `dbname` accepts connections.

    `dbname` defaults to POSTGRES_DB, but ``postgres`` is used first by the
    bootstrap: without it libpq would try to connect to a database named after
    the role, which does not exist on a fresh server.
    """
    deadline = time.monotonic() + timeout
    last_error: object | None = None
    while time.monotonic() < deadline:
        try:
            with connect(dbname) as conn, conn.cursor() as cur:
                cur.execute("SELECT 1")
                return
        except psycopg.Error as exc:  # server down, db missing, auth not ready...
            last_error = exc
            time.sleep(2)
    raise SystemExit(
        f"api: FATAL - database '{dbname}' on {settings.POSTGRES_HOST}:"
        f"{settings.POSTGRES_PORT} not reachable after {timeout}s: {last_error}"
    )
