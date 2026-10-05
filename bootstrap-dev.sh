#!/usr/bin/env bash
#
# bootstrap-dev.sh — provision the local development stack (docker-compose-dev.yml) with
# usable data, idempotently. Companion to DEV-SETUP.md → "One-command bootstrap".
#
# What it provisions
#   1. the deployment's own domain (DEFAULT_DOMAIN from env.dev):
#        - <MAIL_ADMIN_USER>@<DEFAULT_DOMAIN>   the human administrator mailbox, also created as
#                                               the PostfixAdmin superadmin (README setup step)
#        - the default aliases (postmaster, abuse, hostmaster, webmaster) → the admin mailbox
#   2. the test domain (default example.net):
#        - alice, bob, charlie, dylan mailboxes with generated passwords
#        - the same default aliases → alice
#        - alice as the PostfixAdmin *domain admin* of the test domain
#   3. test.creds (git-ignored, mode 0600) with every credential, then verifies them:
#        IMAP auth through doveadm for each mailbox and a real PostfixAdmin web login.
#
# Everything is idempotent: a second run re-asserts the same state and changes nothing else.
# A password already present in test.creds is never replaced (--rotate-creds forces new ones).
# Dev only: it is hard-wired to docker-compose-dev.yml.
#
# Usage: ./bootstrap-dev.sh [--help]
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="docker-compose-dev.yml"
readonly EXEC_TIMEOUT=60     # hard ceiling for every single docker call (never hang)
readonly WAIT_DB=120         # seconds to wait for Postgres
readonly WAIT_SCHEMA=180     # seconds to wait for the PostfixAdmin schema
readonly WAIT_HTTP=120       # seconds to wait for a web UI
readonly WAIT_MUA=120        # seconds to wait for the webmail per-domain config
readonly WAIT_CLAMAV=900     # seconds to wait for the first ClamAV signature download

# The default aliases PostfixAdmin creates for a new domain. Kept in sync with
# admin/docker-entrypoint.sh ($CONF['default_aliases']) and the README "Domain Setup" step.
readonly DEFAULT_ALIAS_PARTS=(postmaster abuse hostmaster webmaster)

# ---------------------------------------------------------------- defaults ---
TEST_DOMAIN="example.net"
TEST_USERS=(alice bob charlie dylan)
ALIAS_TARGET=""
CREDS_FILE="test.creds"
ROTATE_CREDS=0
SUPERADMIN=0
SKIP_DEFAULT_DOMAIN=0
DEFAULT_DOMAIN_OVERRIDE=""
DO_START=1
DO_VERIFY=1
QUIET=0
SKIP_CLAMAV_WAIT=0

usage() {
	cat <<'EOF'
Provision the local development stack with usable mail data (idempotent).

Usage: ./bootstrap-dev.sh [options]

  --domain <domain>          test domain to create            (default: example.net)
  --users <a,b,c,d>          mailboxes in the test domain     (default: alice,bob,charlie,dylan)
  --alias-target <address>   where the test domain's default aliases (postmaster, abuse,
                             hostmaster, webmaster) point       (default: first user)
  --superadmin               also make the test-domain admin a PostfixAdmin superadmin
                             (the default is a *domain admin* of the test domain only)
  --default-domain <domain>  override DEFAULT_DOMAIN from env.dev for this run
  --skip-default-domain      do not provision DEFAULT_DOMAIN; only the test domain is created
  --creds <file>             credentials file                 (default: test.creds)
  --rotate-creds             generate new passwords even when <file> already has them
  --no-start                 assume the stack is already up (never call `up`)
  --skip-verify              skip the IMAP / web-login verification step
  --skip-clamav-wait         do not wait for the first ClamAV signature download
                             (with AV enabled amavis defers all mail until it lands)
  --quiet                    only print warnings, errors and the final summary
  -h, --help                 this text

Examples:
  ./bootstrap-dev.sh                                  # example.net + the env.dev default domain
  ./bootstrap-dev.sh --domain dev.local --users anna,erik
  ./bootstrap-dev.sh --no-start --skip-verify         # stack already running
EOF
}

# ---------------------------------------------------------------- console ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
	C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

step() { [ "$QUIET" = 1 ] || printf '\n%s==>%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
log() { [ "$QUIET" = 1 ] || printf '%s==>%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
item() { [ "$QUIET" = 1 ] || printf '      %s\n' "$*"; }
ok() { printf '%s  ok%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die() { printf '%sFAIL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- options ----
while [ $# -gt 0 ]; do
	case "$1" in
		--domain) [ $# -ge 2 ] || die "--domain needs a value"; TEST_DOMAIN="$2"; shift 2 ;;
		--users) [ $# -ge 2 ] || die "--users needs a value"; IFS=',' read -r -a TEST_USERS <<< "$2"; shift 2 ;;
		--alias-target) [ $# -ge 2 ] || die "--alias-target needs a value"; ALIAS_TARGET="$2"; shift 2 ;;
		--superadmin) SUPERADMIN=1; shift ;;
		--default-domain) [ $# -ge 2 ] || die "--default-domain needs a value"; DEFAULT_DOMAIN_OVERRIDE="$2"; shift 2 ;;
		--skip-default-domain) SKIP_DEFAULT_DOMAIN=1; shift ;;
		--creds) [ $# -ge 2 ] || die "--creds needs a value"; CREDS_FILE="$2"; shift 2 ;;
		--rotate-creds) ROTATE_CREDS=1; shift ;;
		--no-start) DO_START=0; shift ;;
		--skip-verify) DO_VERIFY=0; shift ;;
		--skip-clamav-wait) SKIP_CLAMAV_WAIT=1; shift ;;
		--quiet) QUIET=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
