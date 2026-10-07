#!/bin/sh
#
# MailD imapsieve pipe helper: learn the piped message as SPAM.
# Called by the global learn-spam.sieve script when a user moves a
# message INTO the Junk mailbox. Runs as the vmail user on the mda
# container. Never fails the user's IMAP operation.

TMP=$(mktemp /tmp/sa-learn-XXXXXXXX.eml)
cat > ${TMP}

# keep the shared bayes folder usable (first run may find it missing)
mkdir -p /var/lib/spamassassin/bayes 2>/dev/null || true
chmod 0777 /var/lib/spamassassin/bayes 2>/dev/null || true

HOME=/tmp sa-learn --spam --no-sync --file ${TMP} > /dev/null 2>&1
R=$?

rm -f ${TMP}
logger -t sa-imapsieve -p mail.info "learned a message as spam (rc=${R})"

# always succeed: a learning failure must not disturb the IMAP session
exit 0
