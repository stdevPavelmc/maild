#!/bin/bash
set -m

# postgresql data
CFILE=/tmp/config.local
echo "POSTGRES_HOST=${POSTGRES_HOST}" > "${CFILE}"
echo "POSTGRES_DB=${POSTGRES_DB}" >> "${CFILE}"
echo "POSTGRES_USER=${POSTGRES_USER}" >> "${CFILE}"
echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "${CFILE}"
CLAMAVIP=`host ${CLAMAV} | awk '/has address/ { print $4 }'`
echo "CLAMAVIP=${CLAMAVIP}" >> "${CFILE}"

CLAMAVIP=`host ${CLAMAV} | awk '/has address/ { print $4 }'`
echo $CLAMAVIP > /tmp/CLAMAVIP

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
    find /etc/amavis/ -type f -exec sed -i s/"\_${v}\_"/"${CONT}"/g {} \;
done

# check for the MTA configuration
if [ -z "${AMAVIS_MTA}" ]; then
    echo "Error, you must specify a MTA to forward mail to in the 'AMAVIS_MTA' var"
    echo "Example: AMAVIS_MTA=mta on the vars/amavis.env"
    exit 1;
fi

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

# dkim functionality
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

    # output format
    #  domain  
    #----------
    # sample1.com.jm
    # exercises.jm
    #(2 rows)

    cat /tmp/domains.txt | grep -v ' domain' | grep -v '\-\-\-' | grep -v ' row' | tr -d ' ' | xargs
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

    # debug dkim_domians if debugging
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
                SELECTOR=$(openssl rand -base64 18)
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

# ensure a defined end oin the file
echo '1;' >> /etc/amavis/conf.d/15-content_filter_mode

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
