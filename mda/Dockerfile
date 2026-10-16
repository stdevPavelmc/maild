FROM ubuntu:resolute

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
ENV REFRESHED_AT=2023-04-23
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        sed \
        netcat-openbsd \
        dovecot-pop3d \
        dovecot-imapd \
        dovecot-pgsql \
        dovecot-sieve \
        dovecot-lmtpd \
        dovecot-managesieved \
        spamassassin \
        python3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# resolute package notes: `netcat` is now a virtual package apt refuses to resolve (it
# ships `netcat-openbsd` and `netcat-traditional`), so the former is installed
# explicitly — it provides the `nc` the healthcheck uses. Everything else keeps its
# name, and the Ubuntu LTS jump drags Dovecot from 2.3.16 to 2.4.2: the /etc/dovecot
# tree below is 2.4 configuration (the 2.3 one is archived in dovecot-jammy/ for
# reference and as the diff baseline, see .agents/devops/base-os-upgrade.md).
# spamassassin moves to 4.0.2, the version amavis already runs (the container only
# uses sa-learn for the imapsieve learning scripts).
#
# The vmail uid/gid stays pinned at 5000 on purpose: it owns the mailboxes on the
# shared /home/vmail volume (mta and cron mount it too), so it must not follow the
# distro's dynamic allocation — unlike the service accounts of amavis/clamav.

RUN mkdir /home/vmail && \
    chown -R 5000:5000 /home/vmail && \
    groupadd -r postfix && \
    groupadd -g 5000 vmail && \
    useradd -d /home/vmail -g 5000 -u 5000 vmail && \
    useradd -r -d /var/spool/ -g postfix postfix

ADD dovecot/ /etc/dovecot

# NOTE: the imapsieve learning scripts are NOT compiled at build time:
# the vnd.dovecot.pipe & imapsieve extensions are only available when
# the sieve plugins are loaded at runtime, dovecot compiles the scripts
# lazily on first use inside the IMAP process.

# pipe helpers for the imapsieve learning scripts
COPY sieve-pipe/ /usr/lib/dovecot/sieve-pipe/
RUN chmod +x /usr/lib/dovecot/sieve-pipe/*

# daily mailbox quota report, started as a background loop by the entrypoint.
# It lives outside /etc/dovecot on purpose: configure.sh runs a blind
# `find /etc/dovecot/ -type f -exec sed -i` over every file in there, and this
# script needs no placeholders (it reads the env directly)
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

ADD docker-entrypoint.sh configure.sh check.sh /
RUN chmod +x /*.sh

# sendmail wrapper to log LMTP deliveries from sieve
COPY sendmail.py /usr/sbin/sendmail
RUN chmod +x /usr/sbin/sendmail

# log for the sendmail utility
RUN touch /var/log/sendmail-lmtp.log
RUN chmod 0666 /var/log/sendmail-lmtp.log

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano net-tools; \
    fi

VOLUME ["/certs", "/home/vmail"]

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=2m --retries=2 \
    CMD /check.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

# Ports pop, imap, sieve and sasl
EXPOSE 110 143 993 995 4190 12345

CMD ["dovecot"]


# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD MDA (Dovecot)" \
      org.opencontainers.image.description="MailD Mail Delivery Agent: IMAP/POP3/Sieve access, mail delivery and quotas" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-15"
