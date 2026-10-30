# MailD MCP (`mcp`)

Lets AI assistants (Claude, ChatGPT, Gemini CLI, Claude Code, …) read, organise and send mail
on behalf of a mailbox owner, through MCP (Streamable HTTP), a REST mirror and a web UI.

- Design and decisions: [`technical-proposal.md`](technical-proposal.md)
- Delivery status and log: [`progress.md`](progress.md)

## Current state: P0 (foundations)

- Django 6.1 + uvicorn, non-root (uid 10001), read-only rootfs.
- `GET /healthz` → 200 when the `mcp` database, the catalogue and the mda IMAP greeting answer.
- Boot (`manage.py mcp_boot`): waits for the `maild_provision` sentinel, migrates, seeds the
  `/adminmcp` admin on first boot, ensures the service mailbox.
- Mailbox access goes through a Dovecot master user over IMAP STARTTLS (`mda:143`); the
  container never mounts the mail storage.
- Database access only as the restricted `maild_mcp` role (`db/ensure_roles.sh`); the
  container never receives `POSTGRES_PASSWORD` (no `env_file:`, explicit allow-list).

## Variables

Mandatory: `DEFAULT_DOMAIN`, `MCP_SECRET_KEY`, `MCP_DB_PASSWORD`, `MCP_DOVECOT_MASTER_PASSWORD`.
Optional (image defaults in `Dockerfile`, documented in `env.sample`): `MCP_HOSTNAME`,
`MCP_ADMIN_USER/PASSWORD/EMAIL` (first boot only), `MCP_SERVICE_EMAIL/PASSWORD`,
`MCP_DOVECOT_MASTER_USER`, `MCP_DB`, `MCP_DB_USER`, `MCP_IMAP_*`, `MCP_WORKERS`, `MCP_DEBUG`.

## Operations

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml logs mcp        # boot log (generated passwords)
curl -s http://localhost:8085/healthz                                       # dev port
docker compose --env-file env.dev -f docker-compose-dev.yml exec mcp python manage.py showmigrations
```