done

# ---------------------------------------------------------------- stdin ------
# Never inherit the terminal on stdin. `docker compose exec` (even with -T) deadlocks when
# stdin is a TTY while stdout/stderr are redirected — exactly what wait_up() does below with
# "$@" >/dev/null 2>&1 — and this Compose then leaves the terminal in raw mode, so the hang
# cannot even be interrupted with Ctrl+C and the whole shell has to be killed. The script is
# fully non-interactive (options come from argv, files are read via explicit redirects), so
# handing every child /dev/null on stdin is safe and removes the whole class of stalls.
exec </dev/null

# ---------------------------------------------------------------- helpers ----
# Read KEY=value from an env file: the last occurrence wins, surrounding quotes are stripped and
# a trailing " # comment" is removed (MAX_MESSAGESIZE in .env carries one).
env_file_value() {
	local file="$1" key="$2" line
	[ -f "$file" ] || return 1
	line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n1 || true)"
	[ -n "$line" ] || return 1
	line="${line#*=}"
	line="$(printf '%s' "$line" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
	line="${line%\"}"; line="${line#\"}"
	line="${line%\'}"; line="${line#\'}"
	printf '%s' "$line"
}

is_service_up() { # <service> — compose-native, no container-name guessing
	local ids
	ids="$(timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" ps --status running -q "$1" 2>/dev/null || true)"
	[ -n "$ids" ]
}

wait_up() { # <seconds> <probe...> — bounded, never hangs, never echoes
	local seconds="$1"; shift
	local start=$SECONDS
	while :; do
		# </dev/null: a probe that inherits a TTY on stdin deadlocks `docker compose exec`
		# (see the stdin note above); the EOF keeps this helper truly bounded/hang-proof.
		if "$@" </dev/null >/dev/null 2>&1; then return 0; fi
		if [ $((SECONDS - start)) -ge "$seconds" ]; then return 1; fi
		sleep 2
	done
}

psql_q() { # <db> <sql> — one value on stdout ('' when there is no row)
	timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T db psql -U "$PGUSER" -d "$1" -tAc "$2" 2>/dev/null |
		tr -d '\r' | head -n1
}

psql_in() { # <db> [psql args...] — the SQL is read from stdin
	local db="$1"; shift
	timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T db psql -U "$PGUSER" -d "$db" -v ON_ERROR_STOP=1 "$@" -f -
}

gen_pw() { openssl rand -hex 16; }

valid_domain() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
valid_local() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$'; }
valid_address() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }

mailbox_name() { # <address> — display name used by PostfixAdmin
	case "${1%%@*}" in
		sysadmin) printf 'Mail administrator' ;;
		no-reply|noreply) printf 'MailD service (no reply)' ;;
		alice) printf 'Alice' ;;
		bob) printf 'Bob' ;;
		charlie) printf 'Charlie' ;;
		dylan) printf 'Dylan' ;;
		*) printf '%s' "${1%%@*}" ;;
	esac
}

# ---------------------------------------------------------------- preflight --
step "preflight"

[ -f "$SCRIPT_DIR/$COMPOSE_FILE" ] || die "$SCRIPT_DIR/$COMPOSE_FILE not found: run this script from the repository"
cd "$SCRIPT_DIR"

command -v docker >/dev/null 2>&1 || die "docker is not installed / not on PATH"
docker compose version >/dev/null 2>&1 || die "docker compose (v2) is not available"
timeout -k10 "$EXEC_TIMEOUT" docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"
command -v openssl >/dev/null 2>&1 || die "openssl is required (password generation)"
command -v curl >/dev/null 2>&1 || die "curl is required (web UI checks)"

# The dev stack interpolates its secrets from env.dev (fake, committed) — never from .env,
# which holds the real local/production passwords. Always pass the flag: a plain
# `docker compose -f <file>` would silently interpolate from .env and drift.
readonly ENV_FILE="env.dev"
readonly DC=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

"${DC[@]}" config --quiet >/dev/null 2>&1 ||
	die "'docker compose --env-file $ENV_FILE -f $COMPOSE_FILE config' failed: fix the compose file / $ENV_FILE first"

for f in env.sample vars/db.env vars/admin.env vars/mda.env vars/mta.env vars/mua.env; do
	[ -f "$SCRIPT_DIR/$f" ] || die "$f is missing: this does not look like a MailD checkout"
done
[ -f "$SCRIPT_DIR/$ENV_FILE" ] ||
	die "$ENV_FILE is missing: the dev stack needs it for POSTGRES_PASSWORD (fake dev-only secrets; the real ones in .env are never used by the dev stack)"

PGUSER="$(env_file_value vars/db.env POSTGRES_USER || true)"
PGDB="$(env_file_value vars/db.env POSTGRES_DB || true)"
PGUSER="${PGUSER:-maild}"; PGDB="${PGDB:-mailddb}"
ok "docker compose v2, compose file, $ENV_FILE and vars/ are in place"

# ------------------------------------------------------------ configuration --
step "configuration"

DEFAULT_DOMAIN="$(env_file_value "$ENV_FILE" DEFAULT_DOMAIN || true)"
[ -n "$DEFAULT_DOMAIN" ] || DEFAULT_DOMAIN="$(env_file_value env.sample DEFAULT_DOMAIN || true)"
[ -n "$DEFAULT_DOMAIN_OVERRIDE" ] && DEFAULT_DOMAIN="$DEFAULT_DOMAIN_OVERRIDE"
MAIL_ADMIN_USER="$(env_file_value "$ENV_FILE" MAIL_ADMIN_USER || true)"
[ -n "$MAIL_ADMIN_USER" ] || MAIL_ADMIN_USER="$(env_file_value env.sample MAIL_ADMIN_USER || true)"
MAIL_ADMIN_USER="${MAIL_ADMIN_USER:-sysadmin}"

