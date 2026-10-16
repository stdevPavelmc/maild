#!/bin/sh

env >> /etc/environment

# SpamAssassin shared config: seed on the amavis container's first boot, if the volume is empty
# must wait to me popupated to start
while [ ! -f /etc/spamassassin/init.pre ]; do
    echo "==> Waiting for Spamassassin to be populated from amavis container"
    sleep 3
done

# execute CMD
echo "$@"
exec "$@"
