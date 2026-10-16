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

# hostnames
# Postfix cannot look these up at runtime (mynetworks, the LMTP/SASL targets and the policy
# service only take literals), so the peer addresses get BAKED into main.cf/master.cf here.
# Resolving them exactly once, while a peer was not up yet, used to bake an EMPTY value -- and
# an empty address in the 10025 reinjection allow-list makes Postfix reject the content
# filter's return path ("554 5.7.1 Client host rejected: Access denied"), deferring every
# filtered message. So wait (bounded) for the peers, and refuse to start on an incomplete
# mail path instead of coming up silently broken.
PEER_WAIT_TIMEOUT=${PEER_WAIT_TIMEOUT:-120}
PEER_WATCH_INTERVAL=${PEER_WATCH_INTERVAL:-30}

resolve_peer() { # <hostname> -> IPv4 address on stdout, empty while it does not resolve yet
    host "$1" 2>/dev/null | awk '/has address/ { print $4; exit }'
}

wait_peer() { # <NAME> <hostname> <critical|best-effort> -> address on stdout (diagnostics on stderr)
    WP_IP=""
    WP_T=0
    while : ; do
        WP_IP="$(resolve_peer "$2")"
        if [ -n "$WP_IP" ] ; then
            break
        fi
        if [ "$WP_T" -ge "$PEER_WAIT_TIMEOUT" ] ; then
            if [ "$3" = "critical" ] ; then
                echo "ERROR: mta: '$2' is not resolvable after ${WP_T}s and it is part of the mail path." 1>&2
                echo "       Refusing to start: an empty address in main.cf/master.cf makes Postfix reject" 1>&2
                echo "       the content filter (554 Client host rejected: Access denied) and defer every" 1>&2
                echo "       message. Start '$2' first, or raise PEER_WAIT_TIMEOUT." 1>&2
                exit 1
            fi
            echo "WARNING: mta: '$2' is not resolvable after ${WP_T}s, continuing with $1 empty" 1>&2
            break
        fi
        echo "mta: waiting for '$2' to resolve... (${WP_T}s/${PEER_WAIT_TIMEOUT}s)" 1>&2
        sleep 3
        WP_T=$((WP_T+3))
    done
    echo "$WP_IP"
}

# AMAVISIP owns the 10025 reinjection allow-list; MDAIP carries LMTP delivery, SASL and the
# policy service. Either one missing means Postfix accepts mail and then defers it forever.
AMAVISIP="$(wait_peer AMAVISIP "${AMAVIS}" critical)" || exit 1
MDAIP="$(wait_peer MDAIP "${MDA}" critical)" || exit 1
MUAIP="$(wait_peer MUAIP "${MUA}" best-effort)"
ADMINIP="$(wait_peer ADMINIP "${ADMIN}" best-effort)"
# The container's own address, used for the _OWN_IP_ placeholder (the 10025 reinjection
# listener). It used to come from `ifconfig eth0` (net-tools), which no longer exists on
# resolute — and neither does iproute2 in this image — so it is resolved through libc from the
# name Docker publishes for this container (getent reads /etc/hosts first, then the compose DNS),
# with `hostname -i` as the fallback. Both are dependency-free.
OWN_IP="$(getent hosts "$(hostname)" | awk '/^[0-9]/ {print $1; exit}')"
[ -n "$OWN_IP" ] || OWN_IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
if [ -z "$OWN_IP" ] ; then
    echo "mta: WARNING - could not determine this container's IP, the 10025 listener will bind every interface" 1>&2
fi

echo "AMAVISIP=${AMAVISIP}" >> "${CFILE}"
echo "MDAIP=${MDAIP}" >> "${CFILE}"
echo "MUAIP=${MUAIP}" >> "${CFILE}"
echo "ADMINIP=${ADMINIP}" >> "${CFILE}"
echo "OWN_IP=${OWN_IP}" >> "${CFILE}"
#- set files for checks
echo "$AMAVISIP" > /tmp/AMAVISIP
echo "$MDAIP" > /tmp/MDAIP
echo "$MUAIP" > /tmp/MUAIP
echo "$ADMINIP" > /tmp/ADMINIP
echo "$OWN_IP" > /tmp/OWNIP

# postgresql data
echo "POSTGRES_HOST=${POSTGRES_HOST}" >> "${CFILE}"
echo "POSTGRES_DB=${POSTGRES_DB}" >> "${CFILE}"
echo "POSTGRES_USER=${POSTGRES_USER}" >> "${CFILE}"
echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "${CFILE}"
# dnsbl
echo "DNSBL_LIST='${DNSBL_LIST}'" >> "${CFILE}"

# config dump
if [ "${MTA_DEBUG}" ] ; then
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

