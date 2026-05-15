#!/bin/bash

# This script is part of MailD
# Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>

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
