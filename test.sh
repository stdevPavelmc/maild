#!/bin/bash
#
# test.sh — black-box acceptance suite for the MailD stack.
#
# Dev usage (against docker-compose-dev.yml + bootstrap-dev.sh):
#     ./bootstrap-dev.sh          # provision the fixtures (test.creds)
#     ./test.sh                   # run everything
#
# Options:
#   --skip-content   skip the AV / SPAM / banned-attachment checks
#   --skip-quota     skip the mailbox-quota checks (they mutate bob@… and restore it)
#   --skip-docker    only wire-level checks (no `docker compose exec` assertions)
#   --debug          echo every action and trace its execution to ./test-debug.log
#                    (set -x + all console messages; the trace expands variables, so
#                    the file carries the mailbox passwords — dev only, git-ignored)
#   -h, --help       this text
#
# Secrets come from ./test.creds (written by bootstrap-dev.sh); everything is also
# overridable from the environment: DOMAIN, ADMINMAIL, PASS, SERVER, FROM, RELAY_PROBE_DOMAIN.
#
# The suite is self-cleaning: the quota fixture (bob@DOMAIN), any sieve script it creates,
# the message it copies into Junk for the imapsieve check (with the sa-learn state that run
# leaves behind) and the /var/log/syslog it materialises inside the cron container (phase G)
# are restored or removed on exit, whatever the outcome.
#
# Exit code: 0 when every executed check passed, 1 otherwise (skips are reported).

# --------------------------------------------------------------- configuration
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose-dev.yml}"
ENV_FILE="${ENV_FILE:-env.dev}"

DOMAIN="${DOMAIN:-example.net}"
ADMINMAIL="${ADMINMAIL:-alice@$DOMAIN}"
SERVER="${SERVER:-localhost}"
FROM="${FROM:-pavelmc@gmail.com}"
MESSAGESIZE="${MESSAGESIZE:-2}"          # MB, target size of the size-limit probe
SWAKS_TIMEOUT="${SWAKS_TIMEOUT:-180}"
DELIVERY_WAIT="${DELIVERY_WAIT:-60}"     # seconds to wait for a local delivery
QUOTA_USER="${QUOTA_USER:-bob@$DOMAIN}"
QUOTA_BYTES="${QUOTA_BYTES:-5242880}"    # 5 MB: the mailbox.quota column is BYTES

DEBUG_LOG="${DEBUG_LOG:-$SCRIPT_DIR/test-debug.log}"

SKIP_CONTENT=0
SKIP_QUOTA=0
SKIP_DOCKER=0
DEBUG=0
LAUNCH_ARGS="$*"
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-content) SKIP_CONTENT=1 ;;
        --skip-quota)   SKIP_QUOTA=1 ;;
        --skip-docker)  SKIP_DOCKER=1 ;;
        --debug)        DEBUG=1 ;;
        -h|--help)      sed -n '2,/^$/p' "$0"; exit 0 ;;
        *)              echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- stdin ------
# Never inherit the terminal on stdin (same guard as bootstrap-dev.sh). uutils'
# timeout(1) (Ubuntu >= 25 ships it instead of coreutils) runs the command it wraps
# in a new, non-foreground process group -- and puts itself there too. When any
# member of a background group reads the controlling terminal the kernel stops the
# whole group (SIGTTIN, state T), and a stopped group can neither be reached by an
# interactive Ctrl+C (SIGINT is delivered to the foreground group only) nor serve
# its own timeout deadline: `docker compose exec -T` (and swaks) then hang for ever
# and the run is unkillable from the shell. GNU timeout avoids this by keeping the
# command in the foreground group when launched from a prompt (its --foreground
# option documents it), which is why the stall only shows up with uutils. Nothing
# in this suite reads the terminal, so detaching stdin removes the whole class of
# stalls while keeping every child on a non-tty stdin.
exec </dev/null

# Readings the compose file needs. DEFAULT_DOMAIN is the deployment's own domain: bootstrap-dev.sh
# provisions it (mailbox + default aliases) UNLESS it was run with --skip-default-domain, so the MTA
# either hosts it — and mail for it must be accepted and delivered — or it does not, and mail for it
# must be refused as a relay. Phase F detects which case applies (domain_is_hosted) and asserts
# accordingly, so the suite stays correct in both bootstrap modes.
env_value() { # <file> <key>
    [ -f "$1" ] || return 1
    sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n1 | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//'
}
DEFAULT_DOMAIN="$(env_value "$ENV_FILE" DEFAULT_DOMAIN || true)"
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-chagod.software}"
MAIL_ADMIN_USER="$(env_value "$ENV_FILE" MAIL_ADMIN_USER || true)"
MAIL_ADMIN_USER="${MAIL_ADMIN_USER:-sysadmin}"
DEPLOY_ADMIN="${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}"
# RFC 2606 reserved domain: it always resolves and it is never hosted here — the target of the
# open-relay negative (F3a), which must reach reject_unauth_destination and not an earlier filter.
RELAY_PROBE_DOMAIN="${RELAY_PROBE_DOMAIN:-example.com}"

# ------------------------------------------------------------------- console --
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=; C_ERR=; C_WARN=; C_DIM=; C_OFF=
fi
T_PASS=0; T_FAIL=0; T_SKIP=0
FAILED_NAMES=()
# Every message is echoed to the terminal and mirrored into test-debug.log when --debug
# is on (the set -x trace of the commands lands in the same file).
_dbg() { [ "$DEBUG" = 1 ] && printf '%s\n' "$*" >> "$DEBUG_LOG"; return 0; }
section() { echo; printf '%s==>%s %s\n' "$C_DIM" "$C_OFF" "$*"; _dbg "==> $*"; }
info()    { printf '      %s\n' "$*"; _dbg "      $*"; }
t_ok()    { T_PASS=$((T_PASS+1)); printf '%s===> Ok%s: %s\n' "$C_OK" "$C_OFF" "$*"; _dbg "===> Ok: $*"; }
t_fail()  { T_FAIL=$((T_FAIL+1)); FAILED_NAMES+=("$1"); printf '%s===> FAIL%s: %s\n' "$C_ERR" "$C_OFF" "$*"; _dbg "===> FAIL: $*"; }
t_skip()  { T_SKIP=$((T_SKIP+1)); printf '%s===> Skipped%s: %s\n' "$C_WARN" "$C_OFF" "$*"; _dbg "===> Skipped: $*"; }
dump_swaks() {
    local out
    out="$(sed -n '1,40p' "$SW_LOG" 2>/dev/null | sed 's/^/        /')"
    printf '%s\n' "$out"
    _dbg "$out"
}

LOG="$SCRIPT_DIR/test.log"
TMPRUN="$(mktemp -d)"
: > "$LOG"

# ---------------------------------------------------------------- credentials
CREDS_FILE="${CREDS_FILE:-$SCRIPT_DIR/test.creds}"
declare -A CRED=()
load_creds() {
    local line key
    [ -r "$CREDS_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        CRED["${key,,}"]="${line#*=}"
    done < "$CREDS_FILE"
}
load_creds
PASS="${PASS:-${CRED[${ADMINMAIL,,}]:-}}"

# --------------------------------------------------------------------- tools --
BC=; CURL=`which curl`; SOFT=`which swaks`
if [ -z "$SOFT" ] ; then
    echo ">>> Swaks not found, installing it locally (no root needed)"
    # swaks ships as a single Perl script: fetch the .deb with `apt-get download` and unpack
    # it into .local/bin, so the suite runs on a fresh machine without sudo.
    LOCAL_BIN="$SCRIPT_DIR/.local/bin"
    TMPDEB="$(mktemp -d)"
    if (cd "$TMPDEB" && apt-get download swaks > /dev/null 2>&1) &&
       dpkg-deb -x "$TMPDEB"/swaks_*.deb "$TMPDEB/root" &&
       install -D -m 0755 "$TMPDEB"/root/usr/bin/swaks "$LOCAL_BIN/swaks" ; then
        echo ">>> swaks installed at $LOCAL_BIN/swaks"
    fi
    rm -rf "$TMPDEB"
    PATH="$LOCAL_BIN:$PATH"
    export PATH
    SOFT=`which swaks`
fi
if [ -z "$SOFT" ] ; then
    echo ">>> ERROR: swaks is not available, install it (apt install swaks) and re-run"
    exit 1
fi

# Reset the locales (deterministic parsing)
LANGUAGE="en_US"; LC_ALL=C; LANG="en_US.UTF-8"
export LANGUAGE LC_ALL LANG

chrono() { { date; echo "$RANDOM$RANDOM"; } | sha256sum | awk '{print $1}'; }   # unique fingerprint

# ------------------------------------------------------------------ containers
DC=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
HAVE_DC=0
dcx() { timeout -k10 60 "${DC[@]}" exec -T "$1" "${@:2}"; }   # <service> <cmd...>
if [ "$SKIP_DOCKER" = 0 ] && command -v docker > /dev/null 2>&1 && [ -f "$COMPOSE_FILE" ] &&
   "${DC[@]}" ps -q mda > /dev/null 2>&1; then
    HAVE_DC=1
fi

# ----------------------------------------------------------------- swaks runs
SW_RC=0
SW_LOG=""
swx() {   # <swaks args...>  → SW_RC holds the exit code; transcript in $SW_LOG and $LOG
    SW_LOG="$TMPRUN/swaks.log"
    _dbg "RUN swaks $*"
    timeout -k5 "$SWAKS_TIMEOUT" "$SOFT" "$@" > "$SW_LOG" 2>&1
    SW_RC=$?
    _dbg "    -> rc=$SW_RC (transcript: $SW_LOG)"
    { echo; echo "==== swaks $*"; cat "$SW_LOG"; } >> "$LOG"
    return 0
}

# ----------------------------------------------------------------- mailbox ops
sql() { dcx db psql -U maild -d mailddb -tAc "$1" 2>/dev/null; }
domain_is_hosted() { # <domain> → 0 when the MTA hosts (serves) that domain
    local n
    if [ "$HAVE_DC" = 1 ] ; then
        # the very source of truth Postfix reads (virtual_domains_maps.cf / relay_domains.cf)
        n="$(sql "SELECT count(*) FROM domain WHERE domain='${1,,}' AND active")"
        if [ -n "$n" ] ; then
            [ "$n" -gt 0 ] && return 0
            return 1
        fi
    fi
    # --skip-docker, or an unreadable db: bootstrap writes a credential line for every mailbox it
    # provisions, so its admin address being in test.creds means the domain is hosted.
    [ -n "${CRED[${MAIL_ADMIN_USER}@${1,,}]:-}" ]
}
msg_in() { # <address> <mailbox> <subject substring>
    [ -n "$(dcx mda doveadm search -u "$1" mailbox "$2" subject "$3" 2>/dev/null)" ]
}
maildir_has() { # <address> <mailbox|.> <raw pattern> — greps the maildir on disk
    local addr="$1" mbox="$2" pat="$3" dom="${addr##*@}" dir
    dir="/home/vmail/$dom/${addr%%@*}/maildir"
    case "$mbox" in INBOX|inbox|.|-) : ;; *) dir="$dir/.$mbox" ;; esac
    dcx mda sh -c "grep -rls -- '$pat' '$dir' 2>/dev/null | head -n1"
}
wait_msg() { # <address> <mailbox> <subject> [seconds] — 0 when the message shows up
    local start=$SECONDS
    while : ; do
        msg_in "$1" "$2" "$3" && return 0
        [ $((SECONDS-start)) -ge "${4:-$DELIVERY_WAIT}" ] && return 1
        sleep 2
    done
}
mbox_count() { # <address> <mailbox> → message count ('' when the mailbox is missing)
    dcx mda doveadm mailbox status -u "$1" messages "$2" 2>/dev/null |
        sed -n 's/.*messages=\([0-9]*\).*/\1/p'
}
wait_count_gt() { # <address> <mailbox> <n> [seconds]
    local start=$SECONDS n
    while : ; do
        n="$(mbox_count "$1" "$2")"
        [ -n "$n" ] && [ "$n" -gt "$3" ] && return 0
        [ $((SECONDS-start)) -ge "${4:-$DELIVERY_WAIT}" ] && return 1
        sleep 2
    done
}
# Subject-scoped variants: a mailbox total cannot tell *which* message arrived, and several
# checks mail the same mailbox concurrently (the cron jobs all write to MAIL_ADMIN_USER@…),
# so counting the matches of one subject is the only unambiguous "this one landed" signal.
subj_count() { # <address> <mailbox> <subject substring> → how many messages match
    dcx mda doveadm search -u "$1" mailbox "$2" subject "$3" 2>/dev/null | grep -c . | tr -d ' \r'
}
wait_subj_count_gt() { # <address> <mailbox> <subject> <n> [seconds]
    local start=$SECONDS n
    while : ; do
        n="$(subj_count "$1" "$2" "$3")"
        [ -n "$n" ] && [ "$n" -gt "$4" ] && return 0
        [ $((SECONDS-start)) -ge "${5:-$DELIVERY_WAIT}" ] && return 1
        sleep 2
    done
}
msg_newest_uid() { # <address> <mailbox> <subject substring> → uid of the newest match
    dcx mda doveadm search -u "$1" mailbox "$2" subject "$3" 2>/dev/null |
        awk '{print $2}' | sort -n | tail -n1 | tr -d ' \r'
}
msg_text() { # <address> <mailbox> <uid> → the raw message, headers and body
    dcx mda doveadm fetch -u "$1" text mailbox "$2" uid "$3" 2>/dev/null
}
wait_quarantine_gt() { # <kind> <n> [seconds] — amavis quarantines slightly after the 250
    local start=$SECONDS
    while : ; do
        [ "$(_q_count "$1")" -gt "$2" ] && return 0
        [ $((SECONDS-start)) -ge "${3:-25}" ] && return 1
        sleep 2
    done
}

