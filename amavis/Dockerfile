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
        netcat-openbsd \
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

CMD ["amavis"]
