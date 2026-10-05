#!/bin/bash
set -m -o pipefail

# copy or overwrite the config files from the default ones
cd /etc/amavis
rm -rdf conf.d
cp -rfv conf.default conf.d

# SpamAssassin shared config:
#   - seed the shared config volume if empty (each image stages the
#     distro files on /etc/spamassassin.dist at build time)
#   - write the MailD tuning file, shared with the cron & mda containers
if [ ! -f /etc/spamassassin/init.pre ] ; then
    echo "Seeding the shared SpamAssassin config folder"
    cp -a /etc/spamassassin.dist/. /etc/spamassassin/
fi
cat > /etc/spamassassin/maild.cf <<EOF
# Generated at startup by MailD, do not edit by hand (overwritten on restart)
# tune it via env vars on the amavis container (see vars/amavis.env)
use_bayes 1
bayes_path ${SA_BAYES_PATH:-/var/lib/spamassassin/bayes/db}
bayes_file_mode 0666
bayes_auto_learn 1
bayes_auto_learn_threshold_nonspam ${SA_AUTOLEARN_NONSPAM:-0.1}
bayes_auto_learn_threshold_spam ${SA_AUTOLEARN_SPAM:-10}
EOF

# make sure the shared bayes folder is usable by amavis (scans), root
# on the cron container (batch learning) and the vmail user on the mda
# container (instant learning via imapsieve)
mkdir -p /var/lib/spamassassin/bayes
chmod 0777 /var/lib/spamassassin/bayes

# amavis runtime dirs: a fresh dev *bind* mount of ./ldata/amavis is empty (docker only
# pre-populates NAMED volumes from the image), which makes amavisd die with
# "No TEMPBASE directory: /var/lib/amavis/tmp". Recreate them here so the stack also comes up
# on a clean bind mount; idempotent and harmless when the dirs already exist (production).
mkdir -p /var/lib/amavis/tmp /var/lib/amavis/db /var/lib/amavis/dkim /var/lib/amavis/virusmails
chown -R amavis:amavis /var/lib/amavis/tmp /var/lib/amavis/db /var/lib/amavis/dkim /var/lib/amavis/virusmails 2>/dev/null || true


# postgresql data
CFILE=/tmp/config.local
echo "POSTGRES_HOST=${POSTGRES_HOST}" > "${CFILE}"
echo "POSTGRES_DB=${POSTGRES_DB}" >> "${CFILE}"
echo "POSTGRES_USER=${POSTGRES_USER}" >> "${CFILE}"
echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "${CFILE}"
echo "MTA=${MTA}" >> "${CFILE}"
MTAIP=`host ${MTA} | awk '/has address/ { print $4 }'`
echo "MTAIP=${MTAIP}" >> "${CFILE}"
CLAMAVIP=`host ${CLAMAV} | awk '/has address/ { print $4 }'`
echo "CLAMAVIP=${CLAMAVIP}" >> "${CFILE}"
CRONIP=`host ${CRON} | awk '/has address/ { print $4 }'`
echo "CRONIP=${CRONIP}" >> "${CFILE}"

# check if  any of the IPs are empty
if [ -z "${CLAMAVIP}" ] ; then
    echo "====== !!!!!!!!!!!!!!!!!! ======="
    echo "CLAMAV IP is empty"
    exit 1
fi
if [ -z "${MTAIP}" ] ; then
    echo "====== !!!!!!!!!!!!!!!!!! ======="
    echo "MTA IP is empty"
    exit 1
fi
if [ -z "${CRONIP}" ] ; then
    echo "====== !!!!!!!!!!!!!!!!!! ======="
    echo "CRON IP is empty"
    exit 1
fi

# IP data for the checks
echo $CLAMAVIP > /tmp/CLAMAVIP
echo $MTAIP > /tmp/MTAIP
echo $CRONIP > /tmp/CRONIP

# config dump
if [ "${AMAVIS_DEBUG}" ] ; then
    echo "Config file dump:"
    cat ${CFILE}
fi

# get the vars from the file
VARS=`cat "${CFILE}" | cut -d "=" -f 1`

# replace the vars in the folders
for v in `echo "${VARS}" | xargs` ; do
    # get the var content
    CONTp=${!v}

    # escape possible "/" in there
    CONT=`echo ${CONTp//\//\\\\/}`

    # replace the var
    find /etc/amavis/conf.d/ -type f -exec sed -i s/"\_${v}\_"/"${CONT}"/g {} \;
done

