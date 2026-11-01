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
        # Credentials are mailbox addresses; skip metadata lines (e.g. the AdminNG
        # dev-device note) so they never reach the SMTP/IMAP loops.
        case "$key" in *@*) ;; *) continue ;; esac
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
MCP_TOUCHED=0
MCP_K_TOUCHED=0
MCP_M_TOUCHED=0
MCP_N_TOUCHED=0
MCP_O_TOUCHED=0
MCP_P_TOUCHED=0
MCP_LEGACY_USER="mcp-legacy-probe@${DOMAIN}"
MCP_INACTIVE_USER="mcp-inactive-probe@${DOMAIN}"
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
        # Phase J (MCP): the two throwaway mailboxes and their homes.
        if [ "$MCP_TOUCHED" = 1 ]; then
            dcx db psql -U maild -d mailddb -q -c \
                "DELETE FROM mailbox WHERE username IN ('$MCP_LEGACY_USER','$MCP_INACTIVE_USER');" \
                > /dev/null 2>&1 || true
            dcx mda rm -rf "/home/vmail/${DOMAIN}/${MCP_LEGACY_USER%%@*}" "/home/vmail/${DOMAIN}/${MCP_INACTIVE_USER%%@*}" \
                > /dev/null 2>&1 || true
            dcx mda doveadm auth cache flush > /dev/null 2>&1 || true
        fi
        # Phase P (REST mirror): the maild-p5-* messages, the p5-* master token, the p-rest client.
        if [ "$MCP_P_TOUCHED" = 1 ]; then
            for p_f in INBOX Trash ; do
                dcx mda doveadm expunge -u "alice@$DOMAIN" mailbox "$p_f" subject "maild-p5-" > /dev/null 2>&1 || true
            done
            dcx db psql -U maild -d mcp -q -c "
                DELETE FROM confirm_handle WHERE token_id IN (SELECT id FROM token WHERE (kind = 'master' AND name LIKE 'p5-%') OR name IN ('p-all', 'p-read'));
                DELETE FROM token WHERE kind = 'master' AND name LIKE 'p5-%';
                DELETE FROM oauth_code WHERE client_id IN (SELECT client_id FROM oauth_client WHERE metadata->>'client_name' = 'p-rest');
                DELETE FROM oauth_request WHERE client_id IN (SELECT client_id FROM oauth_client WHERE metadata->>'client_name' = 'p-rest');
                DELETE FROM token WHERE client_id IN (SELECT client_id FROM oauth_client WHERE metadata->>'client_name' = 'p-rest');
                DELETE FROM oauth_client WHERE metadata->>'client_name' = 'p-rest';" > /dev/null 2>&1 || true
        fi
        # Phase O (OAuth): the scripted clients, their pending requests and codes, the grants of the fixtures.
        if [ "$MCP_O_TOUCHED" = 1 ]; then
            dcx db psql -U maild -d mcp -q -c "
                DELETE FROM oauth_request WHERE client_id IN (SELECT client_id FROM oauth_client WHERE metadata->>'client_name' LIKE 'Scripted %' OR metadata->>'client_name' = 'o-rules');
                DELETE FROM oauth_code WHERE client_id IN (SELECT client_id FROM oauth_client WHERE metadata->>'client_name' LIKE 'Scripted %' OR metadata->>'client_name' = 'o-rules');
                DELETE FROM oauth_client WHERE metadata->>'client_name' LIKE 'Scripted %' OR metadata->>'client_name' = 'o-rules';
                DELETE FROM oauth_code WHERE account_id IN (SELECT id FROM account WHERE main_email LIKE '%@${DOMAIN}');
                DELETE FROM token WHERE kind IN ('oauth_access', 'oauth_refresh') AND account_id IN (SELECT id FROM account WHERE main_email LIKE '%@${DOMAIN}');" > /dev/null 2>&1 || true
        fi
        # Phase N (MCP admin): restore the admin row, the settings and the domain policy as found, the
        # service mailbox hash, drop the master tokens and admin sessions/codes the phase made.
        if [ "$MCP_N_TOUCHED" = 1 ]; then
            dcx db psql -U maild -d mcp -q -c "
                DELETE FROM confirm_handle WHERE token_id IN (SELECT id FROM token WHERE kind='master' AND name LIKE 'n-%');
                DELETE FROM token WHERE kind='master' AND name LIKE 'n-%';
                DELETE FROM otp_challenge; DELETE FROM web_session WHERE kind='admin';
                DELETE FROM notice_throttle WHERE kind IN ('master_access','token_seen');
                UPDATE admin_user a SET password_hash=b.password_hash, email=b.email FROM n_bak_admin b WHERE a.id=b.id;
                DELETE FROM setting; INSERT INTO setting SELECT * FROM n_bak_setting;
                DELETE FROM domain_policy; INSERT INTO domain_policy SELECT * FROM n_bak_policy;
                DROP TABLE IF EXISTS n_bak_admin, n_bak_setting, n_bak_policy;" > /dev/null 2>&1 || true
            [ -n "${N_SVC_HASH:-}" ] && sql "UPDATE mailbox SET password='$N_SVC_HASH' WHERE username='$N_SVC'" > /dev/null 2>&1 || true
            dcx mda doveadm auth cache flush > /dev/null 2>&1 || true
            for n_box in "$DEPLOY_ADMIN" "alice@$DOMAIN" "bob@$DOMAIN" "dylan@$DOMAIN" ; do
                dcx mda doveadm expunge -u "$n_box" mailbox INBOX header From "MailD MCP" > /dev/null 2>&1 || true
                dcx mda doveadm expunge -u "$n_box" mailbox INBOX subject "maild-p3-" > /dev/null 2>&1 || true
            done
        fi
        # Phase M (MCP write/send): every maild-p2-* message and folder, the send counters.
        if [ "$MCP_M_TOUCHED" = 1 ]; then
            for m_box in "alice@$DOMAIN" "bob@$DOMAIN" "charlie@$DOMAIN" ; do
                for m_f in INBOX Sent Drafts Junk Trash ; do
                    dcx mda doveadm expunge -u "$m_box" mailbox "$m_f" subject "maild-p2-" > /dev/null 2>&1 || true
                done
            done
            dcx mda sh -c "doveadm mailbox list -u alice@$DOMAIN | grep -E '^P2r?-maild-p2-' | while read -r f; do doveadm mailbox delete -u alice@$DOMAIN \"\$f\"; done" > /dev/null 2>&1 || true
            dcx db psql -U maild -d mcp -q -c "DELETE FROM send_counter; DELETE FROM confirm_handle;" > /dev/null 2>&1 || true
        fi
        # Phase L (amavis listeners): the 10026 probe mail and, if L6 was interrupted, its placeholder.
        dcx mda doveadm expunge -u "$DEPLOY_ADMIN" mailbox INBOX subject "maild-p1b-internal-" > /dev/null 2>&1 || true
        [ -n "${L_PLACEHOLDER:-}" ] && docker rm -f "$L_PLACEHOLDER" > /dev/null 2>&1 || true
        # Phase K (MCP user side): fixture accounts with their tokens and addresses (children first:
        # the ORM's CASCADE is not a database ON DELETE), their sessions and
        # lockouts, the example.net policy as found, the service mails the phase caused.
        if [ "$MCP_K_TOUCHED" = 1 ]; then
            dcx db psql -U maild -d mcp -q -c "
                DELETE FROM web_session WHERE kind='user' AND subject_id IN (SELECT id FROM account WHERE main_email LIKE '%@${DOMAIN}');
                DELETE FROM confirm_handle WHERE token_id IN (SELECT t.id FROM token t JOIN account a ON a.id = t.account_id WHERE a.main_email LIKE '%@${DOMAIN}');
                DELETE FROM oauth_code WHERE account_id IN (SELECT id FROM account WHERE main_email LIKE '%@${DOMAIN}');
                DELETE FROM token WHERE account_id IN (SELECT id FROM account WHERE main_email LIKE '%@${DOMAIN}');
                DELETE FROM account_address WHERE account_id IN (SELECT id FROM account WHERE main_email LIKE '%@${DOMAIN}');
                DELETE FROM account WHERE main_email LIKE '%@${DOMAIN}';
                DELETE FROM login_failure WHERE key LIKE '%@${DOMAIN}';
                DELETE FROM notice_throttle WHERE kind='claim_conflict' AND key LIKE '%@${DOMAIN}';" > /dev/null 2>&1 || true
            case "${K_POLICY_BEFORE:-}" in
                t) dcx db psql -U maild -d mcp -q -c "UPDATE domain_policy SET allowed=true WHERE domain='$DOMAIN'" > /dev/null 2>&1 || true ;;
                f) dcx db psql -U maild -d mcp -q -c "UPDATE domain_policy SET allowed=false WHERE domain='$DOMAIN'" > /dev/null 2>&1 || true ;;
                *) dcx db psql -U maild -d mcp -q -c "DELETE FROM domain_policy WHERE domain='$DOMAIN'" > /dev/null 2>&1 || true ;;
            esac
            for k_box in "alice@$DOMAIN" "bob@$DOMAIN" "dylan@$DOMAIN" "$DEPLOY_ADMIN" ; do
                dcx mda doveadm expunge -u "$k_box" mailbox INBOX header From "MailD MCP" > /dev/null 2>&1 || true
            done
        fi
        # Phase I (AdminNG): test devices (sessions cascade) and the fixture domain.
        dcx api adminng.py --reset-ratelimit 'nobody@adminng-lockout.test' > /dev/null 2>&1 || true
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
# from an image default. Four signals: an untouched default (mda), an override (mua's
# BANNER_TITLE, set in env.dev), a baked peer hostname the env file never mentions (mta)
# and the baked F-07 tarpit delay (mta's SMTP_TARPIT_DELAY).
if [ "$HAVE_DC" = 1 ] ; then
    ENV_WHY=""
    [ "$(dcx mda printenv DEFAULT_MAILBOX_SIZE 2>/dev/null | tr -d '\r\n')" = "200M" ] ||
        ENV_WHY="$ENV_WHY mda-image-default(DEFAULT_MAILBOX_SIZE);"
    [ "$(dcx mua printenv BANNER_TITLE 2>/dev/null | tr -d '\r\n')" = "MailD Dev Override" ] ||
        ENV_WHY="$ENV_WHY env.dev-override(BANNER_TITLE);"
    [ "$(dcx mta printenv AMAVIS 2>/dev/null | tr -d '\r\n')" = "amavis" ] ||
        ENV_WHY="$ENV_WHY mta-image-default(AMAVIS);"
    [ "$(dcx mta printenv SMTP_TARPIT_DELAY 2>/dev/null | tr -d '\r\n')" = "2" ] ||
        ENV_WHY="$ENV_WHY mta-image-default(SMTP_TARPIT_DELAY);"
    if [ -n "$ENV_WHY" ] ; then
        t_fail "image ENV defaults are baked and env.dev overrides win (${ENV_WHY# })"
    else
        t_ok "image ENV defaults are baked and env.dev overrides win (BANNER_TITLE)"
    fi
else
    t_skip "env schema checks (docker compose is needed to read the container environment)"
fi

# M-05 (2026-10 audit) — static: in every production compose file only the three ingress
# services may be routed by Traefik; every other service is labelled traefik.enable=false
# (a stock Traefik has exposedByDefault=true and would publish the raw api otherwise).
TRAEFIK_WHY=""
for PF in docker-compose.yml compose-github.yml compose-gitlab.yml ; do
    TRAEFIK_WHY="$TRAEFIK_WHY$(awk -v f="$PF" '
        /^services:/ { s = 1; next }
        s && /^  [a-z-]+:$/ { if (svc != "") chk(); svc = $1; sub(":", "", svc); en = "" ; next }
        s && /traefik\.enable=/ { en = ($0 ~ /enable=true/) ? "true" : "false" }
        function chk() {
            want = (svc == "adminng" || svc == "mua" || svc == "mcp") ? "true" : "false"
            if (en != want) printf " %s:%s=%s", f, svc, (en == "" ? "unset" : en)
        }
        END { if (svc != "") chk() }' "$SCRIPT_DIR/$PF")"
done
if [ -z "$TRAEFIK_WHY" ] ; then
    t_ok "production compose files: only adminng/mua/mcp are Traefik-routed, every other service traefik.enable=false"
else
    t_fail "production compose Traefik labels:$TRAEFIK_WHY"
fi

# M-06 (2026-10 audit) — cron gets an allow-list, never the whole operator env file, and
# the /etc/environment its jobs source is root-only (it holds POSTGRES_PASSWORD)
if [ "$HAVE_DC" = 1 ] ; then
    CRON_ENV_MODE="$(dcx cron stat -c %a /etc/environment 2>/dev/null | tr -d '\r\n')"
    CRON_LEAK="$(dcx cron sh -c 'grep -oE "^(ADMINNG_SECRET_KEY|MCP_SECRET_KEY|MCP_DB_PASSWORD|MCP_DOVECOT_MASTER_PASSWORD|POSTFIXADMIN_SETUP_PASSWORD)=" /etc/environment; env | grep -oE "^(ADMINNG_SECRET_KEY|MCP_SECRET_KEY|MCP_DB_PASSWORD|MCP_DOVECOT_MASTER_PASSWORD|POSTFIXADMIN_SETUP_PASSWORD)="' 2>/dev/null | tr -d '\r' | sort -u | xargs)"
    CRON_PW_COPIES="$(dcx cron grep -c '^POSTGRES_PASSWORD=' /etc/environment 2>/dev/null | tr -d '\r\n')"
    CRON_MX="$(dcx cron printenv MX_HOSTNAME 2>/dev/null | tr -d '\r\n')"
    if [ "$CRON_ENV_MODE" = 600 ] && [ -z "$CRON_LEAK" ] && [ "$CRON_PW_COPIES" = 1 ] &&
       [ -n "$CRON_MX" ] ; then
        t_ok "cron: allow-listed env only (no foreign secrets), /etc/environment mode 600 with one copy, operator tunables pass through (MX_HOSTNAME)"
    else
        t_fail "cron env (mode=$CRON_ENV_MODE leaks='$CRON_LEAK' pw_copies=$CRON_PW_COPIES MX_HOSTNAME='$CRON_MX')"
    fi
fi

# M-03 (2026-10 audit) — the SnappyMail admin panel shares the public webmail host, so it is
# off unless MUA_ADMIN_PANEL=on: /?admin answers 403 while the webmail itself still serves
MUA_ADMIN_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$SERVER:8081/?admin")"
MUA_HOME_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$SERVER:8081/")"
if [ "$MUA_ADMIN_CODE" = 403 ] && [ "$MUA_HOME_CODE" = 200 ] ; then
    t_ok "webmail admin panel is disabled by default (/?admin 403, webmail 200)"
else
    t_fail "webmail admin panel exposure (/?admin=$MUA_ADMIN_CODE, /=$MUA_HOME_CODE; want 403/200)"
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
# External sender on purpose: a local sender is refused earlier by
# reject_unauthenticated_sender_login_mismatch with a 553 ("not logged in"), which
# would let this check pass without ever exercising reject_unlisted_recipient
# (the path audit F-07 is about).
NOSUCH="no-such-user-$RANDOM$RANDOM"
swx -s "$SERVER" --protocol SMTP -t "$NOSUCH@$DOMAIN" -f "$FROM" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 25 refuses mail for a non-existent local user"
else
    t_fail "port 25 refuses mail for a non-existent local user (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A7 — port 25 refuses a bad local recipient (external sender, same reason as A6)
swx -s "$SERVER" --protocol SMTP -t "fake_account.mee@$DOMAIN" -f "$FROM" --header "Subject: $(chrono)"
if [ "$SW_RC" -eq 24 ] ; then
    t_ok "port 25 refuses unknown recipients"
else
    t_fail "port 25 refuses unknown recipients (rc=$SW_RC, want 24)" ; dump_swaks
fi

# A7b — F-07: the unknown-recipient 550 on :25 is tarpitted. The probe times ONLY the
# RCPT round trip (the suite's connect/DNS baseline would drown a wall-clock check) and
# uses an external sender so the reply really is the virtual-mailbox miss behind the
# sleep; the latency must reach the mta's configured delay.
TARPIT_DELAY="$(dcx mta printenv SMTP_TARPIT_DELAY 2>/dev/null | tr -d '\r\n')"
case "$TARPIT_DELAY" in ''|*[!0-9]*) TARPIT_DELAY=0 ;; esac
if [ "$TARPIT_DELAY" -eq 0 ] ; then
    t_skip "tarpit delay on :25 (SMTP_TARPIT_DELAY=0)"
elif ! command -v python3 > /dev/null 2>&1 ; then
    t_skip "tarpit delay on :25 (python3 is not installed)"
else
    cat > "$TMPRUN/rcpt_latency.py" <<'PY'
import socket, sys, time
host, port, sender, rcpt = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = socket.create_connection((host, port), timeout=20)
f = s.makefile("rb")
def line():
    while True:
        l = f.readline().decode("utf-8", "replace").rstrip("\r\n")
        if len(l) > 3 and l[3] == "-":
            continue
        return l
line()                                              # banner
s.sendall(b"EHLO probe.local\r\n"); line()          # ehlo
s.sendall(("MAIL FROM:<%s>\r\n" % sender).encode())
m = line()
if not m.startswith("250"):
    print("MAILFAIL: %s" % m); sys.exit(2)
t0 = time.monotonic()
s.sendall(("RCPT TO:<%s>\r\n" % rcpt).encode())
r = line()
ms = int((time.monotonic() - t0) * 1000)
s.sendall(b"QUIT\r\n")
print("%d %s" % (ms, r))
PY
    _OUT="$(python3 "$TMPRUN/rcpt_latency.py" "$SERVER" 25 "$FROM" \
            "tarpit.probe.$RANDOM$RANDOM@$DOMAIN" 2>&1)"
    _MS="${_OUT%% *}"; _REPLY="${_OUT#* }"
    case "$_MS" in ''|*[!0-9]*) _MS=0 ;; esac
    # 250ms slack: the sleep itself is exact, the reply may arrive a hair early on a
    # signal; anything below the delay minus slack means the tarpit is not running.
    if [ "$_MS" -ge $((TARPIT_DELAY * 1000 - 250)) ] && \
       printf '%s' "$_REPLY" | grep -q "User unknown in virtual mailbox table" ; then
        t_ok "port 25 tarpits the unknown-recipient 550 (RCPT took ${_MS}ms, delay ${TARPIT_DELAY}s)"
    else
        t_fail "port 25 tarpits the unknown-recipient 550 (RCPT took ${_MS}ms, want >= $((TARPIT_DELAY * 1000 - 250))ms; reply: ${_REPLY})"
    fi
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

# A14 — F-12: submission/smtps consult the per-user outbound rate-limit policy daemon,
# fail-open (DUNNO when it is down) and actually listening.
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "outbound rate-limit policy wiring ($DC_NEEDED)"
else
    RATE_WHY=""
    for SVC in submission smtps ; do
        MCFL="$(dcx mta postconf -M "$SVC/inet" 2>/dev/null | tr -d '\r')"
        case "$MCFL" in
            *"check_policy_service inet:127.0.0.1:12341"*) : ;;
            *) RATE_WHY="$RATE_WHY $SVC-no-policy-service;" ;;
        esac
        case "$MCFL" in
            *"smtpd_policy_service_default_action=DUNNO"*) : ;;
            *) RATE_WHY="$RATE_WHY $SVC-no-fail-open;" ;;
        esac
    done
    dcx mta python3 -c 'import socket; socket.create_connection(("127.0.0.1", 12341), 3).close()' \
        2>/dev/null || RATE_WHY="$RATE_WHY daemon-not-listening;"
    if [ -z "$RATE_WHY" ] ; then
        t_ok "submission and smtps consult the outbound rate-limit daemon (fail-open, listening)"
    else
        t_fail "submission and smtps consult the outbound rate-limit daemon (${RATE_WHY# })"
    fi
fi

# A15/A16 — F-12 functional probes of the live ratelimitd, speaking the policy protocol
# directly (the same wire Postfix uses): a synthetic user must hit the limit exactly and
# an exempt account must bypass it from any "IP". The synthetic user burns counters that
# belong to nobody, so the suite's real submission traffic is never throttled.
RL_LIMIT="$(dcx mta printenv OUTBOUND_RATE_RECIPIENTS 2>/dev/null | tr -d '\r\n')"
case "$RL_LIMIT" in ''|*[!0-9]*) RL_LIMIT=0 ;; esac
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "outbound rate-limit daemon behaviour ($DC_NEEDED)"
elif [ "$RL_LIMIT" -le 0 ] ; then
    t_skip "outbound rate-limit daemon behaviour (OUTBOUND_RATE_RECIPIENTS=0)"
else
    cat > "$TMPRUN/rl_probe.py" <<'PY'
import socket, sys
user, limit = sys.argv[1], int(sys.argv[2])
s = socket.create_connection(("127.0.0.1", 12341), 10)
f = s.makefile("rwb")
dunno = throttled = 0
first_thr = None
bad = []
for i in range(limit + 2):
    f.write(("request=smtpd_rcpt\nclient_address=203.0.113.7\n"
             "client_name=probe.example.net\nsender=probe@example.org\n"
             "recipient=rcpt-%d@example.net\nsasl_method=PLAIN\n"
             "sasl_username=%s\n\n" % (i, user)).encode())
    f.flush()
    act = ""
    while True:
        line = f.readline()
        if not line:
            bad.append("eof-before-action")
            break
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if not line:
            break
        if line.startswith("action="):
            act = line[7:]
    if act == "DUNNO":
        dunno += 1
    elif act.startswith("450"):
        throttled += 1
        if first_thr is None:
            first_thr = i + 1
    elif act:
        bad.append(act)
print("%d %d %s %s" % (dunno, throttled,
                       first_thr if first_thr is not None else "-", ";".join(bad[:2])))
PY
    RL_PROBE="rl-probe-$RANDOM$RANDOM@$DOMAIN"
    RL_OUT="$(dcx mta python3 - "$RL_PROBE" "$RL_LIMIT" < "$TMPRUN/rl_probe.py" 2>&1)"
    set -- $RL_OUT
    if [ "$1" = "$RL_LIMIT" ] && [ "$2" = "2" ] && [ "$3" = "$((RL_LIMIT + 1))" ] ; then
        t_ok "ratelimitd defers past the per-user limit (DUNNO x$1, then 450 at #$3)"
    else
        t_fail "ratelimitd defers past the per-user limit (want DUNNO x$RL_LIMIT then 450, got: $RL_OUT)"
    fi

    RL_EXEMPT="$(dcx mta printenv OUTBOUND_RATE_EXEMPT_USERS 2>/dev/null | tr -d '\r' | cut -d, -f1)"
    if [ -z "$RL_EXEMPT" ] ; then
        t_skip "ratelimitd exempt-account bypass (OUTBOUND_RATE_EXEMPT_USERS is empty)"
    else
        RL_OUT="$(dcx mta python3 - "$RL_EXEMPT" "$RL_LIMIT" < "$TMPRUN/rl_probe.py" 2>&1)"
        set -- $RL_OUT
        if [ "$1" = "$((RL_LIMIT + 2))" ] && [ "$2" = "0" ] ; then
            t_ok "ratelimitd exempts $RL_EXEMPT from any client (DUNNO x$1, no throttle)"
        else
            t_fail "ratelimitd exempts $RL_EXEMPT from any client (want DUNNO x$((RL_LIMIT + 2)), got: $RL_OUT)"
        fi
    fi
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

# B2b — M-01 (2026-10 audit): the MX port never offers AUTH, not even after STARTTLS (the
# old postscreen command filter never saw the post-TLS AUTH); 587 still does
swx -s "$SERVER" -p 25 -tls --quit-after EHLO
B2B_25="$(grep -cE '^<~? *250[- ]AUTH' "$SW_LOG")"
swx -s "$SERVER" -p 587 -tls --quit-after EHLO
B2B_587="$(grep -cE '^<~? *250[- ]AUTH' "$SW_LOG")"
if [ "$B2B_25" = 0 ] && [ "$B2B_587" -ge 1 ] ; then
    t_ok "port 25 advertises no AUTH even after STARTTLS; 587 still does"
else
    t_fail "AUTH advertisement (port 25: $B2B_25 AUTH line(s), want 0; port 587: $B2B_587, want ≥1)"
fi

# B2c — M-01: anvil throttles SASL attempts (every smtpd) and submission connections
# (587/465 only, never :25) per client IP — the image defaults reach the live config
if [ "$HAVE_DC" = 1 ] ; then
    B2C_AUTH="$(dcx mta postconf -h smtpd_client_auth_rate_limit 2>/dev/null | tr -d '\r\n')"
    B2C_CONN="$(dcx mta postconf -P submission/inet/smtpd_client_connection_rate_limit smtps/inet/smtpd_client_connection_rate_limit 2>/dev/null | awk -F' = ' '{print $2}' | xargs)"
    B2C_25="$(dcx mta postconf -h smtpd_client_connection_rate_limit 2>/dev/null | tr -d '\r\n')"
    if [ "$B2C_AUTH" = 60 ] && [ "$B2C_CONN" = "60 60" ] && [ "$B2C_25" = 0 ] ; then
        t_ok "SASL throttle: 60 AUTH/min per IP, 60 connections/min on 587/465, :25 unthrottled"
    else
        t_fail "SASL throttle (auth=$B2C_AUTH, 587/465 conn='$B2C_CONN', global conn=$B2C_25; want 60, '60 60', 0)"
    fi
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

# C2b — fan-out alias (goto "alice,bob" lands in both INBOXes; bob is always a
# provisioned fixture mailbox, second after alice in TEST_USERS)
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "fan-out alias ($DC_NEEDED)"
else
    FANOUT="fanout@$DOMAIN"
    SECONDMAIL="bob@$DOMAIN"
    sql "INSERT INTO alias (address, goto, domain, active)
         VALUES ('$FANOUT', '$ADMINMAIL,$SECONDMAIL', '$DOMAIN', true)
         ON CONFLICT (address) DO UPDATE SET goto = '$ADMINMAIL,$SECONDMAIL', active = true;" \
        > /dev/null 2>&1
    F="$(chrono)"
    swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
        -t "$FANOUT" -f "$ADMINMAIL" --header "Subject: $F"
    if [ "$SW_RC" -eq 0 ] && wait_msg "$ADMINMAIL" INBOX "$F" && wait_msg "$SECONDMAIL" INBOX "$F" ; then
        t_ok "a fan-out goto delivers to every recipient (1→N)"
    else
        t_fail "fan-out alias delivery (rc=$SW_RC)" ; dump_swaks
    fi
    sql "DELETE FROM alias WHERE address = '$FANOUT';" > /dev/null 2>&1
fi

# C2c — PostfixAdmin alias domain: preserve the local part onto the target domain,
# then ensure an inactive alias-domain row is not accepted at RCPT.
if [ "$HAVE_DC" != 1 ] ; then
    t_skip "domain alias routing ($DC_NEEDED)"
