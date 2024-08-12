FROM ubuntu:jammy

LABEL image.app="MailD, http://github.com/stdevPavelmc/maild"
LABEL image.name="MailD filtering and safeguarding, aka: Amavis-NG"
LABEL org.opencontainers.image.description="MailD filtering and safeguarding, aka: Amavis-NG"
LABEL org.opencontainers.image.source=https://github.com/stdevPavelmc/maild
LABEL org.opencontainers.image.licenses=GPL-3.0
LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
LABEL last_modified="2024-08-11"

#repoubuntu

ENV DEBIAN_FRONTEND=noninteractive

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

RUN mkdir -p {/var/lib/amavis/tmp, /var/lib/amavis/db, /var/lib/amavis/dkim} && \
    chown -R amavis:amavis /var/lib/amavis

COPY amavis/ /etc/amavis/
COPY check.sh docker-entrypoint.sh /
RUN chmod +x /*.sh

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano ; \
    fi

VOLUME ["/var/lib/amavis", "/var/lib/spamassassin"]

EXPOSE 10024

ENTRYPOINT ["/docker-entrypoint.sh"]

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=30s --retries=2 \
    CMD /check.sh

CMD ["amavis"]