# --------------------------------------------------------------- filters ------
# AV and SpamAssassin are toggled with the usual truthy/falsy spellings. The distro
# default lives in /usr/share/amavis/conf.d/20-package: "@bypass_*_checks_maps = (1)"
# (1 = bypass everyone = the checks are DISABLED). Overwriting both maps in a file
# that loads last (60-* comes after 15-content_filter_mode and 50-user) with the
# empty list re-enables them deterministically. The previous implementation edited
# 15-content_filter_mode with sed and tested the variables for non-emptiness, so the
# two documented "off" values ("no" in the dev compose, empty) had opposite effects.
filter_toggle() { # <value> — returns 0 = on, 1 = off, 2 = invalid
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        yes|true|1|on)     return 0 ;;
        no|false|0|off|'') return 1 ;;
        *)                 return 2 ;;
    esac
}

filter_toggle "${AV_ENABLED}"
case $? in
    0) AV_MODE=on ;;
    1) AV_MODE=off ;;
    *) echo "ERROR: AV_ENABLED must be yes/no/true/false/1/0 (got '${AV_ENABLED}')" >&2 ; exit 1 ;;
esac

filter_toggle "${SPAM_FILTER_ENABLED}"
case $? in
    0) SPAM_MODE=on ;;
    1) SPAM_MODE=off ;;
    *) echo "ERROR: SPAM_FILTER_ENABLED must be yes/no/true/false/1/0 (got '${SPAM_FILTER_ENABLED}')" >&2 ; exit 1 ;;
esac

FILTER_MODE=/etc/amavis/conf.d/60-maild_content_filter_mode
{
    echo 'use strict;'
    echo '# generated at startup by MailD from AV_ENABLED / SPAM_FILTER_ENABLED'
    if [ "${AV_MODE}" = on ] ; then
        echo '@bypass_virus_checks_maps = ();  # empty list: nobody bypasses => AV scanning enabled'
    else
        echo '@bypass_virus_checks_maps = (1); # bypass everyone => AV scanning disabled'
    fi
    if [ "${SPAM_MODE}" = on ] ; then
        echo '@bypass_spam_checks_maps = ();   # empty list: nobody bypasses => SpamAssassin enabled'
    else
        echo '@bypass_spam_checks_maps = (1);  # bypass everyone => SpamAssassin disabled'
    fi
    echo '1;  # ensure a defined return'
} > "${FILTER_MODE}"
echo "Content filter mode: AV=${AV_MODE}, SpamAssassin=${SPAM_MODE}"

# spamassassin logging
if [ "${AMAVIS_DEBUG}" ] ; then
    sed s/"^\$sa_debug.*"/'$sa_debug = 1;'/ -i /etc/amavis/conf.d/45-logging
else
    sed s/"^\$sa_debug.*"/'$sa_debug = 0;'/ -i /etc/amavis/conf.d/45-logging
fi

# --- first-boot provisioning gate ------------------------------------------
# amavis caches the domain list (and generates the DKIM keys) at start, so it waits (bounded)
# for the admin container to finish provisioning the catalogue: a fresh deploy then comes up
# signed with no manual restart. Opt out with AUTO_PROVISION=no.
if [ "${AUTO_PROVISION:-yes}" != "no" ] ; then
    echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
    chmod 0600 ~/.pgpass
    T=0
    while : ; do
        if [ "$(psql -tAq -w -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
                -c "SELECT 1 FROM maild_provision WHERE id=1 AND version >= ${PROVISION_VERSION:-1}" 2>/dev/null)" = "1" ] ; then
            echo "amavis: catalogue is provisioned, configuring"
            break
        fi
        if [ "$T" -ge "${PROVISION_WAIT_TIMEOUT:-180}" ] ; then
            echo "amavis: WARNING - catalogue not provisioned after ${T}s, continuing"
            break
        fi
        sleep 3 ; T=$((T+3))
    done
fi

# for the dkim functionality
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
        echo "EMPTY"
        exit 1
    fi

    # debug
    if [ "${AMAVIS_DEBUG}" ] ; then
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

# for the dkim functionality
function get_numbers() {
    # just output a random string composed of numbers of 20 chars length
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1
}

# dkim folder
mkdir -p /var/lib/amavis/dkim
# this file will hold the selector and domain for all configured ones
DKIM_LIST=/var/lib/amavis/dkim/db.txt
touch $DKIM_LIST