else
    DOMAIN_ALIAS_TEST="aliasroute-$DOMAIN"
    DOMAIN_ALIAS_USER="${ADMINMAIL%%@*}"
    sql "INSERT INTO domain
            (domain, description, aliases, mailboxes, maxquota, quota, transport, backupmx, active)
        VALUES ('$DOMAIN_ALIAS_TEST', 'test.sh alias domain', 0, 0, 0, 0, 'virtual', false, true)
        ON CONFLICT (domain) DO UPDATE SET active = true;" > /dev/null 2>&1
    sql "INSERT INTO alias_domain (alias_domain, target_domain, active)
        VALUES ('$DOMAIN_ALIAS_TEST', '$DOMAIN', true)
        ON CONFLICT (alias_domain) DO UPDATE SET target_domain = '$DOMAIN', active = true;" \
        > /dev/null 2>&1
    F="$(chrono)"
    swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
       -t "$DOMAIN_ALIAS_USER@$DOMAIN_ALIAS_TEST" -f "$ADMINMAIL" --header "Subject: $F"
    if [ "$SW_RC" -eq 0 ] && wait_msg "$ADMINMAIL" INBOX "$F" ; then
       t_ok "domain alias $DOMAIN_ALIAS_TEST preserves the local part and delivers to $DOMAIN"
    else
       t_fail "domain alias routing (rc=$SW_RC)" ; dump_swaks
    fi
    sql "UPDATE alias_domain SET active = false WHERE alias_domain = '$DOMAIN_ALIAS_TEST';" \
       > /dev/null 2>&1
    swx -s "$SERVER" -p 587 -tls -a PLAIN -au "$ADMINMAIL" -ap "$PASS" \
       -t "$DOMAIN_ALIAS_USER@$DOMAIN_ALIAS_TEST" -f "$ADMINMAIL" --header "Subject: $(chrono)"
    if [ "$SW_RC" -ne 0 ] && grep -Eq ' 550| 553' "$SW_LOG" ; then
       t_ok "inactive domain alias $DOMAIN_ALIAS_TEST is refused at RCPT"
    else
       t_fail "inactive domain alias is refused (rc=$SW_RC)" ; dump_swaks
    fi
    sql "DELETE FROM alias_domain WHERE alias_domain = '$DOMAIN_ALIAS_TEST';
        DELETE FROM domain WHERE domain = '$DOMAIN_ALIAS_TEST';" > /dev/null 2>&1
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

    # G4c — and the MailD MCP database (accounts, tokens, settings), when the MCP is deployed
    if [ -z "$(env_value "$ENV_FILE" MCP_DB_PASSWORD || true)" ] ; then
        t_skip "the MCP archive (MCP_DB_PASSWORD not set in $ENV_FILE: no MCP deployed)"
    else
        BK_MNEW="$(dcx cron sh -c 'ls -1t /backups/db/maild_mcp_*.sql.gz 2>/dev/null | head -n1' | tr -d '\r')"
        if [ -z "$BK_MNEW" ] ; then
            t_fail "the run also writes the MCP archive (maild_mcp_*.sql.gz)"
        elif ! dcx cron gzip -t "$BK_MNEW" 2>/dev/null ; then
            t_fail "the MCP archive passes 'gzip -t' ($BK_MNEW)"
        elif dcx cron sh -c "zcat '$BK_MNEW' | grep -q 'CREATE TABLE public.admin_user'" &&
             dcx cron sh -c "zcat '$BK_MNEW' | grep -q '^-- PostgreSQL database dump complete\$'" ; then
            t_ok "the same run also dumps the MCP database (admin_user + trailer present)"
        else
            t_fail "the MCP archive carries the mcp schema (no admin_user / trailer)"
        fi
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

    # -------------------------------------------- outbound volume watch job (F-12) --
    # outbound_watch.sh (cron, hourly at :23) reads the same materialised syslog: per-user
    # submission volume from the sasl_username= attached to queue-id from= lines, plus the
    # ratelimitd "maild-ratelimit: throttled" events, and mails the admin an [ALERT] past
    # OUTBOUND_ALERT_MESSAGES (or for a throttle engagement), at most once per user per day
    # (marker in /tmp). The spike user seeded below is synthetic, so the counters it burns
    # belong to nobody; and because the syslog only holds THIS run's traffic, no real
    # fixture user can cross the threshold during the suite.
    if ! dcx cron sh -c 'grep -q "^23 \* \* \* .*outbound_watch\.sh" /etc/crontab' ; then
        t_fail "G12 the outbound volume watch job is scheduled in the cron crontab (no hourly outbound_watch.sh entry)"
    else
        t_ok "G12 the outbound volume watch job is scheduled hourly in the cron crontab"
    fi

    OW_SUBJECT="[ALERT] MailD outbound volume"
    OW_THRESHOLD="$(dcx cron printenv OUTBOUND_ALERT_MESSAGES 2>/dev/null | tr -d '\r')"
    case "$OW_THRESHOLD" in ''|*[!0-9]*) OW_THRESHOLD=150 ;; esac
    OW_USER="rl-spike-$RANDOM$RANDOM@example.net"
    OW_SPIKE=$((OW_THRESHOLD + 5))
    dcx cron sh -c 'rm -f /tmp/maild-outbound-alerted-*' > /dev/null 2>&1 || true

    if [ "$RES_SEEDED" != 1 ] ; then
        t_skip "outbound_watch.sh alert behaviour (no materialised syslog to seed)"
    else
        # G13 — seed the over-threshold volume + a throttle engagement, run the job, and
        # expect the [ALERT] to reach the admin's inbox naming both.
        OW_STAMP="$(dcx cron date +'%b %e %H:%M:%S' 2>/dev/null | tr -d '\r')"
        OW_TMP="$(mktemp)"
        for i in $(seq 1 "$OW_SPIKE") ; do
            echo "${OW_STAMP} $(hostname) maild-mta: postfix/submission/smtpd[9999]: 00000000${i}: from=<${OW_USER}>, size=1024, nrcpts=1, queue-id=00000000${i}, proto=ESMTP, sasl_username=${OW_USER}" >> "$OW_TMP"
        done
        echo "${OW_STAMP} $(hostname) maild-mta: maild-ratelimit: throttled user=${OW_USER} count=$((OW_SPIKE + 1)) limit=${OW_THRESHOLD} window=3600s recipient=rcpt@example.net" >> "$OW_TMP"
        dcx cron sh -c 'cat >> /var/log/syslog' < "$OW_TMP" || true
        rm -f "$OW_TMP"

        OW_BEFORE="$(subj_count "$DEPLOY_ADMIN" INBOX "$OW_SUBJECT")"
        timeout -k10 120 "${DC[@]}" exec -T cron /scripts/outbound_watch.sh > "$TMPRUN/ow.log" 2>&1
        OW_RC=$?
        if [ "$OW_RC" -ne 0 ] ; then
            t_fail "G13 outbound_watch.sh runs to completion with a seeded spike (rc=$OW_RC)"
            info "$(tail -n 10 "$TMPRUN/ow.log" | sed 's/^/        /')"
        elif ! wait_subj_count_gt "$DEPLOY_ADMIN" INBOX "$OW_SUBJECT" "${OW_BEFORE:-0}" 240 ; then
            t_fail "G13 the outbound alert was delivered to $DEPLOY_ADMIN's INBOX (still $(subj_count "$DEPLOY_ADMIN" INBOX "$OW_SUBJECT") match(es), had ${OW_BEFORE:-0})"
            info "$(tail -n 10 "$TMPRUN/ow.log" | sed 's/^/        /')"
        else
            OW_UID="$(msg_newest_uid "$DEPLOY_ADMIN" INBOX "$OW_SUBJECT")"
            msg_text "$DEPLOY_ADMIN" INBOX "${OW_UID:-0}" > "$TMPRUN/ow-mail.txt" 2>&1
            if grep -qF "$OW_USER" "$TMPRUN/ow-mail.txt" && \
               grep -q 'maild-ratelimit: throttled' "$TMPRUN/ow-mail.txt" ; then
                t_ok "G13 the outbound alert names the over-threshold user and the throttle engagement"
            else
                t_fail "G13 the outbound alert names the over-threshold user and the throttle engagement (body incomplete)"
                info "$(sed -n '/^$/,$p' "$TMPRUN/ow-mail.txt" | sed -n '1,14p' | sed 's/^/        /')"
            fi
        fi

        # G14 — once per user per day (marker) and the ignore list: after clearing just
        # the spike's marker entry, a re-run must stay silent by the marker, and a run
        # with the user on OUTBOUND_ALERT_IGNORE_USERS must stay silent by the list.
        timeout -k10 120 "${DC[@]}" exec -T cron /scripts/outbound_watch.sh > "$TMPRUN/ow2.log" 2>&1
        OW_RC2=$?
        dcx cron sh -c "sed -i '/^${OW_USER}\$/d' /tmp/maild-outbound-alerted-* 2>/dev/null" || true
        timeout -k10 120 "${DC[@]}" exec -T cron sh -c \
            "OUTBOUND_ALERT_IGNORE_USERS=${OW_USER} /scripts/outbound_watch.sh" > "$TMPRUN/ow3.log" 2>&1
        OW_RC3=$?
        if [ "$OW_RC2" -eq 0 ] && grep -q 'no new outbound alerts' "$TMPRUN/ow2.log" && \
           [ "$OW_RC3" -eq 0 ] && grep -q 'no new outbound alerts' "$TMPRUN/ow3.log" ; then
            t_ok "G14 the outbound alert fires once per user per day and honours the ignore list"
        else
            t_fail "G14 the outbound alert fires once per user per day and honours the ignore list (rc=$OW_RC2/$OW_RC3)"
            info "$(tail -n 4 "$TMPRUN/ow2.log" "$TMPRUN/ow3.log" | sed 's/^/        /')"
        fi

        # G14b — mail sent through the MailD MCP enters at amavis:10026, skipping Postfix SASL: its
        # "maild-mcp: sent user=…" lines count toward the same daily total, and its own limiter's
        # "maild-mcp: throttled" line is reported like ratelimitd's (P2, proposal §9.3).
        OW_MCP_USER="mcp-spike-$RANDOM$RANDOM@example.net"
        OW_TMP="$(mktemp)"
        for i in $(seq 1 "$OW_SPIKE") ; do
            echo "${OW_STAMP} $(hostname) maild-mcp: mcp: INFO - maild-mcp: sent user=${OW_MCP_USER} rcpts=1 token=0000000000000000" >> "$OW_TMP"
        done
        echo "${OW_STAMP} $(hostname) maild-mcp: mcp: WARNING - maild-mcp: throttled user=${OW_MCP_USER} rcpts=3 token=0000000000000000" >> "$OW_TMP"
        dcx cron sh -c 'cat >> /var/log/syslog' < "$OW_TMP" || true
        rm -f "$OW_TMP"
        OW_BEFORE="$(subj_count "$DEPLOY_ADMIN" INBOX "$OW_SUBJECT")"
        timeout -k10 120 "${DC[@]}" exec -T cron /scripts/outbound_watch.sh > "$TMPRUN/ow4.log" 2>&1
        if wait_subj_count_gt "$DEPLOY_ADMIN" INBOX "$OW_SUBJECT" "${OW_BEFORE:-0}" 240 ; then
            OW_UID="$(msg_newest_uid "$DEPLOY_ADMIN" INBOX "$OW_SUBJECT")"
            msg_text "$DEPLOY_ADMIN" INBOX "${OW_UID:-0}" > "$TMPRUN/ow-mail4.txt" 2>&1
        fi
        if grep -qF "${OW_MCP_USER}: ${OW_SPIKE} message(s)" "$TMPRUN/ow-mail4.txt" 2>/dev/null && \
           grep -q 'maild-mcp: throttled' "$TMPRUN/ow-mail4.txt" ; then
            t_ok "G14b MCP sends count toward the outbound alert and the MCP limiter's throttle lines are reported"
        else
            t_fail "G14b the outbound alert counts MCP sends (expected '${OW_MCP_USER}: ${OW_SPIKE} message(s)' + the MCP throttle line)"
            info "$(tail -n 4 "$TMPRUN/ow4.log" | sed 's/^/        /')"
        fi
    fi
    dcx cron sh -c 'rm -f /tmp/maild-outbound-alerted-*' > /dev/null 2>&1 || true

    if [ "$RES_SEEDED" = 1 ] ; then
        info "the materialised /var/log/syslog is removed from the cron container on exit"
    fi
    # ------------------------------------------------ daily DNS health check ---
    # check_dns.sh (cron, `20 04 * * *`) verifies what the OUTSIDE world sees for every
    # active domain (MX, SPF, DMARC, DKIM against the keys Amavis really signs with,
    # PTR/FCrDNS, MTA-STS/TLS-RPT when published, blocklists) and mails the admin only when
    # a finding reaches DNS_CHECK_ALERT_LEVEL — silence is the success signal. The answers
    # below come from a fixture tree pushed into the cron container (`--fixture-dir`: one
    # `<TYPE>.<name>` file per answer holding raw `host` output, a missing file = NXDOMAIN),
    # so nothing here depends on the public DNS or on the fictitious dev domains.
    if ! dcx cron sh -c 'grep -q "^20 04 \* \* \* .*check_dns\.sh" /etc/crontab' ; then
        t_fail "G15 the DNS health check is scheduled in the cron crontab (no 04:20 check_dns.sh entry)"
    else
        t_ok "G15 the DNS health check is scheduled daily at 04:20 in the cron crontab"
    fi

    # read the environment the jobs source (the entrypoint restores the image defaults there;
    # a bare `docker exec printenv` sees the compose allow-list, which unsets them — M-06)
    DNS_GATE="$(dcx cron sh -c '. /etc/environment; printf %s "$DNS_CHECK_ALERT_LEVEL"' 2>/dev/null | tr -d '\r')"
    if dcx cron test -r /var/lib/amavis/dkim/db.txt && [ -n "$DNS_GATE" ] ; then
        t_ok "G16 the cron container reads the amavis DKIM keys (read-only mount) and carries the DNS_CHECK_* defaults (gate=$DNS_GATE)"
    else
        t_fail "G16 the cron container reads the amavis DKIM keys and carries the DNS_CHECK_* defaults (db.txt readable? gate='${DNS_GATE}': without the mount the DKIM comparison degrades to a notice)"
    fi

    DNS_DOM_OK=good.example
    DNS_DOM_BAD=broken.example
    DNS_SUBJ="[ALERT] MailD DNS health"
    DNSFIX="$TMPRUN/dnsfix"
    rm -rf "$DNSFIX" ; mkdir -p "$DNSFIX"
    dnsfix() { printf '%s\n' "$3" > "$DNSFIX/$1.$2" ; }
    # a healthy domain: delegated, one MX that resolves, SPF "mx -all", DMARC reject with a
    # routed rua, matching PTR/FCrDNS, no optional records and clean blocklists
    dnsfix SOA "$DNS_DOM_OK" "$DNS_DOM_OK has SOA record ns1.$DNS_DOM_OK. hostmaster.$DNS_DOM_OK. 2026010101 3600 600 604800 300"
    dnsfix NS "$DNS_DOM_OK" "$DNS_DOM_OK name server ns1.$DNS_DOM_OK."
    dnsfix MX "$DNS_DOM_OK" "$DNS_DOM_OK mail is handled by 10 mta.$DNS_DOM_OK."
    dnsfix CNAME "mta.$DNS_DOM_OK" "mta.$DNS_DOM_OK has no CNAME record"
    dnsfix A "mta.$DNS_DOM_OK" "mta.$DNS_DOM_OK has address 203.0.113.10."
    dnsfix AAAA "mta.$DNS_DOM_OK" "mta.$DNS_DOM_OK has no IPv6 address"
    dnsfix TXT "$DNS_DOM_OK" "$DNS_DOM_OK descriptive text \"v=spf1 mx -all\""
    dnsfix TXT "_dmarc.$DNS_DOM_OK" "_dmarc.$DNS_DOM_OK descriptive text \"v=DMARC1; p=reject; rua=mailto:postmaster@$DNS_DOM_OK\""
    dnsfix CNAME "_dmarc.$DNS_DOM_OK" "_dmarc.$DNS_DOM_OK has no CNAME record"
    dnsfix PTR 10.113.0.203.in-addr.arpa "10.113.0.203.in-addr.arpa domain name pointer mta.$DNS_DOM_OK."
    dnsfix TXT "_mta-sts.$DNS_DOM_OK" "_mta-sts.$DNS_DOM_OK has no TXT record"
    dnsfix A "mta-sts.$DNS_DOM_OK" "mta-sts.$DNS_DOM_OK has no A record"
    dnsfix AAAA "mta-sts.$DNS_DOM_OK" "mta-sts.$DNS_DOM_OK has no IPv6 address"
    dnsfix TXT "_smtp._tls.$DNS_DOM_OK" "_smtp._tls.$DNS_DOM_OK has no TXT record"
    dnsfix A "$DNS_DOM_OK.multi.surbl.org" "$DNS_DOM_OK.multi.surbl.org has no A record"
    dnsfix A 10.113.0.203.zen.spamhaus.org "10.113.0.203.zen.spamhaus.org has no A record"
    # a broken domain: MX on a foreign host, SPF +all, no DMARC, a PTR that does not confirm
    # forward, listed on the domain blocklist and a "refused" answer on the IP blocklist
    dnsfix SOA "$DNS_DOM_BAD" "$DNS_DOM_BAD has SOA record ns1.$DNS_DOM_BAD. hostmaster.$DNS_DOM_BAD. 1 3600 600 604800 300"
    dnsfix NS "$DNS_DOM_BAD" "$DNS_DOM_BAD name server ns1.$DNS_DOM_BAD."
    dnsfix MX "$DNS_DOM_BAD" "$DNS_DOM_BAD mail is handled by 10 mx.elsewhere.example."
    dnsfix CNAME mx.elsewhere.example "mx.elsewhere.example has no CNAME record"
    dnsfix A mx.elsewhere.example "mx.elsewhere.example has address 198.51.100.7."
    dnsfix AAAA mx.elsewhere.example "mx.elsewhere.example has no IPv6 address"
    dnsfix TXT "$DNS_DOM_BAD" "$DNS_DOM_BAD descriptive text \"v=spf1 +all\""
    dnsfix CNAME "_dmarc.$DNS_DOM_BAD" "_dmarc.$DNS_DOM_BAD has no CNAME record"
    dnsfix TXT "_dmarc.$DNS_DOM_BAD" "_dmarc.$DNS_DOM_BAD has no TXT record"
    dnsfix PTR 7.100.51.198.in-addr.arpa "7.100.51.198.in-addr.arpa domain name pointer host7.isp.example."
    dnsfix A host7.isp.example "host7.isp.example has address 198.51.100.8."
    dnsfix TXT "_mta-sts.$DNS_DOM_BAD" "_mta-sts.$DNS_DOM_BAD has no TXT record"
    dnsfix A "mta-sts.$DNS_DOM_BAD" "mta-sts.$DNS_DOM_BAD has no A record"
    dnsfix AAAA "mta-sts.$DNS_DOM_BAD" "mta-sts.$DNS_DOM_BAD has no IPv6 address"
    dnsfix TXT "_smtp._tls.$DNS_DOM_BAD" "_smtp._tls.$DNS_DOM_BAD has no TXT record"
    dnsfix A "$DNS_DOM_BAD.multi.surbl.org" "$DNS_DOM_BAD.multi.surbl.org has address 127.0.0.2."
    dnsfix A 7.100.51.198.zen.spamhaus.org "7.100.51.198.zen.spamhaus.org has address 127.255.255.254."
    tar -C "$DNSFIX" -cf - . | dcx cron sh -c 'rm -rf /tmp/dnsfix && mkdir -p /tmp/dnsfix && tar -C /tmp/dnsfix -xf -' || true

    DNS_MAIL_BEFORE="$(subj_count "$DEPLOY_ADMIN" INBOX "$DNS_SUBJ")"
    dcx cron /scripts/check_dns.sh --dry-run --fixture-dir /tmp/dnsfix \
        --domains "$DNS_DOM_OK" --mx-hostname "mta.$DNS_DOM_OK" > "$TMPRUN/dns-ok.log" 2>&1
    DNS_OK_RC=$?
    if [ "$DNS_OK_RC" -eq 0 ] && grep -q 'no findings at/above' "$TMPRUN/dns-ok.log" ; then
        t_ok "G17 check_dns.sh exits 0 and stays silent when every record of $DNS_DOM_OK is healthy"
    else
        t_fail "G17 check_dns.sh exits 0 and stays silent when every record is healthy (rc=$DNS_OK_RC)"
        info "$(grep -E 'MailD: dns check' "$TMPRUN/dns-ok.log" | tail -n 8 | sed 's/^/        /')"
    fi

    dcx cron /scripts/check_dns.sh --dry-run --fixture-dir /tmp/dnsfix \
        --domains "$DNS_DOM_OK" --mx-hostname '' > "$TMPRUN/dns-infer.log" 2>&1
    DNS_INFER_RC=$?
    if [ "$DNS_INFER_RC" -eq 0 ] && grep -q 'MX_HOSTNAME is unset' "$TMPRUN/dns-infer.log" ; then
        t_ok "G18 an unset MX_HOSTNAME degrades to the documented inference path (notice, exit 0, no mail)"
    else
        t_fail "G18 an unset MX_HOSTNAME degrades to the inference path (rc=$DNS_INFER_RC)"
        info "$(grep -E 'MailD: dns check' "$TMPRUN/dns-infer.log" | tail -n 8 | sed 's/^/        /')"
    fi

    dcx cron /scripts/check_dns.sh --fixture-dir /tmp/dnsfix \
        --domains "$DNS_DOM_BAD" --mx-hostname "mta.$DNS_DOM_OK" > "$TMPRUN/dns-bad.log" 2>&1
    DNS_BAD_RC=$?
    if [ "$DNS_BAD_RC" -eq 1 ] ; then
        t_ok "G19 check_dns.sh exits 1 and mails when $DNS_DOM_BAD has findings above the gate"
    else
        t_fail "G19 check_dns.sh exits 1 when there are findings above the gate (rc=$DNS_BAD_RC)"
        info "$(grep -E 'MailD: dns check' "$TMPRUN/dns-bad.log" | tail -n 8 | sed 's/^/        /')"
    fi

    if ! wait_subj_count_gt "$DEPLOY_ADMIN" INBOX "$DNS_SUBJ" "${DNS_MAIL_BEFORE:-0}" 240 ; then
        t_fail "G20 the DNS report reached $DEPLOY_ADMIN's INBOX through postmaster@$DEFAULT_DOMAIN (still $(subj_count "$DEPLOY_ADMIN" INBOX "$DNS_SUBJ") match(es), had ${DNS_MAIL_BEFORE:-0})"
        info "$(grep -E 'MailD: dns check' "$TMPRUN/dns-bad.log" | tail -n 6 | sed 's/^/        /')"
    else
        t_ok "G20 the DNS report reached $DEPLOY_ADMIN's INBOX through the postmaster@$DEFAULT_DOMAIN alias"
        DNS_UID="$(msg_newest_uid "$DEPLOY_ADMIN" INBOX "$DNS_SUBJ")"
        msg_text "$DEPLOY_ADMIN" INBOX "${DNS_UID:-0}" > "$TMPRUN/dns-mail.txt" 2>&1
        DNS_MISS=""
        grep -qF "$DNS_DOM_BAD" "$TMPRUN/dns-mail.txt" || DNS_MISS="$DNS_MISS domain-not-named;"
        grep -qF '+all' "$TMPRUN/dns-mail.txt" || DNS_MISS="$DNS_MISS spf-not-reported;"
        grep -qF 'mx.elsewhere.example' "$TMPRUN/dns-mail.txt" || DNS_MISS="$DNS_MISS mx-mismatch-not-reported;"
        grep -q 'blocklist' "$TMPRUN/dns-mail.txt" || DNS_MISS="$DNS_MISS blocklist-not-reported;"
        grep -q 'PTR' "$TMPRUN/dns-mail.txt" || DNS_MISS="$DNS_MISS ptr-not-reported;"
        if [ -z "$DNS_MISS" ] ; then
            t_ok "G21 the report names each broken record of $DNS_DOM_BAD (SPF +all, foreign MX, blocklist listing, PTR)"
        else
            t_fail "G21 the report names each broken record of $DNS_DOM_BAD (${DNS_MISS})"
            info "$(sed -n '/^Domain:/,$p' "$TMPRUN/dns-mail.txt" | head -n 20 | sed 's/^/        /')"
        fi
        if [ "$(grep -c 'impact' "$TMPRUN/dns-mail.txt")" -ge 3 ] && \
           [ "$(grep -c 'action' "$TMPRUN/dns-mail.txt")" -ge 3 ] ; then
            t_ok "G22 every reported finding carries a found/expected/impact/action block (recommendations, not just alarms)"
        else
            t_fail "G22 every reported finding carries a found/expected/impact/action block (impact=$(grep -c 'impact' "$TMPRUN/dns-mail.txt") action=$(grep -c 'action' "$TMPRUN/dns-mail.txt"))"
        fi
    fi

    if dcx cron /scripts/check_dns.sh --dry-run --domains none > "$TMPRUN/dns-off.log" 2>&1 && \
       grep -q 'disabled by DNS_CHECK_DOMAINS=none' "$TMPRUN/dns-off.log" ; then
        t_ok "G23 DNS_CHECK_DOMAINS=none disables the job without touching the catalogue (exit 0, no mail)"
    else
        t_fail "G23 DNS_CHECK_DOMAINS=none disables the job (see $TMPRUN/dns-off.log)"
        info "$(tail -n 4 "$TMPRUN/dns-off.log" | sed 's/^/        /')"
    fi
    dcx cron rm -rf /tmp/dnsfix > /dev/null 2>&1 || true

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
ADMINNG_DEVICE_3="aaaaaaaa-0000-4000-8000-0000000000a3"
# Client-minted secrets for the two fixture browsers (the server stores only
# sha256). Every device-scoped call must present the matching one.
ADMINNG_DEVICE_SECRET="testsh-device-secret-aaaaaaaa-0000-4000-8000-0000000000a1"
ADMINNG_DEVICE_SECRET_2="testsh-device-secret-aaaaaaaa-0000-4000-8000-0000000000a2"
ADMINNG_DEVICE_SECRET_3="testsh-device-secret-aaaaaaaa-0000-4000-8000-0000000000a3"
ADMIN_PW="${CRED[${DEPLOY_ADMIN,,}]:-}"
ADMINNG_TOKEN=""
ADMINNG_REFRESH=""

adminng_secret() { # <device-id> → the fixture secret for that browser
    case "$1" in
        "$ADMINNG_DEVICE")   printf '%s' "$ADMINNG_DEVICE_SECRET" ;;
        "$ADMINNG_DEVICE_2") printf '%s' "$ADMINNG_DEVICE_SECRET_2" ;;
        "$ADMINNG_DEVICE_3") printf '%s' "$ADMINNG_DEVICE_SECRET_3" ;;
        *)                   printf '' ;;
    esac
}