# The stack declares port mappings in docker-compose-dev.yml; keep them here so the printed URLs
# and the verification steps match the running stack.
ADMIN_PORT="8080"
MUA_PORT="8081"

valid_domain "$TEST_DOMAIN" || die "--domain '$TEST_DOMAIN' is not a valid domain name"
if [ "$SKIP_DEFAULT_DOMAIN" = 0 ]; then
	valid_domain "$DEFAULT_DOMAIN" || die "DEFAULT_DOMAIN '$DEFAULT_DOMAIN' is not a valid domain name"
	[ "$TEST_DOMAIN" != "$DEFAULT_DOMAIN" ] ||
		die "the test domain equals DEFAULT_DOMAIN ($DEFAULT_DOMAIN): use --skip-default-domain for a single-domain run"
fi
for u in "${TEST_USERS[@]}"; do
	valid_local "$u" || die "--users: '$u' is not a valid local part"
done
[ "${#TEST_USERS[@]}" -ge 1 ] || die "--users needs at least one mailbox"
[ -n "$ALIAS_TARGET" ] || ALIAS_TARGET="${TEST_USERS[0]}@${TEST_DOMAIN}"
valid_address "$ALIAS_TARGET" || die "--alias-target '$ALIAS_TARGET' is not a valid address"
case "$ALIAS_TARGET" in
	*@"$TEST_DOMAIN") ;;
	*) warn "--alias-target $ALIAS_TARGET is outside $TEST_DOMAIN: the default aliases will forward outside the test domain" ;;
esac

ok "test domain          : $TEST_DOMAIN"
ok "test mailboxes       : ${TEST_USERS[*]}"
ok "default aliases      : ${DEFAULT_ALIAS_PARTS[*]}@$TEST_DOMAIN → $ALIAS_TARGET"
if [ "$SKIP_DEFAULT_DOMAIN" = 1 ]; then
	ok "deployment domain    : skipped (--skip-default-domain)"
else
	ok "deployment domain    : $DEFAULT_DOMAIN ($MAIL_ADMIN_USER)"
fi

# ------------------------------------------------------------ bind mounts ----
step "fresh bind mounts"

# Unlike a named volume (which docker pre-populates from the image), a fresh *bind* mount is
# created empty: the amavis TEMPBASE disappears (amavisd-new then dies with "No TEMPBASE
# directory") and clamav cannot write its freshclam.dat. Re-create the missing pieces from a
# throwaway container — root inside docker, so no sudo on the workstation (the same trick the
# vmail/mua chowns below use). Idempotent: mkdir/chown to the same owner is a no-op.
bind_prep() { # <image> <host dir> <sh snippet run inside /target>
	timeout -k10 120 docker run --rm -v "${SCRIPT_DIR}/$2:/target" --entrypoint /bin/sh "$1" \
		-c "$3" >/dev/null ||
		warn "could not prepare $2 with $1: $3"
}
# image names match docker-compose-dev.yml (this script is hard-wired to the dev stack);
# amavis is uid 101 (amavis), clamav is uid 101 / gid 102 (clamav).
# amavis: the whole image content matters — beside tmp/ it needs $db_home (amavisd-new dies
# with "Please create an empty directory /var/lib/amavis/db") and virusmails; cp -n never
# overwrites what the services already created, so a re-run is a no-op.
bind_prep "pavelmc/maild-amavis:develop" "ldata/amavis" \
	"cp -a -n /var/lib/amavis/. /target/ && chown -R 101:101 /target"
# clamav: the clamav image itself runs as uid 101 and cannot chown, so use a root image
# (the amavis one) as the vehicle.
bind_prep "pavelmc/maild-amavis:develop" "ldata/clamav" \
	"chown -R 101:102 /target && chmod 0750 /target"
ok "amavis TEMPBASE and the clamav volume are in place"

# --------------------------------------------------------------- stack up ----
step "services"

# Refuse to continue when the stack was created with different secrets than $ENV_FILE (e.g. a
# plain `docker compose -f $COMPOSE_FILE up` without --env-file, which silently interpolates
# from .env): postgres only honours POSTGRES_PASSWORD on first init, so recreating containers
# with a new value would leave the db and its clients with different passwords. Dev data is
# disposable, so the fix is always the same: down, wipe ldata/, re-run.
db_cid="$(timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" ps -aq db 2>/dev/null || true)"
if [ -n "$db_cid" ]; then
	db_pw="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$db_cid" 2>/dev/null |
		sed -n 's/^POSTGRES_PASSWORD=//p' | head -n1 || true)"
	want_pw="$(env_file_value "$ENV_FILE" POSTGRES_PASSWORD || true)"
	if [ -n "$db_pw" ] && [ "$db_pw" != "$want_pw" ]; then
		die "the db container was created with different secrets than $ENV_FILE (compose probably ran without --env-file): run 'docker compose -f $COMPOSE_FILE --env-file $ENV_FILE down', then 'rm -rf ldata/' and re-run (dev data is disposable)"
	fi
fi

if [ "$DO_START" = 1 ]; then
	# `cron` is in the list on purpose: the amavis entrypoint refuses to start when it cannot
	# resolve the cron container's IP ("CRON IP is empty"), and amavis is in the MTA's delivery
	# path via depends_on — a subset `up` would otherwise leave it crash-looping and mail deferred.
	# `clamav` and `amavis` are explicit (not only via mta's depends_on): the content
	# filter sits in the delivery path, so its readiness gates everything below.
	log "docker compose up -d db admin mda mta mua cron clamav amavis"
	timeout -k10 600 "${DC[@]}" up -d db admin mda mta mua cron clamav amavis >/dev/null ||
		die "'docker compose up -d' failed: see 'docker compose -f $COMPOSE_FILE logs'"
