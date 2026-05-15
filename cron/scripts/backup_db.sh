#!/bin/bash

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>

# Goal:
#   - Create a daily backup of the PostgreSQL database
#   - Keep backups for 15 days (retention policy)
#   - Compress backups to save space
#   - Send notification to admin on success/failure

# Import environment variables
source /etc/environment

# Configuration
BACKUP_DIR="/backups/db"
BACKUP_RETENTION_DAYS=15
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/maild_backup_${DATE}.sql.gz"
LOG_FILE="${BACKUP_DIR}/backup.log"

# Ensure backup directory exists
mkdir -p ${BACKUP_DIR}

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a ${LOG_FILE}
}

# Start backup
log "=== Starting PostgreSQL backup ==="

# Setup the postgres credentials & secure it
echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
chmod 0600 ~/.pgpass

# Perform the backup with pg_dump and compress on the fly
log "Backing up database: ${POSTGRES_DB} from ${POSTGRES_HOST}"

if pg_dump -h ${POSTGRES_HOST} \
           -U ${POSTGRES_USER} \
           -d ${POSTGRES_DB} \
           -w \
           --no-owner \
           --no-acl \
           | gzip > ${BACKUP_FILE} 2>> ${LOG_FILE}; then

    BACKUP_SIZE=$(du -h ${BACKUP_FILE} | cut -f1)
    log "Backup completed successfully: ${BACKUP_FILE} (${BACKUP_SIZE})"
    BACKUP_STATUS="SUCCESS"

    # Verify the backup file is not empty
    if [ ! -s ${BACKUP_FILE} ]; then
        log "ERROR: Backup file is empty!"
        BACKUP_STATUS="FAILED"
    fi
else
    log "ERROR: Backup failed!"
    BACKUP_STATUS="FAILED"
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
Backup Size: ${BACKUP_SIZE}

Retention Policy: ${BACKUP_RETENTION_DAYS} days
Current Backup Count: ${BACKUP_COUNT}
Total Storage Used: ${TOTAL_SIZE}

Recent Backups:
$(find ${BACKUP_DIR} -name "maild_backup_*.sql.gz" -type f -mtime -7 -printf "%TY-%Tm-%Td %TH:%TM %f (%s bytes)\n" | sort -r)

Log file: ${LOG_FILE}

$(if [ "${BACKUP_STATUS}" = "FAILED" ]; then
    echo "ACTION REQUIRED: Please investigate the backup failure immediately!"
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

    swaks \
        --server ${SERVER} \
        --port 10024 \
        --protocol SMTP \
        --to ${TO} \
        --from ${TO} \
        --header "Subject: ${SUBJECT}" \
        --body @${EMAIL_BODY} > /dev/null

    log "Notification email sent to ${TO}"
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
