#!/bin/bash
#
# MailD-MCP (D-26): ensure the databases exist on *every* boot.
#
# Three sources, all optional except POSTGRES_DB:
#   POSTGRES_DB        the PostfixAdmin catalogue (mailddb)
#   POSTGRES_EXTRA_DB  comma-separated extras consumed by other services
#                      (contacts — SnappyMail's address book)
#   ADMINNG_DB         AdminNG's own state database (devices, sessions, TOTP,
#                      audit trail)
#
# ADMINNG_DB is a variable of its own on purpose: POSTGRES_EXTRA_DB is a *list*
# here, but mua/config-setup.php reads the same variable as a SINGLE database
# name for the SnappyMail contacts DSN. Appending "adminng" to that list would
# silently break the webmail's address book, so AdminNG gets its own knob (the
# api image bakes the same default — they must match).
#
# Blanks are skipped and existing databases are left alone. Replaces the old
# init-only multiple_db.sh, which ran once on an empty data directory and
# hardcoded a single name (F-03).
#
set -euo pipefail

LIST="${POSTGRES_DB},${POSTGRES_EXTRA_DB:-},${ADMINNG_DB:-}"
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
