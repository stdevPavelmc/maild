#!/bin/bash
set -e

### create the tmp files
MAIN=/tmp/main.cf
MASTER=/tmp/master.cf
cp /etc/postfix/main.cf.s ${MAIN}
cp /etc/postfix/master.cf.s ${MASTER}

### Vars handling

# optionals
if [ -z "${RELAY}" ] ; then
    RELAY=""
fi
if [ -z "${MAX_MESSAGESIZE}" ] ; then
    MAX_MESSAGESIZE=2264924
fi
if [ -z "${ALWAYS_BCC}" ] ; then
    ALWAYS_BCC=
fi
if [ -z "${SPF_ENABLE}" ] ; then
    SPF_ENABLE='no'
fi
if [ -z "${DNSBL_ENABLE}" ] ; then
    DNSBL_ENABLE='no'
fi

# mandatory
HOSTNAME=`hostname -f`
SYSADMINS=`echo ${MAILADMIN} | sed s/"@"/"\\\@"/`

# create the local config file
CFILE=/etc/postfix/config.local
echo "DOMAIN=${DEFAULT_DOMAIN}" > "${CFILE}"
echo "MESSAGESIZE=${MAX_MESSAGESIZE}" >> "${CFILE}"
echo "HOSTNAME=${HOSTNAME}" >> "${CFILE}"
echo "RELAY=${RELAY}" >> "${CFILE}"
echo "ALWAYSBCC=${ALWAYS_BCC}" >> "${CFILE}"
echo "SYSADMINS=${SYSADMINS}" >> "${CFILE}"
echo "AMAVISHN=${AMAVIS}" >> "${CFILE}"
AMAVISIP=`host ${AMAVIS} | awk '/has address/ { print $4 }'`
echo "AMAVISIP=${AMAVISIP}" >> "${CFILE}"
OWN_IP=`ifconfig eth0 | grep inet | awk '{print $2}'`
echo "OWN_IP=${OWN_IP}" >> "${CFILE}"
# postgresql data
echo "POSTGRES_HOST=${POSTGRES_HOST}" >> "${CFILE}"
echo "POSTGRES_DB=${POSTGRES_DB}" >> "${CFILE}"
echo "POSTGRES_USER=${POSTGRES_USER}" >> "${CFILE}"
echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "${CFILE}"

# config dump
if [ "${DEBUG}" ] ; then
    echo "Config file dump:"
    cat ${CFILE}
fi

# loading configs
export $(cat "${CFILE}" | xargs)

# get the vars from the file
VARS=`cat "${CFILE}" | cut -d "=" -f 1`

# replace the vars in the folders
for v in `echo "${VARS}" | xargs` ; do
    # get the var content
    CONTp=${!v}

    # escape possible "/" in there
    CONT=`echo ${CONTp//\//\\\\/}`

    # temp config files 
    sed s/"\_${v}\_"/"${CONT}"/g -i ${MAIN}
    sed s/"\_${v}\_"/"${CONT}"/g -i ${MASTER}

    # pgsql files
    find /etc/postfix/pgsql/ -type f -exec sed s/"\_${v}\_"/"${CONT}"/g -i {} \;
done

# check for SPF activation
if [ -z "${SPF_ENABLE}" -o "${SPF_ENABLE}" == "no" -o "${SPF_ENABLE}" == "No" -o "${SPF_ENABLE}" == "False" -o "${SPF_ENABLE}" == "false"  ] ; then
    # disable SPF
    sed -i s/"^.*spf.*$"/''/g ${MAIN}

    # notice
    echo "Disabed SPF as requested by the config"
fi

### DNSBL
if [ "${DNSBL_ENABLE}" == "yes" -o "${DNSBL_ENABLE}" == "Yes" -o "${DNSBL_ENABLE}" == "True" -o "${DNSBL_ENABLE}" == "true" ] ; then
    # notice
    echo "Enabled DNSBL filtering as requested by the config"

    # disable simple smtp
    sed -i s/"^smtp      inet  n       -       y       -       -       smtpd"/"#smtp      inet  n       -       y       -       -       smtpd"/ ${MASTER}

    # enable postscreen, smtpd, dnsblog & tlsproxy
    sed -i s/"^#smtp      inet  n       -       y       -       1       postscreen"/"smtp      inet  n       -       y       -       1       postscreen"/ ${MASTER}
    sed -i s/"^#smtpd     pass  -       -       y       -       -       smtpd"/"smtpd     pass  -       -       y       -       -       smtpd"/ ${MASTER}
    sed -i s/"^#dnsblog   unix  -       -       y       -       0       dnsblog"/"dnsblog   unix  -       -       y       -       0       dnsblog"/ ${MASTER}
    sed -i s/"^#tlsproxy  unix  -       -       y       -       0       tlsproxy"/"tlsproxy  unix  -       -       y       -       0       tlsproxy"/ ${MASTER}
