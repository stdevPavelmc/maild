FROM ubuntu:resolute

ENV DEBIAN_FRONTEND=noninteractive

# pg_dump MUST be >= the major version of the server in db/Dockerfile (postgres:15-bookworm in
# the working tree, postgres:18-bookworm is the canonical target): an older client refuses with
# "aborting because of server version mismatch" and writes nothing on stdout, so the dump came
# out as a 20-byte .gz that backup_db.sh reported as SUCCESS for weeks. Ubuntu jammy only ships
# postgresql-client 14 (hence the PGDG archive this image used to install); resolute ships
# postgresql-client 18, which is >= both the current server and the canonical one, so the distro
# package is used and the PGDG keyring/repository (and the curl it needed) are gone. Bump
# PG_CLIENT_MAJOR together with the server image — backup_db.sh also checks the pair at run time
# and reports a CRITICAL mail instead of a silent empty backup.
ARG PG_CLIENT_MAJOR=18

RUN apt-get update && \
    apt-get install -y \
        swaks \
        pflogsumm \
        bind9-host \
        spamassassin \
        cron \
        ca-certificates \
        postgresql-client-${PG_CLIENT_MAJOR} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    which cron && \
    pg_dump --version && \
    rm -rf /etc/cron.*/*

# resolute package notes: spamassassin moves 3.4.6 -> 4.0.2 (only sa-learn is used, and its
# "Learned tokens from N message(s)" output is unchanged), pflogsumm 1.1.5 -> 1.1.14 and it now
# lives in /usr/bin (cron/scripts/resume.sh resolves it from PATH for that reason), swaks
# 20201014 -> 20240103 and bind9-host 9.18 -> 9.20. The daemon itself is still cron 3.0pl1.

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

# --- MailD default configuration (new env schema) --------------------------------
# The deployment defaults for this service live HERE now: each image bakes only the
# variables its own entrypoint/scripts consume, as ENV defaults. Any same-named variable
# in the operator's env file (docker compose env_file / environment / docker run -e)
# overrides these at runtime — never rebuild the image to deploy a different value.
# Secrets are NEVER baked: POSTGRES_PASSWORD must come from the operator env file
# (dev: env.dev, prod: .env — see env.sample). The entrypoint dumps the whole
# environment into /etc/environment, from where the cron jobs source it.
# Full variable matrix: .agents/services/configuration.md.
ENV POSTGRES_HOST=db \
    POSTGRES_DB=mailddb \
    POSTGRES_USER=maild \
    MTA=mta \
    JUNK_RETENTION_DAYS=7 \
    SA_HAM_SAMPLE_PER_USER=25 \
    SA_HAM_SAMPLE_MAX=400 \
    OUTBOUND_ALERT_MESSAGES=150 \
    OUTBOUND_ALERT_IGNORE_USERS=

# the daemon stays in the foreground (CMD) and every job appends to /proc/1/fd/1; the healthcheck
# just proves cron is alive: it is the pidfile Debian's cron writes at start-up
HEALTHCHECK --interval=1m --timeout=5s --start-period=10s --retries=2 \
    CMD sh -c 'test -r /var/run/crond.pid && kill -0 "$(cat /var/run/crond.pid)"'

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
      org.opencontainers.image.created="2026-10-19"
