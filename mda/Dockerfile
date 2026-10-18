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
        postgresql-client \
        python3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# resolute package notes: `netcat` is now a virtual package apt refuses to resolve (it
# ships `netcat-openbsd` and `netcat-traditional`), so the former is installed
# explicitly — it provides the `nc` the healthcheck uses. `postgresql-client` is
# the rehash-on-login helper's UPDATE channel (scripts/rehash-password.sh, wired
# as a postlogin service in 10-master.conf): it migrates legacy md5crypt ($1$)
# password hashes to Argon2id as users authenticate (2026-10 audit F-18; the
# weak-scheme window ends 2027-02-01). Everything else keeps its
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

# --- MailD default configuration (new env schema) --------------------------------
# The deployment defaults for this service live HERE now: each image bakes only the
# variables its own entrypoint/scripts consume, as ENV defaults. Any same-named variable
# in the operator's env file (docker compose env_file / environment / docker run -e)
# overrides these at runtime — never rebuild the image to deploy a different value.
# Secrets are NEVER baked: POSTGRES_PASSWORD must come from the operator env file
# (dev: env.dev, prod: .env — see env.sample). DEFAULT_DOMAIN and MAIL_ADMIN_USER are
# deployment values passed by the compose file (they have no default here on purpose).
# COUNTRY/STATE/CITY/ORG/OU feed the self-signed certificate subject (first boot only).
# PASSWORD_SCHEME is the stack-wide hash scheme (argon2id default; md5crypt is the
# legacy escape hatch that ends 2027-02-01): the mda only reads it to decide whether
# rehash-on-login may migrate legacy $1$ rows (it is skipped under md5crypt).
# Full variable matrix: .agents/services/configuration.md.
ENV POSTGRES_HOST=db \
    POSTGRES_DB=mailddb \
    POSTGRES_USER=maild \
    PASSWORD_SCHEME=argon2id \
    DEFAULT_MAILBOX_SIZE=200M \
    QUOTA_REPORT_HOUR=0 \
    QUOTA_REPORT_MINUTE=1 \
    COUNTRY=JM \
    STATE=Kingston \
    CITY=Kingston \
    ORG=MailD \
    OU=MailD

ADD dovecot/ /etc/dovecot

# rehash-creds.sh carries the catalogue credentials for the rehash-on-login
# helper (substituted by configure.sh at first boot); readable only by root
# and the vmail group, which is what the postlogin script runs as.
RUN chown root:vmail /etc/dovecot/rehash-creds.sh && \
    chmod 0640 /etc/dovecot/rehash-creds.sh

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
      org.opencontainers.image.created="2026-10-18"
