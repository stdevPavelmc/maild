FROM postgres:16-bookworm

LABEL image.app="MailD, http://github.com/stdevPavelmc/maild"
LABEL image.name="MailD Database, aka: Postgres"
LABEL org.opencontainers.image.description="MailD Database, aka: Postgres"
LABEL org.opencontainers.image.source=https://github.com/stdevPavelmc/maild
LABEL org.opencontainers.image.licenses=GPL-3.0
LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
LABEL last_modified="2024-08-11"

#repodebian

COPY multiple_db.sh /docker-entrypoint-initdb.d/
RUN chmod +x docker-entrypoint-initdb.d/multiple_db.sh

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/bin/pg_isready -U $POSTGRES_USER -h localhost  || exit 1
