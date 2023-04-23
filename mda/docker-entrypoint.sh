#!/bin/sh
set -e

if [ ! -f /etc/dovecot/configured ]; then
    # create the local config file
    CFILE=/etc/dovecot/config.local
    # Domain
    echo "DEFAULT_DOMAIN=${DEFAULT_DOMAIN}" > "${CFILE}"
    echo "COUNTRY=${COUNTRY}" >> ${CFILE}
    echo "STATE=${STATE}" >> ${CFILE}
    echo "CITY=${CITY}" >> ${CFILE}
    echo "ORG=${ORG}" >> ${CFILE}
    echo "OU=${OU}" >> ${CFILE}
    # #TODO
    echo "DEFAULT_MAILBOX_SIZE=${DEFAULT_MAILBOX_SIZE}" >> "${CFILE}"
    # DB
    echo "POSTGRES_USER=${POSTGRES_USER}" >> "${CFILE}"
    echo "POSTGRES_DB=${POSTGRES_DB}" >> "${CFILE}"
    echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "${CFILE}"
    echo "POSTGRES_HOST=${POSTGRES_HOST}" >> "${CFILE}"

    # config dump
    if [ "${DEBUG}" ] ; then
        echo "Config file dump:"
        cat ${CFILE}
    fi

    # force creation of sive fodler
    mkdir -p /var/lib/dovecot/sieve/
    echo "Sieve folder created!"

    # create the default sieve filter
    FILE=/var/lib/dovecot/sieve/default.sieve
    echo 'require "fileinto";' > ${FILE}
    echo 'if header :contains "X-Spam-Flag" "YES" {' >> ${FILE}
    echo '    fileinto "Junk";' >> ${FILE}
    echo '}' >> ${FILE}
    echo "Sieve default SPAM filter created"

    # fix ownership
    #chown -R vmail:vmail /var/lib/dovecot

    # compile it
    sievec /var/lib/dovecot/sieve/default.sieve
    echo "Sieve compilation done"

    # Run the configuration
    echo "Config starting"
    /configure.sh

    ## dhparms generation
    if [ ! -f /certs/RSA2048.pem ] ; then
        echo "Generation of SAFE dhparam, this may take a time, be patient..."
        openssl dhparam -out /certs/RSA2048.pem -5 2048
        chmod 0644 /certs/RSA2048.pem
        echo "dhparam generated!"
    else
        echo "DHparam already present, skiping generation!"
    fi

    # create the flag file
    touch /etc/dovecot/configured
    echo "Flag created: container ready!"

    # debug, remove the config file at the end or not if debugging
    if [ -z "${DEBUG}" ] ; then
        rm ${CFILE}
    fi
fi

if [ "$1" = 'dovecot' ]; then
    if [ ! -f /certs/mail.crt -o ! -f /certs/mail.key -o ! -f /certs/RSA2048.pem ] ; then
        echo "Ooops! There is some SSL files missing"
        echo "We need a valid 'mail.crt' & 'mail.key' files in the /certs volume!"
        exit 1
    fi

    exec /usr/sbin/dovecot -F < /dev/null
fi

exec "$@"