adminng_call() { # <method> <path> <device> <token> [json] [vtoken] → ADMINNG_CODE/ADMINNG_BODY
    local method="$1" path="$2" device="$3" token="$4" data="${5:-}" vtoken="${6:-}"
    local out="$TMPRUN/adminng.json" secret
    secret="$(adminng_secret "$device")"
    local args=(-s -o "$out" -w '%{http_code}' -X "$method" -H "X-Device-ID: $device")
    [ -n "$secret" ] && args+=(-H "X-Device-Secret: $secret")
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
        "DELETE FROM device WHERE device_id IN ('$ADMINNG_DEVICE','$ADMINNG_DEVICE_2','$ADMINNG_DEVICE_3');" \
        > /dev/null 2>&1 || true
    dcx db psql -U maild -d mailddb -q -c \
        "DELETE FROM alias WHERE domain='$ADMINNG_DOMAIN'; DELETE FROM domain_admins WHERE domain='$ADMINNG_DOMAIN'; DELETE FROM mailbox WHERE domain='$ADMINNG_DOMAIN'; DELETE FROM domain WHERE domain='$ADMINNG_DOMAIN';" \
        > /dev/null 2>&1 || true

    # I1 — no anonymous registration: a fresh browser is only written by a login
    # whose password verifies, and that login stays PENDING (audit F-11)
    adminng_call GET "/device/status?username=$DEPLOY_ADMIN" "$ADMINNG_DEVICE" ""
    I1_PRE="$ADMINNG_CODE"
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
        "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\",\"client_type\":\"web\",\"device_name\":\"test.sh\"}"
    if [ "$I1_PRE" = 404 ] && [ "$ADMINNG_CODE" = 403 ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q DEVICE_NOT_AUTHORIZED ; then
        t_ok "I1 a fresh browser (unknown to /device/status) is registered PENDING by a verified login"
    else
        t_fail "I1 device gate (status=$I1_PRE step1=$ADMINNG_CODE body=$(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi

    # I1b — only the secret holder may read the status; a wrong secret is a 404
    adminng_call GET "/device/status?username=$DEPLOY_ADMIN" "$ADMINNG_DEVICE" ""
    I1B_OK="$ADMINNG_CODE" ; I1B_BODY="$ADMINNG_BODY"
    ADMINNG_DEVICE_SECRET_SAVE="$ADMINNG_DEVICE_SECRET"
    ADMINNG_DEVICE_SECRET="aaaaaaaa-bogus-secret-bogus-0000000000000000"
    adminng_call GET "/device/status?username=$DEPLOY_ADMIN" "$ADMINNG_DEVICE" ""
    ADMINNG_DEVICE_SECRET="$ADMINNG_DEVICE_SECRET_SAVE"
    if [ "$I1B_OK" = 200 ] && printf '%s' "$I1B_BODY" | grep -q '"authorization_state":"PENDING"' &&
       printf '%s' "$I1B_BODY" | grep -q '"fingerprint":"' &&
       [ "$ADMINNG_CODE" = 404 ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q DEVICE_UNKNOWN ; then
        t_ok "I1b the status poll needs the secret (wrong secret → 404 DEVICE_UNKNOWN, no enumeration)"
    else
        t_fail "I1b status secret gate (ok=$I1B_OK wrong=$ADMINNG_CODE)"
    fi

    # I2 — CLI approval is device-scoped: it flips the browser to APPROVED
    dcx api adminng.py --approve-device "$ADMINNG_DEVICE" --user "$DEPLOY_ADMIN" > /dev/null 2>&1
    adminng_call GET "/device/status?username=$DEPLOY_ADMIN" "$ADMINNG_DEVICE" ""
    if printf '%s' "$ADMINNG_BODY" | grep -q APPROVED ; then
        t_ok "I2 the server-side CLI approval flips the device to APPROVED"
    else
        t_fail "I2 device approval (body=$(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi

    # I2b — a leaked device id alone is useless: a known browser presenting a
    # foreign secret is refused *before* the credentials are even read (the
    # password is deliberately wrong, yet the answer must stay 403, not 401)
    ADMINNG_DEVICE_SECRET_SAVE="$ADMINNG_DEVICE_SECRET"
    ADMINNG_DEVICE_SECRET="$ADMINNG_DEVICE_SECRET_2"
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
        "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"not-the-real-password\"}"
    ADMINNG_DEVICE_SECRET="$ADMINNG_DEVICE_SECRET_SAVE"
    if [ "$ADMINNG_CODE" = 403 ] && printf '%s' "$ADMINNG_BODY" | grep -q DEVICE_NOT_AUTHORIZED ; then
        t_ok "I2b a known device id with a foreign secret is refused before the password check"
    else
        t_fail "I2b foreign secret (got $ADMINNG_CODE: $(printf '%s' "$ADMINNG_BODY" | head -c 120))"
    fi

    # I3 — TOTP policy: superadmin must enroll on the first login
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
        "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\",\"remember\":true}"
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
            "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\",\"remember\":true}"
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
    # The enrollment step is allowed once for the login that follows, so the current
    # code must verify here (a retry with the next step covers a 30 s window edge).
    CODE="$(adminng_code "$DEPLOY_ADMIN")"
    adminng_call POST /auth/login-step2 "$ADMINNG_DEVICE" "" \
        "{\"flow_token\":\"$FLOW\",\"code\":\"$CODE\"}"
    if [ "$ADMINNG_CODE" != 200 ] ; then
        # replay/window guard: retry once with the next step
        FLOW="$(curl -s -X POST "$API_BASE/auth/login-step1" -H "X-Device-ID: $ADMINNG_DEVICE" \
            -H "X-Device-Secret: $ADMINNG_DEVICE_SECRET" \
            -H 'Content-Type: application/json' \
            --data "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\",\"remember\":true}" | adminng_jqf flow_token)"
        CODE="$(adminng_code "$DEPLOY_ADMIN" --next)"
        adminng_call POST /auth/login-step2 "$ADMINNG_DEVICE" "" \
            "{\"flow_token\":\"$FLOW\",\"code\":\"$CODE\"}"
    fi
    ADMINNG_TOKEN="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
    ADMINNG_REFRESH="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf refresh_token)"
    I4_LOGIN="$ADMINNG_BODY"
    REMEMBER_TTL="$(dcx api python -c 'from app import settings; print(settings.ADMINNG_REMEMBER_TTL)' 2>/dev/null | tr -d ' \r\n')"
    adminng_call GET /auth/me "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ -n "$ADMINNG_TOKEN" ] && [ -n "$ADMINNG_REFRESH" ] && [ -n "$REMEMBER_TTL" ] &&
       printf '%s' "$I4_LOGIN" | grep -q "\"remember\":true" &&
       printf '%s' "$I4_LOGIN" | grep -q "\"expires_in\":$REMEMBER_TTL" &&
       printf '%s' "$I4_LOGIN" | grep -q "\"idle_timeout\":$REMEMBER_TTL" &&
       printf '%s' "$ADMINNG_BODY" | grep -q '"superadmin":true' ; then
        t_ok "I4 remembered login carries its configured token and refresh idle TTL through TOTP"
    else
        t_fail "I4 step2/login (body=$(printf '%s' "$ADMINNG_BODY" | head -c 140))"
    fi
    # I4b — the secret is enforced on every authenticated call, not only at login
    ADMINNG_DEVICE_SECRET_SAVE="$ADMINNG_DEVICE_SECRET"
    ADMINNG_DEVICE_SECRET="$ADMINNG_DEVICE_SECRET_2"
    adminng_call GET /auth/me "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    ADMINNG_DEVICE_SECRET="$ADMINNG_DEVICE_SECRET_SAVE"
    if [ "$ADMINNG_CODE" = 403 ] && printf '%s' "$ADMINNG_BODY" | grep -q DEVICE_NOT_AUTHORIZED ; then
        t_ok "I4b an authenticated call with the wrong device secret is refused (403)"
    else
        t_fail "I4b authenticated secret gate (got $ADMINNG_CODE: $(printf '%s' "$ADMINNG_BODY" | head -c 120))"
    fi

    # I4c — the remembered login armed a fixed 24h window: the next login on this
    # (device, admin) is issued straight away, without asking for the code again
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
        "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\",\"remember\":true}"
    if [ "$ADMINNG_CODE" = 200 ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q '"session_state":"AUTHENTICATED"' ; then
        t_ok "I4c a remembered device skips the TOTP challenge on the next login"
    else
        t_fail "I4c remembered skip (get $ADMINNG_CODE: $(printf '%s' "$ADMINNG_BODY" | head -c 140))"
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
        t_ok "I6 the API-created mailbox logs into IMAPS immediately (Argon2id hash verified)"
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

    # I8b — alias-domain CRUD is scoped on both domain endpoints and audited.
    DOMAIN_ALIAS_API="alias-$ADMINNG_DOMAIN"
    adminng_call POST /domains "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"domain\":\"$DOMAIN_ALIAS_API\",\"description\":\"Alias domain test\"}"
    DOMAIN_ALIAS_SOURCE_CODE="$ADMINNG_CODE"
    adminng_call POST /domain-aliases "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"alias_domain\":\"$DOMAIN_ALIAS_API\",\"target_domain\":\"$ADMINNG_DOMAIN\"}"
    DOMAIN_ALIAS_CREATE_CODE="$ADMINNG_CODE"
    adminng_call GET "/domain-aliases?domain=$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    DOMAIN_ALIAS_LIST="$ADMINNG_BODY"
    adminng_call PUT "/domain-aliases/$DOMAIN_ALIAS_API" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        '{"active":false}'
    DOMAIN_ALIAS_UPDATE_CODE="$ADMINNG_CODE"
    adminng_call GET "/domain-aliases/$DOMAIN_ALIAS_API" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    DOMAIN_ALIAS_STATE="$ADMINNG_BODY"
    adminng_call GET "/domains/$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$DOMAIN_ALIAS_SOURCE_CODE" = 201 ] &&
       [ "$DOMAIN_ALIAS_CREATE_CODE" = 201 ] &&
       printf '%s' "$DOMAIN_ALIAS_LIST" | grep -q "\"alias_domain\":\"$DOMAIN_ALIAS_API\"" &&
       [ "$DOMAIN_ALIAS_UPDATE_CODE" = 200 ] &&
       printf '%s' "$DOMAIN_ALIAS_STATE" | grep -q '"active":false' &&
       printf '%s' "$ADMINNG_BODY" | grep -q '"alias_domains":1' ; then
        t_ok "I8b domain-alias CRUD lists both endpoints, counts target aliases and updates active state"
    else
        t_fail "I8b domain-alias API (source=$DOMAIN_ALIAS_SOURCE_CODE create=$DOMAIN_ALIAS_CREATE_CODE update=$DOMAIN_ALIAS_UPDATE_CODE)"
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
        t_ok "I10 remembered login still requires password re-auth + the armed confirm for DELETE"
    else
        t_fail "I10 re-auth negative (delete=$I10_NO token_len=${#SV})"
    fi

    # I11 — tenant isolation with a custom admin
    if [ "$(sql "SELECT superadmin FROM admin WHERE username='$ADMINMAIL'")" = "t" ] ; then
        t_skip "I11 tenant isolation (the fixture admin $ADMINMAIL is a superadmin)"
    else
        # The browser is approved once (device-scoped): the CLI needs no --user,
        # and any admin may then sign in from it.
        adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE_2" "" \
            "{\"username\":\"$ADMINMAIL\",\"password\":\"$PASS\"}"
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

        # I11b — a domain admin is the full manager of its tenant's admins:
        #       the list is scoped (no superadmins, itself visible), and a
        #       peer can be created, disabled and deleted with re-auth
        adminng_call GET /admins "$ADMINNG_DEVICE_2" "$A_TOKEN"
        I11B_LIST="$ADMINNG_CODE" ; I11B_BODY="$ADMINNG_BODY"
        adminng_call POST /admins "$ADMINNG_DEVICE_2" "$A_TOKEN" \
            "{\"username\":\"deputy@$DOMAIN\",\"password\":\"deputy-pass-1\",\"superadmin\":false,\"domains\":[\"$DOMAIN\"]}"
        I11B_CREATE="$ADMINNG_CODE"
        adminng_call PUT "/admins/deputy@$DOMAIN" "$ADMINNG_DEVICE_2" "$A_TOKEN" \
            '{"active":false}'
        I11B_DISABLE="$ADMINNG_CODE"
        adminng_call POST /auth/reauth-confirm "$ADMINNG_DEVICE_2" "$A_TOKEN" \
            "{\"password\":\"$PASS\"}"
        A_SV="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf security_validation_token)"
        adminng_call DELETE "/admins/deputy@$DOMAIN" "$ADMINNG_DEVICE_2" "$A_TOKEN" "" "$A_SV"
        I11B_DELETE="$ADMINNG_CODE"
        if [ "$I11B_LIST" = 200 ] &&
           ! printf '%s' "$I11B_BODY" | grep -q '"superadmin":true' &&
           printf '%s' "$I11B_BODY" | grep -q "\"username\":\"$ADMINMAIL\"" &&
           [ "$I11B_CREATE" = 201 ] && [ "$I11B_DISABLE" = 200 ] &&
           [ "$I11B_DELETE" = 204 ] ; then
            t_ok "I11b a domain admin lists its tenant's admins only, then creates, disables and deletes a peer (re-auth)"
        else
            t_fail "I11b tenant admin lifecycle (list=$I11B_LIST create=$I11B_CREATE disable=$I11B_DISABLE delete=$I11B_DELETE)"
        fi

        # I11c — the H-01 regression: a valid re-auth token must NOT let a
        #        domain admin delete a superadmin or itself, nor create one
        adminng_call POST /auth/reauth-confirm "$ADMINNG_DEVICE_2" "$A_TOKEN" \
            "{\"password\":\"$PASS\"}"
        A_SV="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf security_validation_token)"
        adminng_call DELETE "/admins/$DEPLOY_ADMIN" "$ADMINNG_DEVICE_2" "$A_TOKEN" "" "$A_SV"
        I11C_SUPER="$ADMINNG_CODE"
        adminng_call DELETE "/admins/$ADMINMAIL" "$ADMINNG_DEVICE_2" "$A_TOKEN" "" "$A_SV"
        I11C_SELF="$ADMINNG_CODE"
        adminng_call POST /admins "$ADMINNG_DEVICE_2" "$A_TOKEN" \
            "{\"username\":\"evil@$DOMAIN\",\"password\":\"evil-pass-1\",\"superadmin\":true,\"domains\":[]}"
        I11C_ESC="$ADMINNG_CODE"
        # an admin named after a foreign-tenant address (its password would be
        # mirrored onto that mailbox) is refused even when scoped to $DOMAIN
        adminng_call POST /admins "$ADMINNG_DEVICE_2" "$A_TOKEN" \
            "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"evil-pass-1\",\"superadmin\":false,\"domains\":[\"$DOMAIN\"]}"
        I11C_FOREIGN="$ADMINNG_CODE"
        if [ "$I11C_SUPER" = 403 ] && [ "$I11C_SELF" = 403 ] && [ "$I11C_ESC" = 403 ] &&
           [ "$I11C_FOREIGN" = 403 ] ; then
            t_ok "I11c a domain admin cannot delete a superadmin or itself, nor create a superadmin or a foreign-address admin (403)"
        else
            t_fail "I11c tenant admin negatives (super=$I11C_SUPER self=$I11C_SELF escalate=$I11C_ESC foreign=$I11C_FOREIGN)"
        fi
    fi

    # I12 — re-auth DELETE cascade (fresh 30 s token)
    adminng_call POST /auth/reauth-confirm "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"password\":\"$ADMIN_PW\"}"
    SV="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf security_validation_token)"
    adminng_call DELETE "/domain-aliases/$DOMAIN_ALIAS_API" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_DA="$ADMINNG_CODE"
    adminng_call DELETE "/domains/$DOMAIN_ALIAS_API" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_DS="$ADMINNG_CODE"
    adminng_call DELETE "/aliases/sales@$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_A="$ADMINNG_CODE"
    adminng_call DELETE "/mailboxes/$ADMINNG_USER" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_B="$ADMINNG_CODE"
    adminng_call DELETE "/domains/$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" "" "$SV"
    I12_C="$ADMINNG_CODE"
    adminng_call GET "/domains/$ADMINNG_DOMAIN" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$I12_DA" = 204 ] && [ "$I12_DS" = 204 ] &&
       [ "$I12_A" = 204 ] && [ "$I12_B" = 204 ] && [ "$I12_C" = 204 ] &&
       [ "$ADMINNG_CODE" = 404 ] &&
       [ "$(sql "SELECT count(*) FROM mailbox WHERE domain='$ADMINNG_DOMAIN'")" = "0" ] ; then
        t_ok "I12 re-auth DELETE removes domain alias/source, alias/mailbox/domain (204s, then 404)"
    else
        t_fail "I12 delete cascade (domain_alias=$I12_DA source=$I12_DS alias=$I12_A mailbox=$I12_B domain=$I12_C get=$ADMINNG_CODE)"
    fi

    # I13 — refresh rotation + reuse detection
    REFRESH_HASH="$(dcx api python -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' \
        "$ADMINNG_REFRESH" 2>/dev/null | tr -d ' \r\n')"
    dcx db psql -U maild -d adminng -q -c \
        "UPDATE session SET last_used_at=now()-interval '16 minutes' WHERE jti='$REFRESH_HASH';" \
        > /dev/null 2>&1
    adminng_call POST /auth/refresh "$ADMINNG_DEVICE" "" "{\"refresh_token\":\"$ADMINNG_REFRESH\"}"
    I13_OK="$ADMINNG_CODE"
    NEW_AT="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
    NEW_RT="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf refresh_token)"
    I13_BODY="$ADMINNG_BODY"
    adminng_call POST /auth/refresh "$ADMINNG_DEVICE" "" "{\"refresh_token\":\"$ADMINNG_REFRESH\"}"
    if [ "$I13_OK" = 200 ] && [ -n "$NEW_AT" ] &&
       printf '%s' "$I13_BODY" | grep -q "\"remember\":true" &&
       printf '%s' "$I13_BODY" | grep -q "\"idle_timeout\":$REMEMBER_TTL" &&
       [ "$ADMINNG_CODE" = 401 ] ; then
        t_ok "I13 remembered refresh survives >15 min idle, rotates the jti and rejects reuse"
        ADMINNG_TOKEN="$NEW_AT" ; ADMINNG_REFRESH="$NEW_RT"
    else
        t_fail "I13 refresh rotation (first=$I13_OK reuse=$ADMINNG_CODE)"
    fi

    # I14 — audit trail
    adminng_call GET "/logs?limit=50" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$ADMINNG_CODE" = 200 ] && printf '%s' "$ADMINNG_BODY" | grep -q LOGIN_OK &&
       printf '%s' "$ADMINNG_BODY" | grep -q MAILBOX_CREATE &&
       printf '%s' "$ADMINNG_BODY" | grep -q DOMAIN_ALIAS_CREATE &&
       printf '%s' "$ADMINNG_BODY" | grep -q DOMAIN_DELETE ; then
        t_ok "I14 the audit trail records login, mailbox and domain-alias changes and domain delete"
    else
        t_fail "I14 audit logs (code=$ADMINNG_CODE)"
    fi

    # I15b — revoking one admin's access on a shared browser leaves the browser
    # (and the other admins) alone: only that admin is deny-listed and its
    # sessions die; the sysadmin keeps working on the same browser.
    dcx api adminng.py --approve-device "$ADMINNG_DEVICE" --user "$ADMINMAIL" > /dev/null 2>&1
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE" "" \
        "{\"username\":\"$ADMINMAIL\",\"password\":\"$PASS\"}"
    A1_TOKEN="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
    if [ -z "$A1_TOKEN" ] && printf '%s' "$ADMINNG_BODY" | grep -q REQUIRES_2FA ; then
        A1_FLOW="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf flow_token)"
        A1_CODE="$(adminng_code "$ADMINMAIL" --next)"
        adminng_call POST /auth/login-step2 "$ADMINNG_DEVICE" "" \
            "{\"flow_token\":\"$A1_FLOW\",\"code\":\"$A1_CODE\"}"
        A1_TOKEN="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf access_token)"
    fi
    dcx api adminng.py --revoke-grant "$ADMINNG_DEVICE" --user "$ADMINMAIL" > /dev/null 2>&1
    adminng_call GET /auth/me "$ADMINNG_DEVICE" "$A1_TOKEN"
    I15B_A="$ADMINNG_CODE" ; I15B_BODY="$ADMINNG_BODY"
    adminng_call GET /auth/me "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$I15B_A" = 401 ] && printf '%s' "$I15B_BODY" | grep -q DEVICE_REVOKED &&
       [ "$ADMINNG_CODE" = 200 ] ; then
        t_ok "I15b --revoke-grant kills only that admin's sessions on a shared browser"
    else
        t_fail "I15b grant-scoped revoke (alice=$I15B_A sysadmin=$ADMINNG_CODE)"
    fi

    # I15 — device revocation kills the sessions
    adminng_call POST /auth/reauth-confirm "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"password\":\"$ADMIN_PW\"}"
    SV2="$(printf '%s' "$ADMINNG_BODY" | adminng_jqf security_validation_token)"
    adminng_call PUT "/admin/devices/$ADMINNG_DEVICE/state" "$ADMINNG_DEVICE" "$ADMINNG_TOKEN" \
        "{\"action\":\"REVOKE\",\"username\":\"$DEPLOY_ADMIN\"}" "$SV2"
    I15_R="$ADMINNG_CODE"
    adminng_call GET /auth/me "$ADMINNG_DEVICE" "$ADMINNG_TOKEN"
    if [ "$I15_R" = 200 ] && [ "$ADMINNG_CODE" = 401 ] &&
       printf '%s' "$ADMINNG_BODY" | grep -q DEVICE_REVOKED ; then
        t_ok "I15 revoking the device grant kills its sessions immediately (DEVICE_REVOKED)"
    else
        t_fail "I15 device revoke (revoke=$I15_R me=$ADMINNG_CODE)"
    fi

    # I16 — lockout: five failed logins lock that username+IP for 15 minutes
    # (a non-existent account, so no real fixture is affected)
    LOCK_USER="nobody@adminng-lockout.test"
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

    # I16b — H-02 regression: rotating X-Forwarded-For must NOT dodge the lockout.
    # The api believes XFF only from trusted proxies (the attached subnet minus the
    # docker gateway the test host comes through), so every attempt keys on the
    # gateway even with a distinct forged IP each time.
    LOCK_USER2="nobody2@adminng-lockout.test"
    for I16B_N in 1 2 3 4 5 6 ; do
        I16B_CODE="$(curl -s -o "$TMPRUN/xff.json" -w '%{http_code}' \
            -X POST "$API_BASE/auth/login-step1" \
            -H "X-Device-ID: $ADMINNG_DEVICE_2" \
            -H "X-Device-Secret: $ADMINNG_DEVICE_SECRET_2" \
            -H 'Content-Type: application/json' \
            -H "X-Forwarded-For: 198.51.100.$I16B_N" \
            --data "{\"username\":\"$LOCK_USER2\",\"password\":\"wrong\"}")"
    done
    I16B_BODY="$(cat "$TMPRUN/xff.json" 2>/dev/null)"
    if [ "$I16B_CODE" = 429 ] && printf '%s' "$I16B_BODY" | grep -q RATE_LIMITED ; then
        t_ok "I16b rotating X-Forwarded-For cannot bypass the lockout (429 despite a new forged IP per attempt)"
    else
        t_fail "I16b XFF lockout bypass (got $I16B_CODE: $(printf '%s' "$I16B_BODY" | head -c 120))"
    fi

    # I16c — the stored key is the real peer, not the forged header (audit integrity)
    I16C_IP="$(dcx db psql -U maild -d adminng -tAq -c \
        "SELECT ip FROM rate_limit WHERE username='$LOCK_USER2' ORDER BY updated_at DESC LIMIT 1;" \
        2>/dev/null | tr -d ' \r\n')"
    if [ -n "$I16C_IP" ] && ! printf '%s' "$I16C_IP" | grep -q '^198\.51\.100\.' ; then
        t_ok "I16c the lockout/audit IP is the real peer ($I16C_IP), not the forged X-Forwarded-For"
    else
        t_fail "I16c forged client IP stored (got '$I16C_IP')"
    fi
    dcx api adminng.py --reset-ratelimit "$LOCK_USER2" > /dev/null 2>&1 || true

    # I17 — adminng.py --reset-ratelimit lifts the lockout (testing/ops aid)
    if dcx api adminng.py --reset-ratelimit "$LOCK_USER" > /dev/null 2>&1 ; then
        adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE_2" "" \
            "{\"username\":\"$LOCK_USER\",\"password\":\"wrong\"}"
        if [ "$ADMINNG_CODE" = 401 ] ; then
            t_ok "I17 --reset-ratelimit clears the lockout (429 -> 401 on the next try)"
        else
            t_fail "I17 --reset-ratelimit did not clear the lockout (got $ADMINNG_CODE)"
        fi
    else
        t_fail "I17 --reset-ratelimit command failed"
    fi

    # I18 — a PENDING browser older than ADMINNG_PENDING_TTL_DAYS is purged (the
    # client re-enrolls from zero); the device row is backdated so it is instant.
    # A third fixture browser is used so the approved a1/a2 stay untouched.
    adminng_call POST /auth/login-step1 "$ADMINNG_DEVICE_3" "" \
        "{\"username\":\"$DEPLOY_ADMIN\",\"password\":\"$ADMIN_PW\"}"
    I18_LOGIN="$ADMINNG_CODE"
    I18_STATE="$(dcx db psql -U maild -d adminng -tAc \
        "SELECT state FROM device WHERE device_id='$ADMINNG_DEVICE_3';" 2>/dev/null | tr -d ' \r\n')"
    dcx db psql -U maild -d adminng -q -c \
        "UPDATE device SET first_seen = now() - interval '10 days' WHERE device_id='$ADMINNG_DEVICE_3';" \
        > /dev/null 2>&1
    dcx api adminng.py --purge-pending > /dev/null 2>&1
    I18_N="$(dcx db psql -U maild -d adminng -tAc \
        "SELECT count(*) FROM device WHERE device_id='$ADMINNG_DEVICE_3';" \
        2>/dev/null | tr -d ' \r\n')"
    if [ "$I18_LOGIN" = 403 ] && [ "$I18_STATE" = "PENDING" ] && [ "$I18_N" = "0" ] ; then
        t_ok "I18 --purge-pending drops PENDING browsers older than the TTL (backdated 10d)"
    else
        t_fail "I18 pending TTL purge (login=$I18_LOGIN state=$I18_STATE rows=$I18_N)"
    fi
fi

# ================================= J. MailD MCP (P0 foundations) ============
# mcp/technical-proposal.md §5.3/§5.4/§9.1/§9.2/§7.4: the Dovecot master user (IMAP only, never
# for inactive mailboxes, never rehashing a legacy hash with the master password), the
# restricted maild_mcp db role, the service mailbox and the container healthcheck. Two
# throwaway mailboxes (MCP_LEGACY_USER, MCP_INACTIVE_USER) are created here and removed by
# cleanup().
section "J. MailD MCP (master user, db role, service mailbox, /healthz)"

MCP_MASTER_PW="$(env_value "$ENV_FILE" MCP_DOVECOT_MASTER_PASSWORD || true)"
MCP_MASTER_NAME="$(env_value "$ENV_FILE" MCP_DOVECOT_MASTER_USER || true)"
MCP_MASTER_NAME="${MCP_MASTER_NAME:-mcp}"
MCP_DB_PW="$(env_value "$ENV_FILE" MCP_DB_PASSWORD || true)"
MCP_DB_ROLE="$(env_value "$ENV_FILE" MCP_DB_USER || true)"
MCP_DB_ROLE="${MCP_DB_ROLE:-maild_mcp}"
MCP_SVC="$(env_value "$ENV_FILE" MCP_SERVICE_EMAIL || true)"
MCP_SVC="${MCP_SVC:-mcp@${DEFAULT_DOMAIN}}"
MCP_HTTP="${MCP_HTTP:-http://$SERVER:8085}"
MCP_FIXTURE="${MCP_FIXTURE:-charlie@$DOMAIN}"

mcp_imap() { # <user> <pass> [imap command] — IMAP STARTTLS on 143, as the mcp connects
    timeout -k5 20 curl -s --insecure --ssl-reqd --user "$1:$2" \
        --url "imap://$SERVER:143/INBOX" -X "${3:-SEARCH ALL}" 2>&1 | grep -q '\* SEARCH'
}
mcp_sql() { # <database> <sql> — as the restricted MCP role, over TCP like the container
    dcx db env PGPASSWORD="$MCP_DB_PW" psql -h 127.0.0.1 -U "$MCP_DB_ROLE" -d "$1" -X -tAc "$2" 2>&1
}
mcp_hash() { dcx db psql -U maild -d mailddb -tAc "SELECT password FROM mailbox WHERE username='$1'" 2>/dev/null | tr -d '\r'; }

if [ "$HAVE_DC" != 1 ] || [ -z "$MCP_MASTER_PW" ] || [ -z "$MCP_DB_PW" ] ; then
    t_skip "MailD MCP checks (need docker plus MCP_DOVECOT_MASTER_PASSWORD and MCP_DB_PASSWORD in $ENV_FILE)"
else
    MCP_TOUCHED=1
    MCP_PROBE_PW="$(chrono | cut -c1-24)"
    MCP_MD5="$(dcx mda doveadm pw -s MD5-CRYPT -p "$MCP_PROBE_PW" 2>/dev/null | tr -d '\r' | sed 's/^{MD5-CRYPT}//')"
    MCP_HOMES="/home/vmail/${DOMAIN}/${MCP_LEGACY_USER%%@*} /home/vmail/${DOMAIN}/${MCP_INACTIVE_USER%%@*}"
    dcx mda sh -c "mkdir -p $MCP_HOMES && chown 5000:5000 $MCP_HOMES" > /dev/null 2>&1 || true
    sql "INSERT INTO mailbox (username, password, name, maildir, quota, domain, local_part, active) VALUES
           ('$MCP_LEGACY_USER',   '$MCP_MD5', 'mcp probe', '${DOMAIN}/${MCP_LEGACY_USER%%@*}/',   0, '$DOMAIN', '${MCP_LEGACY_USER%%@*}',   true),
           ('$MCP_INACTIVE_USER', '$MCP_MD5', 'mcp probe', '${DOMAIN}/${MCP_INACTIVE_USER%%@*}/', 0, '$DOMAIN', '${MCP_INACTIVE_USER%%@*}', false)
         ON CONFLICT (username) DO UPDATE SET password = EXCLUDED.password, active = EXCLUDED.active;" > /dev/null
    dcx mda doveadm auth cache flush > /dev/null 2>&1 || true

    # J1 — master login opens an active mailbox over IMAP (STARTTLS)
    if mcp_imap "${MCP_FIXTURE}*${MCP_MASTER_NAME}" "$MCP_MASTER_PW" ; then
        t_ok "J1 the MCP master user opens an active mailbox over IMAP STARTTLS (${MCP_FIXTURE}*${MCP_MASTER_NAME})"
    else
        t_fail "J1 master-user IMAP login to ${MCP_FIXTURE} (check 'docker compose logs mda' for the master passdb)"
    fi

    # J2 — ... and Dovecot logs who really authenticated (independent audit trail)
    sleep 1
    if "${DC[@]}" logs --no-log-prefix --since 2m mda 2>/dev/null |
         grep -q "Logged in: user=<${MCP_FIXTURE}>, auth_user=<${MCP_MASTER_NAME}>" ; then
        t_ok "J2 Dovecot logs the master name on a master login (auth_user=<${MCP_MASTER_NAME}>)"
    else
        t_fail "J2 the mda login line carries auth_user=<${MCP_MASTER_NAME}> for the master login"
    fi

    # J3 — the master user never opens an inactive mailbox
    if mcp_imap "${MCP_INACTIVE_USER}*${MCP_MASTER_NAME}" "$MCP_MASTER_PW" ; then
        t_fail "J3 the master user must NOT open an inactive mailbox (${MCP_INACTIVE_USER} logged in)"
    else
        t_ok "J3 the master user cannot open an inactive mailbox"
    fi

    # J4 — IMAP only: POP3, SMTP AUTH (the mta's SASL on mda's auth socket) and ManageSieve refuse it
    MCP_POP="$(timeout -k5 20 curl -s --insecure --user "${MCP_FIXTURE}*${MCP_MASTER_NAME}:$MCP_MASTER_PW" \
                 --url "pop3s://$SERVER:995/" > /dev/null 2>&1; echo $?)"
    MCP_SMTP="$(timeout -k5 30 curl -s --insecure --ssl-reqd --user "${MCP_FIXTURE}*${MCP_MASTER_NAME}:$MCP_MASTER_PW" \
                 --url "smtp://$SERVER:587" --mail-from "$MCP_FIXTURE" --mail-rcpt "$MCP_FIXTURE" -T /dev/null > /dev/null 2>&1; echo $?)"
    MCP_SIEVE="$(dcx mda doveadm auth test -x service=sieve "${MCP_FIXTURE}*${MCP_MASTER_NAME}" "$MCP_MASTER_PW" 2>&1 | tr -d '\r')"
    if [ "$MCP_POP" = 67 ] && [ "$MCP_SMTP" = 67 ] && printf '%s' "$MCP_SIEVE" | grep -q 'auth failed' ; then
        t_ok "J4 the master user is IMAP only (POP3, SMTP AUTH and ManageSieve refuse it)"
    else
        t_fail "J4 master user outside IMAP (pop3 rc=$MCP_POP smtp rc=$MCP_SMTP sieve: $(printf '%s' "$MCP_SIEVE" | head -n1))"
    fi

    # J5 — §5.4: a master login must NOT rehash a legacy $1$ row (the plaintext it sees is the
    # MASTER password: the user would be locked out and the master password would become theirs)
    MCP_BEFORE="$(mcp_hash "$MCP_LEGACY_USER")"
    mcp_imap "${MCP_LEGACY_USER}*${MCP_MASTER_NAME}" "$MCP_MASTER_PW" ; MCP_RC=$?
    sleep 1
    MCP_AFTER="$(mcp_hash "$MCP_LEGACY_USER")"
    if [ "$MCP_RC" = 0 ] && [ -n "$MCP_BEFORE" ] && [ "$MCP_BEFORE" = "$MCP_AFTER" ] ; then
        t_ok "J5 a master login leaves a legacy \$1\$ hash untouched (rehash-on-login skips master logins)"
    else
        t_fail "J5 legacy hash after a master login (login rc=$MCP_RC, before=${MCP_BEFORE:0:12}… after=${MCP_AFTER:0:12}…)"
    fi

    # J6 — control for J5: the user's OWN login still migrates the row, so J5 is not vacuous
    dcx mda doveadm auth cache flush > /dev/null 2>&1 || true
    mcp_imap "$MCP_LEGACY_USER" "$MCP_PROBE_PW" ; MCP_RC=$?
    sleep 1
    MCP_AFTER="$(mcp_hash "$MCP_LEGACY_USER")"
    case "$MCP_AFTER" in
        '{ARGON2ID}$argon2id$'*) [ "$MCP_RC" = 0 ] && t_ok "J6 the user's own login still rehashes the legacy row to Argon2id (control for J5)" \
                                   || t_fail "J6 own login of the legacy probe failed (rc=$MCP_RC)" ;;
        *) t_fail "J6 the user's own login did not rehash the legacy row (rc=$MCP_RC, now ${MCP_AFTER:0:12}…)" ;;
    esac

    # J7 — D8: the maild_mcp role reads only the granted columns, never mailbox.password
    MCP_OUT_COLS="$(mcp_sql mailddb "SELECT count(*) FROM mailbox WHERE username='$MCP_FIXTURE' AND active")"
    MCP_OUT_PW="$(mcp_sql mailddb "SELECT password FROM mailbox LIMIT 1")"
    MCP_OUT_ALIAS="$(mcp_sql mailddb "SELECT count(*) FROM alias")"
    if [ "$(printf '%s' "$MCP_OUT_COLS" | tail -n1 | tr -d '\r ')" = 1 ] &&
       printf '%s' "$MCP_OUT_PW" | grep -q 'permission denied' &&
       printf '%s' "$MCP_OUT_ALIAS" | grep -q 'permission denied' ; then
        t_ok "J7 ${MCP_DB_ROLE} reads the granted catalogue columns and cannot read mailbox.password (nor alias)"
    else
        t_fail "J7 ${MCP_DB_ROLE} column grants (cols='$MCP_OUT_COLS' password='$(printf '%s' "$MCP_OUT_PW" | head -n1)')"
    fi

    # J8 — ... and cannot change the catalogue
    MCP_OUT_UPD="$(mcp_sql mailddb "UPDATE mailbox SET name = name WHERE username='$MCP_FIXTURE'")"
    MCP_OUT_INS="$(mcp_sql mailddb "INSERT INTO domain (domain) VALUES ('mcp-probe.invalid')")"
    if printf '%s' "$MCP_OUT_UPD" | grep -q 'permission denied' &&
       printf '%s' "$MCP_OUT_INS" | grep -q 'permission denied' ; then
        t_ok "J8 ${MCP_DB_ROLE} cannot UPDATE or INSERT in the catalogue"
    else
        t_fail "J8 ${MCP_DB_ROLE} wrote to the catalogue (update='$(printf '%s' "$MCP_OUT_UPD" | head -n1)' insert='$(printf '%s' "$MCP_OUT_INS" | head -n1)')"
    fi

    # J9 — ... but can EXECUTE the service-mailbox function, which never touches an existing row
    # and refuses anything that is not an {ARGON2ID} hash
    MCP_SVC_BEFORE="$(dcx db psql -U maild -d mailddb -tAc "SELECT md5(password) || modified FROM mailbox WHERE username='$MCP_SVC'" 2>/dev/null | tr -d '\r')"
    MCP_OUT_FN="$(mcp_sql mailddb "SELECT maild_mcp_ensure_service_mailbox('$MCP_SVC', '{ARGON2ID}\$argon2id\$v=19\$m=65536,t=4,p=1\$probe\$probe', 'probe')" | tail -n1 | tr -d '\r ')"
    MCP_OUT_WEAK="$(mcp_sql mailddb "SELECT maild_mcp_ensure_service_mailbox('mcp-weak-probe@$DOMAIN', '$MCP_MD5', 'probe')")"
    MCP_SVC_AFTER="$(dcx db psql -U maild -d mailddb -tAc "SELECT md5(password) || modified FROM mailbox WHERE username='$MCP_SVC'" 2>/dev/null | tr -d '\r')"
    MCP_WEAK_ROWS="$(sql "SELECT count(*) FROM mailbox WHERE username='mcp-weak-probe@$DOMAIN'" | tr -d '\r ')"
    if [ "$MCP_OUT_FN" = f ] && [ -n "$MCP_SVC_BEFORE" ] && [ "$MCP_SVC_BEFORE" = "$MCP_SVC_AFTER" ] &&
       printf '%s' "$MCP_OUT_WEAK" | grep -q 'ARGON2ID' && [ "$MCP_WEAK_ROWS" = 0 ] ; then
        t_ok "J9 ${MCP_DB_ROLE} can EXECUTE maild_mcp_ensure_service_mailbox(): no-op on an existing mailbox, refuses a weak hash"
    else
        t_fail "J9 service-mailbox function (existing → '$MCP_OUT_FN', row unchanged: $([ "$MCP_SVC_BEFORE" = "$MCP_SVC_AFTER" ] && echo yes || echo no), weak rows: $MCP_WEAK_ROWS)"
    fi

    # J10 — D9: the service mailbox was created once, active, and an mcp restart leaves it untouched
    MCP_SVC_ROWS="$(sql "SELECT count(*) FROM mailbox WHERE username='$MCP_SVC' AND active AND password LIKE '{ARGON2ID}%'" | tr -d '\r ')"
    timeout -k10 90 "${DC[@]}" restart mcp > /dev/null 2>&1
    MCP_UP=0
    for _ in $(seq 1 30); do
        if timeout -k5 5 curl -s -o /dev/null -w '%{http_code}' "$MCP_HTTP/healthz" 2>/dev/null | grep -q 200 ; then MCP_UP=1; break; fi
        sleep 2
    done
    MCP_SVC_RESTART="$(dcx db psql -U maild -d mailddb -tAc "SELECT md5(password) || modified FROM mailbox WHERE username='$MCP_SVC'" 2>/dev/null | tr -d '\r')"
    if [ "$MCP_SVC_ROWS" = 1 ] && [ "$MCP_UP" = 1 ] && [ "$MCP_SVC_BEFORE" = "$MCP_SVC_RESTART" ] &&
       "${DC[@]}" logs --no-log-prefix --since 2m mcp 2>/dev/null | grep -q "service mailbox $MCP_SVC present and active" ; then
        t_ok "J10 the service mailbox $MCP_SVC exists once (active, Argon2id) and an mcp restart leaves it untouched"
    else
        t_fail "J10 service mailbox (rows=$MCP_SVC_ROWS up_after_restart=$MCP_UP unchanged=$([ "$MCP_SVC_BEFORE" = "$MCP_SVC_RESTART" ] && echo yes || echo no))"
    fi

    # J11 — the container healthcheck: db, catalogue and IMAP reachable
    MCP_HZ="$(timeout -k5 10 curl -s -w ' %{http_code}' "$MCP_HTTP/healthz" 2>/dev/null)"
    case "$MCP_HZ" in
        *'"status": "ok"'*' 200') t_ok "J11 mcp /healthz answers 200 (db, catalogue and IMAP reachable)" ;;
        *) t_fail "J11 mcp /healthz (got: $MCP_HZ)" ;;
    esac