# ------------------------------------------------------------- filter helpers
container_env() { dcx amavis printenv "$1" 2>/dev/null | tr -d '\r'; }
truthy() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in yes|true|1|on) return 0 ;; *) return 1 ;; esac; }
clamav_db_ready() { dcx clamav sh -c 'test -f /var/lib/clamav/main.cvd || test -f /var/lib/clamav/main.cld'; }
# amavis files its quarantined messages under $MYHOME/virusmails/<hash>/<kind>-<id>;
# counting per kind is the ground-truth signal that a filter actually fired.
quarantine_count() { _q_count "$1"; }
_q_count() { dcx amavis sh -c "ls /var/lib/amavis/virusmails/*/$1-* 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r'; }
virus_q_count() { _q_count virus; }
spam_q_count() { _q_count spam; }
banned_q_count() { _q_count banned; }

# -------------------------------------------------------------- quota helpers
quota_set() { # <address> <bytes>
    sql "UPDATE mailbox SET quota=$2 WHERE username='$1'" > /dev/null
    dcx mda doveadm auth cache flush > /dev/null 2>&1 || true
    dcx mda doveadm quota recalc -u "$1" > /dev/null 2>&1 || true
}
quota_get() { # <address> value|limit → KB ('-' when unlimited)
    local col=4
    [ "$2" = limit ] && col=5
    dcx mda doveadm quota get -u "$1" 2>/dev/null | awk -v c="$col" '$3=="STORAGE"{print $c; exit}'
}
expunge_mailbox() { dcx mda doveadm expunge -u "$1" mailbox "$2" all > /dev/null 2>&1 || true; }

# -------------------------------------------------------------------- payloads
# The EICAR test file must be byte-exact (68 bytes, one single backslash): clamd's
# signature does not match the string once a message body wraps or reflows it, so the
# mail-path test (D2) ships it as an attachment and the direct probe (D1) reads the file.
EICAR_FILE="$TMPRUN/eicar.com"
printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > "$EICAR_FILE"

GTUBE='XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X'
make_file() { dd if=/dev/zero of="$1" bs=1024 count=$(( $2 / 1024 )) status=none; }

# The stack must come back the way it was found: undo whatever the quota fixture
# did (bob@… goes back to unlimited, its test mail is expunged), drop any sieve
# script the suite installed, empty the Junk copy the imapsieve check made (plus
# the sa-learn state that run left in the container's /tmp) and remove the syslog
# phase G materialised in the cron container (dev has no /var/log/syslog of its
# own, see phase G).
QUOTA_TOUCHED=0
RES_SEEDED=0
IMAPSIEVE_TOUCHED=0
cleanup() {
    if [ "$HAVE_DC" = 1 ]; then
        dcx mda rm -f "/home/vmail/${DOMAIN}/${ADMINMAIL%%@*}/dovecot.sieve" > /dev/null 2>&1 || true
        if [ "$IMAPSIEVE_TOUCHED" = 1 ]; then
            expunge_mailbox "$ADMINMAIL" Junk
            dcx mda rm -rf /tmp/.spamassassin > /dev/null 2>&1 || true
        fi
        if [ "$RES_SEEDED" = 1 ]; then
            dcx cron sh -c 'rm -f /var/log/syslog /var/log/syslog.1 /var/log/.maild-test-seeded' > /dev/null 2>&1 || true
        fi
        if [ "$QUOTA_TOUCHED" = 1 ]; then
            expunge_mailbox "$QUOTA_USER" INBOX
            expunge_mailbox "$QUOTA_USER" Junk
            quota_set "$QUOTA_USER" 0
        fi
        # Phase I (AdminNG): test devices (sessions cascade) and the fixture domain.
        dcx db psql -U maild -d adminng -q -c \
            "DELETE FROM device WHERE device_id IN ('aaaaaaaa-0000-4000-8000-0000000000a1','aaaaaaaa-0000-4000-8000-0000000000a2');" \
            > /dev/null 2>&1 || true
        dcx db psql -U maild -d mailddb -q -c \
            "DELETE FROM alias WHERE domain='adminng-e2e.test'; DELETE FROM domain_admins WHERE domain='adminng-e2e.test'; DELETE FROM mailbox WHERE domain='adminng-e2e.test'; DELETE FROM domain WHERE domain='adminng-e2e.test';" \
            > /dev/null 2>&1 || true
    fi
    rm -rf "$TMPRUN"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------- debug ------
# --debug mirrors the console messages (through _dbg) and traces every command with
# `set -x` into test-debug.log. The trace expands variables, so the file contains the
# mailbox passwords — dev only, and test-debug.log is git-ignored via *.log.
debug_enable() {
    [ "$DEBUG" = 1 ] || return 0
    # truncate once, then let both the trace fd and _dbg append, so the two writers
    # never fight over the file offset (garbled log otherwise)
    if ! { : > "$DEBUG_LOG" && exec 9>>"$DEBUG_LOG" ; } ; then
        echo "WARN: cannot write $DEBUG_LOG: tracing disabled" >&2
        DEBUG=0
        return 0
    fi
    BASH_XTRACEFD=9
    PS4='+ [${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}] '
    {
        printf '==== test.sh debug trace ====\n'
        printf 'date  : %s\n' "$(date '+%F %T %z')"
        printf 'argv  : %s\n' "$LAUNCH_ARGS"
        printf 'server: %s   domain: %s   admin: %s   quota-user: %s\n' \
               "$SERVER" "$DOMAIN" "$ADMINMAIL" "$QUOTA_USER"
        printf '=============================\n\n'
    } >> "$DEBUG_LOG"
    set -x
}
debug_enable

# =============================================================== environment ==
section "environment"
[ "$DEBUG" = 1 ] && info "debug trace : $DEBUG_LOG"
info "server      : $SERVER"
info "test domain : $DOMAIN (admin mailbox $ADMINMAIL)"
info "credentials : $CREDS_FILE"
info "containers  : $([ "$HAVE_DC" = 1 ] && echo 'docker compose assertions enabled' || echo 'disabled (wire-level checks only)')"

# Container health, up front. The mta bakes the amavis/mda addresses at its own start
# (mynetworks, the 10025 amavis reinjection allow-list, the LMTP/policy targets): a peer that
# started late or was recreated afterwards leaves the mta unhealthy and rejecting the content
# filter, which then shows up as ~8 unrelated delivery failures further down. Fail once, here,
# with the remedy, instead of scattering them.
if [ "$HAVE_DC" = 1 ] ; then
    HEALTH_BAD=""
    for HC_SVC in db mda amavis clamav mta ; do
        HC_CID="$(timeout -k10 60 "${DC[@]}" ps -q "$HC_SVC" 2>/dev/null | head -n1)"
        HC_ST="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$HC_CID" 2>/dev/null)"
        info "health      : $HC_SVC ${HC_ST:-no-healthcheck}"
        if [ "$HC_ST" != "healthy" ] ; then
            HEALTH_BAD="$HEALTH_BAD $HC_SVC(${HC_ST:-none})"
        fi
    done
    if [ -n "$HEALTH_BAD" ] ; then
        t_fail "containers not healthy:$HEALTH_BAD"
        info "the mta bakes its peers at start: 'docker compose --env-file env.dev -f docker-compose-dev.yml restart mta' re-resolves them (bring amavis/mda up first)"
    else
        t_ok "every mail-path container reports healthy"
    fi
fi

# env schema (new): the defaults are baked as ENV inside each image (per service); env.dev
# carries only the deployment values (domain, admin user, fake secrets) and any deviation
# from an image default. Three signals: an untouched default (mda), an override (mua's
# BANNER_TITLE, set in env.dev) and a baked peer hostname the env file never mentions (mta).
if [ "$HAVE_DC" = 1 ] ; then
    ENV_WHY=""
    [ "$(dcx mda printenv DEFAULT_MAILBOX_SIZE 2>/dev/null | tr -d '\r\n')" = "200M" ] ||
        ENV_WHY="$ENV_WHY mda-image-default(DEFAULT_MAILBOX_SIZE);"
    [ "$(dcx mua printenv BANNER_TITLE 2>/dev/null | tr -d '\r\n')" = "MailD Dev Override" ] ||
        ENV_WHY="$ENV_WHY env.dev-override(BANNER_TITLE);"
    [ "$(dcx mta printenv AMAVIS 2>/dev/null | tr -d '\r\n')" = "amavis" ] ||
        ENV_WHY="$ENV_WHY mta-image-default(AMAVIS);"
    if [ -n "$ENV_WHY" ] ; then
        t_fail "image ENV defaults are baked and env.dev overrides win (${ENV_WHY# })"
    else
        t_ok "image ENV defaults are baked and env.dev overrides win (BANNER_TITLE)"
    fi
else
    t_skip "env schema checks (docker compose is needed to read the container environment)"
fi

if [ -z "$PASS" ] ; then
    echo "ERROR: no password for $ADMINMAIL in $CREDS_FILE (run ./bootstrap-dev.sh first, or export PASS)" >&2
    exit 1
fi

# =========================================================== A. SMTP policy ==
section "A. SMTP policy (ports 25 / 465 / 587)"

# A1 — port 25 accepts mail for a local recipient coming from the outside
F="$(chrono)"
swx -s "$SERVER" --protocol SMTP -t "$ADMINMAIL" -f "$FROM" --header "Subject: $F"
if [ "$SW_RC" -eq 0 ] ; then
    t_ok "port 25 accepts mail for a local recipient"
else
    t_fail "port 25 accepts mail for a local recipient (rc=$SW_RC)" ; dump_swaks
fi

# A2 — a sender whose domain has no DNS is refused
F="$(chrono)"
swx -s "$SERVER" --protocol SMTP -t "$ADMINMAIL" -f "ultrafake@ddmain.rra.ck" --header "Subject: $F"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 25 rejects a sender domain that does not resolve"
else
    t_fail "port 25 rejects a sender domain that does not resolve (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A3 — authenticated submission (587) from the sender itself
F="$(chrono)"
swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
    -t "$ADMINMAIL" -f "$ADMINMAIL" --header "Subject: $F"
if [ "$SW_RC" -eq 0 ] ; then
    t_ok "port 587 accepts an authenticated submission from the sender"
else
    t_fail "port 587 accepts an authenticated submission from the sender (rc=$SW_RC)" ; dump_swaks
fi

# A4 — authenticated SMTPS (465)
F="$(chrono)"
swx -s "$SERVER" -p 465 -tlsc -a PLAIN -au "$ADMINMAIL" -ap "$PASS" -t "$ADMINMAIL" -f "$ADMINMAIL" \
    --protocol SSMTP --header "Subject: $F"
if [ "$SW_RC" -eq 0 ] ; then
    t_ok "port 465 accepts an authenticated submission"
else
    t_fail "port 465 accepts an authenticated submission (rc=$SW_RC)" ; dump_swaks
fi

# A5 — an authenticated user may relay to the outside world
F="$(chrono)"
swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
    -t "fake@example.com" -f "$ADMINMAIL" --header "Subject: $F"
if [ "$SW_RC" -eq 0 ] ; then
    t_ok "authenticated users can relay to the outside world"
else
    t_fail "authenticated users can relay to the outside world (rc=$SW_RC)" ; dump_swaks
fi

# A6 — port 25 refuses mail for a non-existent local user
NOSUCH="no-such-user-$RANDOM$RANDOM"
swx -s "$SERVER" --protocol SMTP -t "$NOSUCH@$DOMAIN" -f "$ADMINMAIL" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 25 refuses mail for a non-existent local user"
else
    t_fail "port 25 refuses mail for a non-existent local user (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A7 — port 25 refuses a bad local recipient
swx -s "$SERVER" --protocol SMTP -t "fake_account.mee@$DOMAIN" -f "$ADMINMAIL" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 25 refuses unknown recipients"
else
    t_fail "port 25 refuses unknown recipients (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A8 — port 25 is not an open relay
swx -s "$SERVER" --protocol SMTP -t "$NOSUCH@example" -f "$NOSUCH@example" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 25 is not an open relay"
else
    t_fail "port 25 is not an open relay (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A9 — port 587 refuses a submission with no authentication
swx -s "$SERVER" -p 587 -tls -t "$ADMINMAIL" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 587 refuses unauthenticated submission"
else
    t_fail "port 587 refuses unauthenticated submission (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A10 — port 465 refuses a submission with no authentication
swx -s "$SERVER" --protocol SSMTP -t "$ADMINMAIL" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 465 refuses unauthenticated submission"
else
    t_fail "port 465 refuses unauthenticated submission (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A11 — no id spoofing: authenticated as X but sending as another local user
swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
    -t "$ADMINMAIL" -f "$NOSUCH@$DOMAIN" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "the server does not allow id spoofing"
else
    t_fail "the server does not allow id spoofing (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A12 — port 587 refuses a submission with no authentication (local sender)
swx -s "$SERVER" -p 587 -tls -t "$ADMINMAIL" -f "$NOSUCH@$DOMAIN" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 587 refuses unauthenticated submission (with a local sender)"
else
    t_fail "port 587 refuses unauthenticated submission (with a local sender) (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A13 — message_size_limit is enforced (payload well above the configured limit)
SLIMIT="$(dcx mta postconf -h message_size_limit 2>/dev/null || true)"
SLIMIT="${SLIMIT:-10485864}"
BIGFILE="$TMPRUN/big.bin"
make_file "$BIGFILE" $(( SLIMIT + 1048576 ))
info "message_size_limit is $SLIMIT bytes, probing with a $(( (SLIMIT+1048576)/1024/1024 )) MB attachment"
swx -s "$SERVER" --protocol SMTP -t "$ADMINMAIL" -f "$FROM" --attach "@$BIGFILE" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] || [ "$SW_RC" -eq 26 ] ; then
    t_ok "messages above message_size_limit are rejected"
