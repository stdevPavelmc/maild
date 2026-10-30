# MailD MCP (`mcp`)

Lets AI assistants (Claude, ChatGPT, Gemini CLI, Claude Code, …) read, organise and send mail
on behalf of a mailbox owner, through MCP (Streamable HTTP), a REST mirror and a web UI.

- Design and decisions: [`technical-proposal.md`](technical-proposal.md)
- Delivery status and log: [`progress.md`](progress.md)

## Current state: P0–P4 done (see progress.md)

- Django 6.1 + uvicorn + MCP SDK 2.3, non-root (uid 10001), read-only rootfs.
- `GET /healthz` → 200 when the `mcp` database, the catalogue and the mda IMAP greeting answer.
- User page (`/`, React SPA in `ui/`, EN/ES): sign in with the mailbox password (ALTCHA),
  MCP switch, secondary addresses (magic link), access tokens.
- MCP endpoint `POST /api/v1/mcp` (Streamable HTTP, stateless), `Authorization: Bearer
  mdmcp_pat_…` or an OAuth access token, 21 tools:
  - read (`mail.read`): `list_accounts`, `list_folders`, `check_new_mail`, `search_emails`,
    `get_email`, `get_thread`, `get_attachment`, `get_quota`;
  - modify (`mail.modify`): `mark_emails`, `move_emails`, `create_folder`, `rename_folder`, `save_draft`;
  - trash/spam (`mail.trash`, two-step with a `confirm` handle): `report_spam`, `not_spam`,
    `trash_emails`, `restore_from_trash`, `delete_folder` — nothing is ever deleted for good;
  - send (`mail.send`): `send_email`, `reply_email`, `forward_email` via amavis:10026, copy in
    Sent, rate-limited, confirmation for recipients outside the server (preference).
- User preferences: confirmation mode, default sender, signature, folders hidden from agents,
  attachment download, email notifications; Activity list.
- Admin panel `/adminmcp`: sign-in with a mailed code, recovery link, admin email/password
  change, domains allow-list, logging, user policy, master tokens (`X-MailD-Act-As` header,
  always audited), service email (internal or external SMTP + Test), logs viewer. CLI fallback:
  `manage.py mcp_admin_reset`.
- OAuth 2.1 for "Add custom connector" (Claude, ChatGPT): discovery from the 401
  (`/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`), PKCE S256,
  client ID metadata documents or dynamic registration, consent page `/consent`, 1 h access /
  30 d rotating refresh tokens; connected apps show in the token list.
- Mailbox access goes through a Dovecot master user over IMAP STARTTLS (`mda:143`, certificate
  pinned); the container never mounts the mail storage.
- Database access only as the restricted `maild_mcp` role (`db/ensure_roles.sh`); the
  container never receives `POSTGRES_PASSWORD` (no `env_file:`, explicit allow-list).
- Domains start denied: `manage.py mcp_domains allow <domain>` (admin panel in P3).

## Variables

Mandatory: `DEFAULT_DOMAIN`, `MCP_SECRET_KEY`, `MCP_DB_PASSWORD`, `MCP_DOVECOT_MASTER_PASSWORD`.
Optional (image defaults in `Dockerfile`, documented in `env.sample`): `MCP_HOSTNAME`,
`MCP_ADMIN_USER/PASSWORD/EMAIL` (first boot only), `MCP_SERVICE_EMAIL/PASSWORD`,
`MCP_DOVECOT_MASTER_USER`, `MCP_DB`, `MCP_DB_USER`, `MCP_IMAP_*`, `MCP_PUBLIC_URL`,
`MCP_TRUSTED_PROXIES`, `MCP_SMTP_HOST/PORT`, `MCP_ACCESS_TTL`, `MCP_USER_SESSION_TTL`,
`MCP_SEND_RATE_RECIPIENTS`, `MCP_SEND_RATE_WINDOW`, `MAX_MESSAGESIZE`, `MCP_ADMIN_SESSION_TTL`,
`MCP_MASTER_TOKEN_MAX_TTL`, `MCP_OAUTH_ACCESS_TTL`, `MCP_OAUTH_REFRESH_TTL`, `MCP_WORKERS`,
`MCP_DEBUG`. Dev compose only: `MCP_CIMD_DEV_ALLOW` (never in production).

## Operations

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml logs mcp        # boot log (generated passwords)
curl -s http://localhost:8085/healthz                                       # dev port
docker compose --env-file env.dev -f docker-compose-dev.yml exec mcp python manage.py showmigrations
docker compose --env-file env.dev -f docker-compose-dev.yml exec mcp python manage.py mcp_domains list
docker compose --env-file env.dev -f docker-compose-dev.yml exec mcp python manage.py mcp_jobs --once
docker compose --env-file env.dev -f docker-compose-dev.yml exec mcp python manage.py mcp_admin_reset   # new admin password, printed once
```

Connect an MCP client (Claude Code example, dev stack):

```bash
claude mcp add --transport http maild-dev http://localhost:8085/api/v1/mcp --header "Authorization: Bearer mdmcp_pat_…"
```

Or without a token: add the URL alone (`claude mcp add --transport http maild-dev
http://localhost:8085/api/v1/mcp`, or "Add custom connector" in Claude / ChatGPT with
`https://<MCP_HOSTNAME>/api/v1/mcp`) and the client discovers the OAuth server, opens the
consent page and stores the tokens itself. Hosted clients (claude.ai, ChatGPT) need the
public HTTPS host: the dev stack on localhost only serves local clients.
