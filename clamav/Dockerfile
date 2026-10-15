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

# No uid/gid pinning here on purpose: the distro-allocated clamav ids win (jammy: 101:102,
# resolute: 100:101). The dev testbed follows whatever this image uses (bootstrap-dev.sh owns
# ldata/clamav with those ids) and the production named volume is pre-populated from the image,
# so it inherits them too. See .agents/devops/base-os-upgrade.md guardrail 8.

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