else
    t_fail "messages above message_size_limit are rejected (rc=$SW_RC, want 24 or 26)" ; dump_swaks
fi

# ========================================================= B. auth and TLS ==
section "B. authentication and TLS"

# B1 — submission with a wrong password is refused (535)
swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap 'definitely-not-the-password' \
    -t "$ADMINMAIL" -f "$ADMINMAIL" --header "Subject: $(chrono)"
if [ "$SW_RC" -ne 0 ] && grep -q ' 535' "$SW_LOG" ; then
    t_ok "submission with a wrong password is refused (535)"
else
    t_fail "submission with a wrong password is refused (rc=$SW_RC)" ; dump_swaks
fi

# B2 — no AUTH in the clear on port 25 (smtpd_tls_auth_only = yes) and therefore no
# unauthenticated relay. The recipient is external on purpose: a plaintext AUTH that
# "worked" would let the relay through and the check would fail, which is the point.
swx -s "$SERVER" -p 25 -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
    -t "outside@example.com" -f "$ADMINMAIL" --header "Subject: $(chrono)"
if [ "$SW_RC" -ne 0 ] ; then
    t_ok "port 25 does not authenticate (nor relay) in the clear"
else
    t_fail "port 25 does not authenticate (nor relay) in the clear (rc=$SW_RC)" ; dump_swaks
fi

# B3 — STARTTLS on 587 serves a certificate
if timeout -k5 20 openssl s_client -starttls smtp -connect "$SERVER:587" \
        -servername mail.localhost </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE' ; then
    t_ok "port 587 offers STARTTLS with a certificate"
else
    t_fail "port 587 offers STARTTLS with a certificate"
fi

# ================================================ C. delivery / read-back ====
section "C. delivery, aliases and mailbox reads"

DC_NEEDED="docker compose is needed to read the delivered mailboxes"

# C1 — the default alias postmaster@DOMAIN lands in the admin mailbox
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "alias postmaster@$DOMAIN → $ADMINMAIL ($DC_NEEDED)"
else
    F="$(chrono)"
    swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
        -t "postmaster@$DOMAIN" -f "$ADMINMAIL" --header "Subject: $F"
    if [ "$SW_RC" -eq 0 ] && wait_msg "$ADMINMAIL" INBOX "$F" ; then
        t_ok "alias postmaster@$DOMAIN is delivered to $ADMINMAIL"
    elif [ "$SW_RC" -ne 0 ] ; then
        t_fail "alias postmaster@$DOMAIN is delivered to $ADMINMAIL (rc=$SW_RC)" ; dump_swaks
    else
        t_fail "alias postmaster@$DOMAIN is delivered to $ADMINMAIL (not found in the INBOX)"
    fi
fi

# C2 — plus-addressing (recipient_delimiter = +, auth_username_format = %Ln@%Ld)
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "plus-addressing $ADMINMAIL+tag@$DOMAIN ($DC_NEEDED)"
else
    F="$(chrono)"
    swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
        -t "${ADMINMAIL%%@*}+tag@$DOMAIN" -f "$ADMINMAIL" --header "Subject: $F"
    if [ "$SW_RC" -eq 0 ] && wait_msg "$ADMINMAIL" INBOX "$F" ; then
        t_ok "plus-addressing delivers to the base mailbox"
    else
        t_fail "plus-addressing delivers to the base mailbox (rc=$SW_RC)" ; dump_swaks
    fi
fi

# C3 — IMAPS (993): login and SEARCH
if out="$(timeout -k5 30 curl --silent --insecure --user "$ADMINMAIL:$PASS" \
            --url "imaps://$SERVER:993/INBOX" -X 'SEARCH ALL' 2>&1)" &&
   printf '%s' "$out" | grep -Eq '\* SEARCH( [0-9]+)+' ; then
    t_ok "IMAPS login and message listing"
else
    t_fail "IMAPS login and message listing" ; printf '%s\n' "$out" | sed -n '1,5p' | sed 's/^/        /'
fi

# C4 — POP3S (995): login and mailbox listing (curl prints the LIST body)
if out="$(timeout -k5 30 curl --silent --insecure --user "$ADMINMAIL:$PASS" \
            --url "pop3s://$SERVER:995" 2>&1)" &&
   printf '%s' "$out" | grep -qE '([0-9]+ [0-9]+|\+OK)' ; then
    t_ok "POP3S login and mailbox listing"
else
    t_fail "POP3S login and mailbox listing" ; printf '%s\n' "$out" | sed -n '1,5p' | sed 's/^/        /'
fi

# ======================================================= D. content filters ==
section "D. content filtering (EICAR / GTUBE / banned attachment)"
if [ "$SKIP_CONTENT" = 1 ] ; then
    t_skip "content-filter checks (--skip-content)"
elif [ "$HAVE_DC" != 1 ] ; then
    t_skip "content-filter checks ($DC_NEEDED)"
else
    AV_FLAG="$(container_env AV_ENABLED)"
    SPAM_FLAG="$(container_env SPAM_FILTER_ENABLED)"
    if ! truthy "$AV_FLAG" || ! truthy "$SPAM_FLAG" ; then
        t_skip "content-filter checks (amavis reports AV_ENABLED='$AV_FLAG' SPAM_FILTER_ENABLED='$SPAM_FLAG'; env.dev turns both on)"
    elif ! clamav_db_ready ; then
        t_fail "content-filter checks: ClamAV has no signature database yet (let the first download finish, then re-run)"
    else

        QUOTA_TOUCHED=1   # section D delivers mail to the fixture mailbox; cleaned on exit

        # D1 — clamd itself flags the EICAR file (fast check of the signature DB)
        if command -v python3 > /dev/null 2>&1 ; then
            cat > "$TMPRUN/clamd_instream.py" <<'PY'
import socket, sys
path, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(path, "rb").read()
s = socket.create_connection((host, port), timeout=20)
s.sendall(b"zINSTREAM\0")
s.sendall(len(data).to_bytes(4, "big") + data)
s.sendall((0).to_bytes(4, "big"))
resp = s.recv(4096).decode("utf-8", "replace")
s.close()
print(resp.strip().replace("\0", ""))
sys.exit(0 if "FOUND" in resp else 1)
PY
            if python3 "$TMPRUN/clamd_instream.py" "$EICAR_FILE" "$SERVER" 3310 > "$TMPRUN/clamd.out" 2>&1 ; then
                t_ok "clamd flags the EICAR file ($(tr -d '\r' < "$TMPRUN/clamd.out" | head -n1))"
            else
                t_fail "clamd flags the EICAR file" ; sed 's/^/        /' "$TMPRUN/clamd.out"
            fi
        else
            t_skip "direct clamd EICAR probe (python3 is not installed)"
        fi

        # D2 — EICAR through the mail path, as an attachment: amavis answers 250 (D_DISCARD
        #      is silent), then discards the message, quarantines it and sends no NDR.
        VQ_BEFORE="$(virus_q_count)"
        F="$(chrono)"
        swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
            -t "$QUOTA_USER" -f "$ADMINMAIL" --attach "@$EICAR_FILE" --header "Subject: $F"
        if [ "$SW_RC" -ne 0 ] ; then
            t_fail "EICAR is accepted then discarded (D_DISCARD) (rc=$SW_RC, want 0: discard is silent)" ; dump_swaks
        elif wait_msg "$QUOTA_USER" INBOX "$F" 20 ; then
            t_fail "EICAR is accepted then discarded (D_DISCARD): the message WAS delivered!"
        elif wait_quarantine_gt virus "$VQ_BEFORE" 25 ; then
            t_ok "EICAR is accepted then discarded and quarantined (no NDR)"
        else
            t_fail "EICAR is accepted then discarded: not delivered, but no virus-quarantine entry appeared"
        fi

        # D3 — GTUBE: SpamAssassin scores it 999 and amavis quarantines it as spam. The
        #      destiny is D_PASS, so nothing is visible at RCPT; the quarantine is the signal.
        SPQ_BEFORE="$(spam_q_count)"
        F="$(chrono)"
        swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
            -t "$QUOTA_USER" -f "$ADMINMAIL" --body "$GTUBE" --header "Subject: $F"
        if [ "$SW_RC" -ne 0 ] ; then
            t_fail "GTUBE is detected as spam (rc=$SW_RC)" ; dump_swaks
        elif wait_quarantine_gt spam "$SPQ_BEFORE" 25 ; then
            t_ok "GTUBE is scored as spam and quarantined by SpamAssassin"
        else
            t_fail "GTUBE is scored as spam (no spam-quarantine entry appeared)"
        fi

        # D4 — banned attachment (.exe): discarded like a virus ($final_banned_destiny)
        printf 'MZ this is not a real PE binary\n' > "$TMPRUN/evil.exe"
        BQ_BEFORE="$(banned_q_count)"
        F="$(chrono)"
        swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
            -t "$QUOTA_USER" -f "$ADMINMAIL" --attach "@$TMPRUN/evil.exe" --header "Subject: $F"
        if [ "$SW_RC" -ne 0 ] ; then
            t_fail "a banned .exe attachment is discarded (rc=$SW_RC, want 0: discard is silent)" ; dump_swaks
        elif wait_msg "$QUOTA_USER" INBOX "$F" 20 ; then
            t_fail "a banned .exe attachment is discarded: the message WAS delivered!"
        elif wait_quarantine_gt banned "$BQ_BEFORE" 25 ; then
            t_ok "a banned .exe attachment is discarded and quarantined"
        else
            t_fail "a banned .exe attachment is discarded: not delivered, but no banned-quarantine entry appeared"
        fi

    fi
