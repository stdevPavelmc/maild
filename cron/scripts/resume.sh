#!/bin/bash

# This script is part of MailD
# Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goals:
#   - Create a resume of yesterday mail services
#     Yesterday is defined as today -1 day
#   - Send it to the mail admin

# loading vars
if [ "$1" = "today" ]; then
    DAY=$(date +" %b %d ")
else
    DAY=$(date -d "1 day ago" +" %b %d ")
fi
# we redirect logs to syslogg and it goes to /var/log/syslog
FILES="/var/log/syslog.1 /var/log/syslog"
TMP=$(mktemp)
RESUME=$(mktemp)
# emails to the sysadmins group or the mailadmin?
TO="${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}"
# which server to send email to?
SERVER=`host amavis | awk '/has address/ { print $4 }'`

# Notice
echo "MailD: Sending the mail traffic summary for ($DAY) to $TO"

# parse files
cat ${FILES} | grep ${MTA} | grep "${DAY}" | \
    grep -v localhost | grep -v '127.0.0.1' | \
    sed -E 's/.* ([A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*)/\1/' \
    > ${TMP}

# ejecutando
/usr/sbin/pflogsumm -i --iso-date-time --problems-first $TMP > ${RESUME}

# weekly SpamAssassin / Bayes health stats, appended to the resume on Sundays
if [ "$(date +%u)" == "7" ] ; then
    MAGIC=$(HOME=/tmp sa-learn --dump magic 2>/dev/null)
    NSPAM=$(echo "${MAGIC}" | awk '/non-token data: nspam/   { v=0; for (i=1; i<=4; i++) if ($i+0 > v) v=$i+0; print v }')
    NHAM=$(echo "${MAGIC}"  | awk '/non-token data: nham/    { v=0; for (i=1; i<=4; i++) if ($i+0 > v) v=$i+0; print v }')
    NTOK=$(echo "${MAGIC}"  | awk '/non-token data: ntokens/ { v=0; for (i=1; i<=4; i++) if ($i+0 > v) v=$i+0; print v }')
    BAL=$(awk -v s=${NSPAM:-0} -v h=${NHAM:-0} 'BEGIN { if (s>0 && h>0) printf "%.2f", s/h; else print "n/a" }')

    echo "" >> ${RESUME}
    echo "=== SpamAssassin / Bayes weekly health ==================================" >> ${RESUME}
    echo "Bayes learned so far: ${NSPAM:-0} spam / ${NHAM:-0} ham messages (${NTOK:-0} tokens)" >> ${RESUME}
    echo "Spam/Ham balance (spam/ham): ${BAL}" >> ${RESUME}

    # freshness of the rules channel, sa-update must run daily on amavis
    UPDIR=$(ls -td /var/lib/spamassassin/*/updates_spamassassin_org 2>/dev/null | head -n1)
    if [ -n "${UPDIR}" ] ; then
        AGE=$(( ( $(date +%s) - $(stat -c %Y "${UPDIR}") ) / 86400 ))
        echo "SA rules channel: last update ${AGE} day(s) ago" >> ${RESUME}
        if [ ${AGE} -gt 7 ] ; then
            echo "WARNING: the rule updates seem stalled, review the amavis container logs!" >> ${RESUME}
        fi
    else
        echo "WARNING: no sa-update ruleset found on /var/lib/spamassassin!" >> ${RESUME}
    fi
fi

# email
swaks \
    --server ${SERVER} \
    --port 10024 \
    --protocol SMTP \
    --to $TO \
    --from $TO \
    --header "Subject: [OK] MailD Daily stats resume..." \
    --body @${RESUME} > /dev/null

# cleaning
rm $TMP $RESUME