fi

# ================================= K. MailD MCP (P1: user side + read access) ==
# mcp/technical-proposal.md §7.1/§7.3/§8 and the 2026-10-29 decisions in mcp/progress.md: the
# domain allow-list CLI, web login (ALTCHA, lockout, IMAP check, rotating refresh cookie),
# secondary addresses (magic link, D11 conflicts + postmaster notice, owner wins, disabled
# refuses login), PATs (scopes, address subset, D12 idle rule, revoke) and the MCP read tools
# through the official SDK client (search never sets \Seen, get_email does). Self-cleaning: the
# fixture accounts are deleted from the mcp DB, the example.net policy and the \Seen flag are
# restored and the service mails are expunged by cleanup().
section "K. MailD MCP user side (web login, addresses, tokens, MCP read tools)"

K_A="alice@$DOMAIN"; K_B="bob@$DOMAIN"; K_C="charlie@$DOMAIN"; K_D="dylan@$DOMAIN"
K_PA="${CRED[${K_A,,}]:-}"; K_PB="${CRED[${K_B,,}]:-}"; K_PC="${CRED[${K_C,,}]:-}"; K_PD="${CRED[${K_D,,}]:-}"
K_JAR="$TMPRUN/k.cookies"; K_OUT="$TMPRUN/k.out"

k_altcha() { dcx mcp python tests/altcha_solve.py 2>/dev/null | tr -d '\r\n'; }
k_json() { python3 -c "import json,sys; d=json.load(open('$K_OUT')); print(eval(sys.argv[1], {}, {'d': d}))" "$1" 2>/dev/null; }
k_api() { # <method> <path> [json] [access] [jar] → K_CODE, body in $K_OUT
    local args=(-s -o "$K_OUT" -w '%{http_code}' -X "$1" -H 'Content-Type: application/json' --max-time 60)
    [ -n "${3:-}" ] && args+=(--data "$3")
    [ -n "${4:-}" ] && args+=(-H "Authorization: Bearer $4")
    [ -n "${5:-}" ] && args+=(-b "$5" -c "$5")
    K_CODE="$(curl "${args[@]}" "$MCP_HTTP/webapi$2")"
}
k_login() { # <email> <password> [jar] → K_CODE, K_AT
    k_api POST /user/login "{\"email\":\"$1\",\"password\":\"$2\",\"altcha\":\"$(k_altcha)\"}" "" "${3:-}"
    K_AT="$(k_json "d.get('access_token','')")"
}
k_call() { # <token> <tool> <json args> → K_RES (json from tests/mcp_call.py)
    K_RES="$(dcx mcp python tests/mcp_call.py "$1" call "$2" "$3" 2>/dev/null | tail -n1)"
}
k_res() { python3 -c "import json,sys; d=json.loads(sys.argv[2]); print(eval(sys.argv[1], {}, {'d': d}))" "$1" "$K_RES" 2>/dev/null; }
k_rpc() { # <token> <tool> → HTTP code of a raw tools/call (headers in $K_OUT.h)
    curl -s -o "$K_OUT" -D "$K_OUT.h" -w '%{http_code}' --max-time 30 -X POST "$MCP_HTTP/api/v1/mcp" \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -H 'MCP-Protocol-Version: 2025-11-25' ${1:+-H "Authorization: Bearer $1"} \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":{}}}"
}
k_seen() { dcx mda doveadm search -u "$1" mailbox INBOX seen 2>/dev/null | wc -l | tr -d ' '; }

if [ "$HAVE_DC" != 1 ] || [ -z "$MCP_DB_PW" ] || [ -z "$K_PA" ] || [ -z "$K_PB" ] || [ -z "$K_PC" ] || [ -z "$K_PD" ] ; then
    t_skip "MailD MCP user-side checks (need docker, MCP secrets in $ENV_FILE and the $DOMAIN fixtures in test.creds)"
else
    MCP_K_TOUCHED=1
    K_POLICY_BEFORE="$(dcx db psql -U maild -d mcp -tAc "SELECT allowed FROM domain_policy WHERE domain='$DOMAIN'" 2>/dev/null | tr -d '\r ')"
    dcx db psql -U maild -d mcp -q -c "DELETE FROM domain_policy WHERE domain='$DOMAIN'" > /dev/null 2>&1

    # K1 — D6: a catalogue domain without a policy row is denied
    k_login "$K_A" "$K_PA"
    if [ "$K_CODE" = 403 ] && [ "$(k_json "d['error']")" = domain_not_allowed ] ; then
        t_ok "K1 a domain is MCP-denied until the admin allows it (login → 403 domain_not_allowed)"
    else
        t_fail "K1 denied-domain login (got $K_CODE $(head -c 200 "$K_OUT"))"
    fi

    # K2 — the allow-list CLI (decision 2026-10-29) flips it
    if dcx mcp python manage.py mcp_domains allow "$DOMAIN" > /dev/null 2>&1 &&
       dcx mcp python manage.py mcp_domains list 2>/dev/null | grep -Eq "^$DOMAIN +ALLOWED" ; then
        t_ok "K2 'manage.py mcp_domains allow $DOMAIN' allows the domain (and 'list' shows it)"
    else
        t_fail "K2 mcp_domains allow/list"
    fi

    # K3 — ALTCHA is mandatory and single-use
    K_ALT="$(k_altcha)"
    k_api POST /user/login "{\"email\":\"$K_A\",\"password\":\"$K_PA\",\"altcha\":\"bm9wZQ==\"}"; K3_BAD="$K_CODE"
    k_api POST /user/login "{\"email\":\"$K_A\",\"password\":\"$K_PA\",\"altcha\":\"$K_ALT\"}"; K3_FIRST="$K_CODE"
    k_api POST /user/login "{\"email\":\"$K_A\",\"password\":\"$K_PA\",\"altcha\":\"$K_ALT\"}"; K3_REPLAY="$K_CODE"
    if [ "$K3_BAD" = 400 ] && [ "$K3_FIRST" = 200 ] && [ "$K3_REPLAY" = 400 ] ; then
        t_ok "K3 login needs a solved ALTCHA, and a solution is accepted only once"
    else
        t_fail "K3 ALTCHA (bad=$K3_BAD first=$K3_FIRST replay=$K3_REPLAY)"
    fi

    # K4 — 5 wrong passwords per username+IP lock the login for 15 min
    for _ in 1 2 3 4 5 ; do k_login "$K_D" "wrong-$RANDOM" ; done
    k_login "$K_D" "$K_PD"
    if [ "$K_CODE" = 429 ] && [ "$(k_json "d['error']")" = locked ] ; then
        t_ok "K4 five failed logins lock the username+IP (even the right password → 429)"
    else
        t_fail "K4 lockout (got $K_CODE)"
    fi
    dcx db psql -U maild -d mcp -q -c "DELETE FROM login_failure WHERE key='$K_D'" > /dev/null 2>&1

    # K5 — login: IMAP check, short access JWT, refresh cookie HttpOnly+Secure+SameSite=Strict+Path=/webapi
    rm -f "$K_JAR"
    K5_HDR="$(curl -s -D - -o "$K_OUT" -X POST "$MCP_HTTP/webapi/user/login" -H 'Content-Type: application/json' \
               -c "$K_JAR" --data "{\"email\":\"$K_A\",\"password\":\"$K_PA\",\"altcha\":\"$(k_altcha)\"}" | tr -d '\r')"
    K_AT="$(k_json "d.get('access_token','')")"
    K5_COOKIE="$(printf '%s\n' "$K5_HDR" | grep -i '^set-cookie: mdmcp_refresh=')"
    if [ -n "$K_AT" ] && [ "$(k_json "d['account']['main_email']")" = "$K_A" ] &&
       printf '%s' "$K5_COOKIE" | grep -qi 'httponly' && printf '%s' "$K5_COOKIE" | grep -qi 'secure' &&
       printf '%s' "$K5_COOKIE" | grep -qi 'samesite=strict' && printf '%s' "$K5_COOKIE" | grep -qi 'path=/webapi' ; then
        t_ok "K5 IMAP-verified login opens a session (access JWT + HttpOnly/Secure/SameSite=Strict refresh cookie)"
    else
        t_fail "K5 login/session (cookie: ${K5_COOKIE:-none})"
    fi

    # K6 — the refresh cookie rotates; replaying the superseded one revokes the session
    cp "$K_JAR" "$K_JAR.old"
    k_api POST /user/refresh "" "" "$K_JAR"; K6_A="$K_CODE"; K_AT2="$(k_json "d.get('access_token','')")"
    k_api POST /user/refresh "" "" "$K_JAR.old"; K6_REPLAY="$K_CODE"
    k_api GET /user/me "" "$K_AT2"; K6_AFTER="$K_CODE"
    if [ "$K6_A" = 200 ] && [ "$K6_REPLAY" = 401 ] && [ "$K6_AFTER" = 401 ] ; then
        t_ok "K6 refresh rotates the cookie; replaying the old one revokes the whole session"
    else
        t_fail "K6 refresh rotation (refresh=$K6_A replay=$K6_REPLAY me-after=$K6_AFTER)"
    fi
    k_login "$K_A" "$K_PA" "$K_JAR"; K_ATA="$K_AT"

    # K7 — no session, no API
    k_api GET /user/me; K7_NONE="$K_CODE"; k_api GET /user/me "" "$K_ATA"; K7_OK="$K_CODE"
    if [ "$K7_NONE" = 401 ] && [ "$K7_OK" = 200 ] ; then
        t_ok "K7 /webapi/user/* answers 401 without a session and 200 with it"
    else
        t_fail "K7 web API auth (none=$K7_NONE ok=$K7_OK)"
    fi

    # K8 — PAT: shown once, stored hashed
    k_api POST /user/tokens '{"name":"k-read","scopes":["mail.read"]}' "$K_ATA"
    K_PAT="$(k_json "d.get('token','')")"; K_PAT_ID="$(k_json "d.get('id','')")"
    K8_DB="$(dcx db psql -U maild -d mcp -tAc "SELECT count(*) FROM token WHERE hash = '$K_PAT' OR display = '$K_PAT' OR name = '$K_PAT'" 2>/dev/null | tr -d '\r ')"
    k_api GET /user/tokens "" "$K_ATA"
    if [ "${K_PAT:0:10}" = mdmcp_pat_ ] && [ "$K8_DB" = 0 ] && ! grep -q "$K_PAT" "$K_OUT" ; then
        t_ok "K8 a PAT (mdmcp_pat_…) is shown once and never stored or listed in clear"
    else
        t_fail "K8 PAT creation (prefix='${K_PAT:0:10}' clear-in-db=$K8_DB)"
    fi

    # K9 — the official SDK client sees the eight read tools (P1 exit criterion, scripted half)
    K9_TOOLS="$(dcx mcp python tests/mcp_call.py "$K_PAT" list 2>/dev/null | tr -d '\r' | head -n 8 | paste -sd, -)"
    if [ "$K9_TOOLS" = "list_accounts,list_folders,check_new_mail,search_emails,get_email,get_thread,get_attachment,get_quota" ] ; then
        t_ok "K9 the MCP SDK client lists the eight read tools (first, in order) over Streamable HTTP with the PAT"
    else
        t_fail "K9 tools/list (got: $K9_TOOLS)"
    fi

    # K10 — 401 with the RFC 9728 pointer when the bearer is missing or wrong
    K10_NONE="$(k_rpc "" list_accounts)"; K10_WWW="$(grep -i '^www-authenticate:' "$K_OUT.h" | tr -d '\r')"
    K10_BAD="$(k_rpc mdmcp_pat_wrong list_accounts)"
    if [ "$K10_NONE" = 401 ] && [ "$K10_BAD" = 401 ] && printf '%s' "$K10_WWW" | grep -q 'resource_metadata=".*/.well-known/oauth-protected-resource/api/v1/mcp"' ; then
        t_ok "K10 the MCP endpoint answers 401 + WWW-Authenticate resource_metadata without a valid bearer"
    else
        t_fail "K10 401 (none=$K10_NONE bad=$K10_BAD header='$K10_WWW')"
    fi

    # K11 — search returns summaries and never sets \Seen
    K11_SEEN0="$(k_seen "$K_A")"
    k_call "$K_PAT" search_emails "{\"account\":\"$K_A\",\"limit\":5}"
    K11_N="$(k_res "len(d['structured']['messages'])")"; K_MID="$(k_res "d['structured']['messages'][0]['id']")"
    K11_SEEN1="$(k_seen "$K_A")"
    if [ "${K11_N:-0}" -ge 1 ] && [ "$K11_SEEN0" = "$K11_SEEN1" ] ; then
        t_ok "K11 search_emails returns $K11_N summaries and leaves \\Seen untouched ($K11_SEEN0 seen before and after)"
    else
        t_fail "K11 search (n=$K11_N seen $K11_SEEN0 → $K11_SEEN1; $(printf '%s' "$K_RES" | head -c 200))"
    fi

    # K12 — get_email(mark_read=false) peeks; the default marks the message read
    K_MUID="${K_MID#*.}"
    dcx mda doveadm flags remove -u "$K_A" '\Seen' mailbox INBOX uid "$K_MUID" > /dev/null 2>&1
    k_call "$K_PAT" get_email "{\"account\":\"$K_A\",\"folder\":\"INBOX\",\"id\":\"$K_MID\",\"mark_read\":false}"
    K12_PEEK="$(k_res "d['structured']['unread']")"; K12_MARK="$(k_res "'UNTRUSTED EMAIL CONTENT' in d['structured']['body']")"
    K12_S1="$(dcx mda doveadm search -u "$K_A" mailbox INBOX uid "$K_MUID" seen 2>/dev/null | wc -l | tr -d ' ')"
    k_call "$K_PAT" get_email "{\"account\":\"$K_A\",\"folder\":\"INBOX\",\"id\":\"$K_MID\"}"
    K12_S2="$(dcx mda doveadm search -u "$K_A" mailbox INBOX uid "$K_MUID" seen 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$K12_PEEK" = True ] && [ "$K12_S1" = 0 ] && [ "$K12_S2" = 1 ] && [ "$K12_MARK" = True ] ; then
        t_ok "K12 get_email marks the message read by default, mark_read=false peeks; the body is wrapped as untrusted"
    else
        t_fail "K12 get_email (peek unread=$K12_PEEK seen after peek=$K12_S1 after read=$K12_S2 marker=$K12_MARK)"
    fi
    dcx mda doveadm flags remove -u "$K_A" '\Seen' mailbox INBOX uid "$K_MUID" > /dev/null 2>&1

    # K13 — scopes: a token without mail.read gets 403 insufficient_scope on a read tool
    k_api POST /user/tokens '{"name":"k-modify","scopes":["mail.modify"]}' "$K_ATA"; K_PATM="$(k_json "d.get('token','')")"
    K13="$(k_rpc "$K_PATM" search_emails)"; K13_WWW="$(grep -i '^www-authenticate:' "$K_OUT.h" | tr -d '\r')"
    if [ "$K13" = 403 ] && printf '%s' "$K13_WWW" | grep -q 'error="insufficient_scope"' && printf '%s' "$K13_WWW" | grep -q 'scope="mail.read"' ; then
        t_ok "K13 a tool outside the token's scopes answers 403 insufficient_scope (scope=\"mail.read\")"
    else
        t_fail "K13 scope check (got $K13, '$K13_WWW')"
    fi

    # K14 — the account's MCP switch cuts every token immediately
    k_api PUT /user/mcp '{"enabled":false}' "$K_ATA"; K14_OFF="$(k_rpc "$K_PAT" list_accounts)"
    k_api PUT /user/mcp '{"enabled":true}' "$K_ATA"; K14_ON="$(k_rpc "$K_PAT" list_accounts)"
    if [ "$K14_OFF" = 403 ] && [ "$K14_ON" = 200 ] ; then
        t_ok "K14 MCP switch off → every token gets 403 mcp_disabled; back on → 200"
    else
        t_fail "K14 MCP switch (off=$K14_OFF on=$K14_ON)"
    fi

    # K15 — secondary address: magic link to THAT inbox, confirm → active
    k_api POST /user/addresses "{\"email\":\"$K_B\"}" "$K_ATA"; K15_ADD="$K_CODE"; K_BID="$(k_json "d.get('id','')")"
    K15_STATUS="$(k_json "d.get('status','')")"
    K_TOKEN_B=""
    if wait_msg "$K_B" INBOX "Confirm $K_B for MailD MCP" 60 ; then
        K15_UID="$(msg_newest_uid "$K_B" INBOX "Confirm $K_B for MailD MCP")"
        # decode the MIME body (the link line is quoted-printable with soft breaks, like any >78-char line)
        K_TOKEN_B="$(msg_text "$K_B" INBOX "$K15_UID" | sed '1{/^text:/d}' | python3 -c 'import email,email.policy,re,sys