fi

# ================================================================ E. quota ====
section "E. mailbox quota (${QUOTA_USER} limited to $((QUOTA_BYTES/1024/1024)) MB)"
if [ "$SKIP_QUOTA" = 1 ] ; then
    t_skip "quota checks (--skip-quota)"
elif [ "$HAVE_DC" != 1 ] ; then
    t_skip "quota checks ($DC_NEEDED)"
else
    QUOTA_TOUCHED=1
    LIMIT_KB=$(( QUOTA_BYTES / 1024 ))

    # fixture: empty the mailbox, then apply the (bytes!) limit
    expunge_mailbox "$QUOTA_USER" INBOX
    expunge_mailbox "$QUOTA_USER" Junk
    quota_set "$QUOTA_USER" "$QUOTA_BYTES"
    LIMIT_NOW="$(quota_get "$QUOTA_USER" limit)"
    if [ "$LIMIT_NOW" = "$LIMIT_KB" ] ; then
        t_ok "the quota limit is applied to $QUOTA_USER (${LIMIT_KB} KB)"
    else
        t_fail "the quota limit is applied to $QUOTA_USER (got '${LIMIT_NOW:-?}' KB, want ${LIMIT_KB} KB)"
    fi

    # fill it from the other provisioned users (~1.4 MB per message, under the size limit)
    ATT="$TMPRUN/fill.bin" ; make_file "$ATT" 1048576
    senders=()
    for addr in "${!CRED[@]}" ; do
        [ "$addr" = "${QUOTA_USER,,}" ] && continue
        senders+=("$addr")
    done
    [ "${#senders[@]}" -eq 0 ] && senders=("$ADMINMAIL")

    sent=0
    while [ "$sent" -lt 8 ] ; do
        s="${senders[$(( sent % ${#senders[@]} ))]}"
        F="$(chrono)"
        swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$s" -ap "${CRED[$s]}" \
            -t "$QUOTA_USER" -f "$s" --attach "@$ATT" --header "Subject: $F"
        sent=$(( sent + 1 ))
        if [ "$SW_RC" -ne 0 ] ; then
            info "filler #$sent was refused by the server (rc=$SW_RC): the mailbox is over quota"
            break
        fi
        sleep 3
        used_kb="$(quota_get "$QUOTA_USER" value)"
        info "filler #$sent delivered from $s, usage now ${used_kb:-?} KB / ${LIMIT_KB} KB"
        [ -n "$used_kb" ] && [ "$used_kb" -ge "$LIMIT_KB" ] && break
    done
    used_kb="$(quota_get "$QUOTA_USER" value)"
    if [ -n "$used_kb" ] && [ "$used_kb" -ge "$LIMIT_KB" ] ; then
        t_ok "the mailbox fills up to its limit (${used_kb} KB ≥ ${LIMIT_KB} KB, the grace allows the crossing)"
    else
        t_fail "the mailbox fills up to its limit (usage ${used_kb:-?} KB < ${LIMIT_KB} KB after $sent fillers)"
    fi

    # the 80 % / 95 % quota_warning scripts must have mailed the user
    W80="$(maildir_has "$QUOTA_USER" INBOX 'el 80% de capacidad')"
    W95="$(maildir_has "$QUOTA_USER" INBOX 'el 95% de capacidad')"
    if [ -n "$W80" ] || [ -n "$W95" ] ; then
        t_ok "quota warning mails delivered (80%: $([ -n "$W80" ] && echo yes || echo no), 95%: $([ -n "$W95" ] && echo yes || echo no))"
    else
        t_fail "quota warning mails delivered (none in the INBOX: check 'docker compose logs mda' for quota-warning)"
    fi

    # over quota: refused at RCPT by the dovecot quota-status policy wired into postfix
    swx -s "$SERVER" --protocol SMTP -t "$QUOTA_USER" -f "$FROM" --header "Subject: $(chrono)"
    if [ "$SW_RC" -eq 24 ] && grep -q 'Mailbox is full' "$SW_LOG" ; then
        t_ok "port 25 refuses mail for a full mailbox at RCPT (552 Mailbox is full)"
    else
        t_fail "port 25 refuses mail for a full mailbox at RCPT (rc=$SW_RC)" ; dump_swaks
    fi

    # over quota via submission: postfix accepts, LMTP rejects, the sender gets an NDR
    N_BEFORE="$(mbox_count "$ADMINMAIL" INBOX)"
    swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
        -t "$QUOTA_USER" -f "$ADMINMAIL" --attach "@$ATT" --header "Subject: $(chrono)"
    if [ "$SW_RC" -ne 0 ] ; then
        t_fail "over-quota mail via submission is accepted then bounced (rc=$SW_RC, want 0)" ; dump_swaks
    elif wait_count_gt "$ADMINMAIL" INBOX "${N_BEFORE:-0}" 90 && msg_in "$ADMINMAIL" INBOX 'Undelivered Mail' ; then
        t_ok "over-quota mail via submission bounces back to the sender (NDR)"
    else
        t_fail "over-quota mail via submission bounces back to the sender (no NDR in the sender INBOX)"
    fi

    # restore the fixture (the EXIT trap repeats this as a safety net)
    expunge_mailbox "$QUOTA_USER" INBOX
    expunge_mailbox "$QUOTA_USER" Junk
    quota_set "$QUOTA_USER" 0
    QUOTA_TOUCHED=0
    info "quota fixture restored (0 = unlimited)"
fi

# ========================================= F. sieve, DKIM and relay negatives ==
section "F. sieve, DKIM and relay negatives"

# F1 — a personal sieve script redirects mail (admin → the quota user)
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "sieve redirect ($DC_NEEDED)"
else
    SIEVE="/home/vmail/${DOMAIN}/${ADMINMAIL%%@*}/dovecot.sieve"
    F="$(chrono)"
    # `redirect' is a base Sieve command: requiring it fails compilation ("not known as a
    # Sieve capability, but ... always available"), so the script is just the redirect.
    if dcx mda sh -c "printf 'redirect \"%s\";\n' '$QUOTA_USER' > '$SIEVE' && chown 5000:5000 '$SIEVE'" ; then
        swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
            -t "$ADMINMAIL" -f "$ADMINMAIL" --header "Subject: $F"
        if [ "$SW_RC" -eq 0 ] && wait_msg "$QUOTA_USER" INBOX "$F" ; then
            t_ok "a personal sieve script redirects the message to $QUOTA_USER"
        else
            t_fail "a personal sieve script redirects the message to $QUOTA_USER (rc=$SW_RC)" ; dump_swaks
        fi
        dcx mda rm -f "$SIEVE" > /dev/null 2>&1 || true
    else
        t_fail "could not install the sieve script for $ADMINMAIL"
    fi
fi

# F2 — DKIM: amavis holds a key and a signing entry for the test domain
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "DKIM key/config for $DOMAIN ($DC_NEEDED)"
elif dcx amavis test -f "/var/lib/amavis/dkim/$DOMAIN.pem" &&
     dcx amavis sh -c "grep -q \"dkim_key('$DOMAIN'\" /etc/amavis/conf.d/22-dkim_signing" ; then
    t_ok "DKIM key and signing entry exist for $DOMAIN"
else
    t_fail "DKIM key and signing entry exist for $DOMAIN (re-run bootstrap-dev.sh: amavis builds them at start)"
fi

# F3a — the MTA is not an open relay: a domain that resolves but is not hosted here is refused.
# A8 uses the reserved, non-resolvable .example TLD and is therefore stopped earlier by
# reject_unknown_recipient_domain; this probe is what actually exercises reject_unauth_destination.
swx -s "$SERVER" --protocol SMTP -t "relay-probe-$RANDOM@$RELAY_PROBE_DOMAIN" -f "$FROM" \
    --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 25 refuses to relay $RELAY_PROBE_DOMAIN (resolvable, not hosted here)"
else
    t_fail "port 25 refuses to relay $RELAY_PROBE_DOMAIN (rc=$SW_RC, want 24)" ; dump_swaks
fi

# F3b — the deployment domain: bootstrap-dev.sh provisions DEFAULT_DOMAIN unless it was run with
# --skip-default-domain, so the expectation follows what the MTA actually hosts.
if domain_is_hosted "$DEFAULT_DOMAIN" ; then
    F="$(chrono)"
    swx -s "$SERVER" --protocol SMTP -t "$DEPLOY_ADMIN" -f "$FROM" --header "Subject: $F"
    if [ "$SW_RC" -ne 0 ] ; then
        t_fail "port 25 accepts mail for the hosted deployment domain $DEFAULT_DOMAIN (rc=$SW_RC)" ; dump_swaks
    elif [ "$HAVE_DC" != 1 ] ; then
        t_ok "port 25 accepts mail for the hosted deployment domain $DEFAULT_DOMAIN ($DEPLOY_ADMIN)"
    elif wait_msg "$DEPLOY_ADMIN" INBOX "$F" ; then
        t_ok "port 25 accepts and delivers mail for the hosted deployment domain $DEFAULT_DOMAIN ($DEPLOY_ADMIN)"
    else
        t_fail "mail for $DEPLOY_ADMIN was accepted but never reached its INBOX" ; dump_swaks
    fi
else
    swx -s "$SERVER" --protocol SMTP -t "$DEPLOY_ADMIN" -f "$FROM" --header "Subject: $(chrono)"
    if [ "$SW_RC" -eq 24 ] ; then
        t_ok "port 25 refuses to relay $DEFAULT_DOMAIN (not provisioned: --skip-default-domain run)"
    else
        t_fail "port 25 refuses to relay $DEFAULT_DOMAIN (rc=$SW_RC, want 24)" ; dump_swaks
    fi
fi

