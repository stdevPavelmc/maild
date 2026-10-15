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

# This is the one thing that breaks silently when the distro reallocates the clamav
# uid/gid (jammy 101:102 -> resolute 100:101, see base-os-upgrade.md guardrail 8): a
# bind-mounted volume still owned by the old ids is unreadable for the uid below, and
# clamd then dies on its signature database with permission errors. Say it out loud.
if [ ! -w /var/lib/clamav ] ; then
    echo "ERROR: /var/lib/clamav is not writable by $(id -un) ($(id -u):$(id -g)); owned by $(stat -c '%u:%g' /var/lib/clamav 2>/dev/null || echo '?')."
    echo "       dev:  re-run ./bootstrap-dev.sh (it re-owns ldata/clamav to the ids this image uses)"
    echo "       prod: docker compose run --rm --no-deps --user root --entrypoint chown clamav -R clamav:clamav /var/lib/clamav"
    exit 1
fi

DB_DIR=$(sed -n 's/^DatabaseDirectory\s\(.*\)\s*$/\1/p' /etc/clamav/freshclam.conf )
DB_DIR=${DB_DIR:-'/var/lib/clamav'}
MAIN_FILE_CVD="$DB_DIR/main.cvd"
MAIN_FILE_CLD="$DB_DIR/main.cld"

if [ -f "$MAIN_FILE_CVD" ] || [ -f "$MAIN_FILE_CLD" ] ; then
    # there is a main.cvd or main.cld file, start it normally
    clamd --foreground &
    # now start the updater
    freshclam -d &
else
    # no updates, start the updater and waith to start the daemon
    freshclam -d &

    until [ -e "$MAIN_FILE_CVD" ] || [ -e "$MAIN_FILE_CLD" ] ; do
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