# --- first-boot provisioning gate ------------------------------------------
# The virtual_aliases are built from the domain list (POSTMASTER_ABUSE_SETUP), so wait
# (bounded) for the admin container to finish provisioning the catalogue before we read it:
# a fresh deploy then comes up with the aliases in place and no manual restart. Opt out with
# AUTO_PROVISION=no.
if [ "${AUTO_PROVISION:-yes}" != "no" ] ; then
    echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
    chmod 0600 ~/.pgpass
    T=0
    while : ; do
        if [ "$(psql -tAq -w -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
                -c "SELECT 1 FROM maild_provision WHERE id=1 AND version >= ${PROVISION_VERSION:-1}" 2>/dev/null)" = "1" ] ; then
            echo "mta: catalogue is provisioned, configuring"
            break
        fi
        if [ "$T" -ge "${PROVISION_WAIT_TIMEOUT:-180}" ] ; then
            echo "mta: WARNING - catalogue not provisioned after ${T}s, continuing"
            break
        fi
        sleep 3 ; T=$((T+3))
    done
fi

# handle abuse and postmaster locally [not by default]
VALIASEFILE="/etc/postfix/aliases/virtual_aliases"
if [ "$POSTMASTER_ABUSE_SETUP" ] ; then

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

        # match any domain like string on the results
        cat /tmp/domains.txt | grep -E '\b[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b' | tr -d ' ' | xargs
    }

    # cycle through domains, if any
    DOMAINS=$(get_domains)
    if [ "$DOMAINS" ] ; then
        for DOMAIN in $DOMAINS ; do
            # create the postmaster
            echo "Creating postmaster and abuse for domain '$DOMAIN'"

            # postmaster
            if [ -z "$(grep 'postmaster@$DOMAIN    $MAILADMIN')" ] ; then
                echo "postmaster@$DOMAIN    $MAILADMIN" >> $VALIASEFILE
            fi
            # abuse
            if [ -z "$(grep 'abuse@$DOMAIN    $MAILADMIN')" ] ; then
                echo "abuse@$DOMAIN    $MAILADMIN" >> $VALIASEFILE
            fi
        done

        # dump the alias file if DEBUG is active
        if [ "$DEBUG" ] ; then
            cat $VALIASEFILE
        fi
    else
        echo "No domains found in the database, exiting"
        exit 1
    fi
fi

# postfix files to make postmap, with full path
# TODO: everyone?
PMFILES="/etc/postfix/rules/blacklist $VALIASEFILE /etc/postfix/rules/everyone_list_check"
for f in `echo "$PMFILES" | xargs` ; do
    # if the file does not exist, create it
    if [ ! -f $f ] ; then
        touch $f
    fi

    # postmapping
    postmap $f
done

### dhparms generation
# Postfix 3.10 obsoleted smtpd_tls_dh1024_param_file (3.9 deprecated it; with ECDHE auto-curves
# the DHE parameters are not needed), so this container neither references nor generates
# /certs/RSA2048.pem any more: the mda owns that file in the shared /certs volume (it is its
# ssl_server_dh_file) and generates it on its own first boot.

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