# F4 — moving a message into Junk fires the imapsieve Bayes learning, MailD's "instant learning"
# path: Dovecot runs the global learn-spam.sieve, which pipes the message to
# mda/sieve-pipe/learn-spam.sh (sa-learn --spam). Only a real IMAP session triggers it
# (`doveadm move` does not: imapsieve is an IMAP plugin), so the check drives the same curl-IMAP
# path C3/C4 use, and it produces its own message instead of depending on the folders: empty
# Junk/INBOX folders are fine.
# Proof of the learning is the bayes state the pipe's sa-learn leaves under its HOME (/tmp) —
# owned by uid 5000 (vmail), which is what tells the message-triggered run apart from the root
# probe at the end (a root-owned state dir would not even be writable by the vmail-user pipe).
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "imapsieve Junk learning trigger ($DC_NEEDED)"
else
    IMAPSIEVE_TOUCHED=1
    F="$(chrono)"
    swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
        -t "$ADMINMAIL" -f "$ADMINMAIL" --header "Subject: $F"
    # start from a clean slate: a stale state dir is root-owned (0700) and the pipe, running as
    # vmail, could not write its learning into it
    dcx mda rm -rf /tmp/.spamassassin > /dev/null 2>&1 || true
    MUID=""
    if [ "$SW_RC" -eq 0 ] && wait_msg "$ADMINMAIL" INBOX "$F" ; then
        MUID="$(msg_newest_uid "$ADMINMAIL" INBOX "$F")"
    fi
    CP_OUT=""
    if [ -n "$MUID" ] ; then
        CP_OUT="$(timeout -k5 40 curl --silent --insecure --user "$ADMINMAIL:$PASS" \
                  --url "imaps://$SERVER:993/INBOX" -X "UID COPY $MUID Junk" 2>&1 | tr -d '\r')"
    fi
    # the pipe helper is what the sieve script calls: it must always succeed (it is written to
    # never fail the user's IMAP operation), so it is probed verbatim with one message on stdin
    HP_OUT="$(dcx mda sh -c 'printf "From: probe@test.invalid\nTo: probe@test.invalid\nSubject: probe\n\nprobe\n" | /usr/lib/dovecot/sieve-pipe/learn-spam.sh; echo "rc=$?"' 2>&1 | tr -d '\r')"
    HP_RC="$(printf '%s' "$HP_OUT" | sed -n 's/^rc=\([0-9][0-9]*\)$/\1/p' | tail -n1)"
    JUNK_UID=""
    ART_UID=""
    if [ -n "$MUID" ] ; then
        for _ in 1 2 3 4 5 ; do
            JUNK_UID="$(msg_newest_uid "$ADMINMAIL" Junk "$F")"
            ART_UID="$(dcx mda sh -c 'stat -c %u /tmp/.spamassassin 2>/dev/null' 2>/dev/null | tr -d ' \r')"
            [ -n "$JUNK_UID" ] && [ "$ART_UID" = 5000 ] && break
            sleep 2
        done
    fi
    if [ -n "$MUID" ] && [ -n "$JUNK_UID" ] && [ "$ART_UID" = 5000 ] && [ "${HP_RC:-1}" = 0 ] ; then
        t_ok "moving a message into Junk triggers the imapsieve Bayes learning (the vmail-user pipe wrote /tmp/.spamassassin and the helper exits 0)"
    else
        t_fail "moving a message into Junk triggers the imapsieve Bayes learning (swaks rc=$SW_RC, INBOX uid='${MUID:-none}', Junk uid='${JUNK_UID:-none}', sa-learn state uid='${ART_UID:-none}' want 5000, helper rc='${HP_RC:-none}' want 0)"
        if [ -n "$MUID" ] ; then
            dump_swaks
            info "COPY reply: ${CP_OUT:-none}"
        fi
    fi
    # the copy is expunged right away (the assertions above already ran): the phases that follow
    # must see the mailbox as they found it, and the exit trap is only the safety net
    expunge_mailbox "$ADMINMAIL" Junk
fi

# ============================================================ G. db backup ====
# The daily pg_dump of the catalogue (cron/crontab → /scripts/backup_db.sh). A pg_dump older
# than the server aborts with "server version mismatch" and writes NOTHING on stdout, and the
# script used to test the exit status of `pg_dump | gzip` — which is gzip's — so a 20-byte
# archive (an empty stream compressed) sailed through the `[ -s file ]` check and was mailed
# as SUCCESS for weeks. G1/G2 pin the causes, G3/G4 the archive the real script produces and
# G5/G6 the two guards that now turn that into a [CRITICAL] mail.
section "G. cron jobs (db backup → /backups/db, daily traffic resume)"

if [ "$HAVE_DC" != 1 ] ; then
    t_skip "db backup checks ($DC_NEEDED)"
