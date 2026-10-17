"""Idempotent SQL migration runner for the AdminNG database.

Every file in `migrations/` is named `NNN_description.sql` and is applied once,
in numeric order, inside its own transaction; `schema_version` records what has
run so re-boots are no-ops. This mirrors the style of the catalogue's
`db/migrations/001_maild_provision.sql` but runs in the *api* container, because
AdminNG's schema is AdminNG's business (db/migrate.sh stays catalogue-only).
"""

from pathlib import Path

from . import settings
from .db import connect


def migration_files() -> list[Path]:
    """Return the migration files in numeric application order."""
    root = Path(settings.MIGRATIONS_DIR)
    return sorted(p for p in root.glob("*.sql") if p.is_file())


def _version_of(path: Path) -> int:
    try:
        return int(path.name.split("_", 1)[0])
    except (IndexError, ValueError):
        raise SystemExit(
            f"api: FATAL - migration '{path.name}' must start with a numeric version "
            "(e.g. 002_my_change.sql)"
        ) from None


def apply_migrations() -> list[str]:
    """Apply pending migrations to ADMINNG_DB; return the file names applied."""
    applied: list[str] = []
    with connect(settings.ADMINNG_DB) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_version (
                  version    int PRIMARY KEY,
                  applied_at timestamptz NOT NULL DEFAULT now()
                )
                """
            )
            conn.commit()
            cur.execute("SELECT version FROM schema_version")
            done = {row["version"] for row in cur.fetchall()}

            for path in migration_files():
                version = _version_of(path)
                if version in done:
                    continue
                cur.execute(path.read_text(encoding="utf-8"))
                cur.execute(
                    "INSERT INTO schema_version (version) VALUES (%s)", (version,)
                )
                conn.commit()
                applied.append(path.name)
    return applied
