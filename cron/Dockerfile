FROM ubuntu:jammy

LABEL image.app="MailD, http://github.com/stdevPavelmc/maild"
LABEL image.name="MailD Cron daemon: programmed tasks"
LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
LABEL last_modified="2024-08-11"

#repoubuntu

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        swaks \
        pflogsumm \
        bind9-host \
        postgresql-client \
        cron && \
    rm -rf /var/lib/apt/lists/* && \
    which cron && \
    rm -rf /etc/cron.*/*

# entrypoint to asure vars are set
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# copy own crontab
COPY ./crontab /etc/crontab
RUN chmod 0644 /etc/crontab

# copy scripts
RUN mkdir /scripts
COPY ./scripts/* /scripts/
RUN chmod +x /scripts/*.sh

# set entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]

# https://manpages.ubuntu.com/manpages/trusty/man8/cron.8.html
# -f | Stay in foreground mode, don't daemonize.
# -L loglevel | Tell  cron  what to log about jobs 
#  (errors are logged regardless of this value) as the sum of
#  the following values:
CMD ["cron","-f", "-L", "2"]

