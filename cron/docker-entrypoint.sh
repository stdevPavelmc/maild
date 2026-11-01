#!/bin/sh

# Restore the image ENV defaults (snapshot taken at build) that compose's bare allow-list
# keys unset: "KEY" with no value removes the image default instead of keeping it. A value
# the operator set (even an empty one) is present and wins.
while IFS= read -r line; do
    key="${line%%=*}"
    eval "[ -n \"\${${key}+x}\" ]" || export "$line"
done < /etc/maild-image.env

# Dump the environment in a form `/etc/environment` can be sourced verbatim: the raw `env`
# output breaks the sourcing as soon as a value carries spaces (dev's
# `BANNER_TITLE=MailD Dev Override` made every cron job print
# "/etc/environment: line 22: Dev: command not found" before doing anything).
# It holds POSTGRES_PASSWORD (2026-10 audit M-06): rewritten (not appended — every restart
# used to add another copy) and readable by root only; every job runs as root. The compose
# file passes an explicit allow-list, never the whole operator env file.
umask 077
env | sed -e "s/'/'\\\\''/g" -e "s/^\([^=]*\)=\(.*\)\$/\1='\2'/" > /etc/environment.new
chmod 600 /etc/environment.new
mv /etc/environment.new /etc/environment
umask 022

# SpamAssassin shared config: seed on the amavis container's first boot, if the volume is empty
# must wait to me popupated to start
while [ ! -f /etc/spamassassin/init.pre ]; do
    echo "==> Waiting for Spamassassin to be populated from amavis container"
    sleep 3
done

# execute CMD
echo "$@"
exec "$@"
