FROM ubuntu:resolute

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
ENV REFRESHED_AT 2023-04-23
ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install --no-install-recommends -y -qq \
        clamav-daemon \
        clamav-freshclam \
        libclamunrar12 \
        netcat-openbsd \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# The packages allocate the clamav user/group ids dynamically: jammy landed on 101:102,
# resolute on 100:101. MailD pins them back to 101:102, because the dev volume is owned
# as 101:102 (bootstrap-dev.sh) and clamd runs as that uid below -- a drifted id would
# leave the signature database unreadable.
RUN groupmod -g 102 clamav && \
    usermod -u 101 -g 102 clamav

# permission juggling
RUN mkdir -p /var/run/clamav && \
    chown clamav:clamav /var/run/clamav /var/lib/clamav && \
    chmod 750 /var/run/clamav /var/lib/clamav

COPY clamav/ /etc/clamav/
COPY docker-entrypoint.sh check.sh /

RUN chown -R clamav:clamav /etc/clamav
RUN chmod +x /*.sh 

# addd amavis compatibility
RUN groupadd -g 114 amavis && \
    useradd -r -u 114 -g amavis -d /var/lib/amavis -s /usr/sbin/nologin amavis && \
    usermod -a -G clamav amavis

VOLUME ["/var/lib/clamav"]
VOLUME ["/var/lib/amavis"]

EXPOSE 3310

USER clamav

# Set the HEALTHCHECK command
HEALTHCHECK --interval=1m --timeout=5s --start-period=2m --retries=2 \
    CMD /check.sh

CMD ["/docker-entrypoint.sh"]


# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD antivirus (ClamAV)" \
      org.opencontainers.image.description="MailD ClamAV antivirus scanning engine for the content filter" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-15"