# Remove references for manual files for set-perms to make it happy
cat /etc/postfix/postfix-files | sed "s|^.*directory/man.*$||g" | uniq > /tmp/1
cat /tmp/1 > /etc/postfix/postfix-files
for f in /etc/postfix/postfix-files.d/* ; do
    sed "s|^.*directory/man.*$||g" -i $f
done

# --- peer-IP watchdog ---------------------------------------------------------
# A peer container (re)created after this one started comes back with a NEW address, while the
# address baked above stays in mynetworks, in the 10025 allow-list and in the LMTP / SASL /
# policy targets -> every message silently starts deferring until the mta is restarted by hand.
# Re-resolve the peers every PEER_WATCH_INTERVAL seconds and repatch ONLY the effective
# addresses (the boot render stays the source of truth for the structure), then reload
# Postfix. Set PEER_WATCH_INTERVAL=0 to disable, e.g. on a fully static deployment.
patch_param() { # <main.cf parameter> <old address> <new address> -> 0 when it was repatched
    PP_CUR="$(postconf -h "$1" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    PP_NEW="$(printf '%s' "$PP_CUR" | sed "s/${2//./\\.}/${3}/g")"
    if [ -n "$PP_CUR" ] && [ "$PP_CUR" != "$PP_NEW" ] ; then
        postconf -e "$1=$PP_NEW" >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

patch_instance() { # <service/type> <parameter> <old address> <new address> -> 0 when repatched
    PI_CUR="$(postconf -M "$1" 2>/dev/null | sed -n "s/.*-o ${2}=//p" | awk '{print $1}')"
    PI_NEW="$(printf '%s' "$PI_CUR" | sed "s/${3//./\\.}/${4}/g")"
    if [ -n "$PI_CUR" ] && [ "$PI_CUR" != "$PI_NEW" ] ; then
        postconf -P "$1/${2}=${PI_NEW}" >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

peer_watchdog() {
    while : ; do
        sleep "$PEER_WATCH_INTERVAL"

        W_AMAVISIP="$(resolve_peer "${AMAVIS}")"
        W_MDAIP="$(resolve_peer "${MDA}")"
        W_MUAIP="$(resolve_peer "${MUA}")"
        W_ADMINIP="$(resolve_peer "${ADMIN}")"
        W_CHANGED=0

        for W_PAIR in "AMAVISIP:${AMAVISIP}:${W_AMAVISIP}" \
                      "MDAIP:${MDAIP}:${W_MDAIP}" \
                      "MUAIP:${MUAIP}:${W_MUAIP}" \
                      "ADMINIP:${ADMINIP}:${W_ADMINIP}" ; do
            W_NAME="$(printf '%s' "$W_PAIR" | cut -d: -f1)"
            W_OLD="$(printf '%s' "$W_PAIR" | cut -d: -f2)"
            W_NEW="$(printf '%s' "$W_PAIR" | cut -d: -f3)"

            # a lookup that fails right now yields an empty value: keep the baked address and
            # retry next round -- never repatch with an empty one (the bug this watchdog exists for)
            if [ -z "$W_OLD" ] || [ -z "$W_NEW" ] || [ "$W_OLD" = "$W_NEW" ] ; then
                continue
            fi

            echo "mta: ${W_NAME} moved ${W_OLD} -> ${W_NEW}, repatching the Postfix maps"
            for W_P in mynetworks smtpd_sasl_path virtual_transport smtpd_recipient_restrictions ; do
                patch_param "$W_P" "$W_OLD" "$W_NEW" || true
            done
            patch_instance "${OWN_IP}:10025/inet" mynetworks "$W_OLD" "$W_NEW" || true
            patch_instance "${OWN_IP}:10025/inet" smtpd_authorized_xforward_hosts "$W_OLD" "$W_NEW" || true

            # keep this loop's bookkeeping and the healthcheck files in sync
            case "$W_NAME" in
                AMAVISIP) AMAVISIP="$W_NEW" ; echo "$W_NEW" > /tmp/AMAVISIP ;;
                MDAIP)    MDAIP="$W_NEW"    ; echo "$W_NEW" > /tmp/MDAIP ;;
                MUAIP)    MUAIP="$W_NEW"    ; echo "$W_NEW" > /tmp/MUAIP ;;
                ADMINIP)  ADMINIP="$W_NEW"  ; echo "$W_NEW" > /tmp/ADMINIP ;;
            esac
            W_CHANGED=1
        done

        if [ "$W_CHANGED" = 1 ] ; then
            if postfix check >/dev/null 2>&1 ; then
                if postfix reload ; then
                    echo "mta: configuration reloaded with the new peer addresses"
                else
                    echo "mta: WARNING - 'postfix reload' failed, the old addresses are still active"
                fi
            else
                echo "mta: WARNING - 'postfix check' rejected the repatched configuration, not reloading"
            fi
        fi
    done
}

# let's start...
if [ "$1" = 'postfix' ]; then
    # only the certificate pair is required here: the DH params belong to the mda now
    if [ ! -f /certs/mail.crt -o ! -f /certs/mail.key ] ; then
        echo "Ooops! There is some SSL files missing"
        echo "We need a existing 'mail.crt' & 'mail.key' files in the /certs volume!"
        exit 1
    fi

    # configure instance (populate etc)
    # compatibility_level comes from main.cf.s (3.9, the value the resolute Postfix ships) — it
    # used to be forced here, which silently overrode whatever the template said.
    # /usr/lib/postfix/configure-instance.sh is NOT called directly any more: Debian's Postfix
    # 3.10 version refuses to run outside postfix-script ("E: This is internal script used by
    # postfix") because it expects that caller's environment. postfix-script runs it itself every
    # time an instance starts — the chroot sync it performs is already visible in the logs of the
    # `postfix set-permissions` above — which is its designed path.
    postfix set-permissions

    # check postfix is happy (also will fix some things)
    echo "postfix >> Checking Postfix Configuration"
    postfix -v check
    if [ $? -ne 0 ] ; then
        echo "postfix >> Postfix is NOT OK"
        exit 1
    else
        echo "postfix >> Postfix is OK, starting"
    fi

    # Peer-IP watchdog: a peer recreated later gets a new address, which would leave the baked
    # allow-list / transport targets stale (see patch_param above). Disabled with 0.
    if [ "${PEER_WATCH_INTERVAL:-30}" -gt 0 ] ; then
        peer_watchdog &
        echo "mta: peer-IP watchdog started (every ${PEER_WATCH_INTERVAL}s)"
    else
        echo "mta: peer-IP watchdog disabled (PEER_WATCH_INTERVAL=${PEER_WATCH_INTERVAL})"
    fi

    # start postfix in foreground
    exec /usr/sbin/postfix start-fg
fi

exec "$@"