m = email.message_from_bytes(sys.stdin.buffer.read(), policy=email.policy.default)
body = (m.get_body(("plain",)) or m).get_content()
f = re.search(r"confirm#(mdmcp_ml_[A-Za-z0-9]+)", body)
print(f.group(1) if f else "")' 2>/dev/null)"
    fi
    k_api POST /confirm "{\"token\":\"$K_TOKEN_B\"}"; K15_CONF="$K_CODE"
    k_api POST /confirm "{\"token\":\"$K_TOKEN_B\"}"; K15_AGAIN="$K_CODE"
    if [ "$K15_ADD" = 200 ] && [ "$K15_STATUS" = pending ] && [ -n "$K_TOKEN_B" ] && [ "$K15_CONF" = 200 ] && [ "$K15_AGAIN" = 404 ] ; then
        t_ok "K15 adding $K_B mails a magic link to $K_B (DKIM path via amavis); it confirms once"
    else
        t_fail "K15 secondary address (add=$K15_ADD status=$K15_STATUS link=${K_TOKEN_B:+yes} confirm=$K15_CONF again=$K15_AGAIN)"
    fi

    # K16 — logging in with an active secondary lands on the owner account
    k_login "$K_B" "$K_PB"
    if [ "$K_CODE" = 200 ] && [ "$(k_json "d['account']['main_email']")" = "$K_A" ] ; then
        t_ok "K16 $K_B (active secondary) logs in and lands on $K_A's account"
    else
        t_fail "K16 secondary login (got $K_CODE, account $(k_json "d.get('account',{}).get('main_email')"))"
    fi

    # K17 — D11: another account claiming it → "Already in use" + ONE postmaster notice per day
    k_login "$K_C" "$K_PC"; K_ATC="$K_AT"
    K17_N0="$(subj_count "$DEPLOY_ADMIN" INBOX "address claim conflict for $K_B")"
    k_api POST /user/addresses "{\"email\":\"$K_B\"}" "$K_ATC"; K17_1="$K_CODE"; K17_MSG="$(k_json "d.get('message')")"
    k_api POST /user/addresses "{\"email\":\"$K_B\"}" "$K_ATC"; K17_2="$K_CODE"
    wait_subj_count_gt "$DEPLOY_ADMIN" INBOX "address claim conflict for $K_B" "${K17_N0:-0}" 60
    sleep 5
    K17_N1="$(subj_count "$DEPLOY_ADMIN" INBOX "address claim conflict for $K_B")"
    if [ "$K17_1" = 409 ] && [ "$K17_2" = 409 ] && [ "$K17_MSG" = "Already in use." ] && [ "$((K17_N1 - ${K17_N0:-0}))" = 1 ] ; then
        t_ok "K17 claiming an address held by another account → 409 'Already in use.', one postmaster notice for two attempts"
    else
        t_fail "K17 claim conflict (codes $K17_1/$K17_2 msg='$K17_MSG' notices ${K17_N0:-0}→$K17_N1)"
    fi

    # K18 — token address subset + a disabled secondary: unusable by tokens, and its login is refused
    k_api POST /user/tokens "{\"name\":\"k-subset\",\"scopes\":[\"mail.read\"],\"addresses\":[\"$K_A\"]}" "$K_ATA"; K_PATS="$(k_json "d.get('token','')")"
    k_call "$K_PATS" list_folders "{\"account\":\"$K_B\"}"; K18_SUB="$(k_res "d['is_error']")"
    k_api POST "/user/addresses/$K_BID/status" "{\"enabled\":false,\"confirm\":\"$K_B\"}" "$K_ATA"; K18_DIS="$K_CODE"
    k_call "$K_PAT" list_accounts '{}'; K18_REASON="$(k_res "[a['reason'] for a in d['structured']['accounts'] if a['address']=='$K_B'][0]")"
    k_login "$K_B" "$K_PB"; K18_LOGIN="$K_CODE"; K18_ERR="$(k_json "d.get('error')")"
    if [ "$K18_SUB" = True ] && [ "$K18_DIS" = 200 ] && [ "$K18_REASON" = disabled ] && [ "$K18_LOGIN" = 403 ] && [ "$K18_ERR" = address_disabled_elsewhere ] ; then
        t_ok "K18 a token's address subset is enforced; a disabled secondary is unusable and its own login is refused"
    else
        t_fail "K18 subset/disabled (subset-error=$K18_SUB disable=$K18_DIS reason=$K18_REASON login=$K18_LOGIN $K18_ERR)"
    fi

    # K19 — resend backoff (2^n from 1 min) and "owner wins" over a pending claim
    k_api POST /user/addresses "{\"email\":\"$K_D\"}" "$K_ATA"; K_DID="$(k_json "d.get('id','')")"
    k_api POST "/user/addresses/$K_DID/resend" "" "$K_ATA"; K19_RESEND="$K_CODE"
    K19_N0="$(subj_count "$K_A" INBOX "$K_D claimed by its owner")"
    k_login "$K_D" "$K_PD"; K19_LOGIN="$K_CODE"; K19_MAIN="$(k_json "d['account']['main_email']")"
    k_api GET /user/me "" "$K_ATA"; K19_GONE="$(k_json "'$K_D' not in [a['email'] for a in d['addresses']]")"
    wait_subj_count_gt "$K_A" INBOX "$K_D claimed by its owner" "${K19_N0:-0}" 60; K19_NOTE=$?
    if [ "$K19_RESEND" = 429 ] && [ "$K19_LOGIN" = 200 ] && [ "$K19_MAIN" = "$K_D" ] && [ "$K19_GONE" = True ] && [ "$K19_NOTE" = 0 ] ; then
        t_ok "K19 an early resend is refused (429); the owner logging in cancels the pending claim and A is notified"
    else
        t_fail "K19 resend/owner-wins (resend=$K19_RESEND login=$K19_LOGIN main=$K19_MAIN gone=$K19_GONE notice=$K19_NOTE)"
    fi

    # K20 — D12: 30 idle days disable a PAT (401 token_idle + hourly job); re-enable from the page works
    dcx db psql -U maild -d mcp -q -c "UPDATE token SET created_at = now() - interval '31 days', last_used_at = now() - interval '31 days', reenabled_at = NULL WHERE id = $K_PAT_ID" > /dev/null 2>&1
    K20_IDLE="$(k_rpc "$K_PAT" list_accounts)"; K20_REASON="$(python3 -c "import json; print(json.load(open('$K_OUT')).get('reason'))" 2>/dev/null)"
    K20_STATE="$(dcx db psql -U maild -d mcp -tAc "SELECT status || '/' || disabled_reason FROM token WHERE id = $K_PAT_ID" 2>/dev/null | tr -d '\r ')"
    K20_JOB="$(dcx mcp python manage.py mcp_jobs --once 2>/dev/null | tr -d '\r')"
    k_api POST "/user/tokens/$K_PAT_ID/enable" "" "$K_ATA"; K20_EN="$K_CODE"
    K20_BACK="$(k_rpc "$K_PAT" list_accounts)"
    if [ "$K20_IDLE" = 401 ] && [ "$K20_REASON" = token_idle ] && [ "$K20_STATE" = disabled/idle ] &&
       printf '%s' "$K20_JOB" | grep -q tokens_idle_disabled && [ "$K20_EN" = 200 ] && [ "$K20_BACK" = 200 ] ; then
        t_ok "K20 a PAT idle for 30 days is disabled (401 token_idle); re-enabling it from the web page restores access"
    else
        t_fail "K20 idle rule (call=$K20_IDLE/$K20_REASON state=$K20_STATE job='$K20_JOB' enable=$K20_EN after=$K20_BACK)"
    fi

    # K21 — revoke is final
    k_api POST "/user/tokens/$K_PAT_ID/revoke" "" "$K_ATA"; K21_REV="$K_CODE"
    K21_CALL="$(k_rpc "$K_PAT" list_accounts)"
    k_api POST "/user/tokens/$K_PAT_ID/enable" "" "$K_ATA"; K21_EN="$K_CODE"
    if [ "$K21_REV" = 200 ] && [ "$K21_CALL" = 401 ] && [ "$K21_EN" = 409 ] ; then
        t_ok "K21 a revoked token is refused (401) and cannot be re-enabled"
    else
        t_fail "K21 revoke (revoke=$K21_REV call=$K21_CALL re-enable=$K21_EN)"
    fi

    # K22 — audit trail: date-named JSON lines, the events are there, no secret ever is
    K22_DAY="$(date -u +%Y-%m-%d)"
    K22_LOG="$(dcx mcp sh -c "cat /var/log/maild-mcp/audit-$K22_DAY.log /var/log/maild-mcp/access-$K22_DAY.log" 2>/dev/null)"
    if printf '%s' "$K22_LOG" | grep -q '"category":"web.login"' && printf '%s' "$K22_LOG" | grep -q '"event":"search_emails"' &&
       printf '%s' "$K22_LOG" | grep -q '"event":"address_claim_conflict"' && printf '%s' "$K22_LOG" | grep -q '"event":"token.idle_disabled"' &&
       ! printf '%s' "$K22_LOG" | grep -qF -e "$K_PA" -e "$K_PAT" -e "$K_PATM" -e "${K_TOKEN_B:-no-token}" ; then
        t_ok "K22 the audit/access logs (audit-$K22_DAY.log) record logins, tool calls and security events, and no password or token"
    else
        t_fail "K22 audit log content"
    fi
fi

# ================================= M. MailD MCP (P2: write access + sending) ===
# mcp/technical-proposal.md §6, §8.3, §7.3.3 and the 2026-10-30 decisions in mcp/progress.md:
# flags/move/folders/drafts, the two-step trash/spam/delete tools (handles bound to token + tool +
# arguments, single use; nothing is ever expunged), send/reply/forward through amavis:10026
# (sender ownership, Bcc envelope-only and kept in Sent, DKIM, confirmation for external
# recipients or by preference, the recipient rate limit, the log line outbound_watch counts) and
# the send-related preferences (signature, hidden folders, attachments) + the Activity list.
# Test mail is injected from cron through amavis:10026 (bank INTERNAL admits cron). Self-cleaning:
# the maild-p2-* messages and folders are removed, the counters reset; the accounts go with K's.
section "M. MailD MCP write tools and sending (flags, folders, trash/spam, send/reply/forward)"

M_TAG="maild-p2-$(chrono | cut -c1-10)"
M_A="alice@$DOMAIN"; M_B="bob@$DOMAIN"; M_C="charlie@$DOMAIN"
m_res() { python3 -c "import json,sys; d=json.loads(sys.argv[2]); print(eval(sys.argv[1], {}, {'d': d}))" "$1" "$M_RES" 2>/dev/null; }
m_call() { M_RES="$(dcx mcp python tests/mcp_call.py "$1" call "$2" "$3" 2>/dev/null | tail -n1)"; }
m_inject() { # <subject> [extra swaks args…] — From bob To alice, through amavis:10026 (cron is admitted).
    # `Message-Id` in swaks's own capitalisation replaces its header instead of adding a second one
    local subj="$1"; shift
    dcx cron sh -c "swaks --server amavis --port 10026 --from $M_B --to $M_A --header 'Subject: $subj' \
        --header 'Message-Id: <$subj@$DOMAIN>' $* >/dev/null 2>&1"
    wait_msg "$M_A" INBOX "$subj" 60
}
m_id() { # <subject> [folder] → the MCP id of the newest match (via search_emails)
    m_call "$M_PAT" search_emails "{\"account\":\"$M_A\",\"folder\":\"${2:-INBOX}\",\"subject\":\"$1\",\"limit\":5}"
    m_res "d['structured']['messages'][0]['id']"
}
m_flag_count() { dcx mda doveadm search -u "$M_A" mailbox "$1" uid "$2" "$3" 2>/dev/null | wc -l | tr -d ' '; }

if [ "$HAVE_DC" != 1 ] || [ -z "$MCP_DB_PW" ] || [ -z "${K_PA:-}" ] ; then
    t_skip "MailD MCP write/send checks (need docker, MCP secrets and the $DOMAIN fixtures)"
