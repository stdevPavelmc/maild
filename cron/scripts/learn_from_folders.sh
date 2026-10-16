#!/bin/bash

# This script is part of MailD
# Copyright 2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goals:
#   - Feed the SpamAssassin Bayes database with fresh daily samples:
#       * SPAM: every message still sitting on the user's Junk folders
#         (the junk the users did not correct; the purge script keeps
#         them 7 days at most, so the corpus stays fresh)
#       * HAM: a small random sample of every user's INBOX; messages
#         flagged as spam are never learned as ham
#   - Sync the journal and let the db expire afterwards
#
# It runs daily on the cron container as root (vmail mounted) and it
# shares the bayes db with amavis (scans & autolearn) and with the mda
# container (instant learning via imapsieve).

# load the vars exported by the container entrypoint
source /etc/environment

VMAILSTORAGE=/home/vmail
HAM_PER_USER=${SA_HAM_SAMPLE_PER_USER:-25}
HAM_MAX_TOTAL=${SA_HAM_SAMPLE_MAX:-400}
BAYESDIR=/var/lib/spamassassin/bayes

# avoid running while another learning job is active
LOCK=/tmp/maild-sa-learn.lock
exec 200>${LOCK}
if ! flock -n 200 ; then
    logger -t sa-learn -p mail.warn "another bayes learning job is still running, exiting"
    exit 0
fi

# keep SA user state out of /root
export HOME=/tmp

# make sure the shared bayes folder is usable by every writer
# (amavis scans, this job and the vmail user on the mda container)
mkdir -p ${BAYESDIR}
chmod 0777 ${BAYESDIR}

SPAMLIST=$(mktemp)
HAMRAW=$(mktemp)
HAMLIST=$(mktemp)

# SPAM candidates: all messages on all Junk folders, skipping the ones
# flagged for deletion on the maildir flags (the letter 'T')
for JUNK in ${VMAILSTORAGE}/*/*/maildir/.Junk ; do
    [ -d "${JUNK}/cur" -a -d "${JUNK}/new" ] || continue
    find "${JUNK}/cur" "${JUNK}/new" -type f -size +0c -size -8M 2>/dev/null \
        | grep -Ev ':2,[A-Za-z]*T[A-Za-z]*$' >> ${SPAMLIST}
done

# HAM candidates: a random sample of every INBOX
for INBOXCUR in ${VMAILSTORAGE}/*/*/maildir/cur ; do
    [ -d "${INBOXCUR}" ] || continue
    NEW=$(find "${INBOXCUR}" "${INBOXCUR%cur}new" -type f -size +0c -size -8M 2>/dev/null \
        | shuf -n ${HAM_PER_USER})
    [ -n "${NEW}" ] && echo "${NEW}" >> ${HAMRAW}
done

# never learn spam-flagged messages as ham
while read -r f ; do
    if grep -qi -m 1 '^X-Spam-Flag:[[:space:]]*YES' "${f}" 2>/dev/null ; then
        continue
    fi
    echo "${f}" >> ${HAMLIST}
done < ${HAMRAW}

# cap the total amount of ham learned on a single run
if [ -s ${HAMLIST} ] ; then
    shuf -n ${HAM_MAX_TOTAL} ${HAMLIST} > ${HAMLIST}.tmp && mv ${HAMLIST}.tmp ${HAMLIST}
fi

# learn in batches (64 messages per sa-learn call)
LEARNED_SPAM=0
if [ -s ${SPAMLIST} ] ; then
    LEARNED_SPAM=$(tr '\n' '\0' < ${SPAMLIST} | \
        xargs -0 -n 64 sa-learn --spam --file 2>&1 | \
        awk '/Learned tokens from/ { gsub(/[^0-9]/, "", $4); s += $4 } END { print s + 0 }')
fi

LEARNED_HAM=0
if [ -s ${HAMLIST} ] ; then
    LEARNED_HAM=$(tr '\n' '\0' < ${HAMLIST} | \
        xargs -0 -n 64 sa-learn --ham --file 2>&1 | \
        awk '/Learned tokens from/ { gsub(/[^0-9]/, "", $4); s += $4 } END { print s + 0 }')
fi

# journal sync & db expiry
sa-learn --sync > /dev/null 2>&1

# keep the db usable by the other containers/users
chmod -R a+rwX ${BAYESDIR}

logger -t sa-learn -p mail.info \
    "bayes learning done: ${LEARNED_SPAM} spam learned from $(wc -l < ${SPAMLIST}) junk message(s); ${LEARNED_HAM} ham learned from $(wc -l < ${HAMLIST}) sampled INBOX message(s)"

rm -f ${SPAMLIST} ${HAMRAW} ${HAMLIST}
