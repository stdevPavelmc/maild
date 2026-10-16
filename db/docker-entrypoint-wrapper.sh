#!/bin/bash
#
# Starts the stock Postgres entrypoint in the background, waits for readiness,
# ensures the extra databases, and then waits on the Postgres process so signals
# and PID-1 semantics stay correct (docker stop keeps doing a clean shutdown).
#
set -uo pipefail

# The stock entrypoint by absolute path so the Postgres bootstrap, POSTGRES_*
# handling and signal semantics stay untouched.
/usr/local/bin/docker-entrypoint.sh postgres &
pid=$!

# forward stop signals to Postgres (clean shutdown on `docker stop`)
forward_term() { kill -TERM "$pid" 2>/dev/null || true; }
trap forward_term TERM INT

# wait for readiness (bounded: never hang the container forever)
n=0
until pg_isready -U "$POSTGRES_USER" -h 127.0.0.1 >/dev/null 2>&1; do
  n=$((n+1))
  if [ "$n" -gt 300 ]; then
    echo "db: FATAL - postgres did not become ready within $n seconds" >&2
    kill -TERM "$pid" 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

echo "db: INFO - postgres is ready, ensuring extra databases"
/usr/local/bin/ensure_databases.sh || echo "db: WARNING - database ensure failed"

# schema migrations (idempotent): the maild_provision sentinel lives here
echo "db: INFO - applying schema migrations"
/usr/local/bin/migrate.sh || echo "db: WARNING - database migrations failed"

# keep the container alive while Postgres runs; `wait` returns early when a trap
# fires, so loop until the process is really gone
while kill -0 "$pid" 2>/dev/null; do
  wait "$pid" || true
done