else
    MCP_M_TOUCHED=1
    dcx mcp python manage.py mcp_domains allow "$DOMAIN" > /dev/null 2>&1
    k_login "$M_A" "$K_PA"; M_AT="$K_AT"
    k_api POST /user/tokens '{"name":"m-all","scopes":["mail.read","mail.modify","mail.trash","mail.send"]}' "$M_AT"; M_PAT="$(k_json "d.get('token','')")"
    k_api POST /user/tokens '{"name":"m-all-2","scopes":["mail.read","mail.modify","mail.trash","mail.send"]}' "$M_AT"; M_PAT2="$(k_json "d.get('token','')")"
    k_api POST /user/tokens '{"name":"m-read","scopes":["mail.read"]}' "$M_AT"; M_PATR="$(k_json "d.get('token','')")"
    m_inject "$M_TAG-one"; m_inject "$M_TAG-two"
    M_ID1="$(m_id "$M_TAG-one")"; M_ID2="$(m_id "$M_TAG-two")"; M_UID1="${M_ID1#*.}"

    # M1 — the tool list grew to 21, in a stable order
    M1="$(dcx mcp python tests/mcp_call.py "$M_PAT" list 2>/dev/null | tr -d '\r' | paste -sd, -)"
    if [ "$M1" = "list_accounts,list_folders,check_new_mail,search_emails,get_email,get_thread,get_attachment,get_quota,mark_emails,move_emails,create_folder,rename_folder,save_draft,report_spam,not_spam,trash_emails,restore_from_trash,delete_folder,send_email,reply_email,forward_email" ] ; then
        t_ok "M1 tools/list: the 8 read tools + 13 write/send tools"
    else
        t_fail "M1 tools/list (got: $M1)"
    fi

    # M2 — mark_emails sets and clears \Seen and \Flagged
    m_call "$M_PAT" mark_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$M_ID1\"],\"read\":true,\"flagged\":true}"
    M2_ON="$(m_flag_count INBOX "$M_UID1" seen)$(m_flag_count INBOX "$M_UID1" flagged)"
    m_call "$M_PAT" mark_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$M_ID1\"],\"read\":false,\"flagged\":false}"
    M2_OFF="$(m_flag_count INBOX "$M_UID1" seen)$(m_flag_count INBOX "$M_UID1" flagged)"
    if [ "$M2_ON" = 11 ] && [ "$M2_OFF" = 00 ] ; then
        t_ok "M2 mark_emails sets and clears \\Seen and \\Flagged"
    else
        t_fail "M2 mark_emails (seen/flagged after set=$M2_ON after clear=$M2_OFF, want 11/00)"
    fi

    # M3 — folders: create, move into, rename, refuse to delete a non-empty / special folder,
    # delete an empty one in two steps
    M_F="P2-$M_TAG"; M_F2="P2r-$M_TAG"
    m_call "$M_PAT" create_folder "{\"account\":\"$M_A\",\"name\":\"$M_F\"}"; M3_C="$(m_res "d['structured']['status']")"
    m_call "$M_PAT" move_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$M_ID2\"],\"target\":\"$M_F\"}"; M3_M="$(m_res "d['structured']['affected']")"
    m_call "$M_PAT" rename_folder "{\"account\":\"$M_A\",\"folder\":\"$M_F\",\"new_name\":\"$M_F2\"}"; M3_R="$(m_res "d['structured']['status']")"
    m_call "$M_PAT" delete_folder "{\"account\":\"$M_A\",\"folder\":\"$M_F2\"}"; M3_NE="$(m_res "d['is_error'] and 'not empty' in d['text']")"
    m_call "$M_PAT" delete_folder "{\"account\":\"$M_A\",\"folder\":\"Sent\"}"; M3_SP="$(m_res "d['is_error']")"
    M_ID2B="$(m_id "$M_TAG-two" "$M_F2")"
    m_call "$M_PAT" move_emails "{\"account\":\"$M_A\",\"folder\":\"$M_F2\",\"ids\":[\"$M_ID2B\"],\"target\":\"INBOX\"}"
    m_call "$M_PAT" delete_folder "{\"account\":\"$M_A\",\"folder\":\"$M_F2\"}"; M3_H="$(m_res "d['structured']['confirm']")"
    m_call "$M_PAT" delete_folder "{\"account\":\"$M_A\",\"folder\":\"$M_F2\",\"confirm\":\"$M3_H\"}"; M3_D="$(m_res "d['structured']['status']")"
    M3_GONE="$(dcx mda doveadm mailbox list -u "$M_A" 2>/dev/null | grep -cx "$M_F2")"
    if [ "$M3_C" = done ] && [ "$M3_M" = 1 ] && [ "$M3_R" = done ] && [ "$M3_NE" = True ] && [ "$M3_SP" = True ] &&
       [ "$M3_D" = done ] && [ "$M3_GONE" = 0 ] ; then
        t_ok "M3 create/move/rename folders; delete_folder refuses non-empty and special folders, deletes an empty one in two steps"
    else
        t_fail "M3 folders (create=$M3_C move=$M3_M rename=$M3_R nonempty-refused=$M3_NE special-refused=$M3_SP delete=$M3_D gone=$M3_GONE)"
    fi
    M_ID2="$(m_id "$M_TAG-two")"

    # M4 — save_draft files a \Draft in Drafts and sends nothing
    m_call "$M_PAT" save_draft "{\"account\":\"$M_A\",\"to\":[\"$M_B\"],\"subject\":\"$M_TAG-draft\",\"body_text\":\"draft\"}"
    M4_N="$(dcx mda doveadm search -u "$M_A" mailbox Drafts subject "$M_TAG-draft" draft 2>/dev/null | wc -l | tr -d ' ')"
    M4_B="$(subj_count "$M_B" INBOX "$M_TAG-draft")"
    if [ "$(m_res "d['structured']['status']")" = done ] && [ "$M4_N" = 1 ] && [ "${M4_B:-0}" = 0 ] ; then
        t_ok "M4 save_draft stores a \\Draft in Drafts and sends nothing"
    else
        t_fail "M4 save_draft (drafts=$M4_N delivered-to-bob=$M4_B)"
    fi

    # M5 — report_spam is two-step: the preview moves nothing; the handle moves to Junk and the
    # imapsieve Bayes learning fires (same proof as F4: the vmail-owned sa-learn state)
    IMAPSIEVE_TOUCHED=1
    dcx mda rm -rf /tmp/.spamassassin > /dev/null 2>&1 || true
    m_call "$M_PAT" report_spam "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$M_ID1\"]}"
    M5_ST="$(m_res "d['structured']['status']")"; M5_H="$(m_res "d['structured']['confirm']")"; M5_PV="$(m_res "len(d['structured']['preview'])")"
    M5_STILL="$(subj_count "$M_A" INBOX "$M_TAG-one")"
    m_call "$M_PAT" report_spam "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$M_ID1\"],\"confirm\":\"$M5_H\"}"
    M5_DONE="$(m_res "d['structured']['to_folder']")"
    M5_ART=""; for _ in 1 2 3 4 5 ; do M5_ART="$(dcx mda sh -c 'stat -c %u /tmp/.spamassassin 2>/dev/null' 2>/dev/null | tr -d ' \r')"; [ "$M5_ART" = 5000 ] && break; sleep 2; done
    if [ "$M5_ST" = confirmation_required ] && [ "$M5_PV" = 1 ] && [ "$M5_STILL" = 1 ] && [ "$M5_DONE" = Junk ] && [ "$M5_ART" = 5000 ] ; then
        t_ok "M5 report_spam previews first (nothing moved), moves to Junk with the handle, and the Bayes learning fires"
    else
        t_fail "M5 report_spam (first=$M5_ST preview=$M5_PV still-in-inbox=$M5_STILL moved-to=$M5_DONE sa-learn uid=$M5_ART)"
    fi

    # M6 — a handle is single use and bound to token + arguments; not_spam brings the message back
    M_IDJ="$(m_id "$M_TAG-one" Junk)"
    m_call "$M_PAT" not_spam "{\"account\":\"$M_A\",\"ids\":[\"$M_IDJ\"]}"; M6_H="$(m_res "d['structured']['confirm']")"
    m_call "$M_PAT2" not_spam "{\"account\":\"$M_A\",\"ids\":[\"$M_IDJ\"],\"confirm\":\"$M6_H\"}"; M6_OTHER="$(m_res "d['is_error']")"
    m_call "$M_PAT" not_spam "{\"account\":\"$M_A\",\"ids\":[\"$M_IDJ\"],\"target\":\"Drafts\",\"confirm\":\"$M6_H\"}"; M6_ARGS="$(m_res "d['is_error']")"
    m_call "$M_PAT" not_spam "{\"account\":\"$M_A\",\"ids\":[\"$M_IDJ\"],\"confirm\":\"$M6_H\"}"; M6_OK="$(m_res "d['structured']['to_folder']")"
    m_call "$M_PAT" not_spam "{\"account\":\"$M_A\",\"ids\":[\"$M_IDJ\"],\"confirm\":\"$M6_H\"}"; M6_REPLAY="$(m_res "d['is_error']")"
    if [ "$M6_OTHER" = True ] && [ "$M6_ARGS" = True ] && [ "$M6_OK" = INBOX ] && [ "$M6_REPLAY" = True ] ; then
        t_ok "M6 confirmation handles refuse another token, other arguments and a replay; not_spam restores to INBOX"
    else
        t_fail "M6 handles/not_spam (other-token=$M6_OTHER other-args=$M6_ARGS done=$M6_OK replay=$M6_REPLAY)"
    fi
    M_ID1="$(m_id "$M_TAG-one")"

    # M7 — trash is two-step, restore undoes it, nothing is ever expunged
    M7_TOTAL0="$(( $(mbox_count "$M_A" INBOX) + $(mbox_count "$M_A" Trash) ))"
    m_call "$M_PAT" trash_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$M_ID1\",\"$M_ID2\"]}"; M7_H="$(m_res "d['structured']['confirm']")"
    m_call "$M_PAT" trash_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$M_ID1\",\"$M_ID2\"],\"confirm\":\"$M7_H\"}"; M7_T="$(m_res "d['structured']['affected']")"
    M7_IN_TRASH="$(subj_count "$M_A" Trash "$M_TAG-")"
    M7_TIDS="$(dcx mcp python tests/mcp_call.py "$M_PAT" call search_emails "{\"account\":\"$M_A\",\"folder\":\"Trash\",\"subject\":\"$M_TAG-\"}" 2>/dev/null | tail -n1 |
               python3 -c "import json,sys; print(json.dumps([m['id'] for m in json.load(sys.stdin)['structured']['messages']]))" 2>/dev/null)"
    m_call "$M_PAT" restore_from_trash "{\"account\":\"$M_A\",\"ids\":${M7_TIDS:-[]}}"; M7_R="$(m_res "d['structured']['affected']")"
    M7_TOTAL1="$(( $(mbox_count "$M_A" INBOX) + $(mbox_count "$M_A" Trash) ))"
    if [ "$M7_T" = 2 ] && [ "$M7_IN_TRASH" = 2 ] && [ "$M7_R" = 2 ] && [ "$M7_TOTAL0" = "$M7_TOTAL1" ] ; then
        t_ok "M7 trash_emails (two steps) moves to Trash, restore_from_trash brings both back, nothing expunged ($M7_TOTAL1 messages before and after)"
    else
        t_fail "M7 trash/restore (trashed=$M7_T in-trash=$M7_IN_TRASH restored=$M7_R total $M7_TOTAL0 → $M7_TOTAL1)"
    fi

    M_ID1="$(m_id "$M_TAG-one")"   # trash + restore gave the messages new UIDs

    # M8 — send inside the hosted domains: no confirmation, DKIM-signed, Bcc only on the envelope,
    # kept in the Sent copy, one "maild-mcp: sent" line
    m_call "$M_PAT" send_email "{\"to\":[\"$M_B\"],\"bcc\":[\"$M_C\"],\"subject\":\"$M_TAG-send\",\"body_text\":\"hello\"}"
    M8_ST="$(m_res "d['structured']['status']")"; M8_SF="$(m_res "d['structured']['sent_folder']")"
    wait_msg "$M_B" INBOX "$M_TAG-send" 60; wait_msg "$M_C" INBOX "$M_TAG-send" 60
    M8_BU="$(msg_newest_uid "$M_B" INBOX "$M_TAG-send")"; M8_CU="$(msg_newest_uid "$M_C" INBOX "$M_TAG-send")"
    M8_BTXT="$(msg_text "$M_B" INBOX "${M8_BU:-0}")"; M8_CTXT="$(msg_text "$M_C" INBOX "${M8_CU:-0}")"
    M8_SU="$(msg_newest_uid "$M_A" Sent "$M_TAG-send")"; M8_STXT="$(msg_text "$M_A" Sent "${M8_SU:-0}")"
    M8_LOG="$("${DC[@]}" logs --no-log-prefix --since 3m mcp 2>/dev/null | grep -c "maild-mcp: sent user=$M_A rcpts=2")"
    if [ "$M8_ST" = sent ] && [ "$M8_SF" = Sent ] && printf '%s' "$M8_BTXT" | grep -qi '^DKIM-Signature:' &&
       ! printf '%s\n%s' "$M8_BTXT" "$M8_CTXT" | grep -qi '^Bcc:' && [ -n "$M8_CU" ] &&
       printf '%s' "$M8_STXT" | grep -qi "^Bcc: $M_C" && [ "${M8_LOG:-0}" -ge 1 ] ; then
        t_ok "M8 send_email (internal): no confirmation, DKIM-signed, Bcc delivered but hidden, kept in the Sent copy, logged for outbound_watch"
    else
        t_fail "M8 send (status=$M8_ST sent=$M8_SF bob=${M8_BU:-none} charlie=${M8_CU:-none} log=$M8_LOG)"
    fi

    # M9 — an external recipient needs the confirmation; the preview submits nothing
    M9_LOG0="$("${DC[@]}" logs --no-log-prefix mcp 2>/dev/null | grep -c 'maild-mcp: sent')"
    m_call "$M_PAT" send_email "{\"to\":[\"someone@$RELAY_PROBE_DOMAIN\"],\"subject\":\"$M_TAG-ext\",\"body_text\":\"x\"}"
    M9_ST="$(m_res "d['structured']['status']")"; M9_WHY="$(m_res "d['structured']['preview']['reason']")"
    M9_LOG1="$("${DC[@]}" logs --no-log-prefix mcp 2>/dev/null | grep -c 'maild-mcp: sent')"
    if [ "$M9_ST" = confirmation_required ] && printf '%s' "$M9_WHY" | grep -q "someone@$RELAY_PROBE_DOMAIN" && [ "$M9_LOG0" = "$M9_LOG1" ] ; then
        t_ok "M9 an external recipient needs the two-step confirmation (preview names it, nothing submitted)"
    else
        t_fail "M9 external confirmation (status=$M9_ST reason='$M9_WHY' sends $M9_LOG0 → $M9_LOG1)"
    fi

    # M10 — sender ownership and scope
    m_call "$M_PAT" send_email "{\"sender\":\"$M_C\",\"to\":[\"$M_B\"],\"subject\":\"$M_TAG-forged\",\"body_text\":\"x\"}"; M10_FOREIGN="$(m_res "d['is_error'] and 'not an address this token may send from' in d['text']")"
    M10_SCOPE="$(k_rpc "$M_PATR" send_email)"
    if [ "$M10_FOREIGN" = True ] && [ "$M10_SCOPE" = 403 ] ; then
        t_ok "M10 a sender that is not the caller's is refused; a read-only token gets 403 on send_email"
    else
        t_fail "M10 sender/scope (foreign-refused=$M10_FOREIGN read-only=$M10_SCOPE)"
    fi

    # M11 — reply: default sender = the address it was sent to, Re: subject, threading headers, quote
    m_call "$M_PAT" reply_email "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$M_ID1\",\"body_text\":\"my reply\"}"
    M11_ST="$(m_res "d['structured']['status']")"; M11_SND="$(m_res "d['structured']['sender']")"
    wait_msg "$M_B" INBOX "Re: $M_TAG-one" 60
    M11_U="$(msg_newest_uid "$M_B" INBOX "Re: $M_TAG-one")"; M11_TXT="$(msg_text "$M_B" INBOX "${M11_U:-0}")"
    if [ "$M11_ST" = sent ] && [ "$M11_SND" = "$M_A" ] && printf '%s' "$M11_TXT" | grep -q "^In-Reply-To: <$M_TAG-one@$DOMAIN>" &&
       printf '%s' "$M11_TXT" | grep -q "wrote:" ; then
        t_ok "M11 reply_email answers from the address it was sent to, with Re:, In-Reply-To and the quoted original"
    else
        t_fail "M11 reply (status=$M11_ST sender=$M11_SND delivered=${M11_U:-none})"
    fi

    # M12 — forward keeps the attachment
    dcx cron sh -c "printf 'attached-%s\n' $M_TAG > /tmp/$M_TAG.txt" > /dev/null 2>&1
    m_inject "$M_TAG-att" --attach-type text/plain --attach-name "$M_TAG.txt" --attach "@/tmp/$M_TAG.txt"
    dcx cron rm -f "/tmp/$M_TAG.txt" > /dev/null 2>&1
    M_IDA="$(m_id "$M_TAG-att")"
    m_call "$M_PAT" forward_email "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$M_IDA\",\"to\":[\"$M_C\"],\"body_text\":\"fyi\"}"
    M12_ST="$(m_res "d['structured']['status']")"
    wait_msg "$M_C" INBOX "Fwd: $M_TAG-att" 60
    M12_U="$(msg_newest_uid "$M_C" INBOX "Fwd: $M_TAG-att")"
    if [ "$M12_ST" = sent ] && msg_text "$M_C" INBOX "${M12_U:-0}" | grep -q "filename=\"\\?$M_TAG.txt" ; then
        t_ok "M12 forward_email delivers 'Fwd:' with the original attachment"
    else
        t_fail "M12 forward (status=$M12_ST delivered=${M12_U:-none})"
    fi

    # M13 — the recipient rate limit (per account): a window already at the limit refuses the send
    M13_LIMIT="$(dcx mcp printenv MCP_SEND_RATE_RECIPIENTS 2>/dev/null | tr -d '\r')"; M13_LIMIT="${M13_LIMIT:-200}"
    M13_ACC="$(dcx db psql -U maild -d mcp -tAc "SELECT id FROM account WHERE main_email='$M_A'" 2>/dev/null | tr -d '\r ')"
    dcx db psql -U maild -d mcp -q -c "INSERT INTO send_counter (subject, window_start, recipients)
        VALUES ('acct:$M13_ACC', to_timestamp(floor(extract(epoch FROM now()) / 3600) * 3600), $M13_LIMIT)
        ON CONFLICT (subject, window_start) DO UPDATE SET recipients = $M13_LIMIT" > /dev/null 2>&1
    m_call "$M_PAT" send_email "{\"to\":[\"$M_B\"],\"subject\":\"$M_TAG-throttled\",\"body_text\":\"x\"}"
    M13_ERR="$(m_res "d['is_error'] and 'send limit reached' in d['text']")"
    M13_LOG="$("${DC[@]}" logs --no-log-prefix --since 2m mcp 2>/dev/null | grep -c "maild-mcp: throttled user=$M_A")"
    dcx db psql -U maild -d mcp -q -c "DELETE FROM send_counter WHERE subject IN ('acct:$M13_ACC', 'addr:$M_A')" > /dev/null 2>&1
    if [ "$M13_ERR" = True ] && [ "${M13_LOG:-0}" -ge 1 ] && [ "$(subj_count "$M_B" INBOX "$M_TAG-throttled")" = 0 ] ; then
        t_ok "M13 the send rate limit refuses a send over $M13_LIMIT recipients/window (logged as maild-mcp: throttled)"
    else
        t_fail "M13 rate limit (refused=$M13_ERR log=$M13_LOG)"
    fi

    # M14 — preferences: confirmation "always", signature, hidden folder, attachments off
    k_api PUT /user/prefs "{\"confirm_send\":\"always\",\"signature\":\"$M_TAG-sig\",\"hidden_folders\":[\"Drafts\"],\"allow_attachments\":false}" "$M_AT"; M14_PUT="$K_CODE"
    k_api PUT /user/prefs '{"confirm_send":"never"}' "$M_AT"; M14_NEVER="$K_CODE"
    m_call "$M_PAT" send_email "{\"to\":[\"$M_B\"],\"subject\":\"$M_TAG-sig\",\"body_text\":\"x\"}"; M14_H="$(m_res "d['structured']['confirm']")"; M14_ST="$(m_res "d['structured']['status']")"
    m_call "$M_PAT" send_email "{\"to\":[\"$M_B\"],\"subject\":\"$M_TAG-sig\",\"body_text\":\"x\",\"confirm\":\"$M14_H\"}"
    wait_msg "$M_B" INBOX "$M_TAG-sig" 60; M14_U="$(msg_newest_uid "$M_B" INBOX "$M_TAG-sig")"
    M14_SIG="$(msg_text "$M_B" INBOX "${M14_U:-0}" | grep -c "$M_TAG-sig")"
    m_call "$M_PAT" list_folders "{\"account\":\"$M_A\"}"; M14_HID="$(m_res "'Drafts' not in [f['name'] for f in d['structured']['folders']]")"
    m_call "$M_PAT" search_emails "{\"account\":\"$M_A\",\"folder\":\"Drafts\"}"; M14_HSRCH="$(m_res "d['is_error'] and 'hidden' in d['text']")"
    m_call "$M_PAT" get_email "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$M_IDA\",\"mark_read\":false}"; M14_PART="$(m_res "d['structured']['attachments'][0]['part']")"
    m_call "$M_PAT" get_attachment "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$M_IDA\",\"part\":\"$M14_PART\"}"; M14_ATT="$(m_res "d['is_error']")"
    k_api PUT /user/prefs '{"confirm_send":"external","signature":"","hidden_folders":[],"allow_attachments":true}' "$M_AT"
    m_call "$M_PAT" get_attachment "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$M_IDA\",\"part\":\"$M14_PART\"}"; M14_ATT2="$(m_res "d['is_error']")"
    if [ "$M14_PUT" = 200 ] && [ "$M14_NEVER" = 400 ] && [ "$M14_ST" = confirmation_required ] && [ "${M14_SIG:-0}" -ge 1 ] &&
       [ "$M14_HID" = True ] && [ "$M14_HSRCH" = True ] && [ "$M14_ATT" = True ] && [ "$M14_ATT2" = False ] ; then
        t_ok "M14 preferences: 'always' confirms even internal mail ('never' is not offered), the signature is appended, a hidden folder is neither listed nor searchable, attachments can be withheld"
    else
        t_fail "M14 preferences (put=$M14_PUT never=$M14_NEVER confirm=$M14_ST signature=$M14_SIG hidden-list=$M14_HID hidden-search=$M14_HSRCH att-off=$M14_ATT att-on-error=$M14_ATT2)"
    fi

    # M15 — the Activity list (last 50 actions) shows the tool calls
    k_api GET /user/activity "" "$M_AT"
    M15="$(k_json "[i['event'] for i in d['items']]")"
    if [ "$K_CODE" = 200 ] && printf '%s' "$M15" | grep -q "'send_email'" && printf '%s' "$M15" | grep -q "'trash_emails'" ; then
        t_ok "M15 the Activity list (GET /webapi/user/activity) shows the account's recent tool calls"
    else
        t_fail "M15 activity (code=$K_CODE events=$(printf '%s' "$M15" | head -c 160))"
    fi
fi

# ================================= N. MailD MCP admin panel (P3) ==============
# mcp/technical-proposal.md §7.2, D7 and the 2026-10-30 decisions in mcp/progress.md: admin
# sign-in (password + ALTCHA + mailed code, lockout), CLI reset, recovery link, password and email
# change with codes, the settings groups (user policy bounds, the "never"/force-confirm switches,
# logging switches), the domains dual list, master tokens (TTL cap, X-MailD-Act-As, CIDR, denied
# domain, always audited, optional owner notice), the user notifications, external service SMTP
# through mta:587 with the Test transcript, and the logs viewer. Self-cleaning: the admin row, the
# settings, the domain policy and the service mailbox hash are snapshotted and restored.
section "N. MailD MCP admin panel (sign-in, settings, domains, master tokens, service email)"

N_ADMIN_MAIL="$(env_value "$ENV_FILE" MCP_ADMIN_EMAIL || true)"; N_ADMIN_MAIL="${N_ADMIN_MAIL:-$DEPLOY_ADMIN}"
N_JAR="$TMPRUN/n.cookies"
n_sql() { dcx db psql -U maild -d mcp -tAc "$1" 2>/dev/null | tr -d '\r'; }
n_api() { # <method> <path> [json] [access] [jar] → K_CODE, body in $K_OUT (admin API)
    local args=(-s -o "$K_OUT" -w '%{http_code}' -X "$1" -H 'Content-Type: application/json' --max-time 60)
    [ -n "${3:-}" ] && args+=(--data "$3")
    [ -n "${4:-}" ] && args+=(-H "Authorization: Bearer $4")
    [ -n "${5:-}" ] && args+=(-b "$5" -c "$5")
    K_CODE="$(curl "${args[@]}" "$MCP_HTTP/webapi/admin$2")"
}
n_code() { # <to> <subject prefix> <count before> → the newest code mailed with that subject
    wait_subj_count_gt "$1" INBOX "$2" "$3" 60 || return 1
    local uid; uid="$(msg_newest_uid "$1" INBOX "$2")"
    dcx mda doveadm fetch -u "$1" hdr mailbox INBOX uid "$uid" 2>/dev/null | sed -n "s/^Subject: .*: \([0-9]\{6\}\).*/\1/p" | head -n1
}
n_login() { # <password> → N_AT (or empty); K_CODE of the last step
    local before ch code
    before="$(subj_count "$N_ADMIN_MAIL" INBOX "MailD MCP admin code")"
    n_api POST /login "{\"username\":\"admin\",\"password\":\"$1\",\"altcha\":\"$(k_altcha)\"}"
    N_AT=""; [ "$K_CODE" = 200 ] || return 1
    ch="$(k_json "d['challenge_id']")"; code="$(n_code "$N_ADMIN_MAIL" "MailD MCP admin code" "${before:-0}")"
    rm -f "$N_JAR"
    n_api POST /login/verify "{\"challenge_id\":\"$ch\",\"code\":\"$code\"}" "" "$N_JAR"
    N_AT="$(k_json "d.get('access_token','')")"
}
n_settings() { n_api PUT "/settings/$1" "$2" "$N_AT"; sleep 3; }   # 2 s settings cache per worker

if [ "$HAVE_DC" != 1 ] || [ -z "$MCP_DB_PW" ] || [ -z "${K_PA:-}" ] ; then
    t_skip "MailD MCP admin checks (need docker, MCP secrets and the $DOMAIN fixtures)"
else
    MCP_N_TOUCHED=1
    dcx db psql -U maild -d mcp -q -c "DROP TABLE IF EXISTS n_bak_admin, n_bak_setting, n_bak_policy;
        CREATE TABLE n_bak_admin AS SELECT * FROM admin_user; CREATE TABLE n_bak_setting AS SELECT * FROM setting;
        CREATE TABLE n_bak_policy AS SELECT * FROM domain_policy;" > /dev/null 2>&1
    N_SVC="$(env_value "$ENV_FILE" MCP_SERVICE_EMAIL || true)"; N_SVC="${N_SVC:-mcp@$DEFAULT_DOMAIN}"
    N_SVC_HASH="$(sql "SELECT password FROM mailbox WHERE username='$N_SVC'" | tr -d '\r')"
    N_PW1="n-$(chrono | cut -c1-20)"; N_PW2="n2-$(chrono | cut -c1-20)"; N_PW3="n3-$(chrono | cut -c1-20)"

    # N1 — CLI reset sets a known password; sign-in = password + ALTCHA + the code mailed to the admin
    dcx mcp python manage.py mcp_admin_reset --password "$N_PW1" > /dev/null 2>&1
    n_api POST /login "{\"username\":\"admin\",\"password\":\"wrong-$RANDOM\",\"altcha\":\"$(k_altcha)\"}"; N1_BAD="$K_CODE"
    N1_BEFORE="$(subj_count "$N_ADMIN_MAIL" INBOX "MailD MCP admin code")"
    n_api POST /login "{\"username\":\"admin\",\"password\":\"$N_PW1\",\"altcha\":\"$(k_altcha)\"}"; N1_S1="$K_CODE"; N1_CH="$(k_json "d['challenge_id']")"
    N1_CODE="$(n_code "$N_ADMIN_MAIL" "MailD MCP admin code" "${N1_BEFORE:-0}")"
    n_api POST /login/verify "{\"challenge_id\":\"$N1_CH\",\"code\":\"000000\"}"; N1_WRONG="$K_CODE"
    rm -f "$N_JAR"
    N1_HDR="$(curl -s -D - -o "$K_OUT" -X POST "$MCP_HTTP/webapi/admin/login/verify" -H 'Content-Type: application/json' -c "$N_JAR" \
              --data "{\"challenge_id\":\"$N1_CH\",\"code\":\"$N1_CODE\"}" | tr -d '\r')"
    N_AT="$(k_json "d.get('access_token','')")"
    N1_CK="$(printf '%s\n' "$N1_HDR" | grep -i '^set-cookie: mdmcp_admin_refresh=')"
    n_api GET /me "" "$N_AT"; N1_ME="$K_CODE"
    if [ "$N1_BAD" = 401 ] && [ "$N1_S1" = 200 ] && [ -n "$N1_CODE" ] && [ "$N1_WRONG" = 400 ] && [ "$N1_ME" = 200 ] &&
       printf '%s' "$N1_CK" | grep -qi 'httponly' && printf '%s' "$N1_CK" | grep -qi 'path=/webapi/admin' && printf '%s' "$N1_CK" | grep -qi 'samesite=strict' ; then
        t_ok "N1 admin sign-in: wrong password 401; password + ALTCHA mail a code to $N_ADMIN_MAIL; a wrong code is refused; the right one opens a session (cookie Path=/webapi/admin)"
    else
        t_fail "N1 admin sign-in (bad=$N1_BAD step1=$N1_S1 code=${N1_CODE:+yes} wrong=$N1_WRONG me=$N1_ME cookie='${N1_CK:-none}')"
    fi

    # N2 — CLI reset revokes the sessions; recovery link (neutral answer) sets a new password, once
    dcx mcp python manage.py mcp_admin_reset --password "$N_PW2" > /dev/null 2>&1
    n_api GET /me "" "$N_AT"; N2_REVOKED="$K_CODE"
    N2_R0="$(subj_count "$N_ADMIN_MAIL" INBOX "admin password reset")"
    n_api POST /recover "{\"email\":\"nobody@$DOMAIN\",\"altcha\":\"$(k_altcha)\"}"; N2_UNK="$K_CODE"; N2_UNK_MSG="$(k_json "d['message']")"
    n_api POST /recover "{\"email\":\"$N_ADMIN_MAIL\",\"altcha\":\"$(k_altcha)\"}"; N2_KNOWN_MSG="$(k_json "d['message']")"
    N2_TOKEN=""
    if wait_subj_count_gt "$N_ADMIN_MAIL" INBOX "admin password reset" "${N2_R0:-0}" 60 ; then
        N2_UID="$(msg_newest_uid "$N_ADMIN_MAIL" INBOX "admin password reset")"
        N2_TOKEN="$(msg_text "$N_ADMIN_MAIL" INBOX "$N2_UID" | sed '1{/^text:/d}' | python3 -c 'import email,email.policy,re,sys
