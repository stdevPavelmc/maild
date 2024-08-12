#!/bin/bash
set -m -o pipefail

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>

# preconditions on start: IP of some of the hosts
CLAMAVIP=`host ${CLAMAV} | awk '/has address/ { print $4 }'`
MTAIP=`host ${MTA} | awk '/has address/ { print $4 }'`
CRONIP=`host ${CRON} | awk '/has address/ { print $4 }'`

# check if  any of the IPs are empty
if [ -z "${CLAMAVIP}" ] ; then
    echo "====== !!!!!!!!!!!!!!!!!! ======="
    echo "CLAMAV IP is empty: die"
    exit 1
fi
if [ -z "${MTAIP}" ] ; then
    echo "====== !!!!!!!!!!!!!!!!!! ======="
    echo "MTA IP is empty: die"
    exit 1
fi
if [ -z "${CRONIP}" ] ; then
    echo "====== !!!!!!!!!!!!!!!!!! ======="
    echo "CRON IP is empty: die"
    exit 1
fi

# copy or overwrite the config files from the default ones
cd /etc/amavis
rm -rdf conf.d
cp -rfv conf.default conf.d

# postgresql data
CFILE=/tmp/config.local
echo "POSTGRES_HOST=${POSTGRES_HOST}" > "${CFILE}"
echo "POSTGRES_DB=${POSTGRES_DB}" >> "${CFILE}"
echo "POSTGRES_USER=${POSTGRES_USER}" >> "${CFILE}"
echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "${CFILE}"
echo "MTA=${MTA}" >> "${CFILE}"
echo "MTAIP=${MTAIP}" >> "${CFILE}"
echo "CLAMAVIP=${CLAMAVIP}" >> "${CFILE}"
echo "CRONIP=${CRONIP}" >> "${CFILE}"

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

# spamassasin enabled
if [ "${SPAM_FILTER_ENABLED}" ] ; then
    echo "Enabling SpamAssassin"

    # enable it
    sed s/"^\.*\@bypass_virus_checks_maps.*$"/'@bypass_spam_checks_maps = ( \%bypass_spam_checks, \@bypass_spam_checks_acl, \$bypass_spam_checks_re); '/ -i /etc/amavis/conf.d/15-content_filter_mode

    # spamassasing logging
    if [ "${AMAVIS_DEBUG}" ] ; then
        sed s/"^\$sa_debug.*"/'$sa_debug = 1;'/ -i /etc/amavis/conf.d/45-logging
    fi
else
    echo "Disabling SpamAssassin"

    # disable it
    sed s/"^.*bypass_virus_checks_maps.*$"/'# @bypass_spam_checks_maps = ( \%bypass_spam_checks, \@bypass_spam_checks_acl, \$bypass_spam_checks_re); '/ -i /etc/amavis/conf.d/15-content_filter_mode

    # spamassasing logging
    if [ ! "${AMAVIS_DEBUG}" ] ; then
        sed s/"^\$sa_debug.*"/'$sa_debug = 0;'/ -i /etc/amavis/conf.d/45-logging
    fi
fi

# AV enabled
if [ "${AV_ENABLED}" ] ; then
    echo "Enabling AV"

    # enable
    sed s/"^.*\@bypass_virus_checks_maps.*$"/'@bypass_virus_checks_maps = ( \%bypass_virus_checks, \@bypass_virus_checks_acl, \$bypass_virus_checks_re);'/ -i /etc/amavis/conf.d/15-content_filter_mode
else
    echo "Disabling AV"

    # disable it
    sed s/"^.*\@bypass_virus_checks_maps.*$"/'# @bypass_virus_checks_maps = ( \%bypass_virus_checks, \@bypass_virus_checks_acl, \$bypass_virus_checks_re);'/ -i /etc/amavis/conf.d/15-content_filter_mode
fi

# for the dkim functionality
function get_domains() {
    # query to get the domains
    QUERY="SELECT domain FROM domain;"

    # craft the auth credentials & secure it
    echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
    chmod 0600 ~/.pgpass &1>2

    # Run psql command to connect to database and run query
    psql -h $POSTGRES_HOST -d $POSTGRES_DB -U $POSTGRES_USER -c "$QUERY" -w > /tmp/domains.txt

    # validate
    R=$?
    if [ ! $R -eq 0 ] ; then
        echo "Error, could not connect to database" >&2
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
    # sample1.com.tld
    # exercises.tld
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

    # debug dkim_domians
    echo "DKIM_DOMAINS: ${DKIM_DOMAINS}"
    echo "FILESIGN: ${FILESIGN}"

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
else
    echo "DKIM signing disabled by default!!!"
fi

# ensure a defined end oin the file if not there
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
