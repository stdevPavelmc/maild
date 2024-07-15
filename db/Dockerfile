FROM postgres:16-bookworm

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"

COPY multiple_db.sh /docker-entrypoint-initdb.d/
RUN chmod +x docker-entrypoint-initdb.d/multiple_db.sh

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/bin/pg_isready -U $POSTGRES_USER -h localhost  || exit 1
