#!/bin/bash
#
# MailD-MCP (D-26): ensure the databases exist on *every* boot.
#
# Three sources, all optional except POSTGRES_DB:
#   POSTGRES_DB        the PostfixAdmin catalogue (mailddb)
#   POSTGRES_EXTRA_DB  comma-separated operator extras (empty by default; it used to be
#                      `contacts`, SnappyMail's address book — an existing one stays)
#   ADMINNG_DB         AdminNG's own state database (devices, sessions, TOTP,
#                      audit trail)
#   MCP_DB             the MailD MCP's own database (accounts, tokens, settings);
#                      owned by the MCP_DB_USER role, see ensure_roles.sh
#   ROUNDCUBE_DB       the webmail's (mua, Roundcube) own database: users, prefs,
#                      personal contacts, sessions; owned by the ROUNDCUBE_DB_USER role.
#                      Only created when ROUNDCUBE_DB_PASSWORD is set (its role needs it)
#
# Each service database has a knob of its own (the consuming image bakes the same
# default — they must match) instead of riding POSTGRES_EXTRA_DB.
#
# Blanks are skipped and existing databases are left alone. Replaces the old
# init-only multiple_db.sh, which ran once on an empty data directory and
# hardcoded a single name (F-03).
#
set -euo pipefail

LIST="${POSTGRES_DB},${POSTGRES_EXTRA_DB:-},${ADMINNG_DB:-},${MCP_DB:-}"
# the webmail's database exists only when its role will (ensure_roles.sh)
[ -n "${ROUNDCUBE_DB_PASSWORD:-}" ] && LIST="${LIST},${ROUNDCUBE_DB:-roundcube}"
seen=""

IFS=',' read -ra DBS <<< "$LIST"
for raw in "${DBS[@]}"; do
  db="$(echo "$raw" | xargs)"            # trim
  [ -n "$db" ] || continue
  case ",${seen}," in
    *",${db},"*) echo "db: database '${db}' already queued (duplicate entry)"; continue ;;
  esac
  seen="${seen}${seen:+,}${db}"
  # -d postgres: without it psql tries to connect to a database named after the role, which
  # does not exist yet on a fresh server (found while running D-26 on the dev stack)
  if [ "$(psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'")" = "1" ]; then
    echo "db: database '${db}' already exists"
  else
    createdb -U "$POSTGRES_USER" "${db}" && echo "db: created database '${db}'"
  fi
done

echo "db: INFO - all requested databases exist".