m = email.message_from_bytes(sys.stdin.buffer.read(), policy=email.policy.default)
f = re.search(r"reset#(mdmcp_rc_[A-Za-z0-9_-]+)", (m.get_body(("plain",)) or m).get_content())
print(f.group(1) if f else "")' 2>/dev/null)"
    fi
    n_api POST /reset "{\"token\":\"$N2_TOKEN\",\"password\":\"$N_PW3\",\"altcha\":\"$(k_altcha)\"}"; N2_RESET="$K_CODE"
    n_api POST /reset "{\"token\":\"$N2_TOKEN\",\"password\":\"$N_PW3\",\"altcha\":\"$(k_altcha)\"}"; N2_AGAIN="$K_CODE"
    n_login "$N_PW3"; N2_LOGIN="$K_CODE"
    if [ "$N2_REVOKED" = 401 ] && [ "$N2_UNK" = 200 ] && [ "$N2_UNK_MSG" = "$N2_KNOWN_MSG" ] && [ -n "$N2_TOKEN" ] &&
       [ "$N2_RESET" = 200 ] && [ "$N2_AGAIN" = 404 ] && [ "$N2_LOGIN" = 200 ] ; then
        t_ok "N2 the CLI reset revokes admin sessions; recovery answers alike for any address, mails a single-use link, and the new password works"
    else
        t_fail "N2 reset/recovery (revoked=$N2_REVOKED neutral=$([ "$N2_UNK_MSG" = "$N2_KNOWN_MSG" ] && echo yes || echo no) link=${N2_TOKEN:+yes} reset=$N2_RESET again=$N2_AGAIN login=$N2_LOGIN)"
    fi

    # N3 — password change: current password + code; email change: one code to the OLD, one to the NEW address
    n_api POST /password/start "{\"current\":\"wrong\",\"new\":\"$N_PW1\"}" "$N_AT"; N3_WRONGCUR="$K_CODE"
    N3_B="$(subj_count "$N_ADMIN_MAIL" INBOX "MailD MCP admin code")"
    n_api POST /password/start "{\"current\":\"$N_PW3\",\"new\":\"$N_PW1\"}" "$N_AT"; N3_CH="$(k_json "d['challenge_id']")"
    N3_CODE="$(n_code "$N_ADMIN_MAIL" "MailD MCP admin code" "${N3_B:-0}")"
    n_api POST /password/confirm "{\"challenge_id\":\"$N3_CH\",\"code\":\"$N3_CODE\"}" "$N_AT"; N3_PW="$K_CODE"
    N3_OB="$(subj_count "$N_ADMIN_MAIL" INBOX "MailD MCP admin code")"; N3_NB="$(subj_count "$K_A" INBOX "MailD MCP admin code")"
    n_api POST /email/start "{\"new_email\":\"$K_A\"}" "$N_AT"; N3_G="$(k_json "d['group']")"
    N3_CO="$(n_code "$N_ADMIN_MAIL" "MailD MCP admin code" "${N3_OB:-0}")"; N3_CN="$(n_code "$K_A" "MailD MCP admin code" "${N3_NB:-0}")"
    n_api POST /email/confirm "{\"group\":\"$N3_G\",\"code_old\":\"$N3_CO\",\"code_new\":\"000000\"}" "$N_AT"; N3_HALF="$K_CODE"
    n_api POST /email/confirm "{\"group\":\"$N3_G\",\"code_old\":\"$N3_CO\",\"code_new\":\"$N3_CN\"}" "$N_AT"; N3_EM="$K_CODE"; N3_NEWMAIL="$(k_json "d.get('email')")"
    dcx db psql -U maild -d mcp -q -c "UPDATE admin_user SET email='$N_ADMIN_MAIL'" > /dev/null 2>&1   # back (codes would go to alice)
    n_login "$N_PW1"; N3_LOGIN="$K_CODE"
    if [ "$N3_WRONGCUR" = 401 ] && [ "$N3_PW" = 200 ] && [ "$N3_HALF" = 400 ] && [ "$N3_EM" = 200 ] && [ "$N3_NEWMAIL" = "$K_A" ] && [ "$N3_LOGIN" = 200 ] ; then
        t_ok "N3 the admin password changes with the current password + a mailed code; the email changes only with both codes (old and new address)"
    else
        t_fail "N3 password/email change (wrong-current=$N3_WRONGCUR pw=$N3_PW half=$N3_HALF email=$N3_EM→$N3_NEWMAIL login=$N3_LOGIN)"
    fi

    # N4 — settings: bounds are enforced; the admin's switches drive the user side
    n_api PUT /settings/user_policy '{"pat_idle_days":31}' "$N_AT"; N4_BOUND="$K_CODE"
    k_login "$K_A" "$K_PA"; N_UAT="$K_AT"
    k_api PUT /user/prefs '{"confirm_send":"never"}' "$N_UAT"; N4_NEVER_OFF="$K_CODE"
    n_settings user_policy '{"allow_no_confirm":true,"force_confirm":true}'
    k_api PUT /user/prefs '{"confirm_send":"never"}' "$N_UAT"; N4_NEVER_ON="$K_CODE"
    k_api POST /user/tokens '{"name":"n-send","scopes":["mail.read","mail.send"]}' "$N_UAT"; N_PATS="$(k_json "d.get('token','')")"
    m_call "$N_PATS" send_email "{\"to\":[\"$K_B\"],\"subject\":\"maild-p3-force\",\"body_text\":\"x\"}"; N4_FORCE="$(m_res "d['structured']['status']")"
    n_settings user_policy '{"allow_no_confirm":false,"force_confirm":false}'
    k_api PUT /user/prefs '{"confirm_send":"external"}' "$N_UAT"
    if [ "$N4_BOUND" = 400 ] && [ "$N4_NEVER_OFF" = 400 ] && [ "$N4_NEVER_ON" = 200 ] && [ "$N4_FORCE" = confirmation_required ] ; then
        t_ok "N4 user policy: the idle limit cannot exceed 30 days; 'never confirm' only once the admin allows it; 'force confirmation' covers internal sends"
    else
        t_fail "N4 policy (idle-31=$N4_BOUND never-before=$N4_NEVER_OFF never-after=$N4_NEVER_ON forced=$N4_FORCE)"
    fi

    # N5 — the domains dual list is the allow-list (D6)
    n_api PUT /domains '{"allowed":[]}' "$N_AT"; k_login "$K_C" "$K_PC"; N5_DENIED="$K_CODE"
    n_api PUT /domains "{\"allowed\":[\"$DOMAIN\"]}" "$N_AT"; N5_PUT="$K_CODE"; k_login "$K_C" "$K_PC"; N5_OK="$K_CODE"
    n_api PUT /domains '{"allowed":["no-such-domain.invalid"]}' "$N_AT"; N5_UNK="$K_CODE"
    if [ "$N5_DENIED" = 403 ] && [ "$N5_PUT" = 200 ] && [ "$N5_OK" = 200 ] && [ "$N5_UNK" = 400 ] ; then
        t_ok "N5 the Domains dual list is the MCP allow-list (empty → login 403; $DOMAIN allowed → 200; unknown domains refused)"
    else
        t_fail "N5 domains (denied=$N5_DENIED put=$N5_PUT allowed=$N5_OK unknown=$N5_UNK)"
    fi

    # N6 — master tokens: TTL cap and never forever; X-MailD-Act-As; a mailbox without any MCP account; denied
    # domain; CIDR allowlist; revoke
    n_api POST /master-tokens '{"name":"n-long","ttl_hours":100000,"scopes":["mail.read"]}' "$N_AT"; N6_LONG="$K_CODE"
    n_api POST /master-tokens '{"name":"n-master","ttl_hours":1,"scopes":["mail.read"]}' "$N_AT"; N_MT="$(k_json "d.get('token','')")"; N_MT_ID="$(k_json "d.get('id','')")"
    n_api POST /master-tokens '{"name":"n-cidr","ttl_hours":1,"scopes":["mail.read"],"allowed_cidrs":["192.0.2.0/24"]}' "$N_AT"; N_MTC="$(k_json "d.get('token','')")"
    n_rpc() { curl -s -o "$K_OUT" -w '%{http_code}' --max-time 30 -X POST "$MCP_HTTP/api/v1/mcp" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-11-25' -H "Authorization: Bearer $1" ${2:+-H "X-MailD-Act-As: $2"} \
        --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_accounts","arguments":{}}}'; }
    N6_NOACT="$(n_rpc "$N_MT")"
    N6_DYLAN="$(n_rpc "$N_MT" "$K_D")"; N6_WHO="$(python3 -c "import json; print(json.load(open('$K_OUT'))['result']['structuredContent']['default_sender'])" 2>/dev/null)"
    N6_DENIED="$(n_rpc "$N_MT" "$DEPLOY_ADMIN")"
    N6_CIDR="$(n_rpc "$N_MTC" "$K_D")"
    if [ "$N6_LONG" = 400 ] && [ "$N6_NOACT" = 400 ] && [ "$N6_DYLAN" = 200 ] && [ "$N6_WHO" = "$K_D" ] &&
       [ "$N6_DENIED" = 403 ] && [ "$N6_CIDR" = 403 ] ; then
        t_ok "N6 master tokens: capped TTL, X-MailD-Act-As required, act on a mailbox with no MCP account, denied domain and foreign source refused (403)"
    else
        t_fail "N6 master token (long=$N6_LONG no-act-as=$N6_NOACT act-as=$N6_DYLAN/$N6_WHO denied-domain=$N6_DENIED cidr=$N6_CIDR)"
    fi

    # N7 — D7: master-token use is audited even with logging switched off; the owner notice is optional
    n_settings logging '{"enabled":false}'
    N7_DAY="$(date -u +%Y-%m-%d)"
    N7_A0="$(dcx mcp sh -c "grep -c '\"event\":\"master_token_use\"' /var/log/maild-mcp/audit-$N7_DAY.log" 2>/dev/null | tr -d '\r')"
    N7_M0="$(dcx mcp sh -c "grep -c '\"event\":\"list_accounts\"' /var/log/maild-mcp/audit-$N7_DAY.log" 2>/dev/null | tr -d '\r')"
    N7_N0="$(subj_count "$K_D" INBOX "administrator access to $K_D")"
    n_rpc "$N_MT" "$K_D" > /dev/null
    m_call "$N_PATS" list_accounts '{}'
    N7_A1="$(dcx mcp sh -c "grep -c '\"event\":\"master_token_use\"' /var/log/maild-mcp/audit-$N7_DAY.log" 2>/dev/null | tr -d '\r')"
    N7_M1="$(dcx mcp sh -c "grep -c '\"event\":\"list_accounts\"' /var/log/maild-mcp/audit-$N7_DAY.log" 2>/dev/null | tr -d '\r')"
    n_settings logging '{"enabled":true}'
    n_settings user_policy '{"master_notify_user":true}'
    n_rpc "$N_MT" "$K_D" > /dev/null; n_rpc "$N_MT" "$K_D" > /dev/null
    wait_subj_count_gt "$K_D" INBOX "administrator access to $K_D" "${N7_N0:-0}" 60; sleep 3
    N7_N1="$(subj_count "$K_D" INBOX "administrator access to $K_D")"
    n_settings user_policy '{"master_notify_user":false}'
    if [ "$((N7_A1 - N7_A0))" -ge 1 ] && [ "$((N7_M1 - N7_M0))" -ge 1 ] && [ "$(( ${N7_N1:-0} - ${N7_N0:-0} ))" = 1 ] ; then
        t_ok "N7 with logging off, the master token's calls are still audited (a PAT's are not); the opt-in owner notice arrives once for two accesses"
    else
        t_fail "N7 D7 audit/notice (master lines +$((N7_A1 - N7_A0)) master tool lines +$((N7_M1 - N7_M0)) notices ${N7_N0:-0}→${N7_N1:-0})"
    fi
    N7_PAT_LINES="$(dcx mcp sh -c "grep '\"event\":\"list_accounts\"' /var/log/maild-mcp/audit-$N7_DAY.log | grep -c '\"kind\":\"pat\"'" 2>/dev/null | tr -d '\r')"
    n_api POST "/master-tokens/$N_MT_ID/revoke" "" "$N_AT"; N7_REV="$(n_rpc "$N_MT" "$K_D")"
    if [ "$N7_REV" = 401 ] ; then t_ok "N7b a revoked master token is refused (401)"; else t_fail "N7b revoked master token (got $N7_REV)"; fi

    # N8 — user notifications: a new token, and its first use from a new client (only once)
    N8_T0="$(subj_count "$K_A" INBOX "new access token \"n-notice\"")"
    k_api POST /user/tokens '{"name":"n-notice","scopes":["mail.read"]}' "$N_UAT"; N_PATN="$(k_json "d.get('token','')")"
    N8_U0="$(subj_count "$K_A" INBOX "token \"n-notice\" used from a new place")"
    m_call "$N_PATN" list_accounts '{}'; m_call "$N_PATN" list_accounts '{}'
    wait_subj_count_gt "$K_A" INBOX "token \"n-notice\" used from a new place" "${N8_U0:-0}" 60; sleep 3
    N8_T1="$(subj_count "$K_A" INBOX "new access token \"n-notice\"")"; N8_U1="$(subj_count "$K_A" INBOX "token \"n-notice\" used from a new place")"
    if [ "$(( ${N8_T1:-0} - ${N8_T0:-0} ))" = 1 ] && [ "$(( ${N8_U1:-0} - ${N8_U0:-0} ))" = 1 ] ; then
        t_ok "N8 the owner is mailed when a token is created and when it is first used from a new IP/client (once)"
    else
        t_fail "N8 notifications (new-token ${N8_T0:-0}→${N8_T1:-0}, new-client ${N8_U0:-0}→${N8_U1:-0})"
    fi

    # N9 — external service SMTP = mta:587 (STARTTLS + AUTH as the service mailbox); the Test transcript
    N9_PW="svc-$(chrono | cut -c1-24)"
    N9_HASH="$(dcx mda doveadm pw -s ARGON2ID -p "$N9_PW" 2>/dev/null | tr -d '\r')"
    sql "UPDATE mailbox SET password='$N9_HASH' WHERE username='$N_SVC'" > /dev/null; dcx mda doveadm auth cache flush > /dev/null 2>&1
    # the dev mta presents the self-signed CN=maild.cu cert: strict verification must refuse it first,
    # then the admin's opt-out (decision 2026-10-30) lets the encrypted, unauthenticated test through
    n_settings service_email "{\"transport\":\"external\",\"host\":\"mta\",\"port\":587,\"tls\":\"starttls\",\"verify_tls\":true,\"user\":\"$N_SVC\",\"password\":\"$N9_PW\"}"
    n_api POST /service-email/test "" "$N_AT"; N9_STRICT="$(k_json "d['ok']")"; N9_STRICT_ERR="$(k_json "'CERTIFICATE_VERIFY_FAILED' in d['error']")"
    n_settings service_email '{"verify_tls":false}'
    n_api GET /settings/service_email "" "$N_AT"; N9_SECRET="$(grep -c "$N9_PW" "$K_OUT")"; N9_SET="$(k_json "d['password_set']")"
    N9_B="$(subj_count "$N_ADMIN_MAIL" INBOX "service email test")"
    n_api POST /service-email/test "" "$N_AT"
    N9_OK="$(k_json "d['ok']")"; N9_STEPS="$(k_json "','.join(s['step'] for s in d['steps'])")"
    wait_subj_count_gt "$N_ADMIN_MAIL" INBOX "service email test" "${N9_B:-0}" 90; N9_DEL=$?
    n_settings service_email '{"transport":"internal","verify_tls":true,"clear_password":true}'
    if [ "$N9_STRICT" = False ] && [ "$N9_STRICT_ERR" = True ] && [ "$N9_OK" = True ] && [ "$N9_STEPS" = "connect,starttls,auth,send" ] &&
       [ "$N9_DEL" = 0 ] && [ "$N9_SET" = True ] && [ "$N9_SECRET" = 0 ] ; then
        t_ok "N9 external service SMTP (mta:587): a self-signed cert fails verification; with verification switched off the Test reports connect → STARTTLS → AUTH → send and the mail arrives; the password is never returned"
    else
        t_fail "N9 external SMTP (strict=$N9_STRICT/$N9_STRICT_ERR ok=$N9_OK steps=$N9_STEPS delivered=$N9_DEL password-set=$N9_SET leaked=$N9_SECRET)"
    fi

    # N10 — the logs viewer and the separate admin bundle
    n_api GET "/logs?kind=audit&q=master_token_use&limit=5" "" "$N_AT"; N10_LOGS="$(k_json "len(d['items'])")"; N10_ONLY="$(k_json "all('master_token_use' in str(i) for i in d['items'])")"
    N10_USER="$(curl -s "$MCP_HTTP/" | grep -c 'admin-')"; N10_ADM="$(curl -s "$MCP_HTTP/adminmcp" | grep -c '/assets/admin-')"
    if [ "${N10_LOGS:-0}" -ge 1 ] && [ "$N10_ONLY" = True ] && [ "$N10_USER" = 0 ] && [ "$N10_ADM" -ge 1 ] ; then
        t_ok "N10 the logs viewer filters the audit trail; /adminmcp loads its own bundle and the user page ships no admin code"
    else
        t_fail "N10 logs/bundles (items=$N10_LOGS filtered=$N10_ONLY user-page-admin-refs=$N10_USER admin-bundle=$N10_ADM)"
    fi

    # N11 — a refresh cookie only rotates its own kind of session: the admin's, presented to the
    # user endpoint, is unknown there (401) and the admin session keeps working (no rotation, no reuse revoke)
    N11_RT="$(awk '$6 == "mdmcp_admin_refresh" {print $7}' "$N_JAR" | tail -n1)"
    N11_USER="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$MCP_HTTP/webapi/user/refresh" -H "Cookie: mdmcp_refresh=$N11_RT")"
    n_api POST /refresh "" "" "$N_JAR"; N11_ADMIN="$K_CODE"; N11_AT="$(k_json "d.get('access_token','')")"
    [ -n "$N11_AT" ] && N_AT="$N11_AT"
    if [ -n "$N11_RT" ] && [ "$N11_USER" = 401 ] && [ "$N11_ADMIN" = 200 ] ; then
        t_ok "N11 the admin refresh cookie is refused by the user refresh endpoint (401) and the admin session still rotates"
    else
        t_fail "N11 refresh kinds (cookie=${N11_RT:+yes} user-endpoint=$N11_USER admin-after=$N11_ADMIN)"
    fi

    # N12 — §7.2: alias domains stay out of the Domains dual list (their mail lands in the target domain)
    N12_ALIAS="mcpalias-$DOMAIN"
    sql "INSERT INTO domain (domain, description, aliases, mailboxes, maxquota, quota, transport, backupmx, active)
            VALUES ('$N12_ALIAS', 'test.sh N12 alias domain', 0, 0, 0, 0, 'virtual', false, true) ON CONFLICT (domain) DO NOTHING;
         INSERT INTO alias_domain (alias_domain, target_domain, active) VALUES ('$N12_ALIAS', '$DOMAIN', true)
            ON CONFLICT (alias_domain) DO NOTHING;" > /dev/null 2>&1
    n_api GET /domains "" "$N_AT"; N12_LIST="$(k_json "' '.join(x['domain'] for x in d['domains'])")"
    n_api PUT /domains "{\"allowed\":[\"$DOMAIN\",\"$N12_ALIAS\"]}" "$N_AT"; N12_PUT="$K_CODE"
    n_api PUT /domains "{\"allowed\":[\"$DOMAIN\"]}" "$N_AT"
    sql "DELETE FROM alias_domain WHERE alias_domain = '$N12_ALIAS'; DELETE FROM domain WHERE domain = '$N12_ALIAS';" > /dev/null 2>&1
    if printf ' %s ' "$N12_LIST" | grep -q " $DOMAIN " && ! printf ' %s ' "$N12_LIST" | grep -q " $N12_ALIAS " && [ "$N12_PUT" = 400 ] ; then
        t_ok "N12 alias domains are left out of the Domains dual list and cannot be allowed"
    else
        t_fail "N12 alias domain (listed='$N12_LIST' allow-alias=$N12_PUT)"
    fi

    # N13 — §7.2 retention defaults follow the rotation (90 days / 26 weeks / 12 months); a hand-set value stays
    n_settings logging '{"rotation":"week","retention":90}'; n_api GET /settings/logging "" "$N_AT"; N13_W="$(k_json "d['retention']")"
    n_settings logging '{"rotation":"month","retention":26}'; n_api GET /settings/logging "" "$N_AT"; N13_M="$(k_json "d['retention']")"
    n_settings logging '{"rotation":"day","retention":40}'; n_api GET /settings/logging "" "$N_AT"; N13_KEEP="$(k_json "d['retention']")"
    n_settings logging '{"rotation":"day","retention":90}'
    if [ "$N13_W" = 26 ] && [ "$N13_M" = 12 ] && [ "$N13_KEEP" = 40 ] ; then
        t_ok "N13 log retention follows the rotation's default (90 days → 26 weeks → 12 months) unless set by hand"
    else
        t_fail "N13 retention defaults (week=$N13_W month=$N13_M hand-set=$N13_KEEP)"
    fi

    # N14 — §9.5: X-Forwarded-For is believed from the networks mcp is attached to (the default when
    # MCP_TRUSTED_PROXIES is unset), so logs/lockouts see the client behind the ingress, not the proxy
    N14_UA="maild-n14-$(chrono)"
    n_settings logging '{"enabled":true}'
    curl -s -o /dev/null -A "$N14_UA" -H 'X-Forwarded-For: 198.51.100.77' "$MCP_HTTP/api/v1/skill.md"
    sleep 1
    N14_LINE="$(dcx mcp sh -c "cat /var/log/maild-mcp/access-*.log" 2>/dev/null | grep -F "$N14_UA" | tail -n1)"
    N14_BOOT="$("${DC[@]}" logs mcp 2>/dev/null | grep -c 'X-Forwarded-For trusted from: [0-9a-f]')"
    if printf '%s' "$N14_LINE" | grep -q '"ip": *"198.51.100.77"' && [ "${N14_BOOT:-0}" -ge 1 ] ; then
        t_ok "N14 with MCP_TRUSTED_PROXIES unset, X-Forwarded-For from the stack's own subnets is believed (access log shows the forwarded client)"
    else
        t_fail "N14 trusted proxies (boot-log=$N14_BOOT access='${N14_LINE:-none}')"
    fi
fi

# ================================= O. MailD MCP OAuth 2.1 (P4) ================
# mcp/technical-proposal.md §8.2, D1 and the 2026-10-30 decisions in mcp/progress.md: discovery
# (401 → RFC 9728 → RFC 8414), DCR and CIMD clients end to end through tests/oauth_flow.py (PKCE
# S256, consent narrowing the scopes, `iss`, single-use codes, audience-bound access tokens, refresh
# rotation + reuse detection, RFC 7009 revocation), the CIMD SSRF refusals, the redirect-URI rule
# (error page, never a redirect to an unverified URI), PKCE/resource enforcement, a denied consent,
# and the grants in the user's token list. The CIMD success path uses the dev-only
# MCP_CIMD_DEV_ALLOW fixture (mcp:8099). Self-cleaning: the scripted clients and their codes go.
section "O. MailD MCP OAuth 2.1 (discovery, DCR, CIMD, PKCE, refresh rotation, revocation)"

O_REDIRECT="http://127.0.0.1:9/callback"
o_flow() { dcx mcp python tests/oauth_flow.py "$1" "$K_A" "$K_PA" 2>/dev/null | tail -n1 | tr -d '\r'; }
o_get() { python3 -c "import json,sys; d=json.loads(sys.argv[2]); print(eval(sys.argv[1], {}, {'d': d}))" "$1" "$2" 2>/dev/null; }
o_loc() { # <query string> → "<status> <Location>" of GET /oauth/authorize
    curl -s -o "$K_OUT" -D "$K_OUT.h" -w '%{http_code}' --max-time 30 "$MCP_HTTP/oauth/authorize?$1"
    printf ' %s' "$(grep -i '^location:' "$K_OUT.h" | cut -d' ' -f2- | tr -d '\r')"
}
o_q() { python3 -c "import sys, urllib.parse as u; print(u.urlencode(dict(a.split('=',1) for a in sys.argv[1:])))" "$@"; }

if [ "$HAVE_DC" != 1 ] || [ -z "$MCP_DB_PW" ] || [ -z "${K_PA:-}" ] ; then
    t_skip "MailD MCP OAuth checks (need docker, MCP secrets and the $DOMAIN fixtures)"
