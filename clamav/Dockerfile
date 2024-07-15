FROM ubuntu:jammy

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"

ENV REFRESHED_AT=2023-04-23
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install --no-install-recommends -y -qq \
        clamav-daemon \
        clamav-freshclam \
        libclamunrar9 \
        netcat \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

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

