#!/bin/bash

# This script is part of MailD
# Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Restore one archive written by backup_db.sh (or its own safety dump) into its database.
# Operator guide: BACKUP-RESTORE.md.
#
#   docker compose exec cron /scripts/restore_db.sh --list
#   docker compose exec cron /scripts/restore_db.sh maild_backup_20261110_080000.sql.gz.age
#
# - The format is detected from the content, not the name: gzip (plain) or age (encrypted,
#   binary or armored). An encrypted archive needs the PRIVATE key: --identity FILE, or it is
#   asked for on the terminal (pasted, never echoed, kept in a 0600 temp file removed on exit).
# - The archive is decrypted/decompressed and validated (gzip -t, the pg_dump header and
#   trailer) BEFORE anything is touched.
# - The target database comes from the file name (maild_backup_ → POSTGRES_DB, maild_adminng_ →
#   ADMINNG_DB, maild_mcp_ → MCP_DB, maild_roundcube_ → ROUNDCUBE_DB, pre-restore_<db>_ → <db>);
#   --database overrides it.
# - A safety dump of the current database is written first (pre-restore_<db>_<date>.sql.gz,
#   encrypted like the daily archives when BACKUP_AGE_RECIPIENT is set; same 15-day retention).
# - The restore is ONE transaction: DROP SCHEMA public CASCADE, CREATE SCHEMA public, the dump.
#   Any error rolls everything back and the database is left exactly as it was. It runs as the
#   database's owner (SET ROLE), so the MCP and Roundcube databases stay owned by their
#   restricted roles.

source /etc/environment
set -o pipefail
umask 077

BACKUP_DIR="/backups/db"
: "${ADMINNG_DB:=adminng}"
: "${MCP_DB:=mcp}"
: "${ROUNDCUBE_DB:=roundcube}"
: "${POSTGRES_PORT:=5432}"

IDENTITY=""
TARGET_DB=""
ASSUME_YES=0
FORCE=0
SAFETY=1
ARCHIVE=""

usage() {
    cat <<'EOF'
Usage: restore_db.sh [options] <archive>
       restore_db.sh --list

  <archive>            file name in /backups/db, or a path
  --identity FILE      age private key (AGE-SECRET-KEY-1… or an ssh private key) for an
                       encrypted archive; without it you are asked to paste the key
  --database NAME      restore into NAME instead of the database the file name implies
  --yes                do not ask for confirmation
  --force              restore even while other clients are connected to the database
                       (the swap is still atomic; stopping them first is safer)
  --no-safety-dump     do not dump the current database before replacing it
  --list               list the archives and whether they are encrypted
EOF
}

die() { echo "restore: ERROR - $*" >&2; exit 1; }
info() { echo "restore: $*"; }

# private work dir (decrypted dump, pasted key, credentials): never ~/.pgpass, which the
# daily backup_db.sh writes and deletes — a restore overlapping it would lose its password
WORK="$(mktemp -d /tmp/maild-restore.XXXXXX)" || { echo "restore: ERROR - mktemp failed" >&2; exit 1; }
cleanup() {
    case "${WORK}" in
        /tmp/maild-restore.?*) rm -rf -- "${WORK}" ;;  # only ever our own mktemp dir
    esac
}
trap cleanup EXIT
export PGPASSFILE="${WORK}/pgpass"

# format of a file: age | gzip | unknown (by content, never by name)
detect_format() {
    local head
    head="$(head -c 34 "$1" 2>/dev/null | tr -d '\0')"
    case "${head}" in
        age-encryption.org/v1*|"-----BEGIN AGE ENCRYPTED FILE-----") echo age; return ;;
    esac
    if [ "$(head -c 2 "$1" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
        echo gzip
    else
        echo unknown
    fi
}

list_archives() {
    local f
    printf '%-52s %-10s %10s  %s\n' "ARCHIVE" "FORMAT" "BYTES" "DATE"
    find "${BACKUP_DIR}" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.sql.gz.age" \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2- | while read -r f; do
        case "$(detect_format "$f")" in
            age) fmt="encrypted" ;; gzip) fmt="plain" ;; *) fmt="unknown" ;;
        esac
        printf '%-52s %-10s %10s  %s\n' "$(basename "$f")" "${fmt}" "$(stat -c %s "$f")" \
            "$(date -r "$f" '+%Y-%m-%d %H:%M')"
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --identity) IDENTITY="${2:-}"; shift ;;
        --database) TARGET_DB="${2:-}"; shift ;;
        --yes) ASSUME_YES=1 ;;
        --force) FORCE=1 ;;
        --no-safety-dump) SAFETY=0 ;;
        --list) list_archives; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; die "unknown option $1" ;;
        *) [ -z "${ARCHIVE}" ] || die "only one archive at a time"; ARCHIVE="$1" ;;
    esac
    shift