else
	log "--no-start: assuming the stack is already up"
fi

# -d "$PGDB": without a database, libpq defaults to the role name ("maild") and the
# server logs 'FATAL: database "maild" does not exist' on every probe.
probe_db() { timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T db pg_isready -U "$PGUSER" -d "$PGDB" -q; }
probe_schema() { [ "$(psql_q "$PGDB" "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='domain'")" = "1" ]; }
probe_admin_http() { timeout -k10 20 curl -sf -o /dev/null "http://localhost:${ADMIN_PORT}/login.php"; }
probe_clamav_db() { timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T clamav \
	sh -c 'test -f /var/lib/clamav/main.cvd || test -f /var/lib/clamav/main.cld'; }

log "waiting for Postgres (up to ${WAIT_DB}s)"
wait_up "$WAIT_DB" probe_db || die "Postgres did not answer within ${WAIT_DB}s (docker compose -f $COMPOSE_FILE logs db)"

log "waiting for the PostfixAdmin schema in '$PGDB' (up to ${WAIT_SCHEMA}s)"
if ! wait_up 60 probe_schema; then
	# spike-log §11 item 9: a leftover admin container can leave the schema uncreated; the
	# documented fix is a force-recreate of the admin service (its entrypoint runs upgrade.php).
	warn "schema still missing: recreating the admin service (its entrypoint creates the schema)"
	timeout -k10 300 "${DC[@]}" up -d --force-recreate admin >/dev/null || true
	wait_up "$WAIT_SCHEMA" probe_schema ||
		die "the PostfixAdmin schema never appeared. Check 'docker compose -f $COMPOSE_FILE logs admin' (its entrypoint must run public/upgrade.php with POSTFIXADMIN_DB_TYPE=pgsql)"
fi
ok "Postgres is up and the PostfixAdmin schema exists"

log "waiting for the PostfixAdmin web UI on :$ADMIN_PORT (up to ${WAIT_HTTP}s)"
wait_up "$WAIT_HTTP" probe_admin_http ||
	die "http://localhost:${ADMIN_PORT}/login.php did not answer within ${WAIT_HTTP}s (docker compose -f $COMPOSE_FILE logs admin)"

is_service_up mda || die "the mda (Dovecot) service is not running (docker compose -f $COMPOSE_FILE logs mda)"
ok "admin (:${ADMIN_PORT}) and mda are reachable"

# With AV enabled amavis defers every message until clamd has a signature database, so
# the stack is not usable before that (first-run) download lands: ~230 MB, minutes on a
# slow link.
if [ "$SKIP_CLAMAV_WAIT" = 1 ]; then
	log "--skip-clamav-wait: not waiting for the ClamAV signature database"
elif probe_clamav_db; then
	ok "ClamAV signature database present"
else
	warn "waiting for the first ClamAV signature download (main.cvd is ~90 MB; ~230 MB the first time)"
	wait_up "$WAIT_CLAMAV" probe_clamav_db ||
		die "ClamAV still has no signature database after ${WAIT_CLAMAV}s, and amavis defers all mail until it does: check 'docker compose -f $COMPOSE_FILE logs clamav' (an ALTERNATE_MIRROR in vars/clamav.env helps on restricted networks) or re-run with --skip-clamav-wait"
	ok "ClamAV signature database downloaded"
fi

# amavis is the MTA's content filter (content_filter = smtp-amavis): while it is down, postfix
# defers every message and the whole test suite fails. On a fresh stack it needs the bind-mount
# repair above plus a restart cycle, hence the bounded wait.
log "waiting for amavis (up to 60s)"
wait_up 60 is_service_up amavis ||
	die "the amavis service is not running (docker compose -f $COMPOSE_FILE logs amavis)"
ok "amavis is up"

# The mta resolves its peers once, at its own start: it writes their addresses into
# /etc/postfix/main.cf (virtual_transport = lmtp:inet:<MDA IP>:24 — the trap of review §15.5) and
# mirrors them in /tmp/*IP for its /check.sh. If any peer container was recreated since, the mta
# keeps delivering to a dead address *and* reports "unhealthy" forever. Detect the drift and
# restart it (the documented remedy); a restart also re-resolves the names.
mta_peer_moved() {
	local svc cached live
	for svc in amavis mda mua admin; do
		cached="$(timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mta cat "/tmp/${svc^^}IP" 2>/dev/null | tr -d ' \r\n' || true)"
		live="$(timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mta getent hosts "$svc" 2>/dev/null | head -n1 | cut -d' ' -f1 || true)"
		if [ -n "$cached" ] && [ -n "$live" ] && [ "$cached" != "$live" ]; then
			log "mta: $svc moved from $cached to $live"
			return 0
		fi
	done
	return 1
}
if is_service_up mta && mta_peer_moved; then
	warn "the mta cached a peer address that changed: restarting it (otherwise LMTP delivery and its own healthcheck fail)"
	timeout -k10 120 "${DC[@]}" restart mta >/dev/null || warn "could not restart the mta service"
	sleep 3
fi

# Effective service addresses, read from the running containers (authoritative). Fall back to the
# values the dev compose derives when the container is not up (--no-start on a partial stack).

