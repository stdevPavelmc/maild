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
# default password file:
PASS="${CONFFOLDER}/admin_password.txt"
CONFIG="${CONFFOLDER}/configs/application.ini"

# small delay to allow the service to create the default config
while [ ! -f "$PASS" ] ; do
    wget -q 'http://localhost/?admin' -O /dev/null
    wget -q 'http://localhost/?/AdminAppData/0/5220854561746323/' -O /dev/null
    sleep 2
    echo "."
done

# Expose for the admin user the defaultt password file
echo "======================================================================"
echo "|| Initial default admin passsword: $(cat ${PASS})"
echo "======================================================================"

# List of environment variables to check
env_vars=(BANNER_TITLE CTDB MTA MDA POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD)

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

# switcheroo voodo magic
sed s/"^title = .*$"/"title = ${BANNER_TITLE}"/ -i ${CONFIG}
sed s/"^type = .*$"/"type = \"pgsql\""/ -i ${CONFIG}
sed s/"^pdo_user = .*$"/"pdo_user = ${POSTGRES_USER}"/ -i ${CONFIG}
sed s/"^pdo_password = .*$"/"pdo_password = ${POSTGRES_PASSWORD}"/ -i ${CONFIG}
sed s/"^pdo_dsn = .*$"/"pdo_dsn = \"host=${POSTGRES_HOST};port=5432;dbname=${CTDB}\""/ -i ${CONFIG}

# Debug
if [ "${MUA_DEBUG}" ] ; then
    echo "Config parse done"
fi

# get the domains on the DB
function get_domains() {
    # query to get the domains
    QUERY="SELECT domain FROM domain;"

    # craaft the auth credentials & secure it
    echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
    chmod 0600 ~/.pgpass &1>2

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

# clean domains configs
cd ${DOMAINFOLDER}
for f in $(ls) ; do
    rm -f ${f}

    # Debug
    if [ "${MUA_DEBUG}" ] ; then
        echo "Deleted found domain config file: $f"
    fi
done

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
