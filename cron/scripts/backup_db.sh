#!/bin/bash

# This script is part of MailD
# Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goal:
#   - Create a daily backup of the PostgreSQL database
#   - Keep backups for 15 days (retention policy)
#   - Compress backups to save space
#   - Send notification to admin on success/failure
#   - Optionally encrypt every archive to the operator's age public key(s)
#     (BACKUP_AGE_RECIPIENT; unset = plain archives). Restore: /scripts/restore_db.sh,
#     key setup: BACKUP-RESTORE.md
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
# AdminNG's own database (devices, sessions, TOTP, audit): created by the db image
# on every boot, used by the api. Defaulted here because the cron image bakes no
# ADMINNG_* variables of its own.
: "${ADMINNG_DB:=adminng}"
# The MailD MCP's own database (accounts, tokens, settings): created by the db image, owned by
# the MCP role, dumped here as POSTGRES_USER (superuser), so the ownership does not get in the way.
: "${MCP_DB:=mcp}"
# Roundcube's own database (the mua webmail: identities, signatures, prefs, personal contacts),
# created by the db image only when ROUNDCUBE_DB_PASSWORD is set; skipped while it is absent.
: "${ROUNDCUBE_DB:=roundcube}"
# An empty dump compressed is ~20 bytes and a real mailddb dump is tens of KB, so anything
# below this is not a backup (overridable from the environment).
BACKUP_MIN_BYTES="${BACKUP_MIN_BYTES:-1024}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/maild_backup_${DATE}.sql.gz"
LOG_FILE="${BACKUP_DIR}/backup.log"
# Every archive this job (or restore_db.sh's safety dump) writes, plain or encrypted (.age)
ARCHIVES=( \( -name "maild_backup_*.sql.gz*" -o -name "maild_adminng_*.sql.gz*" \
              -o -name "maild_mcp_*.sql.gz*" -o -name "maild_roundcube_*.sql.gz*" \
              -o -name "pre-restore_*.sql.gz*" \) )
# Optional encryption (2026-10 audit L-10): one or more age recipients (age1… public keys, or
# ssh-ed25519/ssh-rsa public keys), comma- or newline-separated. Only PUBLIC keys live here:
# the private key never touches this server. Unset/empty = archives stay plain gzip.
RECIPIENT_ARGS=()
while IFS= read -r r; do
    r="$(printf '%s' "$r" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$r" ] && RECIPIENT_ARGS+=( -r "$r" )
done < <(printf '%s\n' "${BACKUP_AGE_RECIPIENT:-}" | tr ',' '\n')
ENCRYPTION="off"
ENCRYPT_FAIL=""
[ "${#RECIPIENT_ARGS[@]}" -gt 0 ] && ENCRYPTION="on ($(( ${#RECIPIENT_ARGS[@]} / 2 )) recipient(s), age)"

# Backups hold password hashes, TOTP ciphertext, session/token hashes and the audit trail:
# root-only (2026-10 audit L-10). The umask covers every file this run creates (dumps, the
# log); the chmods tighten a directory/archives an older image left 0755/0644.
umask 077
mkdir -p ${BACKUP_DIR}
chmod 0700 /backups ${BACKUP_DIR}
find ${BACKUP_DIR} -type f -perm /077 -exec chmod go-rwx {} + 2>/dev/null

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

# Setup the postgres credentials & secure it. One line per database: libpq matches
# host:port:database:user, so the AdminNG dump needs its own entry to get a password.
{
    echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD"
    [ -n "${ADMINNG_DB:-}" ] && echo "$POSTGRES_HOST:5432:$ADMINNG_DB:$POSTGRES_USER:$POSTGRES_PASSWORD"
    [ -n "${MCP_DB:-}" ] && echo "$POSTGRES_HOST:5432:$MCP_DB:$POSTGRES_USER:$POSTGRES_PASSWORD"
    [ -n "${ROUNDCUBE_DB:-}" ] && echo "$POSTGRES_HOST:5432:$ROUNDCUBE_DB:$POSTGRES_USER:$POSTGRES_PASSWORD"
} > ~/.pgpass
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