# ------------------------------------------------------------ credentials ----
declare -A CRED_PW=()   # what test.creds already holds (reused verbatim)
declare -A PW=()        # effective password per address
declare -A NAME=()      # PostfixAdmin display name per address
declare -A ROLE=()      # human-readable label, for test.creds and the summary
declare -a ADDRESSES=() # ordered: deployment domain first, then the test domain
declare -A HASH=()      # MD5-CRYPT hash per address

declare -A SEEN=()      # membership guard for ADDRESSES
add_mailbox() { # <address> <role label>
	local addr="$1"
	[ -n "${SEEN[$addr]:-}" ] && return 0
	SEEN["$addr"]=1
	ADDRESSES+=("$addr")
	NAME["$addr"]="$(mailbox_name "$addr")"
	ROLE["$addr"]="$2"
}

# test.creds is both an output and an input: a password found there is re-applied, never
# regenerated, so a second (or tenth) run keeps the credentials a tester may already be using.
read_creds() {
	local line key value
	[ -f "$CREDS_FILE" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|'#'*) continue ;; esac
		key="${line%%=*}"; value="${line#*=}"
		case "$key" in *[!A-Za-z0-9._@+-]*) continue ;; esac
		CRED_PW["$key"]="$value"
	done < "$CREDS_FILE"
}

step "credentials ($CREDS_FILE)"
read_creds
[ -f "$CREDS_FILE" ] && log "found an existing $CREDS_FILE: its passwords will be reused"

if [ "$SKIP_DEFAULT_DOMAIN" = 0 ]; then
	add_mailbox "${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}" "PostfixAdmin superadmin + human administrator"
else
	log "--skip-default-domain: only $TEST_DOMAIN is provisioned ($DEFAULT_DOMAIN untouched)"
fi

for u in "${TEST_USERS[@]}"; do
	add_mailbox "${u}@${TEST_DOMAIN}" "mailbox in $TEST_DOMAIN"
done
TEST_ADMIN_ADDR="${TEST_USERS[0]}@${TEST_DOMAIN}"
if [ "$SUPERADMIN" = 1 ]; then
	ROLE["$TEST_ADMIN_ADDR"]="PostfixAdmin superadmin + domain admin of $TEST_DOMAIN"
else
	ROLE["$TEST_ADMIN_ADDR"]="PostfixAdmin domain admin of $TEST_DOMAIN"
fi
if [ "$ALIAS_TARGET" = "$TEST_ADMIN_ADDR" ]; then
	ROLE["$TEST_ADMIN_ADDR"]="${ROLE[$TEST_ADMIN_ADDR]} + default alias target"
fi

NEW_PASSWORDS=()
for addr in "${ADDRESSES[@]}"; do
	if [ "$ROTATE_CREDS" = 1 ] || [ -z "${CRED_PW[$addr]:-}" ]; then
		PW["$addr"]="$(gen_pw)"
		NEW_PASSWORDS+=("$addr")
	else
		PW["$addr"]="${CRED_PW[$addr]}"
	fi
done

umask 077
creds_tmp="$(mktemp "${CREDS_FILE}.XXXXXX")"
{
	printf '# MailD dev bootstrap credentials — DEV ONLY, plaintext on purpose.\n'
	printf '# Generated by %s at %s — git-ignored, mode 0600.\n' "${0##*/}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf '# The same password works over IMAP/SMTP and in the PostfixAdmin web UI: Dovecot\n'
	printf '# (MD5-CRYPT) and PostfixAdmin (md5crypt) verify the very same hash.\n'
	printf '#\n'
	printf '# PostfixAdmin (admin) : http://localhost:%s\n' "$ADMIN_PORT"
	printf '# Webmail (SnappyMail) : http://localhost:%s\n' "$MUA_PORT"
	printf '#\n'
	printf '# Accounts in PostfixAdmin:\n'
	for addr in "${ADDRESSES[@]}"; do
		case "${ROLE[$addr]}" in *admin*) printf '#   %-24s %s\n' "$addr" "${ROLE[$addr]}" ;; esac
	done
	printf '#\n'
	printf '# Mailbox passwords:\n'
	for addr in "${ADDRESSES[@]}"; do
		printf '%s=%s\n' "$addr" "${PW[$addr]}"
	done
} > "$creds_tmp"
mv "$creds_tmp" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
ok "$CREDS_FILE written ($(stat -c '%a' "$CREDS_FILE"), ${#ADDRESSES[@]} mailboxes, ${#NEW_PASSWORDS[@]} new password(s))"

# --------------------------------------------------------------- hashing -----
step "password hashes (MD5-CRYPT, the scheme Dovecot verifies)"

for addr in "${ADDRESSES[@]}"; do
	h="$(timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mda doveadm pw -s MD5-CRYPT -p "${PW[$addr]}" 2>/dev/null |
		tr -d '\r' | tail -n1 || true)"
	h="$(printf '%s' "$h" | sed -E 's/^\{[^}]*\}//')"   # drop an optional {SCHEME} prefix
	printf '%s' "$h" | grep -q '^\$1\$' ||
		die "could not produce an MD5-CRYPT hash for $addr (got '${h}'): is the mda container healthy? (docker compose -f $COMPOSE_FILE logs mda)"
	HASH["$addr"]="$h"
done
ok "hashes ready for ${#ADDRESSES[@]} mailboxes"

# --------------------------------------------------------------- catalogue ---
step "mail catalogue ($PGDB)"

