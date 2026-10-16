#!/bin/bash
#
# seed.sh — MailD first-boot catalogue provisioning (idempotent).
#
# Runs inside the admin container, AFTER PostfixAdmin has created/updated its schema
# (public/upgrade.php). It seeds exactly what the manual /setup.php wizard + "create domain"
# clicks would create:
#
#   * DEFAULT_DOMAIN
#   * the PostfixAdmin superadmin  MAIL_ADMIN_USER@DEFAULT_DOMAIN
#   * the matching mailbox (same password, so it is also a real IMAP account)
#   * the default aliases postmaster/abuse/hostmaster/webmaster -> the admin address
#   * the maild_provision sentinel row (tells the boot-time domain-caching services that
#     amavis / mua / mta can configure themselves)
#
# Everything is one transaction guarded by a transaction-scoped advisory lock and every
# statement is idempotent (INSERT ... ON CONFLICT DO NOTHING), so concurrent admin replicas
# (swarm) and repeated boots converge instead of racing. An existing password is never
# clobbered unless PROVISION_FORCE=yes.
#
# Opt out entirely with AUTO_PROVISION=no (the classic OTP + /setup.php flow stays).
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:?DEFAULT_DOMAIN is required}"
MAIL_ADMIN_USER="${MAIL_ADMIN_USER:-sysadmin}"
PROVISION_VERSION="${PROVISION_VERSION:-1}"
PROVISION_WAIT_TIMEOUT="${PROVISION_WAIT_TIMEOUT:-180}"
PROVISION_FORCE="${PROVISION_FORCE:-no}"
ADMIN_ADDR="${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}"

log() { echo "seed: $*" >&2; }

# ---- DB connection --------------------------------------------------------
# In the admin container the catalogue coordinates are POSTFIXADMIN_DB_* (the entrypoint maps
# POSTGRES_* into them) and POSTGRES_PASSWORD is NOT exported here — only
# POSTFIXADMIN_DB_PASSWORD is. Accept both spellings and default everything, so `set -u`
# never trips (this is what broke the first clean-boot run).
PGHOST="${POSTFIXADMIN_DB_HOST:-${POSTGRES_HOST:-db}}"
PGPORT="${POSTFIXADMIN_DB_PORT:-${POSTGRES_PORT:-5432}}"
PGUSER="${POSTFIXADMIN_DB_USER:-${POSTGRES_USER:-maild}}"
PGDB="${POSTFIXADMIN_DB_NAME:-${POSTGRES_DB:-mailddb}}"
PGPASS="${POSTFIXADMIN_DB_PASSWORD:-${POSTGRES_PASSWORD:-}}"

# PGPASSWORD (exported) lets `psql -w` authenticate without depending on $HOME/.pgpass
export PGPASSWORD="$PGPASS"

psql_q() { psql -tAq -w -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -c "$1" 2>/dev/null; }

# ---- fast path: already provisioned --------------------------------------
if [ "${PROVISION_FORCE}" != "yes" ] && \
   [ "$(psql_q "SELECT 1 FROM maild_provision WHERE id=1 AND version >= ${PROVISION_VERSION}" || true)" = "1" ]; then
    log "catalogue already provisioned (version >= ${PROVISION_VERSION}); nothing to do"
    exit 0
fi

# ---- wait for the PostfixAdmin schema (upgrade.php creates it) -----------
t=0
while :; do
    has_schema="$(psql_q "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='domain'" || true)"
    [ "$has_schema" = "1" ] && break
    if [ "$t" -ge "$PROVISION_WAIT_TIMEOUT" ]; then
        log "FATAL: PostfixAdmin schema not present after ${t}s (is the db container up and upgrade.php done?)"
        exit 1
    fi
    sleep 2; t=$((t+2))
done
log "PostfixAdmin schema detected, provisioning ${DEFAULT_DOMAIN}"

# ---- password ------------------------------------------------------------
if [ -n "${MAIL_ADMIN_PASSWORD:-}" ]; then
    ADMIN_PW="${MAIL_ADMIN_PASSWORD}"
else
    # exact-byte read (od) so the producer never gets SIGPIPE under `set -o pipefail`
    ADMIN_PW="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    echo "seed: #################### !!! #############################" >&2
    echo "seed: GENERATED ADMIN PASSWORD for ${ADMIN_ADDR}: ${ADMIN_PW}" >&2
    echo "seed: #################### !!! #############################" >&2
fi

# md5crypt ($1$...): the scheme both PostfixAdmin (encrypt=md5crypt) and Dovecot (MD5-CRYPT) verify.
# -n (no php.ini): the admin image's PHP prints an "imap extension" startup warning on *stdout*
# that would otherwise corrupt the captured value; crypt() is a core function, always available.
HASH="$(php -n -r 'echo crypt($argv[1], sprintf("\$1\$%08x\$", crc32(uniqid("", true))));' "$ADMIN_PW" 2>/dev/null | tr -d '\r\n')"
case "$HASH" in
    \$1\$*) : ;;
    *) log "FATAL: could not produce an md5crypt hash (got '${HASH}')"; exit 1 ;;
esac

# ---- seed (single transaction + advisory lock) ---------------------------
# PROVISION_FORCE=yes re-asserts the password; otherwise the inserts are do-nothing so an
# operator-edited password survives a restart.
if [ "$PROVISION_FORCE" = "yes" ]; then
    REASSERT="UPDATE mailbox SET password = :'hash', active = true WHERE username = :'admin';
UPDATE admin SET password = :'hash', superadmin = true, active = true WHERE username = :'admin';"
else
    REASSERT=""
fi

psql -q -w -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" \
     -v ON_ERROR_STOP=1 -f - \
     -v dom="$DEFAULT_DOMAIN" -v user="$MAIL_ADMIN_USER" -v admin="$ADMIN_ADDR" \
     -v hash="$HASH" -v ver="$PROVISION_VERSION" <<SQL
BEGIN;
SELECT pg_advisory_xact_lock(842019019);

INSERT INTO domain (domain, description, aliases, mailboxes, maxquota, quota, transport, backupmx, active)
VALUES (:'dom', 'MailD deployment domain (DEFAULT_DOMAIN)', 0, 0, 0, 0, 'virtual', false, true)
ON CONFLICT DO NOTHING;

INSERT INTO mailbox (username, password, name, maildir, quota, domain, local_part, active)
VALUES (:'admin', :'hash', 'Mail administrator',
        split_part(:'admin','@',2) || '/' || split_part(:'admin','@',1) || '/',
        0, :'dom', :'user', true)
ON CONFLICT DO NOTHING;

INSERT INTO alias (address, goto, domain, active)
SELECT a.addr, :'admin', :'dom', true
FROM (VALUES ('postmaster@' || :'dom'), ('abuse@' || :'dom'),
             ('hostmaster@' || :'dom'), ('webmaster@' || :'dom')) AS a(addr)
ON CONFLICT DO NOTHING;

INSERT INTO admin (username, password, superadmin, active)
VALUES (:'admin', :'hash', true, true)
ON CONFLICT DO NOTHING;

${REASSERT}

INSERT INTO maild_provision (id, version, default_domain, admin_user, provisioned_by)
VALUES (1, :'ver'::int, :'dom', :'user', current_user)
ON CONFLICT (id) DO UPDATE SET version = EXCLUDED.version,
  default_domain = EXCLUDED.default_domain, admin_user = EXCLUDED.admin_user,
  provisioned_at = now(), provisioned_by = current_user;

COMMIT;
SQL

log "catalogue provisioned: domain=${DEFAULT_DOMAIN} admin=${ADMIN_ADDR} version=${PROVISION_VERSION}"
