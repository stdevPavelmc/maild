#!/bin/bash
set -m

# postgresql data
CFILE=/tmp/config.local
echo "POSTGRES_HOST=${POSTGRES_HOST}" > "${CFILE}"
echo "POSTGRES_DB=${POSTGRES_DB}" >> "${CFILE}"
echo "POSTGRES_USER=${POSTGRES_USER}" >> "${CFILE}"
echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "${CFILE}"

# config dump
if [ "${DEBUG}" ] ; then
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

SPAM=NO
# spamassasin enabled
if [ -z "${SPAMASSASSIN_DISABLED}" ] ; then
    # enable it
    echo '@bypass_spam_checks_maps = ( \%bypass_spam_checks, \@bypass_spam_checks_acl, \$bypass_spam_checks_re); ' >> /etc/amavis/conf.d/15-content_filter_mode
    SPAM=YES
    echo "SpamAssassin Enabled by default!!!"
else
    echo "SpamAssassin Disabled on request!!!"
fi

# AV enabled
if [ -z "${AV_DISABLED}" ] ; then
    # enable av
    echo '@bypass_virus_checks_maps = ( \%bypass_virus_checks, \@bypass_virus_checks_acl, \$bypass_virus_checks_re);' >> /etc/amavis/conf.d/15-content_filter_mode
    echo "AV Enabled by default!!!"
else
    echo "AV Disabled on request!!!"
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
    # FILESELECTORS=/etc/amavis/conf.d/23-dkim_selectors
    
    # debug dkim_domians if debugging
    if [ "${DEBUG}" ] ; then
        echo "DKIM_DOMAINS: ${DKIM_DOMAINS}"
        echo "FILESIGN: ${FILESIGN}"
        # echo "FILESELECTORS: ${FILESELECTORS}"
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

        # # create a file with the selectors
        # echo "@dkim_signature_options_bysender_maps( {" > ${FILESELECTORS}
        # for DOMAIN in ${DKIM_DOMAINS} ; do
        #     KEY=/var/lib/amavis/dkim/${DOMAIN}.pem
        #     SELECTOR=$(grep ${DOMAIN} ${DKIM_LIST} | head -n1 | cut -d ' ' -f 2)
        #     echo "    '.${DOMAIN}' => { ttl => 30*24*3600, c => 'relaxed/simple', a => 'rsa-sha256', d => '${DOMAIN}', s => '${SELECTOR}', key => '${KEY}' }," >> ${FILESELECTORS}
        # done
        # echo "} );" >> ${FILESELECTORS}

        # # close that file
        # echo '1;' >> ${FILESELECTORS}

        # # debug dkim_domians if debugging
        # if [ "${DEBUG}" ] ; then
        #     echo "Dump of the bymail config:"
        #     cat "${FILESELECTORS}"
        # fi

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

# starting amavis
echo "Starting amavis"
rm /var/run/amavis/amavisd.pid 2> /dev/null
/usr/sbin/amavisd-new -u amavis -g amavis -i docker foreground

# results
R=$?
if [ ! $R -eq 0 ] ; then
    echo "Error, could not start amavis, dkim?"
    cat /etc/amavis/conf.d/*dkim*
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
