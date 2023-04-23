FROM ubuntu:jammy

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
ENV REFRESHED_AT 2023-04-23
ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install -y \
        sed \
        dovecot-pop3d \
        dovecot-imapd \
        dovecot-pgsql \
        dovecot-sieve \
        dovecot-lmtpd \
        dovecot-managesieved

RUN mkdir /home/vmail && \
    chown -R 5000:5000 /home/vmail && \
    groupadd -r postfix && \
    groupadd -g 5000 vmail && \
    useradd -d /home/vmail -g 5000 -u 5000 vmail && \
    useradd -r -d /var/spool/ -g postfix postfix

ADD dovecot/ /etc/dovecot

ADD docker-entrypoint.sh /docker-entrypoint.sh
ADD configure.sh /configure.sh
RUN chmod +x /docker-entrypoint.sh && chmod +x /configure.sh

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano net-tools; \
    fi

VOLUME ["/certs", "/home/vmail"]

ENTRYPOINT ["/docker-entrypoint.sh"]

# Ports pop, imap, sieve and sasl
EXPOSE 110 143 993 995 4190 12345

CMD ["dovecot"]