# --- AdminNG database (devices, sessions, TOTP seeds, audit trail) ------------
# A second archive with the same treatment. A failure here does NOT delete the
# catalogue archive, but the run is marked FAILED: a backup without the device
# approvals and the audit trail would silently lose adminng state.
ADMINNG_BACKUP_FILE="${BACKUP_DIR}/maild_adminng_${DATE}.sql.gz"
ADMINNG_STATUS="SKIPPED"
ADMINNG_BYTES=0
ADMINNG_SIZE="n/a"
ADMINNG_TABLES=0
ADMINNG_FAIL=""

if [ "${BACKUP_STATUS}" = "SUCCESS" ] && [ -n "${ADMINNG_DB:-}" ]; then
    log "Backing up AdminNG database: ${ADMINNG_DB}"

    ADMINNG_ERR=$(mktemp)
    pg_dump -h ${POSTGRES_HOST} \
            -U ${POSTGRES_USER} \
            -d "${ADMINNG_DB}" \
            -w \
            --no-owner \
            --no-acl \
            2> ${ADMINNG_ERR} \
        | gzip > "${ADMINNG_BACKUP_FILE}" 2>> ${LOG_FILE}

    PIPE_RC=("${PIPESTATUS[@]}")
    ADMINNG_DUMP_RC="${PIPE_RC[0]:-1}"
    ADMINNG_GZIP_RC="${PIPE_RC[1]:-1}"

    if [ -s "${ADMINNG_ERR}" ]; then
        log "pg_dump (${ADMINNG_DB}) reported:"
        sed 's/^/    /' ${ADMINNG_ERR} | tee -a ${LOG_FILE} > /dev/null
    fi
    rm -f ${ADMINNG_ERR}

    if [ "${ADMINNG_DUMP_RC}" -ne 0 ]; then
        ADMINNG_STATUS="FAILED" ; ADMINNG_FAIL="pg_dump exited with ${ADMINNG_DUMP_RC}"
    elif [ "${ADMINNG_GZIP_RC}" -ne 0 ]; then
        ADMINNG_STATUS="FAILED" ; ADMINNG_FAIL="gzip exited with ${ADMINNG_GZIP_RC}"
    else
        ADMINNG_BYTES=$(stat -c %s "${ADMINNG_BACKUP_FILE}" 2>/dev/null || echo 0)
        ADMINNG_SIZE=$(du -h "${ADMINNG_BACKUP_FILE}" | cut -f1)
        if [ "${ADMINNG_BYTES}" -lt "${BACKUP_MIN_BYTES}" ]; then
            ADMINNG_STATUS="FAILED" ; ADMINNG_FAIL="archive is only ${ADMINNG_BYTES} bytes"
        elif ! gzip -t "${ADMINNG_BACKUP_FILE}" 2>> ${LOG_FILE}; then
            ADMINNG_STATUS="FAILED" ; ADMINNG_FAIL="gzip -t failed"
        else
            ADMINNG_MARKERS=$(zcat "${ADMINNG_BACKUP_FILE}" | awk '
                /^-- PostgreSQL database dump$/          { header = 1 }
                /^-- PostgreSQL database dump complete$/ { trailer = 1 }
                /^CREATE TABLE /                         { tables++ }
                END { printf "%d %d %d", header, trailer, tables+0 }')
            ADMINNG_HEADER="${ADMINNG_MARKERS%% *}"
            ADMINNG_REST="${ADMINNG_MARKERS#* }"
            ADMINNG_TRAILER="${ADMINNG_REST%% *}"
            ADMINNG_TABLES="${ADMINNG_REST##* }"
            if [ "${ADMINNG_HEADER}" != "1" ] || [ "${ADMINNG_TRAILER}" != "1" ]; then
                ADMINNG_STATUS="FAILED"
                ADMINNG_FAIL="payload is not a complete SQL dump (header=${ADMINNG_HEADER}, trailer=${ADMINNG_TRAILER})"
            else
                ADMINNG_STATUS="SUCCESS"
            fi
        fi
    fi

    if [ "${ADMINNG_STATUS}" = "FAILED" ]; then
        rm -f "${ADMINNG_BACKUP_FILE}"
        log "ERROR: AdminNG backup FAILED: ${ADMINNG_FAIL}"
    else
        log "AdminNG backup completed: ${ADMINNG_BACKUP_FILE} (${ADMINNG_SIZE}, ${ADMINNG_BYTES} bytes, ${ADMINNG_TABLES} tables)"
    fi
fi

if [ "${ADMINNG_STATUS}" = "FAILED" ]; then
    BACKUP_STATUS="FAILED"
    FAIL_REASON="the AdminNG database dump failed: ${ADMINNG_FAIL} (the catalogue archive was kept)"
fi

# --- Service databases: MailD MCP, Roundcube (mua) -------------------------------------
# One more archive each, with the same treatment and the same failure rule as AdminNG.
# SKIPPED (not FAILED) when the database does not exist or has no table yet: the db image
# creates each one only when that service is configured, and it stays empty until the
# service has created its schema (the mcp's migrations, the mua entrypoint's initdb).
# Dumped as POSTGRES_USER (superuser), so the restricted owner roles do not get in the way.
#
# dump_service_db <label> <database> <archive> — sets SVC_STATUS SVC_BYTES SVC_SIZE
# SVC_TABLES SVC_FAIL; a failed archive is deleted.
dump_service_db() {
    local label="$1" db="$2" file="$3" has_tables err dump_rc gzip_rc markers header rest trailer
    SVC_STATUS="SKIPPED" ; SVC_BYTES=0 ; SVC_SIZE="n/a" ; SVC_TABLES=0 ; SVC_FAIL=""

    [ "${BACKUP_STATUS}" = "SUCCESS" ] && [ -n "${db}" ] || return 0

    has_tables=$(psql -h ${POSTGRES_HOST} -U ${POSTGRES_USER} -d "${db}" -w -tA \
        -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'" 2>/dev/null | tr -d '[:space:]')
    if [ -z "${has_tables}" ] || [ "${has_tables}" = "0" ]; then
        log "${label} database ${db} missing or empty, skipping its archive"
        return 0
    fi

    log "Backing up ${label} database: ${db}"
    err=$(mktemp)
    pg_dump -h ${POSTGRES_HOST} \
            -U ${POSTGRES_USER} \
            -d "${db}" \
            -w \
            --no-owner \
            --no-acl \
            2> ${err} \
        | gzip > "${file}" 2>> ${LOG_FILE}
    local pipe_rc=("${PIPESTATUS[@]}")
    dump_rc="${pipe_rc[0]:-1}"
    gzip_rc="${pipe_rc[1]:-1}"

    if [ -s "${err}" ]; then
        log "pg_dump (${db}) reported:"
        sed 's/^/    /' ${err} | tee -a ${LOG_FILE} > /dev/null
    fi
    rm -f ${err}

    if [ "${dump_rc}" -ne 0 ]; then
        SVC_STATUS="FAILED" ; SVC_FAIL="pg_dump exited with ${dump_rc}"
    elif [ "${gzip_rc}" -ne 0 ]; then
        SVC_STATUS="FAILED" ; SVC_FAIL="gzip exited with ${gzip_rc}"
    else
        SVC_BYTES=$(stat -c %s "${file}" 2>/dev/null || echo 0)
        SVC_SIZE=$(du -h "${file}" | cut -f1)
        if [ "${SVC_BYTES}" -lt "${BACKUP_MIN_BYTES}" ]; then
            SVC_STATUS="FAILED" ; SVC_FAIL="archive is only ${SVC_BYTES} bytes"
        elif ! gzip -t "${file}" 2>> ${LOG_FILE}; then
            SVC_STATUS="FAILED" ; SVC_FAIL="gzip -t failed"
        else
            markers=$(zcat "${file}" | awk '
                /^-- PostgreSQL database dump$/          { header = 1 }
                /^-- PostgreSQL database dump complete$/ { trailer = 1 }
                /^CREATE TABLE /                         { tables++ }
                END { printf "%d %d %d", header, trailer, tables+0 }')
            header="${markers%% *}"
            rest="${markers#* }"
            trailer="${rest%% *}"
            SVC_TABLES="${rest##* }"
            if [ "${header}" != "1" ] || [ "${trailer}" != "1" ]; then
                SVC_STATUS="FAILED"
                SVC_FAIL="payload is not a complete SQL dump (header=${header}, trailer=${trailer})"
            else
                SVC_STATUS="SUCCESS"
            fi
        fi
    fi

    if [ "${SVC_STATUS}" = "FAILED" ]; then
        rm -f "${file}"
        log "ERROR: ${label} backup FAILED: ${SVC_FAIL}"
        BACKUP_STATUS="FAILED"
        FAIL_REASON="${FAIL_REASON:+${FAIL_REASON}; }the ${label} database dump failed: ${SVC_FAIL} (the catalogue archive was kept)"
    else
        log "${label} backup completed: ${file} (${SVC_SIZE}, ${SVC_BYTES} bytes, ${SVC_TABLES} tables)"
    fi
}

# MailD MCP (accounts, addresses, tokens, settings)
MCP_BACKUP_FILE="${BACKUP_DIR}/maild_mcp_${DATE}.sql.gz"
dump_service_db "MCP" "${MCP_DB:-}" "${MCP_BACKUP_FILE}"
MCP_STATUS="${SVC_STATUS}" ; MCP_BYTES="${SVC_BYTES}" ; MCP_SIZE="${SVC_SIZE}" ; MCP_TABLES="${SVC_TABLES}"

# Roundcube, the mua webmail (identities, signatures, prefs, personal contacts, responses)
ROUNDCUBE_BACKUP_FILE="${BACKUP_DIR}/maild_roundcube_${DATE}.sql.gz"
dump_service_db "Roundcube" "${ROUNDCUBE_DB:-}" "${ROUNDCUBE_BACKUP_FILE}"
ROUNDCUBE_STATUS="${SVC_STATUS}" ; ROUNDCUBE_BYTES="${SVC_BYTES}" ; ROUNDCUBE_SIZE="${SVC_SIZE}" ; ROUNDCUBE_TABLES="${SVC_TABLES}"

# --- Optional encryption ----------------------------------------------------------
# Each archive was validated in plain form above (gzip -t + dump markers), then it is
# encrypted, the ciphertext header checked and the plaintext removed. A bad recipient or a
# failed encryption keeps the PLAIN archive (still 0600) and marks the run FAILED: losing the
# backup would be worse than an unencrypted one, and the mail tells the admin either way.
encrypt_archive() { # <file> → <file>.age, plaintext removed; non-zero on failure
    local in="$1" out="$1.age"
    if age -e "${RECIPIENT_ARGS[@]}" -o "${out}" "${in}" 2>> ${LOG_FILE} &&
       [ "$(head -c 21 "${out}" 2>/dev/null)" = "age-encryption.org/v1" ]; then
        rm -f "${in}"
        return 0
    fi
    rm -f "${out}"
    return 1
}

if [ "${#RECIPIENT_ARGS[@]}" -gt 0 ]; then
    if ! age -e "${RECIPIENT_ARGS[@]}" < /dev/null > /dev/null 2>> ${LOG_FILE}; then
        ENCRYPT_FAIL="BACKUP_AGE_RECIPIENT is not a valid age/ssh public key list (see the log); the archives were kept UNENCRYPTED"
    else
        for var in BACKUP_FILE ADMINNG_BACKUP_FILE MCP_BACKUP_FILE ROUNDCUBE_BACKUP_FILE; do
            f="${!var}"
            [ -f "${f}" ] || continue
            if encrypt_archive "${f}"; then
                printf -v "${var}" '%s' "${f}.age"
                log "Encrypted: $(basename "${f}").age"
            else
                ENCRYPT_FAIL="${ENCRYPT_FAIL:+${ENCRYPT_FAIL}; }could not encrypt $(basename "${f}") (kept unencrypted)"
            fi
        done
    fi
    if [ -n "${ENCRYPT_FAIL}" ]; then
        log "ERROR: ${ENCRYPT_FAIL}"
        BACKUP_STATUS="FAILED"
        FAIL_REASON="${FAIL_REASON:+${FAIL_REASON}; }${ENCRYPT_FAIL}"
    fi
fi

# Clean up old backups (keep only last 15 days)
log "Cleaning up old backups (keeping last ${BACKUP_RETENTION_DAYS} days)..."

OLD_BACKUPS=$(find ${BACKUP_DIR} "${ARCHIVES[@]}" -type f -mtime +${BACKUP_RETENTION_DAYS})

if [ -n "$OLD_BACKUPS" ]; then
    echo "$OLD_BACKUPS" | while read -r old_file; do
        log "Removing old backup: $(basename ${old_file})"
        rm -f "${old_file}"
    done
else
    log "No old backups to remove"
fi

# Count current backups
BACKUP_COUNT=$(find ${BACKUP_DIR} "${ARCHIVES[@]}" -type f | wc -l)
log "Current backup count: ${BACKUP_COUNT}"

# Calculate total backup size
TOTAL_SIZE=$(du -sh ${BACKUP_DIR} | cut -f1)
log "Total backup storage used: ${TOTAL_SIZE}"

# List recent backups
log "Recent backups:"
find ${BACKUP_DIR} "${ARCHIVES[@]}" -type f -mtime -${BACKUP_RETENTION_DAYS} -exec ls -lh {} \; | \
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

AdminNG database: ${ADMINNG_DB:-adminng} (${ADMINNG_STATUS})
AdminNG File: ${ADMINNG_BACKUP_FILE}
AdminNG Size: ${ADMINNG_SIZE} (${ADMINNG_BYTES} bytes, ${ADMINNG_TABLES} tables)

MCP database: ${MCP_DB:-mcp} (${MCP_STATUS})
MCP File: ${MCP_BACKUP_FILE}
MCP Size: ${MCP_SIZE} (${MCP_BYTES} bytes, ${MCP_TABLES} tables)

Roundcube database: ${ROUNDCUBE_DB:-roundcube} (${ROUNDCUBE_STATUS})
Roundcube File: ${ROUNDCUBE_BACKUP_FILE}
Roundcube Size: ${ROUNDCUBE_SIZE} (${ROUNDCUBE_BYTES} bytes, ${ROUNDCUBE_TABLES} tables)

Encryption: ${ENCRYPTION}
Retention Policy: ${BACKUP_RETENTION_DAYS} days
Current Backup Count: ${BACKUP_COUNT}
Total Storage Used: ${TOTAL_SIZE}

Recent Backups:
$(find ${BACKUP_DIR} "${ARCHIVES[@]}" -type f -mtime -7 -printf "%TY-%Tm-%Td %TH:%TM %f (%s bytes)\n" | sort -r)

Log file: ${LOG_FILE}

$(if [ "${BACKUP_STATUS}" = "FAILED" ]; then
    echo "ACTION REQUIRED: Please investigate the backup failure immediately!"
    echo "Reason: ${FAIL_REASON}"
    if [ -n "${ENCRYPT_FAIL}" ]; then
        echo "The dumps themselves are valid; only the encryption failed (fix BACKUP_AGE_RECIPIENT)."
    else
        echo "The failed archive was deleted; any other archive listed above is still valid."
    fi
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
        --port ${AMAVIS_SUBMIT_PORT:-10026} \
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