else
    MCP_O_TOUCHED=1
    dcx mcp python manage.py mcp_domains allow "$DOMAIN" > /dev/null 2>&1
    O_RES="$(curl -s "$MCP_HTTP/.well-known/oauth-protected-resource/api/v1/mcp")"
    O_AS="$(curl -s "$MCP_HTTP/.well-known/oauth-authorization-server")"
    O_RESOURCE="$(o_get "d['resource']" "$O_RES")"

    # O1 — discovery documents
    if [ "$(o_get "d['authorization_servers'][0] == d['resource'].rsplit('/api/v1/mcp',1)[0]" "$O_RES")" = True ] &&
       [ "$(o_get "d['code_challenge_methods_supported'] == ['S256'] and d['client_id_metadata_document_supported'] and d['authorization_response_iss_parameter_supported'] and d['token_endpoint_auth_methods_supported'] == ['none']" "$O_AS")" = True ] ; then
        t_ok "O1 protected-resource (RFC 9728) and authorization-server (RFC 8414) metadata: S256 only, public clients, CIMD, iss"
    else
        t_fail "O1 metadata ($O_RES | $(printf '%s' "$O_AS" | head -c 200))"
    fi

    # O2/O3 — the two client registration paths, end to end
    for O_MODE in dcr cimd ; do
        O_J="$(o_flow "$O_MODE")"
        O_CHECK="d['discovery_401'] == 401 and d['g1_authorize'] == 302 and d['g1_redirect_ok'] and d['g1_iss'] == d['resource'].rsplit('/api/v1/mcp',1)[0] and d['g1_token_status'] == 200 and d['g1_scope'] == 'mail.read' and d['g1_code_reuse'] == 'invalid_grant' and d['mcp_call'] == '$K_A' and d['refresh'] == 200 and d['refresh_widen'] == 'invalid_scope' and d['refresh_reuse'] == 'invalid_grant' and d['after_reuse_access'] == 401 and d['revoke'] == 200 and d['after_revoke_access'] == 401"
        [ "$O_MODE" = dcr ] && O_CHECK="$O_CHECK and d['register'] == 201 and d['register_bad_redirect'] == 'invalid_redirect_uri'"
        O_LABEL="O2 DCR"; [ "$O_MODE" = cimd ] && O_LABEL="O3 CIMD"
        if [ "$(o_get "$O_CHECK" "$O_J")" = True ] ; then
            t_ok "$O_LABEL client: authorize (PKCE) → consent (scopes narrowed) → code (iss, single use) → MCP call → refresh rotation; reuse kills the family; /oauth/revoke works"
        else
            t_fail "$O_LABEL OAuth flow ($(printf '%s' "$O_J" | head -c 600))"
        fi
    done

    # O4 — CIMD fetch is SSRF-safe: plain http, loopback and private addresses are refused (error page)
    O4=""
    for O_CID in "http://example.com/client.json" "https://127.0.0.1/client.json" "https://10.20.30.40/client.json" "https://mda/client.json" ; do
        O4="$O4 $(o_loc "$(o_q "client_id=$O_CID" "redirect_uri=$O_REDIRECT" response_type=code code_challenge=x code_challenge_method=S256)" | cut -d' ' -f1)"
    done
    if [ "$O4" = " 400 400 400 400" ] ; then
        t_ok "O4 CIMD refuses http, loopback, private and internal-name client_id URLs (no fetch towards the stack)"
    else
        t_fail "O4 CIMD SSRF guard (statuses:$O4, want 400 ×4)"
    fi

    # O4b — audit M-02: a refused/failed fetch shows ONE generic message (no upstream status,
    # address or connection detail to probe with), and the URL is remembered: the repeat is
    # answered without a second fetch attempt (no new "CIMD fetch refused" log line)
    O4B_CID="https://127.0.0.2/o4b-$(chrono).json"
    O4B_Q="$(o_q "client_id=$O4B_CID" "redirect_uri=$O_REDIRECT" response_type=code code_challenge=x code_challenge_method=S256)"
    O4B_1="$(o_loc "$O4B_Q" | cut -d' ' -f1)"
    O4B_BODY="$(cat "$K_OUT" 2>/dev/null)"
    O4B_2="$(o_loc "$O4B_Q" | cut -d' ' -f1)"
    O4B_LOGGED="$("${DC[@]}" logs --no-log-prefix mcp 2>/dev/null | grep -c "CIMD fetch refused: client_id=$O4B_CID")"
    if [ "$O4B_1" = 400 ] && [ "$O4B_2" = 400 ] &&
       printf '%s' "$O4B_BODY" | grep -q 'unknown or unreachable client' &&
       ! printf '%s' "$O4B_BODY" | grep -qiE 'non-public|HTTP [0-9]|resolve|127\.0\.0\.2' &&
       [ "$O4B_LOGGED" = 1 ] ; then
        t_ok "O4b a failed CIMD fetch shows only a generic message (cause logged server-side) and is not re-fetched"
    else
        t_fail "O4b CIMD generic error / failed-URL memory (statuses $O4B_1/$O4B_2, fetch attempts logged=$O4B_LOGGED, body: $(printf '%s' "$O4B_BODY" | sed 's/<[^>]*>/ /g' | tr -s ' ' | head -c 160))"
    fi

    # O5 — redirect URI, PKCE and resource rules (a registered DCR client)
    O_CLIENT="$(curl -s -X POST "$MCP_HTTP/oauth/register" -H 'Content-Type: application/json' \
        --data "{\"client_name\":\"o-rules\",\"redirect_uris\":[\"$O_REDIRECT\"]}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["client_id"])' 2>/dev/null)"
    O5_BADURI="$(o_loc "$(o_q "client_id=$O_CLIENT" "redirect_uri=https://evil.example/cb" response_type=code code_challenge=x code_challenge_method=S256)")"
    O5_PORT="$(o_loc "$(o_q "client_id=$O_CLIENT" "redirect_uri=http://127.0.0.1:51234/callback" response_type=code code_challenge=x code_challenge_method=S256 "resource=$O_RESOURCE")")"
    O5_NOPKCE="$(o_loc "$(o_q "client_id=$O_CLIENT" "redirect_uri=$O_REDIRECT" response_type=code state=s1)")"
    O5_RES="$(o_loc "$(o_q "client_id=$O_CLIENT" "redirect_uri=$O_REDIRECT" response_type=code code_challenge=x code_challenge_method=S256 resource=https://other.example/mcp)")"
    O5_JSON="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$MCP_HTTP/oauth/token" -H 'Content-Type: application/json' --data '{"grant_type":"authorization_code"}')"
    if [[ "$O5_BADURI" == "400 " ]] && [[ "$O5_PORT" == "302 /consent#"* ]] &&
       [[ "$O5_NOPKCE" == "302 $O_REDIRECT?error=invalid_request"*"state=s1"*"iss="* ]] &&
       [[ "$O5_RES" == "302 $O_REDIRECT?error=invalid_target"* ]] && [ "$O5_JSON" = 400 ] ; then
        t_ok "O5 an unregistered redirect URI gets an error page (never a redirect); loopback ports may differ; missing PKCE / foreign resource go back as errors with state + iss; the token endpoint wants a form"
    else
        t_fail "O5 rules (bad-uri='$O5_BADURI' loopback-port='$O5_PORT' no-pkce='$O5_NOPKCE' resource='$O5_RES' json=$O5_JSON)"
    fi

    # O6 — a denied consent goes back as access_denied; the grants show in the user's token list
    O6_REQ="$(o_loc "$(o_q "client_id=$O_CLIENT" "redirect_uri=$O_REDIRECT" response_type=code code_challenge=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ code_challenge_method=S256 state=s2)" | sed -n 's/.*#//p')"
    k_login "$K_A" "$K_PA"; O_UAT="$K_AT"
    k_api POST /user/oauth/decision "{\"request_id\":\"$O6_REQ\",\"approve\":false}" "$O_UAT"; O6_DENY="$(k_json "d.get('redirect','')")"
    # a live grant (the scripted flows revoke theirs): approve → exchange the code with the verifier
    O6_V="o6-verifier-$(printf '%040d' 0)"
    O6_C="$(python3 -c "import base64,hashlib,sys; print(base64.urlsafe_b64encode(hashlib.sha256(sys.argv[1].encode()).digest()).rstrip(b'=').decode())" "$O6_V")"
    O6_REQ2="$(o_loc "$(o_q "client_id=$O_CLIENT" "redirect_uri=$O_REDIRECT" response_type=code "code_challenge=$O6_C" code_challenge_method=S256)" | sed -n 's/.*#//p')"
    k_api POST /user/oauth/decision "{\"request_id\":\"$O6_REQ2\",\"approve\":true,\"scopes\":[\"mail.read\"],\"addresses\":[\"$K_A\"]}" "$O_UAT"
    O6_CODE="$(k_json "d['redirect'].split('code=',1)[1].split('&',1)[0]")"
    curl -s -o /dev/null --max-time 30 -X POST "$MCP_HTTP/oauth/token" --data-urlencode grant_type=authorization_code \
        --data-urlencode "code=$O6_CODE" --data-urlencode "client_id=$O_CLIENT" --data-urlencode "redirect_uri=$O_REDIRECT" \
        --data-urlencode "code_verifier=$O6_V"
    k_api GET /user/tokens "" "$O_UAT"; O6_GRANT="$(k_json "[t['name'] for t in d['tokens'] if t['kind']=='oauth_refresh']")"
    O6_GID="$(k_json "[t['id'] for t in d['tokens'] if t['kind']=='oauth_refresh' and t['name']=='o-rules'][0]")"
    k_api POST "/user/tokens/$O6_GID/disable" "" "$O_UAT"; O6_DIS="$K_CODE"
    k_api POST "/user/tokens/$O6_GID/revoke" "" "$O_UAT"; O6_REV="$K_CODE"
    if [[ "$O6_DENY" == "$O_REDIRECT?error=access_denied"*"state=s2"* ]] && printf '%s' "$O6_GRANT" | grep -q "o-rules" &&
       [ "$O6_DIS" = 400 ] && [ "$O6_REV" = 200 ] ; then
        t_ok "O6 a denied consent returns access_denied; app connections appear in the user's token list by client name and can only be revoked"
    else
        t_fail "O6 deny/grant list (deny='$O6_DENY' grants=$O6_GRANT disable=$O6_DIS revoke=$O6_REV)"
    fi

    # O7 — audit: issuance, consent and the reuse detection are recorded
    O7_LOG="$(dcx mcp sh -c "cat /var/log/maild-mcp/audit-$(date -u +%Y-%m-%d).log" 2>/dev/null)"
    if printf '%s' "$O7_LOG" | grep -q '"event":"token.issued"' && printf '%s' "$O7_LOG" | grep -q '"event":"consent.granted"' &&
       printf '%s' "$O7_LOG" | grep -q '"event":"oauth.refresh_reuse"' && printf '%s' "$O7_LOG" | grep -q '"event":"client.registered"' ; then
        t_ok "O7 the audit log records client registration, consent, token issuance and refresh-token reuse"
    else
        t_fail "O7 OAuth audit events"
    fi
fi

# ================================= P. MailD MCP REST mirror (P5) ==============
# mcp/technical-proposal.md §4 and the 2026-10-30 P5 decisions in mcp/progress.md: POST
# /api/v1/mail/<tool> runs the MCP tools themselves (same arguments, validation, authorization and
# audit), personal access and master tokens only (OAuth tokens are bound to /api/v1/mcp), plus the
# generated /api/v1/openapi.json and /api/v1/skill.md. Parity = the same call through the SDK client
# and through REST returns the same structured result on the fixtures. Test mail is injected from
# cron through amavis:10026. Self-cleaning: the maild-p5-* messages, the p5-* master token.
section "P. MailD MCP REST mirror (/api/v1/mail, OpenAPI, SKILL.md, parity with the MCP tools)"

P_TAG="maild-p5-$(chrono | cut -c1-10)"
P_OUT="$TMPRUN/p.out"
p_rest() { # <token> <tool> <json> [extra curl args…] → P_CODE, body in $P_OUT
    local tok="$1" tool="$2" data="$3"; shift 3
    P_CODE="$(curl -s -o "$P_OUT" -D "$P_OUT.h" -w '%{http_code}' --max-time 60 -X POST "$MCP_HTTP/api/v1/mail/$tool" \
        ${tok:+-H "Authorization: Bearer $tok"} -H 'Content-Type: application/json' --data "$data" "$@")"
}
p_json() { python3 -c "import json,sys; d=json.load(open('$P_OUT')); print(eval(sys.argv[1], {}, {'d': d}))" "$1" 2>/dev/null; }
p_same() { # <tool> <json> [drop-key] → "same" when MCP structured == REST body (minus drop-key)
    m_call "$P_PAT" "$1" "$2"; p_rest "$P_PAT" "$1" "$2"
    python3 - "$M_RES" "$P_OUT" "${3:-}" <<'PYEOF' 2>/dev/null
import json, sys
mcp = json.loads(sys.argv[1]); rest = json.load(open(sys.argv[2])); drop = sys.argv[3]
a = mcp.get("structured") or {}
for d in (a, rest):
    d.pop(drop, None)
print("same" if not mcp.get("is_error") and a == rest and a else f"differs: {json.dumps(a)[:200]} | {json.dumps(rest)[:200]}")
PYEOF
}

if [ "$HAVE_DC" != 1 ] || [ -z "$MCP_DB_PW" ] || [ -z "${K_PA:-}" ] ; then
    t_skip "MailD MCP REST mirror checks (need docker, MCP secrets and the $DOMAIN fixtures)"
else
    MCP_P_TOUCHED=1
    dcx mcp python manage.py mcp_domains allow "$DOMAIN" > /dev/null 2>&1
    k_login "$M_A" "$K_PA"; P_AT="$K_AT"
    k_api POST /user/tokens '{"name":"p-all","scopes":["mail.read","mail.modify","mail.trash","mail.send"]}' "$P_AT"; P_PAT="$(k_json "d.get('token','')")"
    k_api POST /user/tokens '{"name":"p-read","scopes":["mail.read"]}' "$P_AT"; P_PATR="$(k_json "d.get('token','')")"
    dcx cron sh -c "printf 'attached-%s\n' $P_TAG > /tmp/$P_TAG.txt" > /dev/null 2>&1
    m_inject "$P_TAG-att" --attach-type text/plain --attach-name "$P_TAG.txt" --attach "@/tmp/$P_TAG.txt"
    dcx cron rm -f "/tmp/$P_TAG.txt" > /dev/null 2>&1
    m_call "$P_PAT" search_emails "{\"account\":\"$M_A\",\"subject\":\"$P_TAG-att\",\"limit\":5}"; P_ID="$(m_res "d['structured']['messages'][0]['id']")"

    # P1 — OpenAPI: one operation per MCP tool, each with its scope, every $ref resolvable
    curl -s --max-time 30 "$MCP_HTTP/api/v1/openapi.json" > "$P_OUT"
    P1_TOOLS="$(dcx mcp python tests/mcp_call.py "$P_PAT" list 2>/dev/null | tr -d '\r' | sort | paste -sd, -)"
    P1="$(python3 - "$P_OUT" "$P1_TOOLS" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])); tools = sys.argv[2].split(",")
ops = {p.rsplit("/", 1)[1]: v["post"] for p, v in d["paths"].items()}
schemas = d["components"]["schemas"]
refs = []
def walk(n):
    if isinstance(n, dict):
        if "$ref" in n: refs.append(n["$ref"])
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for v in n: walk(v)
walk(d)
ok = (d["openapi"].startswith("3.1") and sorted(ops) == tools and len(tools) == 21
      and all(o["security"][0]["bearer"][0].startswith("mail.") for o in ops.values())
      and all(r.startswith("#/components/schemas/") and r.rsplit("/", 1)[1] in schemas for r in refs)
      and "$defs" not in json.dumps(d))
print("ok" if ok else f"bad ops={sorted(ops)} tools={tools}")
PYEOF
)"
    if [ "$P1" = ok ] ; then
        t_ok "P1 /api/v1/openapi.json (OpenAPI 3.1): one POST per MCP tool (21), scope per operation, every schema \$ref resolvable"
    else
        t_fail "P1 OpenAPI document ($P1)"
    fi

    # P2 — SKILL.md: frontmatter, the base URL, every tool
    P2_MD="$(curl -s --max-time 30 "$MCP_HTTP/api/v1/skill.md")"
    P2_MISS=""
    for p_t in ${P1_TOOLS//,/ } ; do printf '%s' "$P2_MD" | grep -q "\`$p_t\`" || P2_MISS="$P2_MISS $p_t" ; done
    if printf '%s' "$P2_MD" | head -1 | grep -qx -- '---' && printf '%s' "$P2_MD" | grep -q '^name: maild-mail$' &&
       printf '%s' "$P2_MD" | grep -q "/api/v1/mail/<tool>" && [ -z "$P2_MISS" ] && [ -n "$P1_TOOLS" ] ; then
        t_ok "P2 /api/v1/skill.md: skill frontmatter, the REST base URL and all 21 tools"
    else
        t_fail "P2 SKILL.md (missing:$P2_MISS)"
    fi

    # P3 — parity: the same calls through the SDK client and through REST give the same results
    P3=""
    for p_case in "list_accounts|{}" "list_folders|{\"account\":\"$M_A\"}" "get_quota|{\"account\":\"$M_A\"}" \
                  "search_emails|{\"account\":\"$M_A\",\"subject\":\"$P_TAG\",\"limit\":5}|next_cursor" \
                  "get_email|{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$P_ID\",\"mark_read\":false}" \
                  "get_thread|{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$P_ID\"}" ; do
        IFS='|' read -r p_tool p_args p_drop <<< "$p_case"
        p_r="$(p_same "$p_tool" "$p_args" "$p_drop")"
        [ "$p_r" = same ] || P3="$P3 $p_tool: $p_r;"
    done
    if [ -z "$P3" ] ; then
        t_ok "P3 parity: list_accounts, list_folders, get_quota, search_emails, get_email, get_thread return the same result over REST and MCP"
    else
        t_fail "P3 REST/MCP parity ($P3)"
    fi

    # P4 — get_attachment over REST is the file itself, byte-identical to the MCP blob
    p_rest "$P_PAT" get_email "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$P_ID\",\"mark_read\":false}"; P4_PART="$(p_json "d['attachments'][0]['part']")"
    P4_ARGS="{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"id\":\"$P_ID\",\"part\":\"$P4_PART\"}"
    m_call "$P_PAT" get_attachment "$P4_ARGS"; P4_MCP="$(m_res "__import__('base64').b64decode(d['blobs'][0]).decode().strip()")"
    p_rest "$P_PAT" get_attachment "$P4_ARGS"; P4_CT="$(grep -i '^content-type:' "$P_OUT.h" | tr -d '\r')"; P4_CD="$(grep -i '^content-disposition:' "$P_OUT.h" | tr -d '\r')"
    if [ "$P_CODE" = 200 ] && [ "$(tr -d '\r\n' < "$P_OUT")" = "attached-$P_TAG" ] && [ "$P4_MCP" = "attached-$P_TAG" ] &&
       [[ "$P4_CT" == *text/plain* ]] && [[ "$P4_CD" == *"attachment; filename*=UTF-8''$P_TAG.txt"* ]] ; then
        t_ok "P4 get_attachment over REST returns the file itself (type + filename headers), identical to the MCP blob"
    else
        t_fail "P4 attachment (code=$P_CODE mcp='$P4_MCP' ct='$P4_CT' cd='$P4_CD')"
    fi

    # P5 — writes and the two-step confirmation through REST
    p_rest "$P_PAT" mark_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$P_ID\"],\"flagged\":true}"; P5_MARK="$P_CODE"
    m_call "$P_PAT" search_emails "{\"account\":\"$M_A\",\"subject\":\"$P_TAG-att\",\"flagged\":true}"; P5_FLAG="$(m_res "len(d['structured']['messages'])")"
    p_rest "$P_PAT" trash_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$P_ID\"]}"
    P5_ST1="$(p_json "d['status']")"; P5_H="$(p_json "d['confirm']")"; P5_PRE="$(p_json "len(d['preview'])")"
    p_rest "$P_PAT" trash_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$P_ID\"],\"confirm\":\"$P5_H\"}"; P5_ST2="$(p_json "d['status']")"
    p_rest "$P_PAT" trash_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$P_ID\"],\"confirm\":\"$P5_H\"}"; P5_REPLAY="$P_CODE/$(p_json "d['error']")"
    m_call "$P_PAT" search_emails "{\"account\":\"$M_A\",\"folder\":\"Trash\",\"subject\":\"$P_TAG-att\"}"; P5_TID="$(m_res "d['structured']['messages'][0]['id']")"
    p_rest "$P_PAT" restore_from_trash "{\"account\":\"$M_A\",\"ids\":[\"$P5_TID\"]}"; P5_REST="$(p_json "d['status']")"
    if [ "$P5_MARK" = 200 ] && [ "$P5_FLAG" = 1 ] && [ "$P5_ST1" = confirmation_required ] && [ "$P5_PRE" = 1 ] &&
       [ "$P5_ST2" = done ] && [ "$P5_REPLAY" = 400/confirmation_invalid ] && [ "$P5_REST" = done ] ; then
        t_ok "P5 REST writes: mark_emails; trash_emails asks first (preview + confirm), runs once with confirm, refuses the replay; restore_from_trash"
    else
        t_fail "P5 REST writes (mark=$P5_MARK flagged=$P5_FLAG step1=$P5_ST1 preview=$P5_PRE step2=$P5_ST2 replay=$P5_REPLAY restore=$P5_REST)"
    fi

    # P6 — errors: missing token, bad arguments, scope, foreign address, unknown tool, method, body
    p_rest "" list_accounts '{}'; P6_NOAUTH="$P_CODE/$(grep -ci 'resource_metadata' "$P_OUT.h")/$(grep -ci 'realm="MailD MCP REST"' "$P_OUT.h")"
    p_rest "$P_PAT" search_emails '{"limit":"many"}'; P6_422="$P_CODE/$(p_json "d['error']+':'+d['details'][0]['field']")"
    p_rest "$P_PATR" mark_emails "{\"account\":\"$M_A\",\"folder\":\"INBOX\",\"ids\":[\"$P_ID\"],\"read\":true}"; P6_SCOPE="$P_CODE/$(p_json "d['error']+':'+d['scope']")"
    p_rest "$P_PAT" list_folders "{\"account\":\"$M_B\"}"; P6_ADDR="$P_CODE/$(p_json "d['error']")"
    p_rest "$P_PAT" no_such_tool '{}'; P6_404="$P_CODE"
    p_rest "$P_PAT" list_accounts '[]'; P6_JSON="$P_CODE/$(p_json "d['error']")"
    P6_GET="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $P_PAT" "$MCP_HTTP/api/v1/mail/list_accounts")"
    if [ "$P6_NOAUTH" = 401/0/1 ] && [ "$P6_422" = 422/invalid_arguments:limit ] && [ "$P6_SCOPE" = 403/insufficient_scope:mail.modify ] &&
       [ "$P6_ADDR" = 403/forbidden ] && [ "$P6_404" = 404 ] && [ "$P6_JSON" = 400/invalid_json ] && [ "$P6_GET" = 405 ] ; then
        t_ok "P6 REST errors: 401 (REST realm, no OAuth discovery), 422 with the field, 403 insufficient_scope / foreign address, 404 unknown tool, 400 non-object body, 405 GET"
    else
        t_fail "P6 REST errors (noauth=$P6_NOAUTH 422=$P6_422 scope=$P6_SCOPE addr=$P6_ADDR 404=$P6_404 json=$P6_JSON get=$P6_GET)"
    fi

    # P7 — tokens: an OAuth access token is refused (bound to /api/v1/mcp); a master token needs X-MailD-Act-As
    P7_CLIENT="$(curl -s -X POST "$MCP_HTTP/oauth/register" -H 'Content-Type: application/json' \
        --data "{\"client_name\":\"p-rest\",\"redirect_uris\":[\"$O_REDIRECT\"]}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["client_id"])' 2>/dev/null)"
    P7_V="p7-verifier-$(printf '%040d' 0)"
    P7_C="$(python3 -c "import base64,hashlib,sys; print(base64.urlsafe_b64encode(hashlib.sha256(sys.argv[1].encode()).digest()).rstrip(b'=').decode())" "$P7_V")"
    P7_REQ="$(o_loc "$(o_q "client_id=$P7_CLIENT" "redirect_uri=$O_REDIRECT" response_type=code "code_challenge=$P7_C" code_challenge_method=S256)" | sed -n 's/.*#//p')"
    k_api POST /user/oauth/decision "{\"request_id\":\"$P7_REQ\",\"approve\":true,\"scopes\":[\"mail.read\"],\"addresses\":[\"$M_A\"]}" "$P_AT"
    P7_CODE="$(k_json "d['redirect'].split('code=',1)[1].split('&',1)[0]")"
    P7_OAT="$(curl -s --max-time 30 -X POST "$MCP_HTTP/oauth/token" --data-urlencode grant_type=authorization_code \
        --data-urlencode "code=$P7_CODE" --data-urlencode "client_id=$P7_CLIENT" --data-urlencode "redirect_uri=$O_REDIRECT" \
        --data-urlencode "code_verifier=$P7_V" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null)"
    p_rest "$P7_OAT" list_accounts '{}'; P7_OAUTH="$P_CODE/$(p_json "d['reason']")"
    P7_OAUTH_MCP="$(k_rpc "$P7_OAT" list_accounts)"
    P7_MST="$(dcx mcp python manage.py shell -c "
from mcpcore import tokens
from mcpcore.models import AdminUser
raw, _ = tokens.create_master(AdminUser.objects.order_by('id').first(), 'p5-rest', 1, ['mail.read'], None, '127.0.0.1')
print(raw)" 2>/dev/null | tail -n1 | tr -d '\r')"
    p_rest "$P7_MST" list_accounts '{}'; P7_NOACT="$P_CODE/$(p_json "d['error']")"
    p_rest "$P7_MST" list_accounts '{}' -H "X-MailD-Act-As: $M_C"; P7_ACT="$P_CODE/$(p_json "d['accounts'][0]['address']")"
    if [ "$P7_OAUTH" = 401/wrong_audience ] && [ "$P7_OAUTH_MCP" = 200 ] && [ "$P7_NOACT" = 400/act_as_required ] &&
       [ "$P7_ACT" = "200/$M_C" ] ; then
        t_ok "P7 REST tokens: an OAuth access token is refused (wrong_audience) though valid on /api/v1/mcp; a master token works with X-MailD-Act-As only"
    else
        t_fail "P7 REST tokens (oauth=$P7_OAUTH oauth-on-mcp=$P7_OAUTH_MCP master-no-act-as=$P7_NOACT master=$P7_ACT)"
    fi

    # P8 — audit: REST calls are recorded like MCP ones (access record + the tool's own event)
    P8_LOG="$(dcx mcp sh -c "cat /var/log/maild-mcp/audit-$(date -u +%Y-%m-%d).log" 2>/dev/null)"
    if printf '%s' "$P8_LOG" | grep '"event":"rest"' | grep -q '"tool":"trash_emails"' &&
       printf '%s' "$P8_LOG" | grep -q '"result":"wrong_audience"' ; then
        t_ok "P8 the audit log records REST access (with the tool) and the refused OAuth token"
    else
        t_fail "P8 REST audit records"
    fi
fi

# ================================= L. amavis listeners (P1b, D13) =========
# mcp/technical-proposal.md §9.6 option B: 10024 (policy bank MTA) admits only the mta, the new
# 10026 (bank INTERNAL) only cron and mcp; both DKIM-sign. The ACLs follow moved peers through
# amavis's peer-IP watchdog (52-maild-acl + amavisd reload). The mail path itself (Postfix →
# 10024 → 10025) is covered by sections A–F, the cron jobs on 10026 by section G and the mcp
# service mail on 10026 by K15. Self-cleaning: the probe mail is expunged and the placeholder
# container that forces cron onto a new address is removed by cleanup().
section "L. amavis listeners 10024 (mta) / 10026 (cron, mcp)"

L_SUBJ="maild-p1b-internal-$(chrono | cut -c1-12)"
l_peer_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null | tr -d '\r'; }
l_py_probe() { # <service> <port> → "open" when amavis greets and accepts MAIL FROM, else the error
    dcx "$1" python -c "import smtplib
try:
    s=smtplib.SMTP('amavis',$2,timeout=10); s.ehlo('probe'); c,_=s.mail('probe@$DEFAULT_DOMAIN'); s.quit(); print('open' if c==250 else 'code %s'%c)
except Exception as e: print(type(e).__name__)" 2>/dev/null | tr -d '\r'
}
l_cron_probe() { # <port> → "open" when amavis accepts MAIL FROM from the cron container
    dcx cron sh -c "swaks --server amavis --port $1 --quit-after MAIL --from probe@$DEFAULT_DOMAIN --to $DEPLOY_ADMIN 2>&1" |
        grep -q '250 2.1.0 Sender' && echo open || echo refused
}

if [ "$HAVE_DC" != 1 ] ; then
    t_skip "amavis listener checks (need docker)"
else
    L_MTA_IP="$(l_peer_ip maild-dev-mta)"; L_CRON_IP="$(l_peer_ip maild-dev-cron)"
    L_ACL="$(dcx amavis cat /etc/amavis/conf.d/52-maild-acl 2>/dev/null | tr -d '\r')"

    # L1 — two listeners, and the ACL file names the right peer in the right bank
    L1_24="$(dcx amavis sh -c 'nc localhost 10024 -w2 </dev/null | head -n1' 2>/dev/null | tr -d '\r')"
    L1_26="$(dcx amavis sh -c 'nc localhost 10026 -w2 </dev/null | head -n1' 2>/dev/null | tr -d '\r')"
    if [[ "$L1_24" == 220* ]] && [[ "$L1_26" == 220* ]] &&
       printf '%s' "$L_ACL" | grep -q "{'MTA'}{inet_acl} = \[qw( 127.0.0.1 \[::1\] $L_MTA_IP )\]" &&
       printf '%s' "$L_ACL" | grep "{'INTERNAL'}" | grep -q " $L_CRON_IP " &&
       ! printf '%s' "$L_ACL" | grep "{'MTA'}" | grep -q " $L_CRON_IP " ; then
        t_ok "L1 amavis listens on 10024 (ACL: mta $L_MTA_IP) and 10026 (ACL: cron $L_CRON_IP + mcp)"
    else
        t_fail "L1 listeners/ACL (10024='$L1_24' 10026='$L1_26' acl: $(printf '%s' "$L_ACL" | grep -c inet_acl) lines)"
    fi

    # L2 — cron → 10026 delivers, DKIM-signed (bank INTERNAL is originating)
    dcx cron sh -c "swaks --server amavis --port 10026 --from postmaster@$DEFAULT_DOMAIN --to $DEPLOY_ADMIN \
        --header 'Subject: $L_SUBJ' --body 'P1b INTERNAL bank probe' >/dev/null 2>&1"
    L2_OK=1; wait_msg "$DEPLOY_ADMIN" INBOX "$L_SUBJ" 60 || L2_OK=0
    L2_UID="$(msg_newest_uid "$DEPLOY_ADMIN" INBOX "$L_SUBJ")"
    if [ "$L2_OK" = 1 ] && msg_text "$DEPLOY_ADMIN" INBOX "$L2_UID" | grep -qi '^DKIM-Signature:' ; then
        t_ok "L2 cron → amavis:10026 is accepted, DKIM-signed and delivered"
    else
        t_fail "L2 cron → 10026 (delivered=$L2_OK, DKIM header $( [ -n "$L2_UID" ] && msg_text "$DEPLOY_ADMIN" INBOX "$L2_UID" | grep -ci '^DKIM-Signature:' || echo n/a))"
    fi

    # L3 — cron → 10024 is refused (and amavis says so)
    L3="$(l_cron_probe 10024)"
    sleep 1
    if [ "$L3" = refused ] && "${DC[@]}" logs --no-log-prefix --since 2m amavis 2>/dev/null |
         grep -q "DENIED ACCESS from IP $L_CRON_IP, policy bank 'MTA'" ; then
        t_ok "L3 cron → amavis:10024 is refused (DENIED ACCESS, policy bank MTA)"
    else
        t_fail "L3 cron → 10024 should be refused (got $L3)"
    fi

    # L4 — any other container (api) is refused on both
    L4_24="$(l_py_probe api 10024)"; L4_26="$(l_py_probe api 10026)"
    if [ "$L4_24" != open ] && [ "$L4_26" != open ] ; then
        t_ok "L4 another container (api) is refused on 10024 and 10026"
    else
        t_fail "L4 api must not submit to amavis (10024=$L4_24 10026=$L4_26)"
    fi

    # L5 — mcp: 10026 yes, 10024 no
    if [ -n "$(env_value "$ENV_FILE" MCP_DB_PASSWORD || true)" ] ; then
        L5_26="$(l_py_probe mcp 10026)"; L5_24="$(l_py_probe mcp 10024)"
        if [ "$L5_26" = open ] && [ "$L5_24" != open ] ; then
            t_ok "L5 mcp → amavis:10026 is accepted, mcp → 10024 refused"
        else
            t_fail "L5 mcp listener access (10026=$L5_26 10024=$L5_24)"
        fi
    else
        t_skip "L5 mcp listener access (no MCP deployed)"
    fi

    # L6 — the watchdog: cron on a NEW address is admitted again within two intervals
    L_WATCH="$(container_env PEER_WATCH_INTERVAL)"; L_WATCH="${L_WATCH:-30}"
    L_NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' maild-dev-cron 2>/dev/null)"
    timeout -k10 120 "${DC[@]}" stop cron > /dev/null 2>&1
    # a placeholder pinned to the address cron just released, so cron must come back elsewhere
    # (a free-address placeholder made this depend on the IPAM's choice: flaky)
    L_PLACEHOLDER="$(docker run -d --rm --network "$L_NET" --ip "$L_CRON_IP" --entrypoint sleep pavelmc/maild-cron:develop 600 2>/dev/null)"
    timeout -k10 120 "${DC[@]}" start cron > /dev/null 2>&1
    L6_NEW="$(l_peer_ip maild-dev-cron)"
    if [ "$L6_NEW" = "$L_CRON_IP" ] || [ -z "$L6_NEW" ] ; then
        t_skip "L6 could not move cron to a new address (still ${L6_NEW:-none}); watchdog not exercised"
    else
        L6_START=$SECONDS; L6="refused"
        while [ $((SECONDS - L6_START)) -le $((2 * L_WATCH + 15)) ] ; do
            L6="$(l_cron_probe 10026)"; [ "$L6" = open ] && break
            sleep 3
        done
        L6_SECS=$((SECONDS - L6_START))
        L6_HEALTH="$(docker inspect -f '{{.State.Health.Status}}' maild-dev-amavis 2>/dev/null)"
        if [ "$L6" = open ] && [ "$L6_HEALTH" = healthy ] &&
           "${DC[@]}" logs --no-log-prefix --since 5m amavis 2>/dev/null | grep -q "cron $L_CRON_IP->$L6_NEW" ; then
            t_ok "L6 cron moved $L_CRON_IP → $L6_NEW: the watchdog re-rendered the ACL and 10026 admits it again after ${L6_SECS}s (amavis stays healthy)"
        else
            t_fail "L6 watchdog (cron $L_CRON_IP → $L6_NEW: 10026=$L6 after ${L6_SECS}s, amavis $L6_HEALTH)"
        fi
    fi
    [ -n "$L_PLACEHOLDER" ] && docker rm -f "$L_PLACEHOLDER" > /dev/null 2>&1
    L_PLACEHOLDER=""
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
