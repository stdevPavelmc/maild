FROM ubuntu:jammy

LABEL image.app="MailD, http://github.com/stdevPavelmc/maild"
LABEL image.name="MailD Mail Transport Agent, aka: Postfix"
LABEL org.opencontainers.image.description="MailD Mail Transport Agent, aka: Postfix"
LABEL org.opencontainers.image.source=https://github.com/stdevPavelmc/maild
LABEL org.opencontainers.image.licenses=GPL-3.0
LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
LABEL last_modified="2024-08-11"

#repoubuntu

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        postfix \
        postfix-pcre \
        postfix-pgsql \
        postfix-policyd-spf-python  \
        net-tools \
        netcat \
        postgresql-client \
        bind9-host && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /home/vmail && \
    chown -R 5000:5000 /home/vmail && \
    groupadd -g 5000 vmail && \
    useradd -d /home/vmail -g 5000 -u 5000 vmail

ADD postfix /etc/postfix

ADD docker-entrypoint.sh check.sh /
RUN chmod +x /*.sh

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano netcat-openbsd ; \
    fi

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=2m --retries=2 \
    CMD /check.sh

VOLUME ["/certs", "/home/vmail", "/var/spool"]

ENTRYPOINT ["/docker-entrypoint.sh"]

# Ports smtp, smtps, submission
EXPOSE 25 465 587

CMD ["postfix"]

