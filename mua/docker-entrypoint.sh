#!/bin/bash
set -m -o pipefail

# Author: Pavel Milane <pavelmc@gmail.com>
# Goal: Configure an instance of snappy mail from the default config file.
# But with one trick, We must start the apache service first

# start apache, always
apache2-foreground &

# Run the CMD if passed
if [ "$1" ] ; then
    exec $@
fi

# defaults
CONFFOLDER="/var/www/html/data/_data_/_default_"
DOMAINFOLDER="${CONFFOLDER}/domains"
CONFIG="${CONFFOLDER}/configs/application.ini"

# SnappyMail builds its configuration on the first request it serves, so poke it until
# application.ini exists: that is the file we have to patch below. Do NOT wait for
# admin_password.txt instead -- SnappyMail deletes that file as soon as an administrator sets a
# password of his own in the admin panel, and an unbounded wait on it left this entrypoint
# spinning forever (container up, healthy and stuck).
WAIT_CONFIG="${MUA_CONFIG_WAIT_TIMEOUT:-120}"
T=0
while [ ! -f "$CONFIG" ] ; do
    wget -q 'http://localhost/?admin' -O /dev/null
    wget -q 'http://localhost/?/AdminAppData/0/5220854561746323/' -O /dev/null
    if [ "$T" -ge "$WAIT_CONFIG" ] ; then
        echo "WARNING: SnappyMail did not create ${CONFIG} within ${T}s"
        echo "WARNING: is /var/www/html/data writable by www-data?"
        break
    fi
    sleep 2 ; T=$((T+2))
    echo "."
done

# List of environment variables to check
env_vars=(BANNER_TITLE POSTGRES_EXTRA_DB MTA MDA POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD)

# Loop over the environment variables
for var in "${env_vars[@]}"; do
    # Check if the variable is empty
    if [ -z "${!var}" ]; then
        echo "WARNING: $var is empty"
        echo "WARNING: This whole shit will fail, check your config and RTFM!"
        killall apache2
        exit 1
    fi
done

# Debug
if [ "${MUA_DEBUG}" ] ; then
    echo "Variable parse done"
fi

# get the IPs of the MTA and the MDA
MTAIP=`host ${MTA} | awk '/has address/ { print $4 }'`
MDAIP=`host ${MDA} | awk '/has address/ { print $4 }'`
echo $MTAIP > /tmp/MTAIP
echo $MDAIP > /tmp/MDAIP

# Debug
if [ "${MUA_DEBUG}" ] ; then
    echo "MDA IP: $MDAIP"
    echo "MTA IP: $MTAIP"
fi