else
    # G1 — the client baked into the cron image must not be older than the server it dumps
    BK_CLIENT="$(dcx cron pg_dump --version 2>/dev/null | awk '{print $3}' | tr -d '\r')"
    BK_SERVER="$(sql "SHOW server_version_num" | tr -d '\r')"
    BK_CLIENT_MAJ="${BK_CLIENT%%.*}"
    BK_SERVER_MAJ="$(( ${BK_SERVER:-0} / 10000 ))"
    if [ -n "$BK_CLIENT_MAJ" ] && [ "$BK_CLIENT_MAJ" -ge "$BK_SERVER_MAJ" ] 2>/dev/null ; then
        t_ok "pg_dump $BK_CLIENT (cron) is >= the server major $BK_SERVER_MAJ"
    else
        t_fail "pg_dump ${BK_CLIENT:-?} (cron) is >= the server major ${BK_SERVER_MAJ:-?} (rebuild cron with PG_CLIENT_MAJOR=${BK_SERVER_MAJ}: an older client dumps nothing)"
    fi

    # G2 — /backups must be a mount, or the dumps die with the container's writable layer
    if dcx cron sh -c 'grep -q " /backups " /proc/mounts' ; then
        t_ok "/backups is a mount on the cron container (the dumps outlive a recreate)"
    else
        t_fail "/backups is a mount on the cron container (docker-compose-dev.yml must bind ./ldata/backups:/backups)"
    fi

    # G3 — run the real script (it also mails the admin, exactly as the cron job does)
    BK_LIST_BEFORE="$(dcx cron sh -c 'ls -1 /backups/db/maild_backup_*.sql.gz 2>/dev/null' | tr -d '\r')"
    timeout -k10 300 "${DC[@]}" exec -T cron /scripts/backup_db.sh > "$TMPRUN/backup_db.log" 2>&1
    BK_RC=$?
    BK_NEW="$(dcx cron sh -c 'ls -1t /backups/db/maild_backup_*.sql.gz 2>/dev/null | head -n1' | tr -d '\r')"
    BK_BYTES="$(dcx cron sh -c "stat -c %s '$BK_NEW' 2>/dev/null" | tr -d '\r')"
    if [ "$BK_RC" -eq 0 ] && [ -n "$BK_NEW" ] ; then
        t_ok "backup_db.sh exits 0 and writes an archive ($(basename "$BK_NEW"), ${BK_BYTES:-0} bytes)"
    else
        t_fail "backup_db.sh exits 0 and writes an archive (rc=$BK_RC, file='${BK_NEW:-none}')"
        info "$(tail -n 15 "$TMPRUN/backup_db.log" | sed 's/^/        /')"
    fi

    # G4 — the archive must be a complete dump of the catalogue, not an empty gzip
    if [ -z "$BK_NEW" ] ; then
        t_skip "the archive is a complete dump (nothing to check)"
    elif [ "${BK_BYTES:-0}" -lt 1024 ] ; then
        t_fail "the archive is a real dump (${BK_BYTES} bytes < 1024: an empty dump compressed is ~20 bytes)"
    elif ! dcx cron gzip -t "$BK_NEW" ; then
        t_fail "the archive passes 'gzip -t' ($BK_NEW)"
    elif ! dcx cron sh -c "zcat '$BK_NEW' | grep -q '^-- PostgreSQL database dump complete\$'" ; then
        t_fail "the archive carries the '-- PostgreSQL database dump complete' trailer"
    elif dcx cron sh -c "zcat '$BK_NEW' | grep -q 'CREATE TABLE public.mailbox'" ; then
        t_ok "the archive is a complete dump of the catalogue (trailer + schema present)"
    else
        t_fail "the archive carries the catalogue schema (no 'CREATE TABLE public.mailbox' inside)"
    fi

    # G4b — the same run also dumps the AdminNG database (device approvals, sessions,
    # TOTP seeds and the audit trail would otherwise be lost on a restore)
    BK_ANEW="$(dcx cron sh -c 'ls -1t /backups/db/maild_adminng_*.sql.gz 2>/dev/null | head -n1' | tr -d '\r')"
    if [ -z "$BK_ANEW" ] ; then
        t_fail "the run also writes the AdminNG archive (maild_adminng_*.sql.gz)"
    elif ! dcx cron gzip -t "$BK_ANEW" 2>/dev/null ; then
        t_fail "the AdminNG archive passes 'gzip -t' ($BK_ANEW)"
    elif dcx cron sh -c "zcat '$BK_ANEW' | grep -q 'CREATE TABLE public.audit_event'" &&
         dcx cron sh -c "zcat '$BK_ANEW' | grep -q '^-- PostgreSQL database dump complete\$'" ; then
        t_ok "the same run also dumps the AdminNG database (audit_event + trailer present)"
    else
        t_fail "the AdminNG archive carries the adminng schema (no audit_event / trailer)"
    fi

    # G5 — the regression itself: a pg_dump that aborts writes nothing and exits non-zero, which
    # gzip happily turns into a valid 20-byte archive. A fake pg_dump claiming a NEWER version
    # passes the version guard and then dies exactly like the real one did.
    BK_COUNT_BEFORE="$(dcx cron sh -c 'ls -1 /backups/db/maild_backup_*.sql.gz 2>/dev/null | wc -l' | tr -d '\r')"
    # The fake has to be injected through /etc/environment: docker-entrypoint.sh dumps `env`
    # into that file (PATH included) and backup_db.sh sources it, so a PATH= prefix on the
    # command line is thrown away. The original file is copied back right after the run.
    dcx cron sh -c 'mkdir -p /tmp/fakebin && printf "%s\n" "#!/bin/sh" "echo pg_dump PostgreSQL 99.0" "exit 1" > /tmp/fakebin/pg_dump && chmod +x /tmp/fakebin/pg_dump && cp -a /etc/environment /tmp/environment.bak && echo "PATH=/tmp/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> /etc/environment' > /dev/null 2>&1
    timeout -k10 300 "${DC[@]}" exec -T cron /scripts/backup_db.sh \
        > "$TMPRUN/backup_db_abort.log" 2>&1
    BK_ABORT_RC=$?
    dcx cron sh -c 'mv /tmp/environment.bak /etc/environment; rm -rf /tmp/fakebin' > /dev/null 2>&1 || true
    BK_COUNT_AFTER="$(dcx cron sh -c 'ls -1 /backups/db/maild_backup_*.sql.gz 2>/dev/null | wc -l' | tr -d '\r')"
    if [ "$BK_ABORT_RC" -ne 0 ] && grep -q 'ERROR:' "$TMPRUN/backup_db_abort.log" &&
       [ "$BK_COUNT_AFTER" = "$BK_COUNT_BEFORE" ] ; then
        t_ok "an aborting pg_dump is reported as FAILED (rc=$BK_ABORT_RC) and its empty archive is deleted"
    else
        t_fail "an aborting pg_dump is reported as FAILED (rc=$BK_ABORT_RC, want != 0; archives $BK_COUNT_BEFORE → $BK_COUNT_AFTER, want unchanged)"
        info "$(tail -n 15 "$TMPRUN/backup_db_abort.log" | sed 's/^/        /')"
    fi

    # G6 — an older client is refused before dumping, with the remedy spelled out in the log
    dcx cron sh -c 'mkdir -p /tmp/fakebin && printf "%s\n" "#!/bin/sh" "echo pg_dump PostgreSQL 9.9" "exit 0" > /tmp/fakebin/pg_dump && chmod +x /tmp/fakebin/pg_dump && cp -a /etc/environment /tmp/environment.bak && echo "PATH=/tmp/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> /etc/environment' > /dev/null 2>&1
    timeout -k10 300 "${DC[@]}" exec -T cron /scripts/backup_db.sh \
        > "$TMPRUN/backup_db_old.log" 2>&1
    BK_OLD_RC=$?
    dcx cron sh -c 'mv /tmp/environment.bak /etc/environment; rm -rf /tmp/fakebin' > /dev/null 2>&1 || true
    if [ "$BK_OLD_RC" -ne 0 ] && grep -q 'older than the server' "$TMPRUN/backup_db_old.log" ; then
        t_ok "a pg_dump older than the server is caught by the version guard (PG_CLIENT_MAJOR remedy logged)"
    else
        t_fail "a pg_dump older than the server is caught by the version guard (rc=$BK_OLD_RC, want != 0)"
        info "$(tail -n 15 "$TMPRUN/backup_db_old.log" | sed 's/^/        /')"
    fi

    # self-cleaning: drop the archives this phase created (they are valid dumps, but the suite
    # must not inflate the dev backup count on every run). G5/G6 also mailed a [CRITICAL]
    # notification to MAIL_ADMIN_USER@DEFAULT_DOMAIN, exactly as the real failure would.
    for f in $(dcx cron sh -c 'ls -1 /backups/db/maild_backup_*.sql.gz 2>/dev/null' | tr -d '\r') ; do
        case "$BK_LIST_BEFORE" in
            *"$f"*) : ;;
            *)      dcx cron rm -f "$f" > /dev/null 2>&1 || true ;;
        esac
    done
    info "the archives created by this phase were removed from /backups/db"

    # --------------------------------------------- daily mail traffic resume --
    # resume.sh (cron, `10 1 * * *` → 01:10 UTC, invoked with no argument, so it summarises
    # *yesterday*) runs the day's mail traffic through pflogsumm and mails it to
    # MAIL_ADMIN_USER@DEFAULT_DOMAIN. It reads /var/log/syslog{,.1}: in production the cron
    # container binds the host /var/log and every service logs through Docker's syslog driver,
    # so rsyslog writes that file. Dev logs to JSON instead (DEV-SETUP.md → Logging) and
    # ./ldata/logs is empty, so the script would parse nothing at all and mail a blank report.
    # G7 therefore materialises today's real mta log there in the shape production's syslog file
    # has: an outer rsyslog stamp in front of Postfix' own `maillog_file = /dev/stdout` line.
    # That outer stamp is not cosmetic — it is what makes resume.sh's `grep " Mon DD "` (note
    # the leading space) and its stamp-stripping sed match at all, since Postfix' own line
    # starts at column 0.
    RES_SUBJECT="MailD Daily stats resume"    # the script's subject is fixed, it carries no date
    RES_DAY="$(dcx cron date +" %b %d " 2>/dev/null | tr -d '\r')"   # the cron clock: it runs UTC, the host may not
    # A previous suite run that was killed (SIGKILL, closed terminal) leaves its materialised
    # file behind -- and reusing it scores a stale window (e.g. one where mail was still being
    # deferred), which shows up as an unrelated G10 failure. The sentinel marks the file as
    # ours, so a leftover from the suite is always regenerated; a real rsyslog file (production
    # parity: the cron container binds the host /var/log) has no sentinel and is left alone.
    if dcx cron sh -c '[ -f /var/log/.maild-test-seeded ]' ; then
        dcx cron sh -c 'rm -f /var/log/syslog /var/log/syslog.1' > /dev/null 2>&1 || true
    fi
    if dcx cron sh -c '[ -s /var/log/syslog ]' ; then
        info "using the /var/log/syslog already present in the cron container"
    elif "${DC[@]}" logs --no-log-prefix --no-color mta 2>/dev/null |
         sed -E "s|^|$(date +'%b %e %H:%M:%S') $(hostname) maild-mta: |" |
         timeout -k10 300 "${DC[@]}" exec -T cron sh -c 'cat > /var/log/syslog; : > /var/log/syslog.1' ; then
        RES_SEEDED=1
        dcx cron sh -c 'touch /var/log/.maild-test-seeded' > /dev/null 2>&1 || true
        RES_LINES="$(dcx cron sh -c 'wc -l < /var/log/syslog' 2>/dev/null | tr -d ' \r')"
        t_ok "G7 today's mta log materialised as /var/log/syslog in the cron container (${RES_LINES:-0} lines)"
    else
        t_fail "G7 today's mta log materialised as /var/log/syslog in the cron container (without it resume.sh parses nothing)"
    fi

    # G8 — run the job on demand: `today` exercises the same code path cron takes with
    # `yesterday`, against the log just materialised. resume.sh ignores swaks' own exit status,
    # so a non-zero rc here means the parsing/pflogsumm half broke, not the delivery half.
    RES_BEFORE="$(subj_count "$DEPLOY_ADMIN" INBOX "$RES_SUBJECT")"
    timeout -k10 300 "${DC[@]}" exec -T cron /scripts/resume.sh today > "$TMPRUN/resume.log" 2>&1
    RES_RC=$?
    if [ "$RES_RC" -eq 0 ] && grep -qF 'mail traffic summary' "$TMPRUN/resume.log" &&
       { [ -z "$RES_DAY" ] || grep -qF "($RES_DAY)" "$TMPRUN/resume.log" ; } ; then
        t_ok "G8 resume.sh today exits 0 and announces the summary for ($RES_DAY) to $DEPLOY_ADMIN"
    else
        t_fail "G8 resume.sh today exits 0 and announces the summary for (${RES_DAY:-?}) to $DEPLOY_ADMIN (rc=$RES_RC)"
        info "$(tail -n 15 "$TMPRUN/resume.log" | sed 's/^/        /')"
    fi

    if ! domain_is_hosted "$DEFAULT_DOMAIN" ; then
        # bootstrap-dev.sh --skip-default-domain: the MTA refuses mail for that domain, so the
        # report cannot be delivered and there is no admin mailbox to read it from.
        t_skip "G9/G10 the resume is delivered and filled ($DEFAULT_DOMAIN is not hosted in this bootstrap mode)"
    else
        # G9 — the report must land in the admin's inbox. Counted on this exact subject and not
        # on the mailbox size: G3/G5/G6 above also mail $DEPLOY_ADMIN and the real cron jobs
        # deliver asynchronously, so only a delta on the resume's own subject proves that *this*
        # run's report arrived. Known narrow race: cron fires resume.sh at 01:10 UTC on
        # *yesterday*, so a suite run spanning that minute can pick up that (in dev empty,
        # because the log we materialise holds today) report as the newest one — re-run it.
        if wait_subj_count_gt "$DEPLOY_ADMIN" INBOX "$RES_SUBJECT" "${RES_BEFORE:-0}" 240 ; then
            t_ok "G9 the daily traffic resume was delivered to $DEPLOY_ADMIN's INBOX"
        else
            t_fail "G9 the daily traffic resume was delivered to $DEPLOY_ADMIN's INBOX (still $(subj_count "$DEPLOY_ADMIN" INBOX "$RES_SUBJECT") match(es) for '$RES_SUBJECT', had ${RES_BEFORE:-0})"
        fi

        # G10 — and it must report the day's real traffic, not the blank report pflogsumm emits
        # for an empty log. That blank one is still ~3 KB of text, so its size proves nothing:
        # the tallies do. $DEFAULT_DOMAIN shows up in it because G3/G5/G6 above mailed the admin,
        # i.e. the report reflects traffic this very run produced.
        RES_UID="$(msg_newest_uid "$DEPLOY_ADMIN" INBOX "$RES_SUBJECT")"
        msg_text "$DEPLOY_ADMIN" INBOX "${RES_UID:-0}" > "$TMPRUN/resume-mail.txt" 2>&1
        # The body alone: the resume mail's own headers name $DEFAULT_DOMAIN anyway
        # (Received: from mta.$DEFAULT_DOMAIN, DKIM d=$DEFAULT_DOMAIN), so grepping the whole
        # message would match even for a blank report and prove nothing.
        sed -n '/^$/,$p' "$TMPRUN/resume-mail.txt" | sed '1d' > "$TMPRUN/resume-body.txt"
        RES_RECV="$(awk '/^[[:space:]]*[0-9]+[[:space:]]+received$/  {print $1; exit}' "$TMPRUN/resume-body.txt")"
        RES_SENT="$(awk '/^[[:space:]]*[0-9]+[[:space:]]+delivered$/ {print $1; exit}' "$TMPRUN/resume-body.txt")"
        if grep -q '^Grand Totals$' "$TMPRUN/resume-body.txt" &&
           grep -q '^Per-Hour Traffic Summary$' "$TMPRUN/resume-body.txt" &&
           [ "${RES_RECV:-0}" -gt 0 ] && [ "${RES_SENT:-0}" -gt 0 ] &&
           grep -qF "$DEFAULT_DOMAIN" "$TMPRUN/resume-body.txt" ; then
            t_ok "G10 the resume reports the day's real traffic ($RES_RECV received / $RES_SENT delivered, $DEFAULT_DOMAIN in the report)"
        else
            t_fail "G10 the resume reports the day's real traffic (received=${RES_RECV:-0}, delivered=${RES_SENT:-0}: want both > 0 plus '$DEFAULT_DOMAIN' in the report body; an all-zeroes report means resume.sh's date filter matched no log line)"
            info "$(sed -n '1,14p' "$TMPRUN/resume-body.txt" | sed 's/^/        /')"
        fi
    fi

    # ---------------------------------------------- daily Bayes learning job --
    # learn_from_folders.sh (cron: `30 03 * * *` → 03:30 UTC) feeds the bayes db with every
    # message sitting on the users' Junk folders plus a random sample of their INBOXes. Two
    # properties matter here: it must survive empty folders (nothing to learn is not an error)
    # and it must release its flock, or the next day's run is skipped — hence the two
    # consecutive runs, both of which must exit 0.
    # Its only output is a `logger` summary and the container has no /dev/log, so the check runs
    # the script with a `logger` shell function injected (sourcing it under bash: the script
    # re-sources /etc/environment, which would drop a PATH stub) to capture that summary
    # verbatim. The script itself is untouched and the learning is the real one. The ham counter
    # varies from run to run (random INBOX sampling) and the spam counter can be 0 even with
    # messages in Junk (an already-learned duplicate is skipped), so only the shape is asserted.
    if ! dcx cron sh -c 'grep -q "^30 03 .*learn_from_folders\.sh" /etc/crontab' ; then
        t_fail "G11 the Bayes learning job is scheduled in the cron crontab (no 03:30 learn_from_folders.sh entry)"
    else
        BAYES_RAW1="$(dcx cron bash -c 'logger() { echo "logger: $*"; }; . /scripts/learn_from_folders.sh' 2>&1)" ; BAYES_RC1=$?
        BAYES_RAW2="$(dcx cron bash -c 'logger() { echo "logger: $*"; }; . /scripts/learn_from_folders.sh' 2>&1)" ; BAYES_RC2=$?
        BAYES_SUM="$(printf '%s\n' "$BAYES_RAW1" | tr -d '\r' | sed -n 's/.*bayes learning done: //p' | head -n1)"
        BAYES_SPAM="$(printf '%s' "$BAYES_SUM" | sed -n 's/^\([0-9][0-9]*\) spam learned from \([0-9][0-9]*\) junk message(s).*/\1/p')"
        BAYES_JUNK="$(printf '%s' "$BAYES_SUM" | sed -n 's/^\([0-9][0-9]*\) spam learned from \([0-9][0-9]*\) junk message(s).*/\2/p')"
        BAYES_HAM="$(printf '%s' "$BAYES_SUM" | sed -n 's/.*; \([0-9][0-9]*\) ham learned from \([0-9][0-9]*\) sampled INBOX message(s).*/\1/p')"
        BAYES_MODE="$(dcx cron sh -c 'stat -c %a /var/lib/spamassassin/bayes 2>/dev/null' 2>/dev/null | tr -d ' \r')"
        if [ "$BAYES_RC1" -ne 0 ] || [ "$BAYES_RC2" -ne 0 ] ; then
            t_fail "G11 the Bayes learning job runs to completion (rc=$BAYES_RC1 then rc=$BAYES_RC2, want 0/0)"
            info "$(printf '%s' "$BAYES_RAW1" | tr -d '\r' | tail -n 5 | sed 's/^/        /')"
        elif [ -z "$BAYES_SUM" ] || [ -z "$BAYES_SPAM" ] || [ -z "$BAYES_JUNK" ] || [ -z "$BAYES_HAM" ] ; then
            t_fail "G11 the Bayes learning job reports its summary (captured: '$(printf '%s' "$BAYES_RAW1" | tr -d '\r' | head -c 160)')"
        elif [ "$BAYES_MODE" != 777 ] ; then
            t_fail "G11 the Bayes learning job leaves the bayes dir writable for its peers (mode=$BAYES_MODE, want 777: amavis scans and the mda learns into it too)"
        else
            t_ok "G11 the Bayes learning job runs twice, releases its lock and reports '$BAYES_SUM'"
        fi
    fi

    if [ "$RES_SEEDED" = 1 ] ; then
        info "the materialised /var/log/syslog is removed from the cron container on exit"
    fi
