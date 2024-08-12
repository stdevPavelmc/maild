FROM ubuntu:jammy

LABEL image.app="MailD, http://github.com/stdevPavelmc/maild"
LABEL image.name="MailD Mail Delivery Agent, aka: Dovecot"
LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
LABEL last_modified="2024-08-11"

#repoubuntu

ENV REFRESHED_AT=2024-07-15
ENV DEBIAN_FRONTEND=noninteractive

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano net-tools; \
    fi

RUN apt-get update && \
    apt-get install -y \
        sed \
        netcat \
        dovecot-pop3d \
        dovecot-imapd \
        dovecot-pgsql \
        dovecot-sieve \
        dovecot-lmtpd \
        dovecot-managesieved && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /home/vmail && \
    chown -R 5000:5000 /home/vmail && \
    groupadd -r postfix && \
    groupadd -g 5000 vmail && \
    useradd -d /home/vmail -g 5000 -u 5000 vmail && \
    useradd -r -d /var/spool/ -g postfix postfix

ADD dovecot/ /etc/dovecot

ADD docker-entrypoint.sh configure.sh check.sh /
RUN chmod +x /*.sh

VOLUME ["/certs", "/home/vmail"]

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=2m --retries=2 \
    CMD /check.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

# Ports pop, imap, sieve and sasl
EXPOSE 110 143 993 995 4190 12345

CMD ["dovecot"]

