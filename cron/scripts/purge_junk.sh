#!/bin/bash

# This script is part of MailD
# Copyright 2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goals:
#   - Cycle trough all mailboxes and empty the Junk folder of every
#     message older than JUNK_RETENTION_DAYS days (default 7)
#   - Log a summary to syslog
#
# It runs daily on the cron container (root), that has the vmail
# storage mounted on /home/vmail

# load the vars exported by the container entrypoint
source /etc/environment

VMAILSTORAGE=/home/vmail
RETENTION_DAYS=${JUNK_RETENTION_DAYS:-7}

# a value of 0 or less disables the purge
if [ "${RETENTION_DAYS}" -le 0 ] ; then
    logger -t junk-purge -p mail.info "junk purge disabled (JUNK_RETENTION_DAYS=${RETENTION_DAYS}), exiting"
    exit 0
fi

MINUTES=$((RETENTION_DAYS * 24 * 60))
TOTAL=0
FREEDKB=0
BOXES=0

# a user's maildir is /home/vmail/<domain>/<user>/maildir and the Junk
# folder on the Maildir++ layout is the sibling folder named ".Junk"
shopt -s nullglob
for JUNK in ${VMAILSTORAGE}/*/*/maildir/.Junk ; do
    # skip broken maildirs (no cur/new inside)
    if [ ! -d "${JUNK}/cur" -o ! -d "${JUNK}/new" ] ; then
        continue
    fi
    BOXES=$((BOXES + 1))

    # messages to erase: the file mtime is the delivery/copy time
    COUNT=$(find "${JUNK}/cur" "${JUNK}/new" -type f -mmin +${MINUTES} 2>/dev/null | wc -l)
    if [ ${COUNT} -eq 0 ] ; then
        continue
    fi

    SIZEBEFORE=$(du -sk "${JUNK}" 2>/dev/null | cut -f1)
    find "${JUNK}/cur" "${JUNK}/new" -type f -mmin +${MINUTES} -delete 2>/dev/null
    SIZEAFTER=$(du -sk "${JUNK}" 2>/dev/null | cut -f1)

    TOTAL=$((TOTAL + COUNT))
    FREEDKB=$((FREEDKB + SIZEBEFORE - SIZEAFTER))
done
shopt -u nullglob

if [ ${TOTAL} -gt 0 ] ; then
    logger -t junk-purge -p mail.info \
        "purged ${TOTAL} junk message(s) older than ${RETENTION_DAYS} day(s) from ${BOXES} mailbox(es), ~$((FREEDKB / 1024)) MB freed"
else
    logger -t junk-purge -p mail.info \
        "no junk messages older than ${RETENTION_DAYS} day(s) to purge (${BOXES} mailbox(es) scanned)"
fi