done

[ -n "${ARCHIVE}" ] || { usage >&2; exit 1; }
[ -f "${ARCHIVE}" ] || ARCHIVE="${BACKUP_DIR}/${ARCHIVE}"
[ -f "${ARCHIVE}" ] || die "no such archive: ${ARCHIVE} (try --list)"

# --- target database ---------------------------------------------------------------
if [ -z "${TARGET_DB}" ]; then
    case "$(basename "${ARCHIVE}")" in
        maild_backup_*)  TARGET_DB="${POSTGRES_DB}" ;;
        maild_adminng_*) TARGET_DB="${ADMINNG_DB}" ;;
        maild_mcp_*)     TARGET_DB="${MCP_DB}" ;;
        maild_roundcube_*) TARGET_DB="${ROUNDCUBE_DB}" ;;
        pre-restore_*)   TARGET_DB="$(basename "${ARCHIVE}" | sed -E 's/^pre-restore_(.+)_[0-9]{8}_[0-9]{6}\.sql\.gz.*$/\1/')" ;;
        *) die "cannot tell the database from the file name, pass --database NAME" ;;
    esac
fi
[ -n "${TARGET_DB}" ] || die "empty target database"

# --- credentials (same as backup_db.sh) ------------------------------------------------
{
    for db in "${POSTGRES_DB}" "${TARGET_DB}" postgres; do
        echo "${POSTGRES_HOST}:${POSTGRES_PORT}:${db}:${POSTGRES_USER}:${POSTGRES_PASSWORD}"
    done
} > "${PGPASSFILE}"
PSQL=(psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -w -X -q)

OWNER="$("${PSQL[@]}" -d postgres -tAc \
    "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${TARGET_DB//\'/\'\'}'" 2>/dev/null)"
[ -n "${OWNER}" ] || die "database '${TARGET_DB}' does not exist (the db container creates it on boot) or the server is unreachable"

PLAIN="${WORK}/dump.sql.gz"

# --- decrypt (if needed) and validate --------------------------------------------------
FORMAT="$(detect_format "${ARCHIVE}")"
case "${FORMAT}" in
    gzip)
        info "$(basename "${ARCHIVE}") is a plain (unencrypted) archive"
        cp "${ARCHIVE}" "${PLAIN}" || die "cannot read ${ARCHIVE}"
        ;;
    age)
        info "$(basename "${ARCHIVE}") is ENCRYPTED (age): the private key is needed"
        if [ -z "${IDENTITY}" ]; then
            [ -t 0 ] || die "encrypted archive and no terminal to ask on: pass --identity FILE (or run 'docker compose exec' without -T)"
            echo "Paste the private key (the AGE-SECRET-KEY-1… line, or a whole ssh private key),"
            echo "then an empty line. It is not echoed and is deleted when this script ends."
            IDENTITY="${WORK}/identity"
            : > "${IDENTITY}"
            while IFS= read -rs line; do
                [ -z "${line}" ] && [ -s "${IDENTITY}" ] && break
                printf '%s\n' "${line}" >> "${IDENTITY}"
            done
            [ -s "${IDENTITY}" ] || die "no key given"
        fi
        [ -r "${IDENTITY}" ] || die "cannot read the identity file ${IDENTITY}"
        age -d -i "${IDENTITY}" -o "${PLAIN}" "${ARCHIVE}" ||
            die "decryption failed: wrong private key, or the archive is damaged"
        info "decrypted"
        ;;
    *) die "$(basename "${ARCHIVE}") is neither a gzip nor an age file" ;;
esac

