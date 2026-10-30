FROM python:3.14-slim-trixie

# MailD MCP: MCP server + REST mirror + web UI over the mailboxes (mcp/technical-proposal.md).
# P0 skeleton: Django + uvicorn, /healthz, admin seed and the service mailbox. The SPA build
# stage (node:26-alpine) arrives with the web UI in P1.

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    HOME=/tmp

# --- MailD default configuration (new env schema) --------------------------------
# Only what this image consumes; the operator env file overrides any of them. Secrets are
# NEVER baked: MCP_SECRET_KEY, MCP_DB_PASSWORD and MCP_DOVECOT_MASTER_PASSWORD come from the
# operator env file (dev: env.dev, prod: .env — see env.sample). MCP_HOSTNAME, MCP_ADMIN_EMAIL
# and MCP_SERVICE_EMAIL default from DEFAULT_DOMAIN at runtime (maild_mcp/settings.py).
# Full variable matrix: .agents/services/configuration.md.
ENV POSTGRES_HOST=db \
    POSTGRES_PORT=5432 \
    POSTGRES_DB=mailddb \
    MCP_DB=mcp \
    MCP_DB_USER=maild_mcp \
    MAIL_ADMIN_USER=sysadmin \
    MCP_ADMIN_USER=admin \
    PROVISION_WAIT_TIMEOUT=180 \
    MCP_IMAP_HOST=mda \
    MCP_IMAP_PORT=143 \
    MCP_IMAP_CA_FILE=/certs/mail.crt \
    MCP_DOVECOT_MASTER_USER=mcp \
    MCP_LOG_DIR=/var/log/maild-mcp \
    MCP_WORKERS=2

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./
COPY docker-entrypoint.sh /docker-entrypoint.sh

# non-root (uid 10001), read-only rootfs friendly: nothing under /app is written at runtime,
# HOME/tmp is a tmpfs and the only writable path is the log volume
RUN chmod +x /docker-entrypoint.sh && \
    groupadd -g 10001 mcp && \
    useradd -u 10001 -g 10001 -d /tmp -s /usr/sbin/nologin -M mcp && \
    mkdir -p /var/log/maild-mcp && chown 10001:10001 /var/log/maild-mcp

USER 10001:10001

VOLUME ["/var/log/maild-mcp"]
EXPOSE 8080

HEALTHCHECK --interval=1m --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=4).status == 200 else 1)" || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["uvicorn"]

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD MCP" \
      org.opencontainers.image.description="MailD MCP server: lets AI assistants read, organise and send mail on behalf of a mailbox owner (MCP + REST + web UI)" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-29"
