#!/bin/sh
# MailD: rehash-on-login — migrate legacy md5crypt ($1$) password hashes to
# Argon2id ({ARGON2ID}$argon2id$…) as users authenticate.
#
# Wired as a postlogin script for the imap and pop3 services (10-master.conf):
# Dovecot runs it after a *successful* login with the userdb fields in the
# environment — PLAIN_PASS comes from the userdb `plain_pass = %{password}`
# field (auth-sql.conf.ext), which Dovecot expands to the *client-supplied*
# plaintext (`%{password}` is the mechanism password, not the stored hash),
# exactly as documented in Dovecot's "Converting Password Schemes" how-to.
# The plaintext is never logged; its only use is as a doveadm pw argument
# inside this container.
#
# Weak-scheme deadline: 2027-02-01 (docker-entrypoint.sh date-gates
# auth_allow_weak_schemes). After it Dovecot rejects $1$ hashes entirely, so
# this script is the passive half of the migration — the user just logs in.
# The active halves are the webmail password change and the AdminNG API.
#
# This script must never break a login: every catalogue step fails open (the
# login proceeds regardless), and it must not write to stdout, which Dovecot
# connects to the client's IMAP/POP3 socket ("Post-login scripting"):
# diagnostics go to stderr, i.e. Dovecot's error log.
set -eu

# script-login (10-master.conf) runs post-login scripts with a *minimal*
# environment: PATH is unset, so `doveadm` aborts with
# "t_binary_abspath(doveadm) failed: PATH environment variable undefined".
# Provide the image's standard PATH so doveadm (and psql) resolve.
PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

log() { echo "rehash-on-login: $*" >&2; }

# No plaintext (e.g. a GSSAPI/CLIENT-CERT login) or no user@domain: nothing to
# rehash, go straight to the real binary.
if [ -z "${PLAIN_PASS:-}" ] || [ -z "${USER:-}" ] || ! printf '%s' "${USER}" | grep -q '@' ; then
    exec "$@"
fi

# {ARGON2ID} is what this script writes, but an operator who set
# PASSWORD_SCHEME=md5crypt (the PostfixAdmin-compatible escape hatch) does not
# want rehash-on-login to migrate rows away from it: skip.
if [ "$(printf '%s' "${PASSWORD_SCHEME:-argon2id}" | tr '[:upper:]' '[:lower:]')" = 'md5crypt' ] ; then
    exec "$@"
fi

# Catalogue credentials (substituted from the _POSTGRES_*_ placeholders by
# configure.sh on first boot, same mechanism as the auth-sql.conf.ext driver).
if [ ! -f /etc/dovecot/rehash-creds.sh ] ; then
    log "/etc/dovecot/rehash-creds.sh missing, skipping migration"
    exec "$@"
fi
. /etc/dovecot/rehash-creds.sh

# Never let a catalogue hiccup stall (or fail) the login: psql never prompts,
# and both the connect and the statement are time-boxed.
export PGPASSWORD="${POSTGRES_PASSWORD:-}"
export PGCONNECT_TIMEOUT=5
export PGOPTIONS='-c statement_timeout=5000'

psql_q() {
    # SQL comes on stdin: `psql -c` does NOT interpolate the `:'var'`
    # placeholders (only input read from a file/stdin is variable-expanded).
    psql -q -w -X -v ON_ERROR_STOP=1 \
        -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" \
        -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
        -t -A "$@" 2>/dev/null
}

# Cheap gate first: only a legacy raw $1$ row needs the expensive Argon2id
# hash, so an already-migrated account pays just one indexed SELECT per login.
if ! psql_q -v user="${USER}" <<'SQL' | grep -q 1
SELECT 1 FROM mailbox
 WHERE username = :'user' AND password LIKE '$1$%' AND active;
SQL
then
    exec "$@"
fi

# doveadm pw -s ARGON2ID prints exactly the stored format the AdminNG API
# writes: {ARGON2ID}$argon2id$v=19$m=…,t=…,p=…$…
if ! HASH="$(doveadm pw -s ARGON2ID -p "${PLAIN_PASS}")" ; then
    log "could not hash the password, skipping migration"
    exec "$@"
fi

# Guarded, single-statement migration: the WHERE clause matches the legacy
# format only, so a concurrent password change (webmail driver / API) can never
# be clobbered and a re-run is a no-op.
if MIGRATED="$(psql_q -v user="${USER}" -v hash="${HASH}" <<'SQL'
UPDATE mailbox
   SET password = :'hash'
 WHERE username = :'user'
   AND password LIKE '$1$%'
   AND active
RETURNING username;
SQL
)" ; then
    if [ -n "${MIGRATED}" ] ; then
        log "${USER} password hash migrated to Argon2id"
    fi
else
    log "catalogue update failed, skipping migration"
fi

exec "$@"