else
    # notice
    echo "Disabled DNSBL filtering as requested by the config"

    sed -i s/"^.*dnsbl.*$"/''/g ${MAIN}

    # enables simple smtp
    sed -i s/"^#smtp      inet  n       -       y       -       -       smtpd"/"smtp      inet  n       -       y       -       -       smtpd"/ ${MASTER}

    # disables postscreen, smtpd, dnsblog & tlsproxy
    sed -i s/"^smtp      inet  n       -       y       -       1       postscreen"/"#smtp      inet  n       -       y       -       1       postscreen"/ ${MASTER}
    sed -i s/"^smtpd     pass  -       -       y       -       -       smtpd"/"#smtpd     pass  -       -       y       -       -       smtpd"/ ${MASTER}
    sed -i s/"^dnsblog   unix  -       -       y       -       0       dnsblog"/"#dnsblog   unix  -       -       y       -       0       dnsblog"/ ${MASTER}
    sed -i s/"^tlsproxy  unix  -       -       y       -       0       tlsproxy"/"#tlsproxy  unix  -       -       y       -       0       tlsproxy"/ ${MASTER}
fi

### DUMP the configuration
cat ${MAIN} > /etc/postfix/main.cf
cat ${MASTER} > /etc/postfix/master.cf

# make postfix happy with premissions
chown -R root:postfix /etc/postfix
find /etc/postfix -type d -exec chmod 0750 {} \;
find /etc/postfix -type f -exec chmod g-w,o-w {} \;

### Accesory files folders
mkdir -p /var/spool/postfix

# postfix files to make postmap, with full path
PMFILES="/etc/postfix/rules/blacklist /etc/postfix/aliases/virtual_aliases"
for f in `echo "$PMFILES" | xargs` ; do
    postmap $f
done

ALIASES="/etc/aliases"
rm -f $ALIASES || exit 0
echo "# File modified at provision time, #MailAD" > $ALIASES
echo "postmaster:       root" >> $ALIASES
echo "clamav:		root" >> $ALIASES
echo "amavis:       root" >> $ALIASES
echo "spamasassin:       root" >> $ALIASES
echo "root:     $SYSADMINS" >> $ALIASES
# apply changes
/usr/bin/newaliases

### dhparms generation
if [ ! -f /certs/RSA2048.pem ] ; then
    echo "Generation of SAFE dhparam, this may take a time, be patient..."
    openssl dhparam -out /certs/RSA2048.pem -5 2048
    chmod 0644 /certs/RSA2048.pem
    echo "dhparam generated!"
else
    echo "DHparam already present, skiping generation!"
fi

# generate a Self-Signed cert/key if not present already on the /cert volume
if [ ! -f /certs/mail.crt -a ! -f /certs/mail.key ] ; then
    # no certs present.
    echo "WARNING! no cert found, generating a Self-Signed cert"

    openssl req -new -x509 -nodes -days 365 \
        -config /etc/postfix/postfix-openssl.cnf \
        -out /certs/mail.crt \
        -keyout /certs/mail.key
    chmod +r /certs/mail.key
else
    echo "SSL certs in place, skipping generation"
fi

if [ "$1" = 'postfix' ]; then
    if [ ! -f /certs/mail.crt -o ! -f /certs/mail.key -o ! -f /certs/RSA2048.pem ] ; then
        echo "Ooops! There is some SSL files missing"
        echo "We need a existing 'RSA2048.pem, mail.crt' & 'mail.key' files in the /certs volume!"
        exit 1
    fi

    # configure instance (populate etc)
    postconf compatibility_level=3.6
    /usr/lib/postfix/configure-instance.sh

    # check postfix is happy (also will fix some things)
    echo "postfix >> Checking Postfix Configuration"
    postfix -v check

    # start postfix in foreground
    exec /usr/sbin/postfix start-fg
fi

exec "$@"
