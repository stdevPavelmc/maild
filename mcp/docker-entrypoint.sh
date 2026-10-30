#!/bin/sh
# MailD MCP entrypoint (proposal §12): run the boot sequence, then hand PID 1 to uvicorn.
#
# mcp_boot waits (bounded by PROVISION_WAIT_TIMEOUT) for the db and the maild_provision
# sentinel, migrates the MCP database under an advisory lock, seeds the admin on first boot and
# ensures the service mailbox. A failure there stops the container with the reason in the log
# (restart policy retries), so a half-configured MCP never serves requests.
set -eu

cd /app

if [ "${1:-}" = "uvicorn" ] ; then
    python manage.py mcp_boot
    exec uvicorn asgi:application --host 0.0.0.0 --port 8080 \
        --workers "${MCP_WORKERS:-2}" --lifespan off --no-server-header --log-level info
fi

exec "$@"
