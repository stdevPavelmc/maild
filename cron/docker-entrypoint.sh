#!/bin/sh

# Dump the environment in a form `/etc/environment` can be sourced verbatim: the raw `env`
# output breaks the sourcing as soon as a value carries spaces (dev's
# `BANNER_TITLE=MailD Dev Override` made every cron job print
# "/etc/environment: line 22: Dev: command not found" before doing anything).
env | sed -e "s/'/'\\\\''/g" -e "s/^\([^=]*\)=\(.*\)\$/\1='\2'/" >> /etc/environment

# SpamAssassin shared config: seed on the amavis container's first boot, if the volume is empty
# must wait to me popupated to start
while [ ! -f /etc/spamassassin/init.pre ]; do
    echo "==> Waiting for Spamassassin to be populated from amavis container"
    sleep 3
done

# execute CMD
echo "$@"
exec "$@"
