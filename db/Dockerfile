FROM postgres:15-bookworm

# Extra databases are ensured on *every* boot by the entrypoint wrapper; schema migrations
# (the maild_provision sentinel) are applied right after, by migrate.sh.
COPY ensure_databases.sh /usr/local/bin/ensure_databases.sh
COPY migrate.sh /usr/local/bin/migrate.sh
COPY migrations/ /usr/local/share/maild/migrations/
COPY docker-entrypoint-wrapper.sh /usr/local/bin/docker-entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/ensure_databases.sh /usr/local/bin/migrate.sh /usr/local/bin/docker-entrypoint-wrapper.sh

# the wrapper starts the stock entrypoint, waits, ensures the DBs, then waits on postgres
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-wrapper.sh"]
CMD ["postgres"]

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/bin/pg_isready -U $POSTGRES_USER -d postgres -h localhost  || exit 1

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD PostgreSQL catalogue" \
      org.opencontainers.image.description="MailD PostgreSQL database backend: domains, mailboxes, aliases and quotas catalogue" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-04"