# --- SnappyMail plugins ------------------------------------------------------------------------
# The plugin CODE comes from the image (pinned at build time, see mua/Dockerfile) and is copied
# over the data volume on every boot: a fresh deployment gets the MailD baseline and a rebuilt
# image refreshes it. The plugin SETTINGS live in the volume (configs/plugin-*.json) and are never
# touched here; the baseline `enabled_list` is applied by config-setup.php just below.
# Managed directories are replaced wholesale, any other directory is left alone, so a plugin
# installed later from the admin panel survives.
PLUGINS_SRC="/opt/maild/plugins"
PLUGINS_DST="${CONFFOLDER}/plugins"
if [ -d "$PLUGINS_SRC" ] ; then
    mkdir -p "$PLUGINS_DST"
    for d in "$PLUGINS_SRC"/* ; do
        [ -d "$d" ] || continue
        P="$(basename "$d")"
        rm -rf "${PLUGINS_DST:?}/${P}"
        cp -a "$d" "${PLUGINS_DST}/${P}"

        # Debug
        if [ "${MUA_DEBUG}" ] ; then
            echo "Plugin synced: ${P}"
        fi
    done
    chown -R www-data:www-data "$PLUGINS_DST"
    chmod -R go-rwx "$PLUGINS_DST"
fi

# switcheroo voodo magic
# One helper does it all: it writes MailD's settings (banner, contacts DB, admin panel login)
# into SnappyMail's configuration, using the same quoting SnappyMail itself writes -- crudini
# wrote them unquoted, PHP then refused the whole file, SnappyMail fell back to its factory
# defaults (losing security.admin_password with them) and minted a new random password that no
# log ever showed, so ?admin + the OTP printed here could not possibly work.
if SETUP="$(php /config-setup.php)" ; then
    ADMIN_LOGIN="$(echo "$SETUP" | sed -n 's/^MUA_ADMIN_LOGIN=//p')"
    ADMIN_PASSWORD="$(echo "$SETUP" | sed -n 's/^MUA_ADMIN_PASSWORD=//p')"
    ADMIN_PASSWORD_SOURCE="$(echo "$SETUP" | sed -n 's/^MUA_ADMIN_PASSWORD_SOURCE=//p')"

    # Expose for the admin user the credentials of the SnappyMail admin panel
    echo "======================================================================"
    echo "|| SnappyMail admin panel: <your webmail URL>/?admin"
    echo "|| login    : ${ADMIN_LOGIN}"
    case "${ADMIN_PASSWORD_SOURCE}" in
        env)
            echo "|| password : the one in MUA_ADMIN_PASSWORD" ;;
        stored)
            echo "|| password : unchanged, set from the admin panel" ;;
        *)
            echo "|| password : ${ADMIN_PASSWORD}   [${ADMIN_PASSWORD_SOURCE}]" ;;
    esac
    echo "======================================================================"
else
    echo "ERROR: SnappyMail could not be configured, see the messages above"
    echo "ERROR: the webmail may be running on its factory defaults and a random password"
fi

# Debug
if [ "${MUA_DEBUG}" ] ; then
    echo "Config parse done"
fi

# --- first-boot provisioning gate ------------------------------------------
# SnappyMail builds one JSON config per domain at start, so it waits (bounded) for the admin
# container to finish provisioning the catalogue: a fresh deploy then gets its per-domain
# configs with no manual restart. Opt out with AUTO_PROVISION=no.
if [ "${AUTO_PROVISION:-yes}" != "no" ] ; then
    echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
    chmod 0600 ~/.pgpass
    T=0
    while : ; do
        if [ "$(psql -tAq -w -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
                -c "SELECT 1 FROM maild_provision WHERE id=1 AND version >= ${PROVISION_VERSION:-1}" 2>/dev/null)" = "1" ] ; then
            echo "mua: catalogue is provisioned, configuring"
            break
        fi
        if [ "$T" -ge "${PROVISION_WAIT_TIMEOUT:-180}" ] ; then
            echo "mua: WARNING - catalogue not provisioned after ${T}s, continuing"
            break
        fi
        sleep 3 ; T=$((T+3))
    done
fi

# get the domains on the DB
function get_domains() {
    # query to get the domains
    QUERY="SELECT domain FROM domain;"

    # craft the auth credentials & secure it
    echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
    chmod 0600 ~/.pgpass

    # Run psql command to connect to database and run query
    psql -h $POSTGRES_HOST -d $POSTGRES_DB -U $POSTGRES_USER -c "$QUERY" -w > /tmp/domains.txt

    # validate
    R=$?
    if [ ! $R -eq 0 ] ; then
        echo "Error, could not connect to database"
        exit 1
    fi

    # debug
    if [ "${MUA_DEBUG}" ] ; then
        echo "DB query result dump:" >&2
        cat /tmp/domains.txt >&2
    fi

    # output format
    #  domain  
    #----------
    # ALL
    # sample1.com.jm
    # exercises.jm
    #(2 rows)

    # match any domain like string on the results
    cat /tmp/domains.txt | grep -E '\b[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b' | tr -d ' ' | xargs
}

# clean the domains configs: SnappyMail keeps one json file per domain and the loop below
# recreates them from the catalogue. Any stale file -- or leftover of an older run -- would
# advertise a domain that no longer exists (the old `for f in $(ls); do rm -f ${f}` also choked
# on names with spaces, and a stray `2` file used to land here on every boot)
find "${DOMAINFOLDER}" -maxdepth 1 -type f -delete

# Debug
if [ "${MUA_DEBUG}" ] ; then
    echo "Domain configs cleaned"
fi

# Cycle through domains
for domain in $(get_domains); do
    # Debug
    if [ "${MUA_DEBUG}" ] ; then
        echo "Parsing config file for Domain: $domain"
    fi

    # create a domain config file (short filename)
    DEST="${DOMAINFOLDER}/${domain}.json"
    cp /tmp/domain.json ${DEST}
    sed s/"_DOMAIN_"/"${domain}"/g -i "${DEST}"
    sed s/"_MTA_"/"${MTAIP}"/g -i "${DEST}"
    sed s/"_MDA_"/"${MDAIP}"/g -i "${DEST}"
    chown www-data:www-data "${DEST}"
    chmod 0600 "${DEST}"
done

# Debug
if [ "${MUA_DEBUG}" ] ; then
    echo "Config finished..."
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
cd /tmp/
trap shutdown SIGINT
wait -n

# return received result
exit $latest_exit
