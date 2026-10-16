FROM postgres:18-trixie

# PostgreSQL data directories are major-incompatible: a cluster initialised by 15 cannot be
# started by 18 (and vice versa). This image therefore always initialises a *fresh* cluster and
# the catalogue is moved between majors with a logical dump/restore — the step-by-step procedure
# and its caveats live in db_upgrade.md (repository root). The version here must track what that
# document was validated against; .agents/devops/base-images.md carries the canonical rule.

# Extra databases are ensured on *every* boot by the entrypoint wrapper; schema migrations
# (the maild_provision sentinel) are applied right after, by migrate.sh.

# Postgres 18 images changed the default data layout to major-version directories
# (PGDATA=/var/lib/postgresql/18/docker) and *refuse to start* when they find the legacy
# /var/lib/postgresql/data mount ("in 18+, these Docker images are configured to store database
# data in a format which is compatible with pg_ctlcluster ... Counter to that, there appears to be
# PostgreSQL data in: /var/lib/postgresql/data (unused mount/volume)"). MailD keeps its historical
# single mount at /var/lib/postgresql/data — the volumes of existing deployments stay valid — so
# PGDATA is pinned back to it explicitly, which is the documented opt-out.
ENV PGDATA=/var/lib/postgresql/data
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
      org.opencontainers.image.created="2026-10-16"
