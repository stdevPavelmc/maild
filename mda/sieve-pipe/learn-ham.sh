#!/bin/sh
#
# MailD imapsieve pipe helper: learn the piped message as HAM.
# Called by the global learn-ham.sieve script when a user moves a
# message OUT of the Junk mailbox (a false positive correction).
# Messages still flagged as spam are skipped. Runs as the vmail user
# on the mda container. Never fails the user's IMAP operation.

TMP=$(mktemp /tmp/sa-learn-XXXXXXXX.eml)
cat > ${TMP}

# a message still flagged as spam must not be learned as ham
if grep -qi -m 1 '^X-Spam-Flag:[[:space:]]*YES' ${TMP} ; then
    logger -t sa-imapsieve -p mail.info "message is spam-flagged, skipped ham learning"
    rm -f ${TMP}
    exit 0
fi

# keep the shared bayes folder usable (first run may find it missing)
mkdir -p /var/lib/spamassassin/bayes 2>/dev/null || true
chmod 0777 /var/lib/spamassassin/bayes 2>/dev/null || true

HOME=/tmp sa-learn --ham --no-sync --file ${TMP} > /dev/null 2>&1
R=$?

rm -f ${TMP}
logger -t sa-imapsieve -p mail.info "learned a message as ham (rc=${R})"

# always succeed: a learning failure must not disturb the IMAP session
exit 0
