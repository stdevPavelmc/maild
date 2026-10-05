#!/bin/bash
#
# Apply the MailD schema migrations (db/migrations/*.sql) to the catalogue database on every
# boot. Idempotent: every migration guards itself (CREATE TABLE IF NOT EXISTS, ...), so a
# re-run is a no-op. Runs from the db entrypoint chain, right after ensure_databases.sh.
#
# This is the documented slot for schema changes that are NOT core PostfixAdmin tables
# (see .agents/services/configuration.md -> "Database schema changes").
#
set -euo pipefail

DIR="/usr/local/share/maild/migrations"
[ -d "$DIR" ] || { echo "db: no migrations directory, skipping"; exit 0; }

shopt -s nullglob
files=("$DIR"/*.sql)
[ "${#files[@]}" -gt 0 ] || { echo "db: no migrations to apply"; exit 0; }

for f in "${files[@]}"; do
  echo "db: applying migration $(basename "$f")"
  # -d "$POSTGRES_DB": the catalogue database (created just before by ensure_databases.sh);
  # no -h so psql uses the local socket, exactly like ensure_databases.sh does.
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f "$f"
done

echo "db: migrations up to date"