fi


# ======================================= H. SpamAssassin maintenance ==========
# The SpamAssassin *rules* refresh is not a cron-container job (cron only runs the Bayes
# learning in section G): the amavis entrypoint starts amavis/sa-update-loop.sh
# (`/sa-update-loop.sh &`), which runs `sa-update --channel updates.spamassassin.org` once a day
# at SA_UPDATE_HOUR:SA_UPDATE_MINUTE and HUPs amavisd when new rules land. This section checks
# the whole chain: the loop is wired and alive, the tool is installed, the knobs are documented
# and — the part that decides whether scanning keeps working — the rules it maintains actually
# load, with the `.pre` set matching the installed major. A distro jump that installs v3*.pre
# under SpamAssassin 4.x is exactly that failure (see the amavis jammy→resolute move) and it
# stays invisible until mail is filtered.
# The live fetch needs egress to updates.spamassassin.org. It is graded when the channel is
# reachable (rc 0 = rules installed, 4 = nothing new; anything else is a real failure), and
# when the channel cannot be reached at all the fetch is reported as evidence while the
# deterministic half decides the check — a mail server that cannot see the update server still
# has to scan with the rules it has.
section "H. SpamAssassin maintenance (sa-update loop)"

if [ "$HAVE_DC" != 1 ] ; then
    t_skip "SpamAssassin rules update checks ($DC_NEEDED)"
else
    SAU_WHY=""
    dcx amavis test -x /sa-update-loop.sh || SAU_WHY="$SAU_WHY loop-script-missing;"
    dcx amavis sh -c 'pgrep -f sa-update-loop.sh > /dev/null' || SAU_WHY="$SAU_WHY loop-not-running;"
    dcx amavis sh -c 'timeout 45 spamassassin --lint > /dev/null 2>&1' || SAU_WHY="$SAU_WHY rules-do-not-load;"
    grep -q 'SA_UPDATE_HOUR' "$SCRIPT_DIR/env.sample" || SAU_WHY="$SAU_WHY SA_UPDATE_* knobs-undocumented;"
    SAU_VER="$(dcx amavis sh -c 'sa-update --version 2>/dev/null' | tr -d '\r' | sed -n 's/^sa-update version \([0-9][0-9.]*\).*/\1/p' | head -n1)"
    if [ -z "$SAU_VER" ] ; then
        SAU_WHY="$SAU_WHY sa-update-missing;"
        SAU_PRE=0
    else
        # v400/v401/v402 under SA 4.x, v310..v343 under 3.4.x: the major decides the family
        SAU_PRE="$(dcx amavis sh -c "ls /etc/spamassassin/v${SAU_VER%%.*}*.pre 2>/dev/null | wc -l" | tr -d ' \r')"
        [ "${SAU_PRE:-0}" -gt 0 ] || SAU_WHY="$SAU_WHY no-v${SAU_VER%%.*}xx.pre-for-SA-$SAU_VER;"
    fi
    if [ -n "$SAU_WHY" ] ; then
        t_fail "H1 the sa-update loop is wired and the rules it maintains load (${SAU_WHY# })"
    else
        # is the channel reachable at all? (netcat-openbsd is in the amavis image)
        SAU_REACH=0
        dcx amavis sh -c 'timeout 10 nc -z -w5 updates.spamassassin.org 80 > /dev/null 2>&1' && SAU_REACH=1
        SAU_OUT="$(timeout -k5 60 "${DC[@]}" exec -T amavis sa-update --channel updates.spamassassin.org 2>&1)"
        SAU_RC=$?
        case "$SAU_RC" in
            0) t_ok "H1 the sa-update loop is alive, its rules load (SA $SAU_VER, $SAU_PRE v${SAU_VER%%.*}xx.pre) and the live fetch installed new rules" ;;
            4) t_ok "H1 the sa-update loop is alive, its rules load (SA $SAU_VER, $SAU_PRE v${SAU_VER%%.*}xx.pre) and the live fetch found nothing new" ;;
            *)
                # an unexpected rc is only conclusive if the channel was reachable: re-check,
                # so an intermittent network drops to the informational path instead of failing
                dcx amavis sh -c 'timeout 10 nc -z -w5 updates.spamassassin.org 80 > /dev/null 2>&1' || SAU_REACH=0
                SAU_MSG="$(printf '%s' "$SAU_OUT" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -n1)"
                if [ "$SAU_REACH" = 1 ] ; then
                    t_fail "H1 sa-update fails although updates.spamassassin.org is reachable (rc=$SAU_RC: $SAU_MSG)"
                else
                    t_ok "H1 the sa-update loop is alive and the rules it maintains load (SA $SAU_VER, $SAU_PRE v${SAU_VER%%.*}xx.pre)"
                    info "live sa-update probe rc=$SAU_RC: $SAU_MSG"
                    info "that channel is unreachable from here; on a networked host the same probe must return 0 or 4"
                fi
                ;;
        esac
    fi
fi

# ================================= I. AdminNG API (Phase 2) =================
# Device trust + TOTP + catalogue + re-auth + audit, black box through the
# nginx proxy. Two fixed device ids keep re-runs deterministic; the sysadmin's
# TOTP credential persists across runs (enrollment is exercised on the first).
section "I. AdminNG API (device trust, TOTP, catalogue, re-auth)"

API_BASE="http://$SERVER:8083/api/v1"
ADMINNG_DOMAIN="adminng-e2e.test"
ADMINNG_USER="probe@$ADMINNG_DOMAIN"
ADMINNG_PW="$(chrono)"
ADMINNG_DEVICE="aaaaaaaa-0000-4000-8000-0000000000a1"
ADMINNG_DEVICE_2="aaaaaaaa-0000-4000-8000-0000000000a2"
ADMIN_PW="${CRED[${DEPLOY_ADMIN,,}]:-}"
ADMINNG_TOKEN=""
ADMINNG_REFRESH=""

