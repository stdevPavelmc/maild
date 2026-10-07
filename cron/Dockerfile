FROM ubuntu:jammy

ENV DEBIAN_FRONTEND=noninteractive

# pg_dump MUST be >= the major version of the server in db/Dockerfile (postgres:15-bookworm):
# an older client refuses with "aborting because of server version mismatch" and writes nothing
# on stdout, so the dump came out as a 20-byte .gz that backup_db.sh reported as SUCCESS for
# weeks. Ubuntu jammy only ships postgresql-client 14, hence the PGDG archive for the matching
# client. Bump PG_CLIENT_MAJOR together with the server image (backup_db.sh also checks the pair
# at run time and reports a CRITICAL mail instead of a silent empty backup).
ARG PG_CLIENT_MAJOR=15
ARG PGDG_SUITE=jammy-pgdg

RUN apt-get update && \
    apt-get install -y \
        swaks \
        pflogsumm \
        bind9-host \
        spamassassin \
        cron \
        ca-certificates \
        curl && \
    install -d /etc/apt/keyrings && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /etc/apt/keyrings/pgdg.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt ${PGDG_SUITE} main" \
        > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y postgresql-client-${PG_CLIENT_MAJOR} && \
    apt-get purge -y postgresql-client postgresql-client-14 curl && \
    apt-get autoremove -y --purge && \
    rm -rf /var/lib/apt/lists/* && \
    which cron && \
    pg_dump --version && \
    rm -rf /etc/cron.*/*

# entrypoint to asure vars are set
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# copy own crontab
COPY ./crontab /etc/crontab
RUN chmod 0644 /etc/crontab

# copy scripts
RUN mkdir /scripts
COPY ./scripts/* /scripts/
RUN chmod +x /scripts/*.sh

# set entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]

# https://manpages.ubuntu.com/manpages/trusty/man8/cron.8.html
# -f | Stay in foreground mode, don't daemonize.
# -L loglevel | Tell  cron  what to log about jobs 
#  (errors are logged regardless of this value) as the sum of
#  the following values:
CMD ["cron","-f", "-L", "2"]


# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD maintenance jobs" \
      org.opencontainers.image.description="MailD scheduled maintenance: db backups, traffic resume, Bayes learning and Junk purge" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-04"