# Column preflight: the PostfixAdmin schema is versioned (the R-20 drift class), so fail loudly
# with the exact missing columns instead of a cryptic SQL error a few statements later.
psql_in "$PGDB" <<'SQL'
DO $$
DECLARE missing text;
BEGIN
	SELECT string_agg(x.t || '.' || x.c, ', ') INTO missing
	  FROM (VALUES
		('domain','domain'), ('domain','description'), ('domain','aliases'), ('domain','mailboxes'),
		('domain','maxquota'), ('domain','quota'), ('domain','transport'), ('domain','backupmx'),
		('domain','active'),
		('mailbox','username'), ('mailbox','password'), ('mailbox','name'), ('mailbox','maildir'),
		('mailbox','quota'), ('mailbox','domain'), ('mailbox','local_part'), ('mailbox','active'),
		('alias','address'), ('alias','goto'), ('alias','domain'), ('alias','active'),
		('admin','username'), ('admin','password'), ('admin','superadmin'), ('admin','active'),
		('domain_admins','username'), ('domain_admins','domain'), ('domain_admins','active')
	  ) AS x(t, c)
	 WHERE NOT EXISTS (
		SELECT 1 FROM information_schema.columns col
		 WHERE col.table_schema = 'public' AND col.table_name = x.t AND col.column_name = x.c);
	IF missing IS NOT NULL THEN
		RAISE EXCEPTION 'bootstrap: unexpected PostfixAdmin schema, missing column(s): %', missing;
	END IF;
END
$$;
SQL
ok "schema check: every expected column is present"

# Every write is "INSERT … ON CONFLICT DO NOTHING" followed by an UPDATE that pins the wanted
# state, so a re-run converges instead of failing on duplicates and no unique-index layout is
# assumed. Passwords are handed to psql as variables (:'name'), never interpolated by the shell.
ensure_domain() { # <domain> <description>
	local dom="$1" desc="$2"
	if [ "$(psql_q "$PGDB" "SELECT 1 FROM domain WHERE domain = '$dom'")" = "1" ]; then
		item "domain  $dom (present, re-asserted)"
	else
		item "domain  $dom (created)"
	fi
	psql_in "$PGDB" -v dom="$dom" -v desc="$desc" <<'SQL'
INSERT INTO domain (domain, description, aliases, mailboxes, maxquota, quota, transport, backupmx, active)
VALUES (:'dom', :'desc', 0, 0, 0, 0, 'virtual', false, true)
ON CONFLICT DO NOTHING;
UPDATE domain
   SET description = :'desc', aliases = 0, mailboxes = 0, maxquota = 0, quota = 0,
       transport = 'virtual', backupmx = false, active = true
 WHERE domain = :'dom';
SQL
}

ensure_mailbox() { # <address> <md5-crypt hash> <display name>
	local addr="$1" hash="$2" name="$3"
	if [ "$(psql_q "$PGDB" "SELECT 1 FROM mailbox WHERE username = '$addr'")" = "1" ]; then
		item "mailbox $addr (present, re-asserted)"
	else
		item "mailbox $addr (created)"
	fi
	# quota stays 0 on purpose: dovecot-sql.conf.ext returns CONCAT('*:bytes=', quota), i.e. the
	# column is read as BYTES here, not as the MB PostfixAdmin assumes (0 = no quota limit).
	psql_in "$PGDB" -v addr="$addr" -v hash="$hash" -v name="$name" <<'SQL'
INSERT INTO mailbox (username, password, name, maildir, quota, domain, local_part, active)
VALUES (:'addr', :'hash', :'name',
        split_part(:'addr', '@', 2) || '/' || split_part(:'addr', '@', 1) || '/',
        0, split_part(:'addr', '@', 2), split_part(:'addr', '@', 1), true)
ON CONFLICT DO NOTHING;
UPDATE mailbox
   SET password   = :'hash',
       name       = :'name',
       maildir    = split_part(:'addr', '@', 2) || '/' || split_part(:'addr', '@', 1) || '/',
       quota      = 0,
       domain     = split_part(:'addr', '@', 2),
       local_part = split_part(:'addr', '@', 1),
       active     = true
 WHERE username = :'addr';
SQL
}

ensure_alias() { # <address> <goto>
	local addr="$1" target="$2"
	if [ "$(psql_q "$PGDB" "SELECT 1 FROM alias WHERE address = '$addr'")" = "1" ]; then
		item "alias   $addr → $target (present, re-asserted)"
	else
		item "alias   $addr → $target (created)"
	fi
	psql_in "$PGDB" -v addr="$addr" -v goto="$target" <<'SQL'
INSERT INTO alias (address, goto, domain, active)
VALUES (:'addr', :'goto', split_part(:'addr', '@', 2), true)
ON CONFLICT DO NOTHING;
UPDATE alias
   SET goto = :'goto', domain = split_part(:'addr', '@', 2), active = true
 WHERE address = :'addr';
SQL
}

ensure_admin() { # <address> <md5-crypt hash> <true|false superadmin> [scoped domain]
	local addr="$1" hash="$2" super="$3" scope="${4:-}"
	if [ "$(psql_q "$PGDB" "SELECT 1 FROM admin WHERE username = '$addr'")" = "1" ]; then
		item "admin   $addr (present, password re-asserted)"
	else
		item "admin   $addr (created)"
	fi
	psql_in "$PGDB" -v addr="$addr" -v hash="$hash" -v super="$super" <<'SQL'
INSERT INTO admin (username, password, superadmin, active)
VALUES (:'addr', :'hash', :'super'::boolean, true)
ON CONFLICT DO NOTHING;
UPDATE admin SET password = :'hash', superadmin = :'super'::boolean, active = true
 WHERE username = :'addr';
SQL
	if [ -n "$scope" ]; then
		item "        scope: domain admin of $scope"
		# domain_admins carries only a surrogate `id` primary key (no unique index on
		# (username, domain)), so "ON CONFLICT DO NOTHING" cannot catch a repeat and would pile
		# up a duplicate row on every run. The NOT EXISTS guard is what makes this idempotent.
		psql_in "$PGDB" -v addr="$addr" -v dom="$scope" <<'SQL'
INSERT INTO domain_admins (username, domain, active)
SELECT :'addr', :'dom', true
 WHERE NOT EXISTS (SELECT 1 FROM domain_admins WHERE username = :'addr' AND domain = :'dom');
UPDATE domain_admins SET active = true WHERE username = :'addr' AND domain = :'dom';
SQL
	fi
}