# if dkim signing enabled
if [ "${DKIM_SIGNING}" ] ; then
    # get the list of domains
    DKIM_DOMAINS=$(get_domains)
    FILESIGN=/etc/amavis/conf.d/22-dkim_signing

    # if no config yet, skip dkim creation
    if [ "${DKIM_DOMAINS}" == "EMPTY" ] ; then
        echo "==> No domains found in DB, skipping DKIM setup for now."
    else
        # debug dkim_domains if debugging
        if [ "${AMAVIS_DEBUG}" ] ; then
            echo "DKIM_DOMAINS: ${DKIM_DOMAINS}"
            echo "FILESIGN: ${FILESIGN}"
        fi

        # setup only if there are domains to process
        if [[ "${DKIM_DOMAINS}" ]] ; then
            # enable signing
            echo '$enable_dkim_signing = 1;' > ${FILESIGN}

            # setup DKIM for each domain if not there
            for DOMAIN in ${DKIM_DOMAINS} ; do
                echo "Setup DKIM signing for domain: $DOMAIN"
                KEY=/var/lib/amavis/dkim/${DOMAIN}.pem

                if [ ! -f ${KEY} ] ; then
                    echo "DKIM key not present for domain ${DOMAIN} ...generating!!!"

                    # generate the key and the selector and set correct perms
                    /usr/sbin/amavisd-new genrsa ${KEY} 1024
                    chmod 640 ${KEY}
                    chown root:amavis ${KEY}
                fi

                # check if there is a selector created for that domain, if not update the list
                SELECTOR=$(grep ${DOMAIN} ${DKIM_LIST} | head -n1 | cut -d ' ' -f 2)
                if [ -z "$SELECTOR" ] ; then
                    # no selector found, create one and set it on file
                    SELECTOR=$(get_numbers)
                    echo "${DOMAIN} ${SELECTOR}" >> ${DKIM_LIST}
                fi

                # add the selector to the config if not there
                FILTER=$(grep "dkim_key('${DOMAIN}', '${SELECTOR}', '${KEY}');" ${FILESIGN})
                if [ -z "$FILTER" ] ; then
                    # no dkim key declared, updating
                    echo "dkim_key('${DOMAIN}', '${SELECTOR}', '${KEY}');" >> ${FILESIGN}
                fi
            done

            # close that file
            echo '1;' >> ${FILESIGN}

            # update the user files
            for DOMAIN in ${DKIM_DOMAINS} ; do
                KEY=/var/lib/amavis/dkim/${DOMAIN}.pem
                SELECTOR=$(grep ${DOMAIN} ${DKIM_LIST} | head -n1 | cut -d ' ' -f 2)
                # show it to the user
                echo " "
                echo "=|| DKIM / DNS config for ${DOMAIN} ||="
                amavisd-new showkeys ${DOMAIN} | tee /var/lib/amavis/dkim/${DOMAIN}.${SELECTOR}.txt
            done
        else
            echo "No domains to process, DKIM signing disabled" 
        fi
    fi
else
    echo "DKIM signing disabled by default!!!"
fi

# ensure a defined end of the file if not there
F=$(tail -n1 /etc/amavis/conf.d/15-content_filter_mode)
if [ "$F" != '1;' ] ; then
    # add defined 1;
    echo '1;' >> /etc/amavis/conf.d/15-content_filter_mode
fi

# Logging
if [ "${AMAVIS_DEBUG}" ] ; then
    echo "Enabling amavis logging"

    # amavis logging
    sed s/"^\$debug_amavis.*"/'$debug_amavis = 1;'/ -i /etc/amavis/conf.d/45-logging
    sed s/"^\$log_level.*"/'$log_level = 3;'/ -i /etc/amavis/conf.d/45-logging
else
    echo "Disabling amavis logging"

    # amavis logging
    sed s/"^\$debug_amavis.*"/'$debug_amavis = 1;'/ -i /etc/amavis/conf.d/45-logging
    sed s/"^\$log_level.*"/'$log_level = 1;'/ -i /etc/amavis/conf.d/45-logging
fi

# setup correct perms
chown -R root:root /etc/amavis/conf.d
find /etc/amavis/ -type f -exec chmod 0644 {} \;
find /etc/amavis/ -type d -exec chmod 0755 {} \;

# testing amavis config
echo "Testing amavis"
rm /var/run/amavis/amavisd.pid 2> /dev/null
/usr/sbin/amavisd-new test-config

# results
R=$?
if [ ! $R -eq 0 ] ; then
    echo "Amavis config testing failed"
    exit 1
fi

# test amavis config
rm /var/run/amavis/amavisd.pid 2> /dev/null
/usr/sbin/amavisd-new -i docker test-config
if [ $? -ne 0 ] ; then
    echo "Amavis config testing failed"
    exit 1
fi

# starting amavis
echo "Starting amavis"

# keep the SpamAssassin rules fresh in the background (daily sa-update
# + amavisd reload after new rules are installed)
/sa-update-loop.sh &

/usr/sbin/amavisd-new -u amavis -g amavis -i docker foreground
if [ $? -ne 0 ] ; then
    echo "Error, could not start amavis !!!"
    exit 1
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
