#!/bin/bash

# This script is part of MailD
# Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goal:
#   - Create a daily backup of the PostgreSQL database
#   - Keep backups for 15 days (retention policy)
#   - Compress backups to save space
#   - Send notification to admin on success/failure
#
# A failed dump MUST be reported as a failure. This script used to pipe pg_dump into gzip
# and test the exit status of that pipeline, which is gzip's: a pg_dump that aborted (the
# usual cause being "server version mismatch", a client older than the server, which writes
# nothing on stdout) still produced a 20-byte .gz, sailed through the `[ -s file ]` check and
# was mailed as SUCCESS. Now: `set -o pipefail`, pg_dump's own status is read from PIPESTATUS,
# its stderr goes to the log, the client/server version pair is checked up front and the
# archive is validated (minimum size, `gzip -t` and the pg_dump header/trailer markers)
# before it is called a backup. An unusable archive is deleted, never kept.

# Import environment variables
source /etc/environment

# a failure of any stage of a pipeline is a failure of the pipeline (pg_dump | gzip).
# No `set -e`: on failure the script must carry on to the notification mail.
set -o pipefail

# Configuration
BACKUP_DIR="/backups/db"
BACKUP_RETENTION_DAYS=15
# An empty dump compressed is ~20 bytes and a real mailddb dump is tens of KB, so anything
# below this is not a backup (overridable from the environment).
BACKUP_MIN_BYTES="${BACKUP_MIN_BYTES:-1024}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/maild_backup_${DATE}.sql.gz"
LOG_FILE="${BACKUP_DIR}/backup.log"

# Ensure backup directory exists
mkdir -p ${BACKUP_DIR}

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a ${LOG_FILE}
}

# State carried into the notification mail
BACKUP_STATUS="SUCCESS"
BACKUP_SIZE="n/a"
BACKUP_BYTES=0
BACKUP_TABLES=0
FAIL_REASON=""

# Record a failure, log the reason and drop the archive: a truncated/empty .gz left behind
# would be counted as a backup by the retention pass and by the "recent backups" listing.
fail() {
    BACKUP_STATUS="FAILED"
    FAIL_REASON="$1"
    log "ERROR: $1"
    if [ -f "${BACKUP_FILE}" ]; then
        rm -f "${BACKUP_FILE}"
        log "Removed the unusable archive: $(basename ${BACKUP_FILE})"
    fi
}

# Start backup
log "=== Starting PostgreSQL backup ==="

# Setup the postgres credentials & secure it
echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
chmod 0600 ~/.pgpass

# pg_dump refuses to dump a server newer than itself and prints nothing on stdout, so check
# the pair before dumping: the client is baked into this image (cron/Dockerfile, PG_CLIENT_MAJOR)
# and the server is pinned by db/Dockerfile. server_version_num is e.g. 150019 for 15.19.
CLIENT_VERSION=$(pg_dump --version 2>&1 | awk '{ print $3 }')
CLIENT_MAJOR="${CLIENT_VERSION%%.*}"
SERVER_VERSION_NUM=$(psql -h ${POSTGRES_HOST} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -w \
    -tAc "SHOW server_version_num" 2>> ${LOG_FILE} | tr -d '[:space:]')

case "${CLIENT_MAJOR}" in
    ''|*[!0-9]*)
        fail "pg_dump is unusable here: 'pg_dump --version' reported '${CLIENT_VERSION}'"
        ;;
esac

if [ "${BACKUP_STATUS}" = "SUCCESS" ]; then
    if [ -n "${SERVER_VERSION_NUM}" ]; then
        SERVER_MAJOR=$(( SERVER_VERSION_NUM / 10000 ))
        log "Versions: client pg_dump ${CLIENT_VERSION} / server ${SERVER_MAJOR}"
        if [ "${CLIENT_MAJOR}" -lt "${SERVER_MAJOR}" ]; then
            fail "pg_dump ${CLIENT_VERSION} is older than the server (major ${SERVER_MAJOR}) and refuses to dump it: rebuild the cron image with PG_CLIENT_MAJOR=${SERVER_MAJOR} (cron/Dockerfile)"
        fi
    else
        log "WARNING: could not read the server version, skipping the version check"
    fi
