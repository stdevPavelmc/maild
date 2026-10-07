FROM ubuntu:jammy

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
ENV REFRESHED_AT 2023-04-23
ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install -y \
        amavisd-new \
        p7zip-full \
        unrar-free \
        cabextract \
        spamassassin \
        gpg \
        netcat \
        bind9-host \
        postgresql-client && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/amavis/tmp /var/lib/amavis/db /var/lib/amavis/dkim /var/lib/amavis/virusmails && \
    chown -R amavis:amavis /var/lib/amavis

COPY amavis/ /etc/amavis/
COPY spamassassin /etc/spamassassin.dist

COPY check.sh docker-entrypoint.sh sa-update-loop.sh /
RUN chmod +x /*.sh

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
      org.opencontainers.image.created="2026-10-04"
