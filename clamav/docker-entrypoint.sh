#!/bin/bash
set -m

if [ ! -f /etc/clamav/configured ] ; then
    # debug
    if [ "${CLAMAV_DEBUG}" ]; then
        echo "Instance not configured, configuring"
    fi

    # config alternate mirrors
    if [ "${ALTERNATE_MIRROR}" ]; then
        sed -i s/"DatabaseMirror .*$"/""/g /etc/clamav/freshclam.conf
        echo "DatabaseMirror ${ALTERNATE_MIRROR}" >> /etc/clamav/freshclam.conf

        # debug
        if [ "${CLAMAV_DEBUG}" ]; then
            echo "Alternate mirror setup done!"
        fi
    fi

    # configure verbose
    if [ "${CLAMAV_DEBUG}" ]; then
        sed -i s/"^LogVerbose .*$"/"LogVerbose true"/g /etc/clamav/clamd.conf
        echo "Setting verbose logging as requested"
    fi

    touch /etc/clamav/configured
fi

# fix perms if needed 
chown clamav:clamav /var/lib/clamav
chmod -R 0755 /var/lib/clamav/

DB_DIR=$(sed -n 's/^DatabaseDirectory\s\(.*\)\s*$/\1/p' /etc/clamav/freshclam.conf )
DB_DIR=${DB_DIR:-'/var/lib/clamav'}
MAIN_FILE="$DB_DIR/main.cvd"

if [ -f "$MAIN_FILE" ] ; then
    # there is a main.cvd file, start it normally
    clamd --foreground &
    # now start the updater
    freshclam -d &
else
    # no updates, start the updater and waith to start the daemon
    freshclam -d &

    until [ -e ${MAIN_FILE} ] ; do
        echo -e "waiting for clam to update..."
        sleep 3
    done

    # now start the daemon
    clamd --foreground&
fi

# recognize PIDs
pidlist=$(jobs -p)

# initialize latest result var
latest_exit=0

# define shutdown helper
function shutdown() {
    trap "" SIGINT

    for single in $pidlist; do
        if ! kill -0 "$single" 2> /dev/null; then
            wait "$single"
            latest_exit=$?
        fi
    done

    kill "$pidlist" 2> /dev/null
}

# run shutdown
trap shutdown SIGINT
wait -n

# return received result
exit $latest_exit