gzip -t "${PLAIN}" 2>/dev/null || die "the archive fails the gzip integrity check"
MARKERS=$(zcat "${PLAIN}" | awk '
    /^-- PostgreSQL database dump$/          { header = 1 }
    /^-- PostgreSQL database dump complete$/ { trailer = 1 }
    /^CREATE TABLE /                         { tables++ }
    END { printf "%d %d %d", header, trailer, tables+0 }')
read -r M_HEAD M_TRAIL M_TABLES <<< "${MARKERS}"
[ "${M_HEAD}" = 1 ] && [ "${M_TRAIL}" = 1 ] ||
    die "the archive is not a complete pg_dump (header=${M_HEAD}, trailer=${M_TRAIL}): refusing to restore it"
info "valid dump: ${M_TABLES} tables → database '${TARGET_DB}' (owner ${OWNER})"

# --- other clients -------------------------------------------------------------------
CLIENTS="$("${PSQL[@]}" -d postgres -tAc "SELECT count(*) FROM pg_stat_activity
    WHERE datname = '${TARGET_DB//\'/\'\'}' AND pid <> pg_backend_pid()" 2>/dev/null)"
if [ "${CLIENTS:-0}" -gt 0 ]; then
    info "${CLIENTS} other session(s) are connected to '${TARGET_DB}':"
    "${PSQL[@]}" -d postgres -tAc "SELECT '    ' || coalesce(nullif(application_name, ''), '?') || ' from ' ||
        coalesce(host(client_addr), 'local') || ' as ' || usename FROM pg_stat_activity
        WHERE datname = '${TARGET_DB//\'/\'\'}' AND pid <> pg_backend_pid()" 2>/dev/null
    if [ "${FORCE}" != 1 ]; then
        cat >&2 <<EOF
restore: stop the services that write to it first, then run this again, e.g.
    docker compose stop api mta mda mua mua2 amavis mcp # catalogue (${POSTGRES_DB})
    docker compose stop api                             # AdminNG (${ADMINNG_DB})
    docker compose stop mcp                             # MCP (${MCP_DB})
    docker compose stop mua2                            # Roundcube (${ROUNDCUBE_DB})
or pass --force: the swap is one transaction (readers see the old or the new data, never a
mix), but anything written between the dump and now is lost either way.
EOF
        exit 1
    fi
    info "--force: going ahead with clients connected"
fi

# --- confirmation ----------------------------------------------------------------------
if [ "${ASSUME_YES}" != 1 ]; then
    [ -t 0 ] || die "no terminal to confirm on: pass --yes"
    echo
    echo "This REPLACES every table of database '${TARGET_DB}' with $(basename "${ARCHIVE}")."
    read -r -p "Type the database name to confirm: " answer
    [ "${answer}" = "${TARGET_DB}" ] || die "not confirmed, nothing changed"
fi

# --- safety dump of the current state -------------------------------------------------
if [ "${SAFETY}" = 1 ]; then
    SAFE="${BACKUP_DIR}/pre-restore_${TARGET_DB}_$(date +%Y%m%d_%H%M%S).sql.gz"
    if pg_dump -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -w \
            -d "${TARGET_DB}" --no-owner --no-acl 2> "${WORK}/safety.err" | gzip > "${SAFE}" &&
       gzip -t "${SAFE}"; then
        RECIPIENT_ARGS=()
        while IFS= read -r r; do
            r="$(printf '%s' "$r" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            [ -n "$r" ] && RECIPIENT_ARGS+=( -r "$r" )
        done < <(printf '%s\n' "${BACKUP_AGE_RECIPIENT:-}" | tr ',' '\n')
        if [ "${#RECIPIENT_ARGS[@]}" -gt 0 ]; then
            if age -e "${RECIPIENT_ARGS[@]}" -o "${SAFE}.age" "${SAFE}"; then
                rm -f "${SAFE}"; SAFE="${SAFE}.age"
            else
                rm -f "${SAFE}.age"
                info "WARNING: could not encrypt the safety dump, it stays plain (0600)"
            fi
        fi
        info "safety dump of the current '${TARGET_DB}': $(basename "${SAFE}")"
    else
        rm -f "${SAFE}"
        sed 's/^/    /' "${WORK}/safety.err" >&2
        die "the safety dump failed, nothing changed (use --no-safety-dump to skip it)"
    fi
fi

# --- the restore: one transaction, as the database owner ------------------------------
info "restoring..."
{
    # recreate public exactly as initdb leaves it (PG15+: owned by pg_database_owner, USAGE for
    # PUBLIC), so the dump — and every later dump — sees the stock schema
    printf '%s\n' 'DROP SCHEMA IF EXISTS public CASCADE;' 'CREATE SCHEMA public;' \
        'ALTER SCHEMA public OWNER TO pg_database_owner;' 'GRANT USAGE ON SCHEMA public TO PUBLIC;'
    zcat "${PLAIN}"
} | PGOPTIONS="-c role=${OWNER} -c lock_timeout=60s" \
    psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -w -X -q \
         -d "${TARGET_DB}" --single-transaction -v ON_ERROR_STOP=1 > "${WORK}/restore.out" 2>&1
RC=$?
if [ "${RC}" -ne 0 ]; then
    sed 's/^/    /' "${WORK}/restore.out" >&2
    die "psql exited with ${RC}: the transaction was rolled back, '${TARGET_DB}' is unchanged"
fi

info "OK: '${TARGET_DB}' restored from $(basename "${ARCHIVE}")"
if [ "${TARGET_DB}" = "${POSTGRES_DB}" ]; then
    echo "restore: next: 'docker compose restart db' (re-asserts the MCP/Roundcube roles' catalogue grants),"
    echo "         then start/restart the mail services: docker compose up -d"
else
    echo "restore: next: start/restart the services that use it: docker compose up -d"
fi
