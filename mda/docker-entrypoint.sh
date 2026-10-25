#!/bin/sh
set -e

# SpamAssassin shared config: seed the shared volume is a tash of amavis 
# Wait for amavis to populate the shared volume on the first boot of the container
while [ ! -f /etc/spamassassin/init.pre ]; do
    echo "==> Waiting for Spamassassin to be populated from amavis container"
    sleep 3
done

# shared bayes folder: usable by amavis (scans), root (cron) and the
# vmail user (this container, imapsieve learning)
mkdir -p /var/lib/spamassassin/bayes
chmod 0777 /var/lib/spamassassin/bayes

if [ ! -f /etc/dovecot/configured ]; then
    # create the local config file
    CFILE=/etc/dovecot/config.local
    # Domain
    echo "MAIL_ADMIN_USER"=${MAIL_ADMIN_USER} > "${CFILE}"
    echo "DEFAULT_DOMAIN=${DEFAULT_DOMAIN}" >> "${CFILE}"
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
    if [ "${MDA_DEBUG_INIT}" ] ; then
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

    # NOTE: the imapsieve learning scripts are compiled lazily by dovecot
    # on their first use, no need to sieve them here; they cache their binary
    # in /var/lib/dovecot/sieve/imapsieve (bin_path in 90-imapsieve.conf)

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

    # debug
    if [ "${MDA_DEBUG_AUTH}" ]; then
        # set auth_verbose & auth_debug to yes
        sed -i s/"^auth_verbose .*$"/"auth_verbose = yes"/g /etc/dovecot/conf.d/10-logging.conf
        sed -i s/"^auth_debug .*$"/"auth_debug = yes"/g /etc/dovecot/conf.d/10-logging.conf

        echo "Auth verbose logging set to yes"
    fi
    if [ "${MDA_DEBUG_AUTH_PASSWORD}" ]; then
        # set auth_verbose_passwords & auth_debug_passwords to yes
        sed -i s/"^auth_verbose_passwords .*$"/"auth_verbose_passwords = yes"/g /etc/dovecot/conf.d/10-logging.conf
        sed -i s/"^auth_debug_passwords .*$"/"auth_debug_passwords = yes"/g /etc/dovecot/conf.d/10-logging.conf

        echo "Auth passwords verbose logging set to yes"
    fi
    if [ "${MDA_DEBUG_MAIL}" ]; then
        # set mail_debug to yes
        sed -i s/"^mail_debug .*$"/"mail_debug = yes"/g /etc/dovecot/conf.d/10-logging.conf

        echo "Mail verbose logging set to yes"
    fi
    if [ "${MDA_DEBUG_SSL}" ]; then
        # Dovecot 2.4 removed verbose_ssl (the setting is no longer accepted), so there
        # is nothing to flip here: TLS-level detail is requested through log_debug with
        # an event filter, which is left to the operator (see env.sample).
        echo "MDA_DEBUG_SSL: verbose_ssl was removed in Dovecot 2.4, no-op (see env.sample)"
    fi

    # create the flag file
    touch /etc/dovecot/configured
    echo "Flag created: container ready!"

    # debug, remove the config file at the end or not if debugging
    if [ -z "${MDA_DEBUG_INIT}" ] ; then
        rm ${CFILE}
    fi
fi

if [ "$1" = 'dovecot' ]; then
    if [ ! -f /certs/mail.crt -o ! -f /certs/mail.key -o ! -f /certs/RSA2048.pem ] ; then
        echo "Ooops! There is some SSL files missing"
        echo "We need a valid 'mail.crt' & 'mail.key' files in the /certs volume!"
        exit 1
    fi

    # --- password-scheme posture (2026-10 audit F-18) -------------------------
    # Weak-scheme (md5crypt) support is a timed coexistence window: it ends on
    # 2027-02-01. Until then legacy raw $1$ hashes keep verifying (see 10-auth.conf);
    # new hashes are Argon2id ({ARGON2ID} prefix, written by the AdminNG API, the
    # webmail change-password driver and the api seeder). This gate runs on EVERY boot
    # (configure.sh only runs on first boot) so the deadline is honored by running
    # containers after a restart, not only by fresh deployments. From the date,
    # auth_allow_weak_schemes goes back to 'no' and legacy mailboxes stop
    # authenticating — `adminng.py --legacy-hashes` lists the rows to migrate, and
    # rehash-on-login migrates them automatically as users authenticate.
    if [ "$(date -u +%Y%m%d)" -ge 20270201 ] ; then
        WEAK_SCHEMES=no
        echo "mda: WARNING - weak-scheme (md5crypt) support ENDED on 2027-02-01." >&2
        echo "mda: WARNING - mailboxes still on legacy \$1\$ hashes can no longer authenticate;" >&2
        echo "mda: WARNING - check 'adminng.py --legacy-hashes' and migrate those accounts." >&2
    else
        WEAK_SCHEMES=yes
        # Track migration progress: count the legacy $1$ rows once per boot
        # (best effort — a slow/unavailable db must never block startup). They
        # migrate on password change or on the next IMAP/POP3 login
        # (rehash-on-login, scripts/rehash-password.sh).
        LEGACY_ROWS="$(PGPASSWORD="${POSTGRES_PASSWORD:-}" psql -q -w -X \
            -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" \
            -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -A -c \
            "SELECT count(*) FROM mailbox WHERE password LIKE '\$1\$%'" 2>/dev/null || true)"
        if [ -n "${LEGACY_ROWS}" ] && [ "${LEGACY_ROWS}" -gt 0 ] 2>/dev/null ; then
            echo "mda: WARNING - ${LEGACY_ROWS} mailbox(es) still use legacy md5crypt (\$1\$) hashes." >&2
            echo "mda: WARNING - weak-scheme support ends 2027-02-01 and they will stop authenticating;" >&2
            echo "mda: WARNING - they migrate on password change or on their next IMAP/POP3 login." >&2
            echo "mda: WARNING - (rehash-on-login is skipped when PASSWORD_SCHEME=md5crypt)." >&2
            echo "mda: WARNING - progress: 'adminng.py --legacy-hashes' (in the api container)." >&2
        fi
    fi
    sed -i "s/^auth_allow_weak_schemes.*/auth_allow_weak_schemes = ${WEAK_SCHEMES}/" \
        /etc/dovecot/conf.d/10-auth.conf

    # daily mailbox quota report: a background loop that mails the admin the
    # mailboxes over QUOTA_REPORT_THRESHOLD (80% by default) on the first tick
    # past QUOTA_REPORT_HOUR:QUOTA_REPORT_MINUTE (00:01 by default) with no
    # report yet today. It never blocks dovecot and logs to the container log.
    # Force one right away with:
    #   docker compose exec mda /scripts/quota_report.sh --now
    /scripts/quota_report.sh --loop >/proc/1/fd/1 2>/proc/1/fd/2 &
    echo "Quota report loop started (daily past ${QUOTA_REPORT_HOUR:-0}:${QUOTA_REPORT_MINUTE:-1})"

    # start dovecot in foreground 
    exec /usr/sbin/dovecot -F < /dev/null
fi

exec "$@"