fi

# Perform the backup with pg_dump and compress on the fly
if [ "${BACKUP_STATUS}" = "SUCCESS" ]; then
    log "Backing up database: ${POSTGRES_DB} from ${POSTGRES_HOST}"

    DUMP_ERR=$(mktemp)

    # pg_dump's stderr goes to its own file: redirecting the pipeline's stderr (as before)
    # only captured gzip's, so the real error never reached ${LOG_FILE}
    pg_dump -h ${POSTGRES_HOST} \
            -U ${POSTGRES_USER} \
            -d ${POSTGRES_DB} \
            -w \
            --no-owner \
            --no-acl \
            2> ${DUMP_ERR} \
        | gzip > ${BACKUP_FILE} 2>> ${LOG_FILE}

    # PIPESTATUS is overwritten by the very next command — including the assignment that reads
    # it — so grab the whole array in one go and read the statuses from the copy. An unknown
    # status defaults to 1: "could not tell" must never be reported as a good backup.
    PIPE_RC=("${PIPESTATUS[@]}")
    DUMP_RC="${PIPE_RC[0]:-1}"
    GZIP_RC="${PIPE_RC[1]:-1}"

    if [ -s "${DUMP_ERR}" ]; then
        log "pg_dump reported:"
        sed 's/^/    /' ${DUMP_ERR} | tee -a ${LOG_FILE} > /dev/null
    fi
    rm -f ${DUMP_ERR}

    if [ "${DUMP_RC}" -ne 0 ]; then
        fail "pg_dump exited with ${DUMP_RC} (see the pg_dump output above)"
    elif [ "${GZIP_RC}" -ne 0 ]; then
        fail "gzip exited with ${GZIP_RC} compressing the dump"
    else
        BACKUP_BYTES=$(stat -c %s "${BACKUP_FILE}" 2>/dev/null || echo 0)
        BACKUP_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    fi
fi

# Validate the archive: a 20-byte .gz (an empty stream compressed) is a valid gzip and a
# non-empty file, which is exactly what fooled the old `[ -s ]` check. A real dump opens with
# "-- PostgreSQL database dump" and closes with "-- PostgreSQL database dump complete", so the
# trailer is what proves the dump was not cut short.
if [ "${BACKUP_STATUS}" = "SUCCESS" ] && [ "${BACKUP_BYTES}" -lt "${BACKUP_MIN_BYTES}" ]; then
    fail "the archive is only ${BACKUP_BYTES} bytes (< ${BACKUP_MIN_BYTES}): the dump is empty or truncated"
fi

if [ "${BACKUP_STATUS}" = "SUCCESS" ] && ! gzip -t "${BACKUP_FILE}" 2>> ${LOG_FILE}; then
    fail "the archive failed the gzip integrity check (gzip -t)"
fi

