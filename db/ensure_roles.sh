#!/bin/bash
#
# MailD MCP (proposal mcp/technical-proposal.md §9.2, D8): ensure the restricted database role
# the mcp container connects as. Runs on *every* boot from the db entrypoint wrapper, after
# ensure_databases.sh (the MCP_DB exists) and migrate.sh (the SECURITY DEFINER function exists).
#
# Only when MCP_DB_PASSWORD is set: without it the MCP is not deployed and nothing happens.
#
# What the role gets (and nothing else):
#   - owner of MCP_DB: full control of its own database only;
#   - on the catalogue (POSTGRES_DB): column-level SELECT on domain/mailbox (never
#     mailbox.password) and alias_domain, SELECT on the maild_provision sentinel, EXECUTE on
#     maild_mcp_ensure_service_mailbox() — its only write path (003_mcp_service_mailbox.sql).
#
# Declarative: the password is re-asserted (rotation = change the env file + restart db) and
# the catalogue grants are revoked and re-granted on every boot, so a grant dropped from this
# file is also dropped from existing deployments. The password reaches psql as a variable on
# stdin, never on a command line, and is never echoed.
#
set -euo pipefail

if [ -z "${MCP_DB_PASSWORD:-}" ]; then
  echo "db: INFO - MCP_DB_PASSWORD not set, skipping the MCP role"
  exit 0
fi

ROLE="${MCP_DB_USER:-maild_mcp}"
MCPDB="${MCP_DB:-mcp}"

psql_su() { # <database> — SQL on stdin (variables are only interpolated from stdin/files)
  psql -U "$POSTGRES_USER" -d "$1" -X -q -v ON_ERROR_STOP=1 \
       -v role="$ROLE" -v pw="$MCP_DB_PASSWORD" -v mcpdb="$MCPDB" -v catdb="$POSTGRES_DB"
}

# cluster level: the role itself and its own database
psql_su postgres <<'SQL'
SELECT format(CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
                   THEN 'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L'
                   ELSE 'CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L'
              END, :'role', :'pw') \gexec
ALTER DATABASE :"mcpdb" OWNER TO :"role";
REVOKE ALL ON DATABASE :"mcpdb" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"mcpdb" TO :"role";
GRANT CONNECT ON DATABASE :"catdb" TO :"role";
SQL

# catalogue: read-only, column level, no password column
psql_su "$POSTGRES_DB" <<'SQL'
BEGIN;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM :"role";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM :"role";
GRANT USAGE ON SCHEMA public TO :"role";
GRANT SELECT (domain, active) ON public.domain TO :"role";
GRANT SELECT (username, domain, local_part, name, active) ON public.mailbox TO :"role";
-- P2: "external recipient" = not an active domain or active alias domain (send confirmation)
GRANT SELECT (alias_domain, target_domain, active) ON public.alias_domain TO :"role";
GRANT SELECT ON public.maild_provision TO :"role";
REVOKE ALL ON FUNCTION public.maild_mcp_ensure_service_mailbox(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.maild_mcp_ensure_service_mailbox(text, text, text) TO :"role";
COMMIT;
SQL

echo "db: INFO - MCP role '${ROLE}' ensured (owner of '${MCPDB}', read-only column grants on '${POSTGRES_DB}')"