if [ "$SKIP_DEFAULT_DOMAIN" = 0 ]; then
	SYSADMIN_ADDR="${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}"
	ensure_domain "$DEFAULT_DOMAIN" "MailD dev deployment domain (DEFAULT_DOMAIN)"
fi
ensure_domain "$TEST_DOMAIN" "MailD dev test domain (bootstrap-dev.sh)"

for addr in "${ADDRESSES[@]}"; do
	ensure_mailbox "$addr" "${HASH[$addr]}" "${NAME[$addr]}"
done

log "default aliases (postmaster, abuse, hostmaster, webmaster)"
if [ "$SKIP_DEFAULT_DOMAIN" = 0 ]; then
	for part in "${DEFAULT_ALIAS_PARTS[@]}"; do
		ensure_alias "${part}@${DEFAULT_DOMAIN}" "$SYSADMIN_ADDR"
	done
fi
for part in "${DEFAULT_ALIAS_PARTS[@]}"; do
	ensure_alias "${part}@${TEST_DOMAIN}" "$ALIAS_TARGET"
done

log "PostfixAdmin accounts"
if [ "$SKIP_DEFAULT_DOMAIN" = 0 ]; then
	# README "Setup Instructions" step 3: the superadmin account. Same password as its mailbox.
	ensure_admin "$SYSADMIN_ADDR" "${HASH[$SYSADMIN_ADDR]}" true
fi
if [ "$SUPERADMIN" = 1 ]; then
	ensure_admin "$TEST_ADMIN_ADDR" "${HASH[$TEST_ADMIN_ADDR]}" true "$TEST_DOMAIN"
else
	# a genuine *domain admin*: admin.superadmin = false + a domain_admins row (WP: "alice is the
	# domain admin" and "all default aliases point to her")
	ensure_admin "$TEST_ADMIN_ADDR" "${HASH[$TEST_ADMIN_ADDR]}" false "$TEST_DOMAIN"
fi
ok "mail catalogue provisioned"

# ------------------------------------------------------------ vmail volume ---
step "mailbox homes on the vmail volume"

# A fresh ./ldata/vmail is created by docker as root, and Dovecot/LMTP write as uid:gid 5000
# (spike-log §11 item 5: "mkdir(/home/vmail/...) failed: Permission denied"). Fix it from inside
# the mda container, which runs as root — no sudo on the workstation needed.
home_dirs=()
for addr in "${ADDRESSES[@]}"; do
	home_dirs+=("/home/vmail/${addr##*@}/${addr%%@*}")
done
timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mda mkdir -p /home/vmail "${home_dirs[@]}" ||
	die "could not create the mailbox home directories (docker compose -f $COMPOSE_FILE logs mda)"
timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mda chown 5000:5000 /home/vmail "${home_dirs[@]}" ||
	die "could not set the vmail ownership (docker compose -f $COMPOSE_FILE logs mda)"
timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mda chmod 0700 "${home_dirs[@]}" || true
ok "vmail homes ready (owner 5000:5000, ${#home_dirs[@]} mailboxes)"

# --------------------------------------------------------------- webmail -----
step "webmail domain configuration"

MUA_DOMAINS=("$TEST_DOMAIN")
[ "$SKIP_DEFAULT_DOMAIN" = 0 ] && MUA_DOMAINS=("$DEFAULT_DOMAIN" "$TEST_DOMAIN")
mua_configs_present() {
	# Checked *inside* the container: SnappyMail keeps its data directory at mode 0700 owned by
	# www-data, so the host mount point is not readable for the user running this script.
	local dom
	for dom in "${MUA_DOMAINS[@]}"; do
		timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mua \
			test -f "/var/www/html/data/_data_/_default_/domains/${dom}.json" || return 1
	done
}

# SnappyMail builds one JSON config per domain when its entrypoint runs (it queries the `domain`
# table and deletes stale configs), so a *restart* — not a recreate, which would change the
# container IP that mua/mta cache at boot — is what makes the new domains usable.
timeout -k10 300 "${DC[@]}" up -d mua >/dev/null || die "'docker compose up -d mua' failed"
# SnappyMail initialises itself by writing into /var/www/html/data (the bind mount above). A
# fresh host directory is root-owned, so the web server (www-data) could not start up: hand the
# directory over from inside the container, which runs as root — no sudo on the workstation.
timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mua chown -R www-data:www-data /var/www/html/data ||
	warn "could not hand /var/www/html/data to www-data: the webmail may not initialise"
timeout -k10 120 "${DC[@]}" restart mua >/dev/null || die "'docker compose restart mua' failed"
if wait_up "$WAIT_MUA" mua_configs_present; then
	ok "SnappyMail per-domain configs ready: ${MUA_DOMAINS[*]}"
else
	warn "no SnappyMail per-domain config for ${MUA_DOMAINS[*]} yet: check 'docker compose -f $COMPOSE_FILE logs mua' and re-run"
fi

