FROM ubuntu:resolute

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
ENV REFRESHED_AT 2023-04-23
ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install -y \
        amavisd-new \
        7zip \
        unrar-free \
        cabextract \
        bzip2 \
        xz-utils \
        lrzip \
        lzop \
        lz4 \
        rpm2cpio \
        spamassassin \
        gpg \
        netcat-openbsd \
        bind9-host \
        postgresql-client && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# resolute package notes: `netcat` is now a virtual package apt refuses to resolve (install
# `netcat-openbsd` instead) and `p7zip-full` is gone, replaced by `7zip` (it Provides
# p7zip-full and still ships /usr/bin/7z + /usr/bin/p7zip, what amavisd's unpacker looks up).
#
# Decompressor helpers: amavisd's @decoders table shells out to `bzip2 -d` (bz2),
# `xz -dc` (xz), `xz -dc --format=lzma` (lzma), `lrzip -q -k -d -o -` (lrz), `lzop -d`
# (lzo), `lz4c -d` (lz4) and `rpm2cpio` (rpm). Without them the matching attachment types
# are flagged as **UNCHECKED** instead of being extracted and scanned. Binary names differ
# from the distro package names: `xz` comes from xz-utils and `lz4c` is a symlink shipped
# by the `lz4` package (there is no package named `lz4c` nor `xz`).

# No uid/gid pinning here on purpose: the distro-allocated amavis ids win (jammy: 101:101,
# resolute: 994:994). bootstrap-dev.sh owns ldata/amavis with the ids this image uses, and a
# production *named* volume is pre-populated from the image — an existing one keeps the old
# owner and needs a one-off chown (see Changelog.md). See
# .agents/devops/base-os-upgrade.md guardrail 8.

RUN mkdir -p /var/lib/amavis/tmp /var/lib/amavis/db /var/lib/amavis/dkim /var/lib/amavis/virusmails && \
    chown -R amavis:amavis /var/lib/amavis

COPY amavis/ /etc/amavis/
COPY spamassassin /etc/spamassassin.dist

COPY check.sh docker-entrypoint.sh sa-update-loop.sh /
RUN chmod +x /*.sh

# --- MailD default configuration (new env schema) --------------------------------
# The deployment defaults for this service live HERE now: each image bakes only the
# variables its own entrypoint/scripts consume, as ENV defaults. Any same-named variable
# in the operator's env file (docker compose env_file / environment / docker run -e)
# overrides these at runtime — never rebuild the image to deploy a different value.
# Secrets are NEVER baked: POSTGRES_PASSWORD must come from the operator env file
# (dev: env.dev, prod: .env — see env.sample). MTA/CLAMAV/CRON are the fixed service
# hostnames (never rename them). SA_BAYES_PATH and the debug switches are deliberately
# unset (the entrypoint carries their fallbacks). Full variable matrix:
# .agents/services/configuration.md.
ENV POSTGRES_HOST=db \
    POSTGRES_DB=mailddb \
    POSTGRES_USER=maild \
    MTA=mta \
    CLAMAV=clamav \
    CRON=cron \
    SPAM_FILTER_ENABLED=yes \
    AV_ENABLED=yes \
    DKIM_SIGNING=yes \
    SA_AUTOLEARN_NONSPAM=0.1 \
    SA_AUTOLEARN_SPAM=10 \
    JUNK_RETENTION_DAYS=7 \
    SA_HAM_SAMPLE_PER_USER=25 \
    SA_HAM_SAMPLE_MAX=400 \
    AUTO_PROVISION=yes \
    PROVISION_VERSION=1 \
    PROVISION_WAIT_TIMEOUT=180

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano ; \
    fi

VOLUME ["/var/lib/amavis", "/var/lib/spamassassin", "/etc/spamassassin"]

EXPOSE 10024

ENTRYPOINT ["/docker-entrypoint.sh"]

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=30s --retries=2 \
    CMD /check.sh

CMD ["amavis"]

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD content filter (Amavis + SpamAssassin)" \
      org.opencontainers.image.description="MailD content filtering relay: antivirus, anti-spam and DKIM signing" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-24"
