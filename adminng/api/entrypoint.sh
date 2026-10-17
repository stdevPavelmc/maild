#!/bin/sh
# AdminNG API entrypoint: bounded wait for Postgres + the adminng database, apply
# this image's own migrations, then hand over to the CMD (uvicorn).
#
# The adminng database itself is created by the *db* container
# (db/ensure_databases.sh creates ADMINNG_DB on every boot, next to POSTGRES_DB
# and POSTGRES_EXTRA_DB): database creation stays a db-container responsibility.
set -eu

echo "api: INFO - starting (db=${POSTGRES_HOST:-db}, catalogue=${POSTGRES_DB:-mailddb}, adminng=${ADMINNG_DB:-adminng})" >&2

python -m app.bootstrap

exec "$@"