adminng_call() { # <method> <path> <device> <token> [json] [vtoken] → ADMINNG_CODE/ADMINNG_BODY
    local method="$1" path="$2" device="$3" token="$4" data="${5:-}" vtoken="${6:-}"
    local out="$TMPRUN/adminng.json"
    local args=(-s -o "$out" -w '%{http_code}' -X "$method" -H "X-Device-ID: $device")
    [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
    [ -n "$vtoken" ] && args+=(-H "X-Security-Validation-Token: $vtoken")
    [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
    ADMINNG_CODE="$(curl "${args[@]}" "$API_BASE$path")"
    ADMINNG_BODY="$(cat "$out" 2>/dev/null)"
}
adminng_imap() { # <user> <pass>
    timeout -k5 20 curl -s --insecure --user "$1:$2" \
        --url "imaps://$SERVER:993/INBOX" -X 'SEARCH ALL' 2>&1 | grep -q '\* SEARCH'
}
adminng_flush_auth() { dcx mda doveadm auth cache flush > /dev/null 2>&1 || true; }
adminng_code() { dcx api python tests/totp_code.py "$@" 2>/dev/null | tr -d ' \r\n'; }
adminng_jqf() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

if [ "$HAVE_DC" = 0 ] || [ -z "$ADMIN_PW" ] ; then
    t_skip "AdminNG API (needs docker and $DEPLOY_ADMIN in test.creds)"
else
    # Deterministic clean slate for the fixtures this section owns.
    dcx db psql -U maild -d adminng -q -c \
        "DELETE FROM device WHERE device_id IN ('$ADMINNG_DEVICE','$ADMINNG_DEVICE_2');" \
        > /dev/null 2>&1 || true
    dcx db psql -U maild -d mailddb -q -c \
        "DELETE FROM alias WHERE domain='$ADMINNG_DOMAIN'; DELETE FROM domain_admins WHERE domain='$ADMINNG_DOMAIN'; DELETE FROM mailbox WHERE domain='$ADMINNG_DOMAIN'; DELETE FROM domain WHERE domain='$ADMINNG_DOMAIN';" \
        > /dev/null 2>&1 || true

    # I1 — handshake + pending login refusal
    adminng_call POST /device/handshake "$ADMINNG_DEVICE" "" '{"client_type":"web","device_name":"test.sh"}'
    I1_H="$ADMINNG_CODE"
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
        "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\"}"
    if [ "$I1_H" = 200 ] && [ "$ADMINNG_CODE" = 403 ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q DEVICE_NOT_AUTHORIZED ; then
        t_ok "I1 new device is PENDING: login-step1 refused with DEVICE_NOT_AUTHORIZED"
    else
        t_fail "I1 device gate (handshake=$I1_H step1=$ADMINNG_CODE body=$(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi

    # I2 — CLI approval turns the device APPROVED
    dcx api adminng.py --approve-device "$ADMINNG_DEVICE" > /dev/null 2>&1
    adminng_call GET /device/status "$ADMINNG_DEVICE" ""
    if printf '%s' "$ADMINNG_BODY" | grep -q APPROVED ; then
        t_ok "I2 the server-side CLI approval flips the device to APPROVED"
    else
        t_fail "I2 device approval (body=$(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi

    # I3 — TOTP policy: superadmin must enroll on the first login
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
        "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\"}"
    NEED_NEXT=0
    if printf '%s' "$ADMINNG_BODY" | grep -q REQUIRES_TOTP_ENROLLMENT ; then
        ET="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf enrollment_token)"
        adminng_call POST /auth/totp-enroll "$ADMINNG_DEVICE" "" \
            "{\"enrollment_token\":\"$ET\"}"
        SECRET="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf secret)"
        CODE="$(dcx api python -c 'import sys; from app import totp; print(totp.code_at(sys.argv[1]))' "$SECRET" 2>/dev/null | tr -d ' \r\n')"
        adminng_call POST /auth/totp-confirm "$ADMINNG_DEVICE" "" \
            "{\"enrollment_token\":\"$ET\",\"code\":\"$CODE\"}"
        I3_C="$ADMINNG_CODE"
        adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
            "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\"}"
        if [ "$I3_C" = 200 ] && printf '%s' "$ADMINNG_BODY" | grep -q REQUIRES_2FA ; then
            t_ok "I3 superadmin enrolls TOTP (QR/otpauth) and step1 then requires the 2FA code"
            NEED_NEXT=1
        else
            t_fail "I3 TOTP enrollment (confirm=$I3_C step1=$(printf '%s' "$ADMINNG_BODY" | head -c 140))"
        fi
    elif printf '%s' "$ADMINNG_BODY" | grep -q REQUIRES_2FA ; then
        t_ok "I3 TOTP already enrolled from a previous run; step1 asks for the 2FA code"
    else
        t_fail "I3 step1 did not ask for enrollment or 2FA ($(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi

    # I4 — step2 with a real TOTP code → tokens; /auth/me
    FLOW="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf flow_token)"
    if [ "$NEED_NEXT" = 1 ] ; then CODE="$(adminng_code "$DEPLOY_ADMIN" --next)" ; else CODE="$(adminng_code "$DEPLOY_ADMIN")" ; fi
    adminng_call POST /auth/login-step2 "$ADMINNG_DEVICE" "" \
        "{\"flow_token\":\"$FLOW\",\"code\":\"$CODE\"}"
    if [ "$ADMINNG_CODE" != 200 ] ; then
        # replay/window guard: retry once with the next step
        FLOW="$(curl -s -X POST "$API_BASE/auth/login-step1" -H "X-Device-ID: $ADMINNG_DEVICE" \
            -H 'Content-Type: application/json' \
            --data "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\"}" | adminng_jqf flow_token)"
        CODE="$(adminng_code "$DEPLOY_ADMIN" --next)"
        adminng_call POST /auth/login-step2 "$ADMINNG_DEVICE" "" \
            "{\"flow_token\":\"$FLOW\",\"code\":\"$CODE\"}"
    fi
    ADMINNG_TOKEN="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
    ADMINNG_REFRESH="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf refresh_token)"
    adminng_call GET /auth/me "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ -n "$ADMINNG_TOKEN" ] && [ -n "$ADMINNG_REFRESH" ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q '"superadmin":true' ; then
        t_ok "I4 login-step2 issues the device-bound token pair and /auth/me is the superadmin"
    else
        t_fail "I4 step2/login (body=$(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi
    # I5 — catalogue writes through the device-bound API
    adminng_call POST /domains "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"domain\":\"$ADMINNG_DOMAIN\",\"description\":\"AdminNG e2e\"}"
    I5_D="$ADMINNG_CODE" ; I5_B="$ADMINNG_BODY"
    adminng_call POST /mailboxes "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"username\":\"$ADMINNG_USER\",\"password\":\"$ADMINNG_PW\",\"name\":\"Probe\",\"quota_bytes\":10485760}"
    if [ "$I5_D" = 201 ] && printf '%s' "$I5_B" | grep -q RESTART_REQUIRED &&
       [ "$ADMINNG_CODE" = 201 ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q "\"maildir\":\"$ADMINNG_DOMAIN/probe/\"" ; then
        t_ok "I5 domain (+ restart advisory) and mailbox (PostfixAdmin maildir/bytes) created via the API"
    else
        t_fail "I5 create (domain=$I5_D mailbox=$ADMINNG_CODE)"
    fi

    # I6 — the API-created mailbox logs into IMAPS
    if adminng_imap "$ADMINNG_USER" "$ADMINNG_PW" ; then
        t_ok "I6 the API-created mailbox logs into IMAPS immediately (md5crypt accepted)"
    else
        t_fail "I6 IMAPS login for the API-created mailbox"
    fi

    # I7 — quota usage from the Maildir++ accounting
    adminng_call GET "/mailboxes/$ADMINNG_USER/quota" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$ADMINNG_CODE" = 200 ] && printf '%s' "$ADMINNG_BODY" | grep -q '"quota_bytes":10485760' &&
       ! printf '%s' "$ADMINNG_BODY" | grep -q '"source":"unavailable"' ; then
        t_ok "I7 quota usage from .maildirsize/du ($(printf '%s' "$ADMINNG_BODY" | adminng_jqf source))"
    else
        t_fail "I7 quota route ($(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi

    # I8 — alias tags + rapid search
    adminng_call POST /aliases "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"address\":\"sales@$ADMINNG_DOMAIN\",\"goto\":\"$ADMINNG_USER\"}"
    adminng_call GET "/aliases?goto=$ADMINNG_USER" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    I8_A="$ADMINNG_CODE" ; I8_B="$ADMINNG_BODY"
    adminng_call GET "/search?q=probe" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$I8_A" = 200 ] && printf '%s' "$I8_B" | grep -q "\"address\":\"sales@$ADMINNG_DOMAIN\"" &&
       printf '%s' "$ADMINNG_BODY" | grep -q "$ADMINNG_USER" ; then
        t_ok "I8 alias tags (?goto=) and rapid search work"
    else
        t_fail "I8 alias/search"
    fi

    # I9 — suspension blocks IMAPS (after the Dovecot auth-cache flush)
    adminng_call PUT "/mailboxes/$ADMINNG_USER" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" '{"active":false}'
    adminng_flush_auth
    if adminng_imap "$ADMINNG_USER" "$ADMINNG_PW" ; then
        t_fail "I9 suspension is enforced for IMAPS"
    else
        t_ok "I9 suspension blocks IMAPS (active=false)"
    fi
    adminng_call PUT "/mailboxes/$ADMINNG_USER" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" '{"active":true}'
    adminng_flush_auth
    if adminng_imap "$ADMINNG_USER" "$ADMINNG_PW" ; then
        t_ok "I9 reactivation restores IMAPS access"
    else
        t_fail "I9 reactivation did not restore IMAPS"
    fi

    # I10 — destructive action without the validation token is refused
    adminng_call DELETE "/domains/$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    I10_NO="$ADMINNG_CODE" ; I10_B="$ADMINNG_BODY"
    adminng_call POST /auth/reauth-confirm "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"password\":\"$ADMIN_PW\"}"
    SV="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf security_validation_token)"
    if [ "$I10_NO" = 403 ] && printf '%s' "$I10_B" | grep -q OPERATION_NOT_VERIFIED &&
       [ -n "$SV" ] ; then
        t_ok "I10 DELETE without X-Security-Validation-Token is refused (403 OPERATION_NOT_VERIFIED); reauth mints the 30 s token"
    else
        t_fail "I10 re-auth negative (delete=$I10_NO token_len=${#SV})"
    fi

    # I11 — tenant isolation with a custom admin
    if [ "$(sql "SELECT superadmin FROM admin WHERE username='$ADMINMAIL'")" = "t" ] ; then
        t_skip "I11 tenant isolation (the fixture admin $ADMINMAIL is a superadmin)"
    else
        adminng_call POST /device/handshake "$ADMINNG_DEVICE_2" "" '{"client_type":"web","device_name":"test.sh tenant"}'
        dcx api adminng.py --approve-device "$ADMINNG_DEVICE_2" > /dev/null 2>&1
        adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE_2" "" \
            "{\"username\":\"$ADMINMAIL\",\"password\":\"$PASS\"}"
        A_TOKEN="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
        if [ -z "$A_TOKEN" ] && printf '%s' "$ADMINNG_BODY" | grep -q REQUIRES_2FA ; then
            A_FLOW="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf flow_token)"
            A_CODE="$(adminng_code "$ADMINMAIL" --next)"
            adminng_call POST /auth/login-step2 "$ADMINNG_DEVICE_2" "" \
                "{\"flow_token\":\"$A_FLOW\",\"code\":\"$A_CODE\"}"
            A_TOKEN="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
        fi
        adminng_call GET "/domains/$DEFAULT_DOMAIN" "$ADMINNG_DEVICE_2" "$A_TOKEN"
        I11_A="$ADMINNG_CODE"
        adminng_call POST /mailboxes "$ADMINNG_DEVICE_2" "$A_TOKEN" \
            "{\"username\":\"intruder@$DEFAULT_DOMAIN\",\"password\":\"x\"}"
        if [ "$I11_A" = 403 ] && [ "$ADMINNG_CODE" = 403 ] &&
           printf '%s' "$ADMINNG_BODY" | grep -q FORBIDDEN_TENANT ; then
            t_ok "I11 a custom admin cannot read or write a foreign domain (403 FORBIDDEN_TENANT)"
        else
            t_fail "I11 tenant isolation (get=$I11_A post=$ADMINNG_CODE)"
        fi
    fi

    # I12 — re-auth DELETE cascade (fresh 30 s token)
    adminng_call POST /auth/reauth-confirm "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"password\":\"$ADMIN_PW\"}"
    SV="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf security_validation_token)"
    adminng_call DELETE "/aliases/sales@$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_A="$ADMINNG_CODE"
    adminng_call DELETE "/mailboxes/$ADMINNG_USER" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_B="$ADMINNG_CODE"
    adminng_call DELETE "/domains/$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_C="$ADMINNG_CODE"
    adminng_call GET "/domains/$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$I12_A" = 204 ] && [ "$I12_B" = 204 ] && [ "$I12_C" = 204 ] &&
       [ "$ADMINNG_CODE" = 404 ] &&
       [ "$(sql "SELECT count(*) FROM mailbox WHERE domain='$ADMINNG_DOMAIN'")" = "0" ] ; then
        t_ok "I12 re-auth DELETE cascade: alias/mailbox/domain gone (204s, then 404)"
    else
        t_fail "I12 delete cascade (alias=$I12_A mailbox=$I12_B domain=$I12_C get=$ADMINNG_CODE)"
    fi

    # I13 — refresh rotation + reuse detection
    adminng_call POST /auth/refresh "$ADMINNG_DEVICE" "" "{\"refresh_token\":\"$ADMINNG_REFRESH\"}"
    I13_OK="$ADMINNG_CODE"
    NEW_AT="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
    NEW_RT="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf refresh_token)"
    adminng_call POST /auth/refresh "$ADMINNG_DEVICE" "" "{\"refresh_token\":\"$ADMINNG_REFRESH\"}"
    if [ "$I13_OK" = 200 ] && [ -n "$NEW_AT" ] && [ "$ADMINNG_CODE" = 401 ] ; then
        t_ok "I13 refresh rotates the jti and a replayed refresh token is rejected"
        ADMINNG_TOKEN="$NEW_AT" ; ADMINNG_REFRESH="$NEW_RT"
    else
        t_fail "I13 refresh rotation (first=$I13_OK reuse=$ADMINNG_CODE)"
    fi

    # I14 — audit trail
    adminng_call GET "/logs?limit=50" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$ADMINNG_CODE" = 200 ] && printf '%s' "$ADMINNG_BODY" | grep -q LOGIN_OK &&
       printf '%s' "$ADMINNG_BODY" | grep -q MAILBOX_CREATE &&
       printf '%s' "$ADMINNG_BODY" | grep -q DOMAIN_DELETE ; then
        t_ok "I14 the audit trail records LOGIN_OK, MAILBOX_CREATE and DOMAIN_DELETE"
    else
        t_fail "I14 audit logs (code=$ADMINNG_CODE)"
    fi

    # I15 — device revocation kills the sessions
    adminng_call POST /auth/reauth-confirm "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"password\":\"$ADMIN_PW\"}"
    SV2="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf security_validation_token)"
    adminng_call PUT "/admin/devices/$ADMINNG_DEVICE/state" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        '{"action":"REVOKE"}' "$SV2"
    I15_R="$ADMINNG_CODE"
    adminng_call GET /auth/me "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$I15_R" = 200 ] && [ "$ADMINNG_CODE" = 401 ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q DEVICE_REVOKED ; then
        t_ok "I15 revoking the device kills its sessions immediately (DEVICE_REVOKED)"
    else
        t_fail "I15 device revoke (revoke=$I15_R me=$ADMINNG_CODE)"
    fi

    # I16 — lockout: five failed logins lock that username+IP for 15 minutes
    # (a non-existent account, so no real fixture is affected)
    LOCK_USER="nobody@adminng-lockout.test"
    adminng_call POST /device/handshake "$ADMINNG_DEVICE_2" "" '{"client_type":"web","device_name":"test.sh lockout"}'
    for _ in 1 2 3 4 5 ; do
        adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE_2" "" \
            "{\"username\":\"$LOCK_USER\",\"password\":\"wrong\"}"
    done
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE_2" "" \
        "{\"username\":\"$LOCK_USER\",\"password\":\"wrong\"}"
    if [ "$ADMINNG_CODE" = 429 ] && printf '%s' "$ADMINNG_BODY" | grep -q RATE_LIMITED ; then
        t_ok "I16 five failed logins lock the username+IP (429 RATE_LIMITED)"
    else
        t_fail "I16 lockout (got $ADMINNG_CODE: $(printf '%s' "$ADMINNG_BODY" | head -c 120))"
    fi
fi

section "summary"
printf '  passed : %d\n' "$T_PASS"
printf '  failed : %d\n' "$T_FAIL"
printf '  skipped: %d\n' "$T_SKIP"
printf '  transcripts: %s\n' "$LOG"
[ "$DEBUG" = 1 ] && printf '  debug trace: %s\n' "$DEBUG_LOG"
if [ "$T_FAIL" -gt 0 ] ; then
    printf '  failed checks:\n'
    for n in "${FAILED_NAMES[@]}" ; do printf '    - %s\n' "$n" ; done
    exit 1
fi
printf '  %sOK: every executed check passed%s\n' "$C_OK" "$C_OFF"
exit 0



