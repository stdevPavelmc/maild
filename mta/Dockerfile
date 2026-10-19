FROM ubuntu:resolute

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
ENV REFRESHED_AT 2023-04-23
ENV DEBIAN_FRONTEND noninteractive

# resolute package notes: Postfix jumps 3.6.4 -> 3.10.6 and postfix-policyd-spf-python 2.9.3 ->
# 3.1.0 (same /usr/bin/policyd-spf binary and /etc/postfix-policyd-spf-python/policyd-spf.conf
# path, so master.cf needs no change). Two parameters MailD was using were obsoleted in 3.9
# (smtpd_tls_dh1024_param_file, smtpd_tls_eecdh_grade) and compatibility_level follows the value
# the resolute package ships (3.9) — see postfix/main.cf.s. `netcat` and `net-tools` used to be
# installed here, but nothing in this image ever used `nc` or `netstat` (the healthcheck reads
# the master pidfile, the scripts use `host`/`psql`/`postconf`), so both are gone; on resolute
# `netcat` is a virtual package anyway. postgresql-client resolves to 18 (>= the 15 catalogue).
RUN apt-get update && \
    apt-get install -y \
        postfix \
        postfix-pcre \
        postfix-pgsql \
        postfix-policyd-spf-python  \
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

# --- MailD default configuration (new env schema) --------------------------------
# The deployment defaults for this service live HERE now: each image bakes only the
# variables its own entrypoint/scripts consume, as ENV defaults. Any same-named variable
# in the operator's env file (docker compose env_file / environment / docker run -e)
# overrides these at runtime — never rebuild the image to deploy a different value.
# Secrets are NEVER baked: POSTGRES_PASSWORD must come from the operator env file
# (dev: env.dev, prod: .env — see env.sample). DEFAULT_DOMAIN / MAIL_ADMIN_USER are
# deployment values passed by the compose file; RELAY / ALWAYS_BCC / POSTMASTER_ABUSE_
# SETUP and the debug switches are deliberately unset (unset ⇒ feature off).
# AMAVIS/MDA/MUA/ADMIN are the fixed service hostnames (never rename them).
# Full variable matrix: .agents/services/configuration.md.
ENV POSTGRES_HOST=db \
    POSTGRES_DB=mailddb \
    POSTGRES_USER=maild \
    MAX_MESSAGESIZE=34865152 \
    SPF_ENABLE=True \
    DNSBL_ENABLE=true \
    DNSBL_LIST=zen.spamhaus.org=127.0.0.[2..11]*2,psbl.surriel.com,bl.spamcop.net,bl.spameatingmonkey.net \
    SMTP_TARPIT_DELAY=2 \
    PEER_WAIT_TIMEOUT=120 \
    PEER_WATCH_INTERVAL=30 \
    AMAVIS=amavis \
    MDA=mda \
    MUA=MUA \
    ADMIN=admin \
    AUTO_PROVISION=yes \
    PROVISION_VERSION=1 \
    PROVISION_WAIT_TIMEOUT=180

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano ; \
    fi

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=2m --retries=2 \
    CMD /check.sh

VOLUME ["/certs", "/home/vmail", "/var/spool"]

ENTRYPOINT ["/docker-entrypoint.sh"]

# Ports smtp, smtps, submission
EXPOSE 25 465 587

CMD ["postfix"]


# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD MTA (Postfix)" \
      org.opencontainers.image.description="MailD Mail Transport Agent: SMTP in/out, submission and content-filter relay hooks" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-19"