# ------------------------------------------------- content filter (DKIM) -----
# amavis reads the domain list once, at its own start, and generates the DKIM key of
# every domain it finds there: a domain created afterwards goes out unsigned. The mta
# caches the amavis address at boot, hence a restart (not a recreate).
DKIM_DOMAINS=("$TEST_DOMAIN")
[ "$SKIP_DEFAULT_DOMAIN" = 0 ] && DKIM_DOMAINS+=("$DEFAULT_DOMAIN")
dkim_keys_present() {
	local dom
	for dom in "${DKIM_DOMAINS[@]}"; do
		timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T amavis \
			test -f "/var/lib/amavis/dkim/${dom}.pem" || return 1
	done
}
if dkim_keys_present; then
	log "DKIM keys already present for ${DKIM_DOMAINS[*]}"
else
	step "content filter / DKIM keys"
	log "restarting amavis so it picks up ${DKIM_DOMAINS[*]} and generates their DKIM keys"
	timeout -k10 120 "${DC[@]}" restart amavis >/dev/null || die "'docker compose restart amavis' failed"
	wait_up 120 dkim_keys_present ||
		warn "amavis has no DKIM key for ${DKIM_DOMAINS[*]} yet: mail from those domains will not be signed (check 'docker compose -f $COMPOSE_FILE logs amavis')"
	wait_up 60 is_service_up amavis || die "the amavis service did not come back after the restart"
	dkim_keys_present && ok "DKIM signing ready for ${DKIM_DOMAINS[*]}"
fi

# ----------------------------------------------------------- verification ----
# The PostfixAdmin web login is the real end-to-end check: GET /login.php to obtain the session
# cookie and the CSRF token, then POST fUsername/fPassword/token and require a 302 to main.php
# (public/login.php does exactly that on success).
admin_login_check() { # <address> <password>
	local addr="$1" pw="$2" jar hdrs page token code
	jar="$(mktemp)"; hdrs="$(mktemp)"
	page="$(timeout -k10 20 curl -sS -c "$jar" "http://localhost:${ADMIN_PORT}/login.php" 2>/dev/null || true)"
	token="$(printf '%s' "$page" | tr '>' '\n' | grep 'name="token"' | sed -n 's/.*value="\([^"]*\)".*/\1/p' | head -n1)"
	if [ -z "$token" ]; then
		rm -f "$jar" "$hdrs"
		warn "PostfixAdmin login check for $addr: the login page carries no CSRF token (is the stack configured?) — the row and hash are in place, but the web login is unverified"
		return 1
	fi
	code="$(timeout -k10 20 curl -sS -o /dev/null -D "$hdrs" -b "$jar" -c "$jar" \
		--data-urlencode "fUsername=$addr" --data-urlencode "fPassword=$pw" \
		--data-urlencode "token=$token" -w '%{http_code}' \
		"http://localhost:${ADMIN_PORT}/login.php" 2>/dev/null || true)"
	if [ "$code" = "302" ] && grep -qi '^location: main.php' "$hdrs"; then
		rm -f "$jar" "$hdrs"
		ok "PostfixAdmin login   $addr (302 → main.php)"
		return 0
	fi
	rm -f "$jar" "$hdrs"
	warn "PostfixAdmin login FAILED for $addr (HTTP ${code:-?})"
	return 1
}

VERIFY_FAILED=0
if [ "$DO_VERIFY" = 1 ]; then
	step "verification"

	for addr in "${ADDRESSES[@]}"; do
		if out="$(timeout -k10 "$EXEC_TIMEOUT" "${DC[@]}" exec -T mda doveadm auth test "$addr" "${PW[$addr]}" 2>&1 || true)" &&
			printf '%s' "$out" | grep -q 'auth succeeded'; then
			ok "IMAP login           $addr"
		else
			warn "IMAP login FAILED for $addr: $(printf '%s' "$out" | tr '\n' ' ')"
			VERIFY_FAILED=1
		fi
	done

	if [ "$SKIP_DEFAULT_DOMAIN" = 0 ]; then
		admin_login_check "$SYSADMIN_ADDR" "${PW[$SYSADMIN_ADDR]}" || VERIFY_FAILED=1
	fi
	admin_login_check "$TEST_ADMIN_ADDR" "${PW[$TEST_ADMIN_ADDR]}" || VERIFY_FAILED=1

	if [ "$VERIFY_FAILED" = 0 ]; then
		ok "every credential works over IMAP and in the PostfixAdmin web UI"
	fi
else
	log "--skip-verify: credentials were written but not verified"
fi

# ---------------------------------------------------------------- summary ----
PROVISIONED_DOMAINS=("$TEST_DOMAIN")
[ "$SKIP_DEFAULT_DOMAIN" = 0 ] && PROVISIONED_DOMAINS=("$DEFAULT_DOMAIN" "$TEST_DOMAIN")

step "summary"
printf '  %s\n' "domains     : ${PROVISIONED_DOMAINS[*]}"
printf '  %s\n' "admin UI    : http://localhost:${ADMIN_PORT}   (PostfixAdmin)"
printf '  %s\n' "webmail     : http://localhost:${MUA_PORT}   (SnappyMail)"
printf '  %s\n' "credentials : ${CREDS_FILE} (mode 600, git-ignored)"
printf '\n  %-30s %-34s %s\n' "MAILBOX" "PASSWORD" "POSTFIXADMIN / ROLE"
printf '  %-30s %-34s %s\n' "------------------------------" "----------------------------------" "-------------------------------"
for addr in "${ADDRESSES[@]}"; do
	printf '  %-30s %-34s %s\n' "$addr" "${PW[$addr]}" "${ROLE[$addr]}"
done

if [ "$VERIFY_FAILED" = 1 ]; then
	printf '\n'
	warn "one or more credentials could not be verified — see the warnings above and 'docker compose -f $COMPOSE_FILE logs mda mta admin'"
	exit 1
fi
printf '\n'
ok "bootstrap complete, and idempotent: run it again any time"
