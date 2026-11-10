#!/bin/bash
set -m -o pipefail

# NOTE: on the resolute (26.04) base the daemon is /usr/sbin/amavisd: the amavisd-new 2.13
# package dropped the /usr/sbin/amavisd-new name jammy shipped. See
# .agents/devops/base-os-upgrade.md.

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
# tune it via env vars on the amavis container (see env.sample)
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

# the MailD MCP is optional and starts after amavis: an unresolved name just leaves it out of
# the 10026 ACL until the watchdog sees it
MCPIP=`host ${MCP:-mcp} 2>/dev/null | awk '/has address/ { print $4; exit }'`

# IP data for the checks
echo $CLAMAVIP > /tmp/CLAMAVIP
echo $MTAIP > /tmp/MTAIP
echo $CRONIP > /tmp/CRONIP
echo $MCPIP > /tmp/MCPIP

# --- listener ACLs (D13) -------------------------------------------------------
# 10024 (bank MTA) admits only the mta, 10026 (bank INTERNAL) only cron and mcp; loopback is
# always in (check.sh). Rendered into its own file so the peer-IP watchdog can rewrite it
# wholesale and reload amavisd, instead of patching addresses inside the distro files.
ACL_FILE=/etc/amavis/conf.d/52-maild-acl
render_acl() { # <mta ip> <cron ip> <mcp ip or empty>
    {
        echo "# MailD: rendered by docker-entrypoint.sh (boot + peer-IP watchdog) — do not edit"
        echo "\$policy_bank{'MTA'}{inet_acl} = [qw( 127.0.0.1 [::1] ${1} )];"
        echo "\$policy_bank{'INTERNAL'}{inet_acl} = [qw( 127.0.0.1 [::1] ${2} ${3} )];"
        echo "1;"
    } > "${ACL_FILE}.new"
    chmod 0644 "${ACL_FILE}.new"
    mv -f "${ACL_FILE}.new" "${ACL_FILE}"
}
render_acl "${MTAIP}" "${CRONIP}" "${MCPIP}"
echo "amavis: listener ACLs 10024=[mta ${MTAIP}] 10026=[cron ${CRONIP}${MCPIP:+, mcp ${MCPIP}}]"

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

# RSA size of NEW DKIM keys (image default 2048; 2026-10 audit L-06). Anything but a
# supported size falls back to 2048 — never below it.
case "${DKIM_KEY_BITS}" in
    2048|3072|4096) ;;
    *)
        [ -n "${DKIM_KEY_BITS}" ] && echo "WARNING: amavis: DKIM_KEY_BITS='${DKIM_KEY_BITS}' is not 2048/3072/4096, using 2048" 1>&2
        DKIM_KEY_BITS=2048
        ;;
esac

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
                    # RFC 8301: 1024-bit keys are deprecated (2026-10 audit L-06). Only NEW keys use
                    # DKIM_KEY_BITS: an existing key is never rotated (see INSTALL.md, DKIM).
                    /usr/sbin/amavisd genrsa ${KEY} ${DKIM_KEY_BITS}
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
                amavisd showkeys ${DOMAIN} | tee /var/lib/amavis/dkim/${DOMAIN}.${SELECTOR}.txt
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
/usr/sbin/amavisd test-config

# results
R=$?
if [ ! $R -eq 0 ] ; then
    echo "Amavis config testing failed"
    exit 1
fi

# test amavis config
rm /var/run/amavis/amavisd.pid 2> /dev/null
/usr/sbin/amavisd -i docker test-config
if [ $? -ne 0 ] ; then
    echo "Amavis config testing failed"
    exit 1
fi

# starting amavis
echo "Starting amavis"

# keep the SpamAssassin rules fresh in the background (daily sa-update
# + amavisd reload after new rules are installed)
/sa-update-loop.sh &

# --- peer-IP watchdog (same idea as the mta's) ------------------------------------
# A peer recreated after amavis started comes back with a new address that the ACLs do not
# know: its mail would be refused until amavis restarts. Every PEER_WATCH_INTERVAL seconds,
# re-resolve mta/cron/mcp; on any change re-render 52-maild-acl and HUP amavisd (a reload
# re-reads the whole configuration, inet_acl included). A lookup that fails right now keeps the
# previous address (never an ACL without the mta or cron); mcp may disappear. 0 = disabled.
acl_watchdog() {
    while : ; do
        sleep "${PEER_WATCH_INTERVAL}"
        W_MTA=`host ${MTA} 2>/dev/null | awk '/has address/ { print $4; exit }'`
        W_CRON=`host ${CRON} 2>/dev/null | awk '/has address/ { print $4; exit }'`
        W_MCP=`host ${MCP:-mcp} 2>/dev/null | awk '/has address/ { print $4; exit }'`
        [ -n "${W_MTA}" ] || W_MTA="${MTAIP}"
        [ -n "${W_CRON}" ] || W_CRON="${CRONIP}"
        if [ "${W_MTA}" != "${MTAIP}" ] || [ "${W_CRON}" != "${CRONIP}" ] || [ "${W_MCP}" != "${MCPIP}" ] ; then
            echo "amavis: peers moved (mta ${MTAIP}->${W_MTA} cron ${CRONIP}->${W_CRON} mcp ${MCPIP:-none}->${W_MCP:-none}), re-rendering the listener ACLs"
            MTAIP="${W_MTA}" ; CRONIP="${W_CRON}" ; MCPIP="${W_MCP}"
            render_acl "${MTAIP}" "${CRONIP}" "${MCPIP}"
            echo "${MTAIP}" > /tmp/MTAIP ; echo "${CRONIP}" > /tmp/CRONIP ; echo "${MCPIP}" > /tmp/MCPIP
            if [ -f /var/run/amavis/amavisd.pid ] ; then
                kill -HUP "$(cat /var/run/amavis/amavisd.pid)" && echo "amavis: reloaded with the new ACLs"
            else
                echo "amavis: WARNING - pid file not found, ACLs rendered but amavisd NOT reloaded"
            fi
        fi
    done
}
if [ "${PEER_WATCH_INTERVAL:-30}" -gt 0 ] 2>/dev/null ; then
    acl_watchdog &
    echo "amavis: peer-IP watchdog started (every ${PEER_WATCH_INTERVAL}s)"
else
    echo "amavis: peer-IP watchdog disabled (PEER_WATCH_INTERVAL=${PEER_WATCH_INTERVAL})"
fi

/usr/sbin/amavisd -u amavis -g amavis -i docker foreground
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