if [ "${BACKUP_STATUS}" = "SUCCESS" ]; then
    # one pass over the payload: markers plus a table count for the notification mail
    MARKERS=$(zcat "${BACKUP_FILE}" | awk '
        /^-- PostgreSQL database dump$/          { header = 1 }
        /^-- PostgreSQL database dump complete$/ { trailer = 1 }
        /^CREATE TABLE /                         { tables++ }
        END { printf "%d %d %d", header, trailer, tables+0 }')
    MARK_HEADER="${MARKERS%% *}"
    MARK_REST="${MARKERS#* }"
    MARK_TRAILER="${MARK_REST%% *}"
    BACKUP_TABLES="${MARK_REST##* }"

    if [ "${MARK_HEADER}" != "1" ] || [ "${MARK_TRAILER}" != "1" ]; then
        fail "the payload is not a complete SQL dump (header=${MARK_HEADER}, trailer=${MARK_TRAILER})"
    elif [ "${BACKUP_TABLES}" -eq 0 ]; then
        # not fatal (an empty database is a valid dump), but nobody should get one here
        log "WARNING: the dump carries no CREATE TABLE statement: is ${POSTGRES_DB} the right database?"
    fi
fi

if [ "${BACKUP_STATUS}" = "SUCCESS" ]; then
    log "Backup completed successfully: ${BACKUP_FILE} (${BACKUP_SIZE}, ${BACKUP_BYTES} bytes, ${BACKUP_TABLES} tables)"
fi

# Clean up old backups (keep only last 15 days)
log "Cleaning up old backups (keeping last ${BACKUP_RETENTION_DAYS} days)..."

OLD_BACKUPS=$(find ${BACKUP_DIR} -name "maild_backup_*.sql.gz" -type f -mtime +${BACKUP_RETENTION_DAYS})

if [ -n "$OLD_BACKUPS" ]; then
    echo "$OLD_BACKUPS" | while read -r old_file; do
        log "Removing old backup: $(basename ${old_file})"
        rm -f "${old_file}"
    done
else
    log "No old backups to remove"
fi

# Count current backups
BACKUP_COUNT=$(find ${BACKUP_DIR} -name "maild_backup_*.sql.gz" -type f | wc -l)
log "Current backup count: ${BACKUP_COUNT}"

# Calculate total backup size
TOTAL_SIZE=$(du -sh ${BACKUP_DIR} | cut -f1)
log "Total backup storage used: ${TOTAL_SIZE}"

# List recent backups
log "Recent backups:"
find ${BACKUP_DIR} -name "maild_backup_*.sql.gz" -type f -mtime -${BACKUP_RETENTION_DAYS} -exec ls -lh {} \; | \
    awk '{print $9, "(" $5 ")"}' | tee -a ${LOG_FILE}

log "=== Backup process completed ==="

# Send email notification to admin
TO="${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}"
SERVER=$(host amavis | awk '/has address/ { print $4 }')

# Only send email if configured
if [ -n "${MAIL_ADMIN_USER}" ] && [ -n "${DEFAULT_DOMAIN}" ]; then
    EMAIL_BODY=$(mktemp)

    cat > ${EMAIL_BODY} <<EOF
Greetings,

This is an automated notification about the PostgreSQL database backup.

Status: ${BACKUP_STATUS}
Date: $(date '+%Y-%m-%d %H:%M:%S %Z')
Database: ${POSTGRES_DB}
Host: ${POSTGRES_HOST}

Backup File: ${BACKUP_FILE}
Backup Size: ${BACKUP_SIZE} (${BACKUP_BYTES} bytes, ${BACKUP_TABLES} tables)

Retention Policy: ${BACKUP_RETENTION_DAYS} days
Current Backup Count: ${BACKUP_COUNT}
Total Storage Used: ${TOTAL_SIZE}

Recent Backups:
$(find ${BACKUP_DIR} -name "maild_backup_*.sql.gz" -type f -mtime -7 -printf "%TY-%Tm-%Td %TH:%TM %f (%s bytes)\n" | sort -r)

Log file: ${LOG_FILE}

$(if [ "${BACKUP_STATUS}" = "FAILED" ]; then
    echo "ACTION REQUIRED: Please investigate the backup failure immediately!"
    echo "Reason: ${FAIL_REASON}"
    echo "The unusable archive was deleted, so there is NO backup of today."
    echo "Check the log file for detailed error messages."
else
    echo "No action required. Backup completed successfully."
fi)

--
Kindly, MailD Backup System.
EOF

    if [ "${BACKUP_STATUS}" = "SUCCESS" ]; then
        SUBJECT="[OK] MailD Daily Database Backup Completed"
    else
        SUBJECT="[CRITICAL] MailD Daily Database Backup FAILED"
    fi

    # the mail IS the alert: a swaks failure must not be logged as a delivered notification
    if swaks \
        --server ${SERVER} \
        --port 10024 \
        --protocol SMTP \
        --to ${TO} \
        --from ${TO} \
        --header "Subject: ${SUBJECT}" \
        --body @${EMAIL_BODY} > /dev/null 2>> ${LOG_FILE}; then
        log "Notification email sent to ${TO}"
    else
        log "WARNING: the notification email to ${TO} could NOT be sent (see the log above)"
    fi
    rm -f ${EMAIL_BODY}
fi

# Clean up credentials
rm -f ~/.pgpass

# Exit with appropriate code
if [ "${BACKUP_STATUS}" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi
