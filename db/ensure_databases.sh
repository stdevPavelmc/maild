#!/bin/bash
#
# MailD-MCP (D-26): ensure the extra databases exist on *every* boot.
#
# POSTGRES_EXTRA_DB is a comma-separated list; single values still work, so no
# existing deployment changes behaviour. Blanks are skipped, existing databases
# are left alone. Replaces the old init-only multiple_db.sh, which ran once on an
# empty data directory and hardcoded a single name (F-03).
#
set -euo pipefail

[ -n "${POSTGRES_EXTRA_DB:-}" ] || { echo "db: no extra databases requested"; exit 0; }

IFS=',' read -ra DBS <<< "${POSTGRES_DB},${POSTGRES_EXTRA_DB}"
for db in "${DBS[@]}"; do
  db="$(echo "$db" | xargs)"            # trim
  [ -n "$db" ] || continue
  # -d postgres: without it psql tries to connect to a database named after the role, which
  # does not exist yet on a fresh server (found while running D-26 on the dev stack)
  if [ "$(psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'")" = "1" ]; then
    echo "db: database '${db}' already exists"
  else
    createdb -U "$POSTGRES_USER" "${db}" && echo "db: created database '${db}'"
  fi
done

echo "db: INFO - all requested databases exist".
