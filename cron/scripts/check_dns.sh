#!/bin/bash

# This script is part of MailD
# Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# shellcheck shell=bash disable=SC2317
#
# check_dns.sh — daily public-DNS health check for every active hosted domain.
#
# Runs from the cron container (cron/crontab, 04:20 UTC). For every active domain in the
# catalogue it verifies what the OUTSIDE world sees, compares it against what this MailD
# deployment intends, and mails the deviations (with an impact + a fix) to
# postmaster@<DEFAULT_DOMAIN> — which the first-boot seeder aliases to the admin mailbox.
# Silent (no mail) when everything is fine: a daily "all good" mail trains operators to
# ignore the alert. Nothing here reads or writes mail state: it is a read-only probe.
#
# Findings catalogue (severity in brackets, every one carries found/expected/impact/action):
#
#  A. Delegation
#     [critical] A1 domain NXDOMAIN — the zone does not resolve at all
#     [critical] A2 domain has no NS and/or no SOA — not a real, delegated zone
#  B. MX
#     [critical] B1 no MX and no A/AAAA — nobody can deliver to this domain
#     [warning]  B2 no MX but an A/AAAA exists — delivery relies on the implicit-MX
#                   fallback (deprecated, ambiguous with a WWW/CNAME host)
#     [critical] B3 null MX (0 .) published — the domain explicitly refuses all mail
#     [critical] B4 an MX target does not resolve (A and AAAA empty)
#     [critical] B5 an MX target is a CNAME — forbidden by RFC 5321 §5.1
#     [critical] B6 an MX target is the domain itself — mail loops back
#     [critical] B7 an MX target resolves to a private/loopback address — unreachable
#                   from the internet
#     [critical] B8 the MX set differs from MX_HOSTNAME (the declared mail host)
#     [warning]  B9 duplicate MX priorities
#     [notice]   B10 a single MX — no redundancy if that host is down
#  C. SPF
#     [critical] C1 no SPF record
#     [critical] C2 more than one SPF record — the result is "permerror"
#     [critical] C3 the policy ends in +all / bare "all" / ?all — no protection at all
#     [warning]  C4 the policy ends in ~all — spoofed mail is only soft-failed
#     [warning]  C5 no "all" mechanism and no redirect= — the default result leaks
#     [notice]   C6 mechanisms after "all" are ignored
#     [warning]  C7 the "ptr" mechanism is used (RFC 7208 says do not)
#     [critical] C8 more than 10 DNS lookups — "permerror" at receivers
#     [warning]  C9 the record is longer than 450 bytes — it may be split/truncated
#     [warning]  C10 the MX IPs are not covered by the policy
#     [warning]  C11 syntax problem (unknown mechanism, bad CIDR, redirect ignored)
#     [warning]  C12 an include: target publishes no SPF record
#  D. DMARC
#     [warning]  D1 no DMARC record (exact domain and immediate parent both empty)
#     [warning]  D2 no DMARC record on the exact domain — policy inherited from a parent
#     [critical] D3 more than one DMARC record — the result is "permerror"
#     [critical] D4 "v=DMARC1" is missing or not the first tag
#     [critical] D5 invalid p= value
#     [warning]  D6 p=none — reports only, spoofing is still delivered
#     [notice]   D7 pct<100 — the policy is only partially applied
#     [warning]  D8 sp=none while p= is enforcing — subdomains stay spoofable
#     [notice]   D9 no rua= — no aggregate reports, problems stay invisible
#     [warning]  D10 a rua= address lives in a domain with no mail route
#     [warning]  D11 invalid alignment/format/interval tag
#     [notice]   D12 strict policy here but not everywhere (SPF soft, no local DKIM key)
#  E. DKIM (compared against the real keys on the amavis volume)
#     [notice]   E1 the amavis DKIM volume is not readable — key comparison skipped
#     [notice]   E2 no local selector for this domain — DKIM is external/not signed here
#     [warning]  E3 a local selector exists but the DNS record is missing
#     [critical] E4 the DNS record publishes an empty p= (key revoked)
#     [critical] E5 the published p= does not match the local private key
#     [warning]  E6 malformed record (no v=DKIM1, unknown k=)
#     [notice]   E7 the published key is 1024 bits (RFC 8301 wants >= 2048)
#     [warning]  E8 more than one TXT record on the selector

#  F. PTR / forward-confirmed reverse DNS
#     [warning]  F1 an MX IP has no PTR
#     [warning]  F2 the PTR does not resolve back to the same IP (no FCrDNS)
#     [notice]   F3 the PTR name differs from the MX hostname
#     [warning]  F4 the PTR looks like a residential/dynamic name
#  G. Optional records (only checked when they exist)
#     [warning]  G1 _mta-sts TXT is malformed
#     [warning]  G2 _mta-sts TXT published but mta-sts.<domain> does not resolve
#     [warning]  G3 mta-sts.<domain> exists but no _mta-sts TXT — senders will fail
#     [warning]  G4 _smtp._tls TXT is malformed
#     [notice]   G5 _dmarc / <selector>._domainkey is a CNAME (breaks flattening/rotation)
#  H. Blocklists (a refused query is a notice, never a daily false alarm)
#     [critical] H1 the domain is listed on a domain blocklist
#     [critical] H2 an MX IP is listed on an IP blocklist
#     [notice]   H3 the blocklist refused/invalidated the query (rate limit, public
#                   resolver, no free access) — the answer cannot be trusted
#     [notice]   H4 a blocklist could not be reached — check skipped
#  I. Deployment
#     [critical] I1 the catalogue cannot be read / holds no active domain
#     [warning]  I2 postmaster@<DEFAULT_DOMAIN> has no mailbox or alias to receive this
#                   report
#     [notice]   I3 MX_HOSTNAME is unset — the expected MX set is inferred per domain
#
# Environment (all default inside cron/Dockerfile, an operator value wins):
#   MX_HOSTNAME              comma-separated MX targets that belong to this deployment.
#                            Unset: inferred from DEFAULT_DOMAIN's live MX (NOTICE I3).
#   DNS_CHECK_DOMAINS        replacement domain list, comma-separated. "none" = skip the
#                            whole job (dev escape hatch); unset = the whole catalogue.
#   DNS_CHECK_TO             report recipient (default postmaster@$DEFAULT_DOMAIN).
#   DNS_CHECK_RESOLVER       resolver IP for every query (default: the container's).
#                            Set it to your own recursive resolver: the Spamhaus free zones
#                            ignore public resolvers and answer "not listed" (false clean).
#   DNS_CHECK_BLOCKLISTS     domain blocklist zones (default multi.surbl.org)
#   DNS_CHECK_IP_BLOCKLISTS  IP blocklist zones (default zen.spamhaus.org)
#   DNS_CHECK_DKIM           auto (default: compare when the local key exists) | no
#   DNS_CHECK_ALERT_LEVEL    critical | warning (default) | notice — findings at or above
#                            this level are mailed, the rest stay in the report/log
#   DNS_CHECK_SPF_MX_COVERAGE  warning (default) | notice | off — C10 severity
#   DNS_CHECK_TIMEOUT        seconds per query (default 10)
#
# Options:
#   --dry-run            print the report, do not mail it
#   --domains a,b        only these domains (same as DNS_CHECK_DOMAINS)
#   --to addr            report recipient (same as DNS_CHECK_TO)
#   --mx-hostname v      expected MX set ("" forces the inference path)
#   --fixture-dir DIR    answer queries from DIR (<TYPE>.<name> files; tests only)
#   -h, --help           this text
#
# Exit: 0 nothing at/above the gate (silent), 1 findings were mailed, 2 the check could not
# run (catalogue/limits), 3 the report could not be mailed.
#
# Typical run:  ./check_dns.sh --dry-run          # what would be mailed, right now
#               ./check_dns.sh --domains a.cu --dry-run
#               ./check_dns.sh --mx-hostname ""  # what the inference path sees
#
set -uo pipefail

source /etc/environment

DKIM_DIR="${DKIM_DIR:-/var/lib/amavis/dkim}"
MX_HOSTNAME="${MX_HOSTNAME:-}"
DOMAINS_OVERRIDE="${DNS_CHECK_DOMAINS:-}"
REPORT_TO="${DNS_CHECK_TO:-}"
RESOLVER="${DNS_CHECK_RESOLVER:-}"
LIST_DOMAINS="${DNS_CHECK_BLOCKLISTS:-multi.surbl.org}"
LIST_IPS="${DNS_CHECK_IP_BLOCKLISTS:-zen.spamhaus.org}"
DKIM_MODE="${DNS_CHECK_DKIM:-auto}"
ALERT_LEVEL="${DNS_CHECK_ALERT_LEVEL:-warning}"
SPF_COVERAGE_MODE="${DNS_CHECK_SPF_MX_COVERAGE:-warning}"
QUERY_TIMEOUT="${DNS_CHECK_TIMEOUT:-10}"
FIXTURE_DIR=""
DRY_RUN="no"
INTERNAL_ERROR=0
SUGGESTED_MX="${MX_HOSTNAME%%,*}"
[ -n "$SUGGESTED_MX" ] || SUGGESTED_MX="mta.${DEFAULT_DOMAIN:-example.org}"
STARTED_UTC="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
RUN_TMP="$(mktemp -d)" || { echo "check_dns: cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$RUN_TMP"' EXIT

usage() { sed -n '/^# check_dns.sh — /,/^set -uo pipefail$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

log() { echo "MailD: dns check: $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN="yes" ;;
        --domains) DOMAINS_OVERRIDE="${2-}"; shift ;;
        --to) REPORT_TO="${2-}"; shift ;;
        --mx-hostname) MX_HOSTNAME="${2-}"; shift ;;
        --fixture-dir) FIXTURE_DIR="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check_dns: unknown option: $1 (see --help)" >&2; exit 64 ;;
    esac
    shift
done

if [ -n "$FIXTURE_DIR" ] && [ ! -d "$FIXTURE_DIR" ]; then
    echo "check_dns: fixture dir not found: $FIXTURE_DIR" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# severity + findings engine
# ---------------------------------------------------------------------------
sev_rank() {
    case "$1" in
        critical) echo 3 ;;
        warning) echo 2 ;;
        notice) echo 1 ;;
        *) echo 0 ;;
    esac
}

GATE_RANK="$(sev_rank "$ALERT_LEVEL")"
if [ "$GATE_RANK" -eq 0 ]; then
    echo "check_dns: invalid DNS_CHECK_ALERT_LEVEL '$ALERT_LEVEL' (critical|warning|notice)" >&2
    exit 2
fi

N_CRIT=0; N_WARN=0; N_NOTICE=0; N_MAILED=0
DETAIL_FILE="$RUN_TMP/detail"
SUMMARY_FILE="$RUN_TMP/summary"
: > "$DETAIL_FILE"
: > "$SUMMARY_FILE"
CUR_DOMAIN=""
SECTION_PENDING="no"

# flush_section — writes the "Domain: x" / "Deployment" heading on the first finding only,
# so a clean domain never produces an empty block in the report
flush_section() {
    [ "$SECTION_PENDING" = "yes" ] || return 0
    if [ -n "$CUR_DOMAIN" ]; then
        { echo; echo "Domain: $CUR_DOMAIN"; echo "--------"; } >> "$DETAIL_FILE"
    else
        { echo; echo "Deployment"; echo "----------"; } >> "$DETAIL_FILE"
    fi
    SECTION_PENDING="no"
}


# add_finding SEV TITLE FOUND EXPECTED IMPACT ACTION — appends a report block
add_finding() {
    local sev="$1" title="$2" found="$3" expected="$4" impact="$5" action="$6"
    local rank line pair label rest
    rank="$(sev_rank "$sev")"
    case "$sev" in
        critical) N_CRIT=$((N_CRIT + 1)) ;;
        warning) N_WARN=$((N_WARN + 1)) ;;
        notice) N_NOTICE=$((N_NOTICE + 1)) ;;
    esac
    if [ "$rank" -ge "$GATE_RANK" ]; then N_MAILED=$((N_MAILED + 1)); fi
    printf '%s|%s\n' "${CUR_DOMAIN:-(deployment)}" "$sev" >> "$SUMMARY_FILE"
    flush_section
    {
        echo
        echo "  [$sev] $title"
        for pair in "found:${found}" "expected:${expected}" "impact:${impact}" "action:${action}"; do
            label="${pair%%:*}"
            rest="${pair#*:}"
            [ -n "$rest" ] || continue
            while IFS= read -r line; do
                [ -n "${line// /}" ] || continue
                printf '      %-9s %s\n' "$label" "$line"
                label=""
            done <<< "$rest"
        done
    } >> "$DETAIL_FILE"
    log "$sev: ${CUR_DOMAIN:-deployment}: $title"
}

# begin_domain DOMAIN — marks the section that the next findings belong to
begin_domain() {
    CUR_DOMAIN="$1"
    SECTION_PENDING="yes"
}

# ---------------------------------------------------------------------------
# catalogue access (same psql/pgpass pattern as the other cron scripts)
# ---------------------------------------------------------------------------
db_ready="no"

db_init() {
    [ "$db_ready" = "yes" ] && return 0
    local pgpass="${HOME:-/root}/.pgpass"
    umask 077
    printf '%s:%s:%s:%s:%s\n' "${POSTGRES_HOST:-db}" "${POSTGRES_PORT:-5432}" \
        "${POSTGRES_DB:-mailddb}" "${POSTGRES_USER:-maild}" "${POSTGRES_PASSWORD:-}" > "$pgpass"
    umask 022
    db_ready="yes"
}

sql() {
    db_init
    psql -q -t -A -w -F '|' \
        -h "${POSTGRES_HOST:-db}" -p "${POSTGRES_PORT:-5432}" \
        -U "${POSTGRES_USER:-maild}" -d "${POSTGRES_DB:-mailddb}" -c "$1" 2>&1
}


# ---------------------------------------------------------------------------
# DNS layer — every query goes through `host` (bind9-host ships in the cron image)
#
# dns_query TYPE NAME
#   rc 0 = answers (DQ_ANS holds them, one per line), 1 = NXDOMAIN, 2 = NODATA (the name
#   exists, no record of that type), 3 = transport failure / unreachable resolver.
#   DQ_RAW keeps the untouched output for diagnostics.
# ---------------------------------------------------------------------------
DQ_RAW=""
DQ_ANS=""

rev4() { local IFS=.; set -- $1; echo "$4.$3.$2.$1"; }

dns_query() {
    local type="$1" name="$2" raw rc=0 f
    name="${name,,}"
    name="${name%.}"
    DQ_RAW=""
    DQ_ANS=""
    if [ -n "$FIXTURE_DIR" ]; then
        f="$FIXTURE_DIR/$type.$name"
        if [ -f "$f" ]; then
            raw="$(cat "$f")"
            if [ -f "$f.rc" ]; then rc="$(tr -cd '0-9' < "$f.rc")"; fi
            rc="${rc:-0}"
        else
            raw="Host $name not found: 3(NXDOMAIN)"
            rc=1
        fi
    elif [ -n "$RESOLVER" ]; then
        raw="$(timeout -k 2 $((QUERY_TIMEOUT + 2)) host -W "$QUERY_TIMEOUT" -t "$type" "$name" "$RESOLVER" 2>&1)"
        rc=$?
    else
        raw="$(timeout -k 2 $((QUERY_TIMEOUT + 2)) host -W "$QUERY_TIMEOUT" -t "$type" "$name" 2>&1)"
        rc=$?
    fi
    DQ_RAW="$raw"
    DQ_ANS="$(printf '%s\n' "$raw" \
        | grep -vE '^(Using domain server:|Name:|Address:|Aliases:)' \
        | grep -vE '^Trying ' | grep -vE '^;;' | grep -vE '^Host .* not found' \
        | grep -vE 'has no ' || true)"
    if printf '%s' "$raw" | grep -q 'NXDOMAIN'; then return 1; fi
    if printf '%s' "$raw" | grep -q 'has no '; then return 2; fi
    if [ -z "$DQ_ANS" ]; then
        if printf '%s' "$raw" | grep -qiE 'timed out|refused|no servers could be reached|SERVFAIL|SIGTERM'; then
            return 3
        fi
        return 2
    fi
    if [ "$rc" -ne 0 ]; then return 3; fi
    return 0
}

# dns_txt NAME — one record per line, quotes removed, multi-string chunks joined
dns_txt() {
    dns_query TXT "$1"
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$DQ_ANS" \
        | sed -e 's/^.*descriptive text //' \
              -e 's/\\"/__DQ__/g' -e 's/"//g' -e 's/__DQ__/"/g'
}

# dns_rr NAME TYPE AWK-EXPR — normalised (no trailing dot), de-duplicated records
dns_rr() {
    local name="$1" type="$2" expr="$3"
    dns_query "$type" "$name"
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$DQ_ANS" | awk "$expr" | sed -e 's/[[:space:]]*$//' | sed '/^$/d' | sort -u
}

mx_targets() {
    dns_query MX "$1"
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$DQ_ANS" | awk '/mail is handled by/ {
            h = $NF; sub(/\.$/, "", h); if (h == "") h = "."
            print $(NF - 1) " " h
        }' | sort -k2
}

a_records() { dns_rr "$1" A '/ has address / { p = $NF; sub(/\.$/, "", p); print p }'; }
aaaa_records() { dns_rr "$1" AAAA '/ has IPv6 address / { print $NF }'; }
ptr_records() { dns_rr "$1" PTR '/domain name pointer/ { h = $NF; sub(/\.$/, "", h); print h }'; }
ns_records() { dns_rr "$1" NS '/name server/ { h = $NF; sub(/\.$/, "", h); print h }'; }
cname_of() {
    dns_rr "$1" CNAME '{
            for (i = 1; i <= NF; i++)
                if ($i == "alias" || $i == "nickname") { h = $NF; sub(/\.$/, "", h); print h }
        }'
}

# comma/space separated list -> one lowercased item per line
split_list() { printf '%s' "$1" | tr ',' ' ' | tr ' ' '\n' | tr 'A-Z' 'a-z' | sed '/^$/d'; }

# spf_term_base TERM — strips the RFC 7208 qualifier prefix (+ - ~ ?) from a mechanism
spf_term_base() {
    local t="$1"
    case "$t" in
        [+~?-]*) t="${t:1}" ;;
    esac
    printf '%s' "$t"
}

is_private_ip() {
    case "$1" in
        10.*|127.*|0.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            return 0 ;;
        ::1|fc*|fd*|fe80:*|ff*) return 0 ;;
    esac
    return 1
}


# ---------------------------------------------------------------------------
# A. delegation
# ---------------------------------------------------------------------------
check_delegation() {
    local dom="$1" ns soa rc
    dns_query SOA "$dom"
    rc=$?
    if [ "$rc" -eq 1 ]; then
        add_finding critical "the domain does not resolve (NXDOMAIN)" \
            "host -t SOA $dom → $(printf '%s' "$DQ_RAW" | head -n 1)" \
            "a delegated zone with NS and SOA records" \
            "the domain is not hosted anywhere: every message to @$dom bounces and nothing below can be verified" \
            "publish/repair the delegation (NS) for $dom at the parent zone, then rerun: host -t NS $dom"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        add_finding warning "the delegation lookup could not be completed" \
            "host -t SOA $dom → $(printf '%s' "$DQ_RAW" | head -n 1)" \
            "an authoritative answer for the $dom SOA" \
            "the domain state is unknown: the remaining checks may report false failures" \
            "check connectivity/resolver (DNS_CHECK_RESOLVER), then rerun: host -t SOA $dom"
        return 0
    fi
    soa="$(printf '%s\n' "$DQ_ANS" | head -n 1)"
    ns="$(ns_records "$dom")"
    if [ -z "$ns" ]; then
        add_finding critical "the zone has no NS records" \
            "SOA: $soa; host -t NS $dom: NODATA" \
            "at least two NS records at the parent delegation" \
            "the zone is not authoritatively served: resolvers fail over unpredictably" \
            "add the NS records for $dom at your DNS provider"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# B. MX
# ---------------------------------------------------------------------------
check_mx() {
    local dom="$1" targets rc n t
    DOM_MX_TARGETS=""
    DOM_MX_IPS=""
    targets="$(mx_targets "$dom")"
    rc=$?
    case "$rc" in
        1) return 0 ;;                 # A1 already reported it
        3)
            add_finding warning "the MX lookup could not be completed" \
                "host -t MX $dom → $(printf '%s' "$DQ_RAW" | head -n 1)" \
                "an authoritative answer for the $dom MX" \
                "mail routing cannot be verified while the lookup fails" \
                "check the resolver (DNS_CHECK_RESOLVER) and the firewall, then rerun: host -t MX $dom"
            return 0 ;;
    esac
    n="$(printf '%s\n' "$targets" | sed '/^$/d' | wc -l)"
    if [ "$n" -eq 0 ]; then
        local a4 a6
        a4="$(a_records "$dom")"
        a6="$(aaaa_records "$dom")"
        DOM_MX_IPS="$(printf '%s\n%s\n' "$a4" "$a6" | sed '/^$/d' | sort -u)"
        if [ -z "$DOM_MX_IPS" ]; then
            add_finding critical "no MX and no address record — the domain cannot receive mail" \
                "host -t MX $dom: NODATA; host -t A/AAAA $dom: NODATA" \
                "an MX record pointing at the mail host, e.g. '$dom. 3600 IN MX 10 $SUGGESTED_MX.'" \
                "senders have no route for @$dom: mail to this domain bounces (5.4.4 / 5.1.2)" \
                "publish 'MX 10 $SUGGESTED_MX.' for $dom"
        else
            add_finding warning "no MX record — delivery falls back to the domain's own address" \
                "host -t MX $dom: NODATA; host -t A/AAAA $dom: $(echo $DOM_MX_IPS)" \
                "an explicit MX record pointing at $SUGGESTED_MX" \
                "RFC 5321 implicit MX is deprecated and stops working as soon as the apex becomes a CNAME/CDN or moves" \
                "publish 'MX 10 $SUGGESTED_MX.' for $dom"
        fi
        return 0
    fi
    printf '%s\n' "$targets" | sed '/^$/d' > "$RUN_TMP/mx"
    DOM_MX_TARGETS="$(cut -d' ' -f2- "$RUN_TMP/mx" | sort -u)"

    if printf '%s\n' "$targets" | grep -qE '^[0-9]+ \.$'; then
        add_finding critical "the domain publishes a null MX — it explicitly refuses all mail" \
            "host -t MX $dom → '0 .'" \
            "a real MX (or no MX at all) if this domain should receive mail" \
            "RFC 7505 null MX tells every sender that @$dom does not accept mail: local mailboxes are unreachable" \
            "remove the '0 .' record and publish 'MX 10 $SUGGESTED_MX.'"
        return 0
    fi


    local ips4 ips6 ip cn dup
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        if [ "$t" = "$dom" ]; then
            add_finding critical "an MX target is the domain itself — mail loops back" \
                "host -t MX $dom → $(printf '%s\n' "$targets" | sed '/^$/d' | tr '\n' ';')" \
                "the MX must name the mail host ($SUGGESTED_MX), never the served domain" \
                "a message for @$dom is routed to $dom itself, which has no mail listener: delivery loops or bounces" \
                "replace the '$t' MX with '$SUGGESTED_MX'"
        fi
        cn="$(cname_of "$t")"
        if [ -n "$cn" ]; then
            add_finding critical "an MX target is a CNAME" \
                "$t is an alias for $cn" \
                "the MX must point at a host with an A/AAAA record (RFC 5321 §5.1)" \
                "strict receivers cannot follow it: delivery becomes intermittent or bounces" \
                "give $t real A/AAAA records instead of a CNAME"
        fi
        ips4="$(a_records "$t")"
        ips6="$(aaaa_records "$t")"
        if [ -z "$ips4$ips6" ]; then
            add_finding critical "an MX target does not resolve" \
                "host -t A/AAAA $t: NODATA" \
                "at least one A or AAAA record for $t" \
                "senders cannot connect to $t: mail for @$dom is deferred and eventually bounces" \
                "create the A/AAAA for $t (or point the MX at '$SUGGESTED_MX')"
        fi
        for ip in $ips4 $ips6; do
            DOM_MX_IPS="$DOM_MX_IPS $ip"
            if is_private_ip "$ip"; then
                add_finding critical "an MX target resolves to a private address" \
                    "$t → $ip" \
                    "the public (routable) address of the mail host" \
                    "not reachable from the internet: external senders cannot deliver to @$dom" \
                    "publish the public IP of $t in the zone (split-horizon DNS leaking into the public view?)"
            fi
        done
    done <<< "$DOM_MX_TARGETS"
    DOM_MX_IPS="$(printf '%s\n' $DOM_MX_IPS | sed '/^$/d' | sort -u)"

    dup="$(cut -d' ' -f1 "$RUN_TMP/mx" | sort | uniq -d | tr '\n' ' ')"
    if [ -n "${dup// /}" ]; then
        add_finding warning "two MX records share a priority" \
            "duplicate priorities: ${dup% }" \
            "a distinct preference per MX (10, 20, ...)" \
            "receivers pick between them at random, so a broken host is used half of the time" \
            "renumber the MX priorities"
    fi
    if [ "$n" -eq 1 ]; then
        add_finding notice "a single MX — no redundancy" \
            "one MX: $(cat "$RUN_TMP/mx")" \
            "two MX records (different priorities/hosts) if uptime matters" \
            "while that host is down every message is deferred; senders retry for days and may give up" \
            "add a second MX (a backup host or a second A record on another server)"
    fi
    compare_mx_set "$dom" "$targets"
}

compare_mx_set() {
    local dom="$1" targets="$2" miss extra sev found
    [ -n "$EXPECTED_MX" ] || return 0
    miss="$(comm -23 <(printf '%s\n' "$EXPECTED_MX" | sed '/^$/d' | sort -u) \
                     <(printf '%s\n' "$DOM_MX_TARGETS" | sed '/^$/d' | sort -u))"
    extra="$(comm -13 <(printf '%s\n' "$EXPECTED_MX" | sed '/^$/d' | sort -u) \
                      <(printf '%s\n' "$DOM_MX_TARGETS" | sed '/^$/d' | sort -u))"
    [ -n "$miss$extra" ] || return 0
    sev="warning"
    [ "$MX_SOURCE" = "MX_HOSTNAME" ] && sev="critical"
    found="published: $(printf '%s\n' "$targets" | sed '/^$/d' | tr '\n' ' ')"
    [ -n "$miss" ] && found="$found"$'\n'"missing from DNS: $(printf '%s\n' "$miss" | tr '\n' ' ')"
    [ -n "$extra" ] && found="$found"$'\n'"not declared in the expected set: $(printf '%s\n' "$extra" | tr '\n' ' ')"
    if [ "$sev" = "critical" ]; then
        add_finding "$sev" "the MX set does not match the declared mail host" \
            "$found" \
            "MX_HOSTNAME: $(printf '%s\n' "$EXPECTED_MX" | tr '\n' ' ')" \
            "senders may hand mail to a host you do not control (stale or typo'd MX), and MX_HOSTNAME no longer matches reality" \
            "point $dom's MX at $(printf '%s\n' "$EXPECTED_MX" | tr '\n' ' ') (or update MX_HOSTNAME if the move was intentional)"
    else
        add_finding "$sev" "the MX set differs from ${DEFAULT_DOMAIN}'s (the inferred reference)" \
            "$found" \
            "the same MX set as ${DEFAULT_DOMAIN}: $(printf '%s\n' "$EXPECTED_MX" | tr '\n' ' ')" \
            "an inconsistent MX set hands mail to hosts that may not know this domain" \
            "declare MX_HOSTNAME in the operator env file and point $dom's MX at it"
    fi
}


# ---------------------------------------------------------------------------
# C. SPF
# ---------------------------------------------------------------------------
SPF_MISSING_FILE="$RUN_TMP/spf-missing"

# spf_lookup_count "<v=spf1 ...>" [depth] — RFC 7208 §4.6.4 lookup budget
# include:/redirect= targets without their own SPF are recorded in $SPF_MISSING_FILE (the
# function runs inside $( ), so it cannot set a global for check_spf to read back).
spf_lookup_count() {
    local rec="$1" depth="${2:-0}" tok name sub count=0
    if [ "$depth" -gt 3 ]; then echo 99; return; fi
    for tok in ${rec#v=spf1}; do
        case "$tok" in
            include:*|redirect=*)
                count=$((count + 1))
                name="${tok#include:}"
                name="${name#redirect=}"
                sub="$(dns_txt "$name" 2>/dev/null | grep -iE '^v=spf1( |$)' | head -n 1)"
                if [ -n "$sub" ]; then
                    count=$((count + $(spf_lookup_count "$sub" $((depth + 1)))))
                else
                    echo "$name" >> "$SPF_MISSING_FILE"
                fi
                ;;
            a|a:*|a/*|mx|mx:*|mx/*|exists:*|ptr|ptr:*)
                count=$((count + 1)) ;;
        esac
    done
    echo "$count"
}

check_spf() {
    local dom="$1" rc recs n rec qual sev
    DOM_SPF=""
    DOM_SPF_QUAL="none"
    : > "$SPF_MISSING_FILE"
    recs="$(dns_txt "$dom")"
    rc=$?
    if [ "$rc" -eq 3 ]; then
        add_finding warning "the TXT lookup could not be completed" \
            "host -t TXT $dom → $(printf '%s' "$DQ_RAW" | head -n 1)" \
            "an authoritative TXT answer for $dom" \
            "SPF/DMARC/verification records cannot be inspected right now" \
            "check the resolver and rerun: host -t TXT $dom"
        return 0
    fi
    recs="$(printf '%s\n' "$recs" | grep -iE '^v=spf1( |$)' || true)"
    n="$(printf '%s\n' "$recs" | sed '/^$/d' | wc -l)"
    if [ "$n" -eq 0 ]; then
        add_finding critical "no SPF record — anyone may spoof this domain" \
            "host -t TXT $dom: no 'v=spf1' record" \
            "TXT \"v=spf1 mx -all\" (allow the MX hosts and nothing else)" \
            "receivers have no way to tell your mail from a forgery, so bounces/backscatter and phishing land on your reputation" \
            "publish: $dom. 3600 IN TXT \"v=spf1 mx -all\" — then check with 'host -t TXT $dom'"
        return 0
    fi
    rec="$(printf '%s\n' "$recs" | head -n 1)"
    DOM_SPF="$rec"
    if [ "$n" -gt 1 ]; then
        add_finding critical "more than one SPF record — receivers return permerror" \
            "$n records: $(printf '%s\n' "$recs" | tr '\n' ';')" \
            "exactly one 'v=spf1' TXT record" \
            "RFC 7208 makes a multi-record SPF a permanent error, so the domain is treated as having no SPF at all" \
            "merge the mechanisms into a single record (use include: for delegated senders)"
    fi

    local -a terms
    read -ra terms <<< "${rec#v=spf1}"
    local total="${#terms[@]}" i tok base all_idx=-1 has_redirect="no"
    for i in "${!terms[@]}"; do
        tok="${terms[$i]}"
        case "$tok" in
            all|+all|-all|~all|'?all') all_idx="$i" ;;
            redirect=*) has_redirect="yes" ;;
        esac
    done
    if [ "$all_idx" -ge 0 ]; then
        tok="${terms[$all_idx]}"
        case "$tok" in
            -all) DOM_SPF_QUAL="fail" ;;
            '~all') DOM_SPF_QUAL="softfail" ;;
            '?all') DOM_SPF_QUAL="neutral" ;;
            *) DOM_SPF_QUAL="pass" ;;
        esac
        if [ "$all_idx" -lt "$((total - 1))" ]; then
            add_finding notice "mechanisms after 'all' are ignored" \
                "record: $rec" \
                "'all' as the last mechanism" \
                "everything after 'all' is dead weight: a sender listed there is still not authorised" \
                "move '${terms[$all_idx]}' to the end of the record"
        fi
    fi


    case "$DOM_SPF_QUAL" in
        pass)
            add_finding critical "the SPF policy ends in +all / bare all / ?all — nothing is protected" \
                "record: $rec" \
                "a restrictive default, e.g. '-all'" \
                "every server on the internet is authorised to send as @$dom: SPF gives zero protection and DMARC alignment is trivially bypassed" \
                "replace the trailing mechanism with '-all' (or '~all' while you migrate)" ;;
        neutral)
            add_finding critical "the SPF policy ends in ?all — nothing is protected" \
                "record: $rec" \
                "a restrictive default, e.g. '-all'" \
                "'?all' asserts nothing: any host may send as @$dom" \
                "replace the trailing mechanism with '-all' (or '~all' while you migrate)" ;;
        softfail)
            add_finding warning "the SPF policy ends in ~all — spoofed mail is only soft-failed" \
                "record: $rec" \
                "'-all' once you are sure every legitimate sender is listed" \
                "receivers usually mark '~all' failures as suspicious but still accept them: spoofed mail reaches inboxes, and DMARC p=reject is weakened for SPF-aligned mail" \
                "audit the senders, then change the trailing mechanism to '-all'" ;;
        none)
            if [ "$has_redirect" = "no" ]; then
                add_finding warning "the SPF record has no 'all' mechanism and no redirect=" \
                    "record: $rec" \
                    "an explicit '-all' (or '~all' + redirect=)" \
                    "if no mechanism matches, the result is Neutral: senders you never authorised are not rejected" \
                    "append '-all' to the record"
            fi ;;
    esac
    if [ "$has_redirect" = "yes" ] && [ "$all_idx" -ge 0 ]; then
        add_finding warning "redirect= is ignored because an 'all' mechanism is present" \
            "record: $rec" \
            "either redirect= or 'all', not both" \
            "the redirect target is never consulted: the policy is not what it looks like" \
            "drop the redirect= modifier (or drop 'all' and rely on the redirect)"
    fi

    local bad="" cidr
    for tok in "${terms[@]}"; do
        base="$(spf_term_base "$tok")"
        case "$base" in
            all|include:*|a|a:*|a/*|mx|mx:*|mx/*|ptr|ptr:*|ip4:*|ip6:*|exists:*|redirect=*|exp=*) ;;
            *'='*) bad="$bad $tok" ;;
            *)
                case "$base" in
                    *:*) bad="$bad $tok" ;;
                esac ;;
        esac
        case "$base" in
            ptr|ptr:*)
                add_finding warning "the SPF record uses the 'ptr' mechanism" \
                    "record: $rec" \
                    "the 'a', 'mx' or 'ip4:' mechanisms instead" \
                    "RFC 7208 §5.5 discourages 'ptr' (slow, unreliable, often wrong) and it adds 2 lookups" \
                    "replace 'ptr' with 'a'/'mx'/'ip4:' entries" ;;
            ip4:*)
                cidr="${base#ip4:}"
                if ! printf '%s' "${cidr##*/}" | grep -qE '^[0-9]{1,2}$' || [ "${cidr##*/}" -gt 32 ]; then
                    add_finding warning "invalid ip4: CIDR length" \
                        "mechanism: $base" \
                        "ip4:<address>/<0-32> (or no mask at all)" \
                        "the whole record is rejected as 'permerror' by RFC 7208 parsers" \
                        "fix the mask, e.g. ip4:${cidr%%/*}/32"
                fi ;;
        esac
    done
    if [ -n "${bad// /}" ]; then
        add_finding warning "unknown SPF mechanism/modifier" \
            "unparsed terms:${bad}" \
            "only all, include, a, mx, ptr, ip4, ip6, exists, redirect=, exp=" \
            "unknown terms are ignored at best and make the record a 'permerror' at worst" \
            "remove or fix the terms listed above"
    fi


    if [ "${#rec}" -gt 450 ]; then
        add_finding warning "the SPF record is longer than 450 bytes" \
            "${#rec} bytes: $rec" \
            "a record under 450 bytes (RFC 7208 recommends it)" \
            "long records get split into strings by some providers/UIs and are then published truncated: the policy silently changes" \
            "shorten it (use include: for large blocks of senders, or an ip4 CIDR summary)"
    fi

    local lookups
    lookups="$(spf_lookup_count "$rec" 0)"
    if [ "$lookups" -gt 10 ]; then
        add_finding critical "the SPF record exceeds the 10-DNS-lookup limit" \
            "$lookups lookups: $rec" \
            "at most 10 (a, mx, include, exists, ptr, redirect)" \
            "receivers return 'permerror', which is treated as no-SPF: you lose all protection on the domain" \
            "reduce to <=10 lookups (flatten includes, replace a/mx with ip4/ip6)"
    elif [ "$lookups" -ge 8 ]; then
        add_finding notice "the SPF record is close to the 10-DNS-lookup limit" \
            "$lookups lookups of 10" \
            "some headroom (<=7)" \
            "one more sender added through include: pushes the record into permerror" \
            "flatten the record while you still have room"
    fi

    local cov="no" has_include="no" v t
    for tok in "${terms[@]}"; do
        base="$(spf_term_base "$tok")"
        case "$base" in
            mx|a) cov="yes" ;;
            include:*) has_include="yes" ;;
            ip4:*|ip6:*)
                v="${base#*:}"; v="${v%%/*}"
                if printf '%s\n' "$DOM_MX_IPS" | grep -Fqx "$v"; then cov="yes"; fi ;;
            a:*|mx:*)
                t="${base#*:}"; t="${t%%/*}"
                if printf '%s\n' "$DOM_MX_TARGETS" | grep -Fqx "$t"; then cov="yes"; fi ;;
        esac
    done
    if [ "$cov" = "no" ] && [ -n "$DOM_MX_IPS" ] && [ "$DOM_SPF_QUAL" != "pass" ]; then
        sev=""
        case "$SPF_COVERAGE_MODE" in
            off) sev="" ;;
            notice) sev="notice" ;;
            *) sev="warning" ;;
        esac
        if [ -n "$sev" ]; then
            if [ "$has_include" = "yes" ]; then
                add_finding notice "the MX IPs are not explicitly covered by the SPF record" \
                    "record: $rec" \
                    "an 'mx' mechanism, or ip4:/ip6: entries for the MX IPs" \
                    "the policy relies entirely on include: targets — if one drops your range, your own outbound mail fails SPF" \
                    "add 'mx' (or the ip4:/ip6: of the MX hosts) to the record"
            else
                add_finding "$sev" "the MX IPs are not covered by the SPF record" \
                    "record: $rec" \
                    "MX IPs: $(echo $DOM_MX_IPS)" \
                    "mail sent from this server (webmail, submissions, forwards) fails SPF and is scored as spoofed" \
                    "add 'mx' to the record, e.g. 'v=spf1 mx -all'"
            fi
        fi
    fi
    local spf_missing
    spf_missing="$(sed '/^$/d' "$SPF_MISSING_FILE" 2>/dev/null | sort -u | tr '\n' ' ')"
    if [ -n "${spf_missing// /}" ]; then
        add_finding warning "an include: target publishes no SPF record" \
            "include/redirect without v=spf1: ${spf_missing% }" \
            "each include: target must publish its own 'v=spf1' TXT record" \
            "a missing include makes the whole SPF evaluation a permerror (no SPF at all)" \
            "remove the dead include: (or ask that provider for its current record)"
    fi
    return 0
}


# ---------------------------------------------------------------------------
# D. DMARC
# ---------------------------------------------------------------------------
DMARC_P=""

check_dmarc() {
    local dom="$1" recs rc n rec parent precs cn
    DMARC_P=""
    cn="$(cname_of "_dmarc.$dom")"
    if [ -n "$cn" ]; then
        add_finding notice "_dmarc.$dom is a CNAME" \
            "_dmarc.$dom is an alias for $cn" \
            "a plain TXT record at _dmarc.$dom" \
            "a CNAME is legal but breaks some receivers and hides the policy from flattening/aggregate tooling" \
            "publish the DMARC policy as a TXT record at _dmarc.$dom"
    fi
    recs="$(dns_txt "_dmarc.$dom")"
    rc=$?
    if [ "$rc" -eq 3 ]; then
        add_finding warning "the DMARC lookup could not be completed" \
            "host -t TXT _dmarc.$dom → $(printf '%s' "$DQ_RAW" | head -n 1)" \
            "an authoritative TXT answer for _dmarc.$dom" \
            "the DMARC state is unknown right now" \
            "check the resolver and rerun: host -t TXT _dmarc.$dom"
        return 0
    fi
    recs="$(printf '%s\n' "$recs" | grep -iE '^v=DMARC1' || true)"
    n="$(printf '%s\n' "$recs" | sed '/^$/d' | wc -l)"
    if [ "$n" -eq 0 ]; then
        parent="${dom#*.}"
        if [ "$parent" != "$dom" ] && printf '%s' "$parent" | grep -q '\.'; then
            precs="$(dns_txt "_dmarc.$parent" | grep -iE '^v=DMARC1' || true)"
        else
            precs=""
        fi
        if [ -n "$precs" ]; then
            add_finding warning "no DMARC record on the exact domain — the policy is inherited from $parent" \
                "host -t TXT _dmarc.$dom: NODATA; host -t TXT _dmarc.$parent: $(printf '%s\n' "$precs" | head -n 1)" \
                "an explicit 'v=DMARC1; p=reject; rua=...' at _dmarc.$dom" \
                "reports are aggregated for the parent and you cannot see or tighten $dom on its own" \
                "publish: _dmarc.$dom. 3600 IN TXT \"v=DMARC1; p=reject; rua=mailto:postmaster@$dom\""
        else
            add_finding warning "no DMARC record — the domain can be spoofed and you never see it" \
                "host -t TXT _dmarc.$dom: NODATA; _dmarc.$parent also empty" \
                "TXT \"v=DMARC1; p=reject; rua=mailto:postmaster@$dom\"" \
                "receivers fall back to SPF/DKIM heuristics only: forged mail from @$dom is delivered and no report ever reaches you" \
                "publish: _dmarc.$dom. 3600 IN TXT \"v=DMARC1; p=reject; rua=mailto:postmaster@$dom\" (start with p=none + rua if you want data first)"
        fi
        return 0
    fi
    rec="$(printf '%s\n' "$recs" | head -n 1)"
    if [ "$n" -gt 1 ]; then
        add_finding critical "more than one DMARC record — receivers return permerror" \
            "$n records: $(printf '%s\n' "$recs" | tr '\n' ';')" \
            "exactly one 'v=DMARC1' TXT record" \
            "RFC 7489 makes a multi-record policy a permanent error: the domain is treated as having no DMARC at all" \
            "delete the extra record(s), keeping the intended policy"
    fi

    local -a tags
    local tag k v first_key="" taglist="" p="" sp="" pct="" rua="" ruf="" adkim="" aspf="" fo="" rf=""
    IFS=';' read -ra tags <<< "$rec"
    for tag in "${tags[@]}"; do
        tag="$(printf '%s' "$tag" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$tag" ] || continue
        k="$(printf '%s' "${tag%%=*}" | tr 'A-Z' 'a-z' | sed 's/[[:space:]]//g')"
        v="$(printf '%s' "${tag#*=}" | sed 's/[[:space:]]//g')"
        [ -n "$first_key" ] || first_key="$k"
        taglist="$taglist $k"
        case "$k" in
            p) p="$(printf '%s' "$v" | tr 'A-Z' 'a-z')" ;;
            sp) sp="$(printf '%s' "$v" | tr 'A-Z' 'a-z')" ;;
            pct) pct="$v" ;;
            rua) rua="$v" ;;
            ruf) ruf="$v" ;;
            adkim) adkim="$(printf '%s' "$v" | tr 'A-Z' 'a-z')" ;;
            aspf) aspf="$(printf '%s' "$v" | tr 'A-Z' 'a-z')" ;;
            fo) fo="$v" ;;
            rf) rf="$v" ;;
        esac
    done
    DMARC_P="$p"

    if [ "$first_key" != "v" ] || ! printf '%s' "$rec" | grep -qiE '^v=DMARC1'; then
        add_finding critical "\"v=DMARC1\" is missing or is not the first tag" \
            "record: $rec" \
            "a record that starts with 'v=DMARC1;'" \
            "receivers must discard the whole policy (RFC 7489 §6.3): DMARC is effectively absent" \
            "rewrite the record starting with 'v=DMARC1; p=...'"
    fi
    case "$p" in
        none|quarantine|reject) ;;
        "") add_finding critical "the DMARC record has no p= tag" \
                "record: $rec" \
                "p=none, p=quarantine or p=reject" \
                "the policy is invalid and gets discarded: no DMARC enforcement at all" \
                "add 'p=reject' (or 'p=none' while you collect reports)" ;;
        *) add_finding critical "invalid DMARC p= value" \
                "p=$p in: $rec" \
                "p=none, p=quarantine or p=reject" \
                "the policy is invalid and gets discarded: no DMARC enforcement at all" \
                "fix the p= tag" ;;
    esac


    if [ "$p" = "none" ] && [ -n "$p" ]; then
        add_finding warning "p=none — DMARC only reports, spoofed mail is still delivered" \
            "record: $rec" \
            "p=quarantine or p=reject once the reports look clean" \
            "a forger still reaches the inbox: p=none only asks receivers to send you reports" \
            "collect a few weeks of rua= reports, then move to p=quarantine and finally p=reject"
    fi
    if [ -n "$p" ] && [ "$p" != "none" ] && [ "$sp" = "none" ]; then
        add_finding warning "sp=none while p=$p — subdomains stay spoofable" \
            "record: $rec" \
            "sp equals p (or omit sp so it inherits p)" \
            "an attacker can spoof anything@sub.$dom even though the apex is protected" \
            "remove sp=none (it inherits p=) or set sp=$p"
    fi
    if [ -n "$pct" ]; then
        if ! printf '%s' "$pct" | grep -qE '^[0-9]{1,3}$'; then
            add_finding warning "invalid DMARC pct= value" \
                "pct=$pct in: $rec" \
                "pct=1..100" \
                "receivers may discard the policy or ignore pct" \
                "use an integer between 1 and 100"
        elif [ "$pct" -lt 100 ]; then
            add_finding notice "pct=$pct — the policy is only applied to part of the mail" \
                "pct=$pct in: $rec" \
                "pct=100 (or no pct at all) for full enforcement" \
                "the remaining $((100 - pct))% of failing mail is still delivered" \
                "raise pct to 100 once you are confident in the reports"
        fi
    fi
    if [ -z "$rua" ]; then
        add_finding notice "no rua= — you receive no DMARC aggregate reports" \
            "record: $rec" \
            "rua=mailto:postmaster@$dom (or your report mailbox)" \
            "you cannot see who sends as @$dom, so authentication problems stay invisible until someone complains" \
            "add 'rua=mailto:postmaster@$dom' to the record"
    else
        local bad
        bad="$(dmarc_route_bad "$rua")"
        if [ -n "$bad" ]; then
            add_finding warning "a DMARC rua= address has no mail route" \
                "unroutable: $bad" \
                "a mailbox/domain that resolves (MX or A) and accepts mail" \
                "report delivery fails silently: you drop the very telemetry that tells you about spoofing" \
                "point rua= at a mailbox inside this deployment, e.g. mailto:postmaster@$dom"
        fi
    fi
    if [ -n "$ruf" ]; then
        if ! printf '%s' "$ruf" | grep -qE '(mailto:|https?://)'; then
            add_finding warning "malformed DMARC ruf= value" \
                "ruf=$ruf" \
                "ruf=mailto:<address> (or an https:// URI)" \
                "receivers ignore an unparsable forensic-report URI" \
                "fix the ruf= tag or drop it (rua= is the important one)"
        fi
    fi
    if [ -n "$adkim" ] && [ "$adkim" != "r" ] && [ "$adkim" != "s" ]; then
        add_finding warning "invalid DMARC adkim= value" \
            "adkim=$adkim" \
            "adkim=r (relaxed) or adkim=s (strict)" \
            "invalid alignment tokens make receivers fall back to the default and can invalidate the policy" \
            "use adkim=r or adkim=s"
    fi
    if [ -n "$aspf" ] && [ "$aspf" != "r" ] && [ "$aspf" != "s" ]; then
        add_finding warning "invalid DMARC aspf= value" \
            "aspf=$aspf" \
            "aspf=r (relaxed) or aspf=s (strict)" \
            "invalid alignment tokens make receivers fall back to the default and can invalidate the policy" \
            "use aspf=r or aspf=s"
    fi
    if [ -n "$fo" ] && printf '%s' "$fo" | grep -qvE '^[01ds](:[01ds])*$'; then
        add_finding warning "invalid DMARC fo= value" \
            "fo=$fo" \
            "fo=0, fo=1, fo=d, fo=s (colon-separated combinations)" \
            "receivers ignore an unparsable fo= tag" \
            "fix or drop the fo= tag"
    fi
    if [ -n "$rf" ] && ! printf '%s' "$rf" | grep -qE '^(afrf|iodef)(:(afrf|iodef))*$'; then
        add_finding warning "invalid DMARC rf= value" \
            "rf=$rf" \
            "rf=afrf (or rf=iodef)" \
            "receivers ignore forensic reports in an unknown format" \
            "use rf=afrf"
    fi
    if { [ "$p" = "quarantine" ] || [ "$p" = "reject" ]; } &&
       { [ "$DOM_SPF_QUAL" = "softfail" ] || [ "$DOM_SPF_QUAL" = "none" ] ||
         [ "$DOM_SPF_QUAL" = "neutral" ] || [ "$DOM_SPF_QUAL" = "pass" ]; } &&
       ! dkim_selector_for "$dom"; then
        add_finding notice "p=$p is strict here, but neither SPF nor a local DKIM key can back it" \
            "DMARC p=$p; SPF ends in $DOM_SPF_QUAL; no DKIM key signs @$dom here" \
            "SPF '-all' and a DKIM selector for $dom" \
            "legitimate mail from @$dom can fail both aligned checks: receivers will quarantine/reject your own users' messages" \
            "tighten SPF to '-all' and enable DKIM for $dom before relying on p=$p"
    fi
    return 0
}

# dmarc_route_bad "<rua list>" — mailto targets whose domain has neither MX nor A
dmarc_route_bad() {
    local list="$1" item addr dom out="" a
    local -a items
    IFS=',' read -ra items <<< "$list"
    for item in "${items[@]}"; do
        item="$(printf '%s' "$item" | sed 's/[[:space:]]//g')"
        case "$item" in mailto:*) addr="${item#mailto:}" ;; *) continue ;; esac
        addr="${addr%%!*}"
        dom="${addr##*@}"
        [ "$dom" != "$addr" ] || continue
        a="$(mx_targets "$dom"; a_records "$dom")"
        [ -n "$a" ] || out="$out $item"
    done
    printf '%s' "${out# }"
}


# ---------------------------------------------------------------------------
# E. DKIM — the DNS record is compared against the key Amavis actually signs with
# ---------------------------------------------------------------------------
DKIM_SEL=""
DKIM_BITS=""

# dkim_selector_for DOMAIN — true when $DKIM_DIR/db.txt maps the domain to a selector
dkim_selector_for() {
    local dom="$1"
    DKIM_SEL=""
    [ -r "$DKIM_DIR/db.txt" ] || return 1
    DKIM_SEL="$(awk -v d="$1" 'tolower($1) == tolower(d) { print $2; exit }' "$DKIM_DIR/db.txt")"
    [ -n "$DKIM_SEL" ] || return 1
    DKIM_SEL="$(printf '%s' "$DKIM_SEL" | tr 'A-Z' 'a-z')"
    return 0
}

check_dkim() {
    local dom="$1" sel f flat lp bits recs rc n rec dp ktag cdn
    DKIM_SEL=""
    DKIM_BITS=""
    if [ "$DKIM_MODE" = "no" ]; then
        log "dkim: comparison disabled (DNS_CHECK_DKIM=no)"
        return 0
    fi
    if [ ! -d "$DKIM_DIR" ] || [ ! -r "$DKIM_DIR/db.txt" ]; then
        add_finding notice "the amavis DKIM volume is not readable — key comparison skipped" \
            "$DKIM_DIR/db.txt is missing inside the cron container" \
            "the amavis volume mounted read-only at $DKIM_DIR" \
            "DKIM records cannot be compared against the signing keys, so a missing or wrong key goes unnoticed" \
            "mount it in the compose cron service ('amavis:/var/lib/amavis:ro') and restart cron"
        return 0
    fi
    if ! dkim_selector_for "$dom"; then
        add_finding notice "no local DKIM selector — this domain is not signed here" \
            "no '$dom <selector>' line in $DKIM_DIR/db.txt" \
            "per-domain keys when this deployment signs mail for $dom" \
            "DKIM alignment for @$dom relies on an external signer; with DMARC p=reject a missing/broken signature loses mail" \
            "if MailD should sign for $dom, generate a key (AdminNG DKIM panel or 'amavisd newkey') and publish it"
        return 0
    fi
    sel="$DKIM_SEL"
    f="$DKIM_DIR/$dom.$sel.txt"
    [ -f "$f" ] || f="$(ls "$DKIM_DIR/$dom".*.txt 2>/dev/null | head -n 1)"
    lp=""
    bits=""
    if [ -n "$f" ] && [ -f "$f" ]; then
        flat="$(tr -d '"' < "$f" | tr '\n' ' ')"
        # 'amavisd showkeys' splits the key over quoted lines ("v=DKIM1; p=" then the base64
        # chunks): drop the ';' comment line and every blank before extracting, or p= is
        # followed by a space and the local key reads empty (E5 never compared anything).
        lp="$(grep -v '^[[:space:]]*;' "$f" | tr -d '"[:space:]()' \
            | grep -oE '(^|;)p=[A-Za-z0-9+/=]+' | head -n 1 | sed 's/^.*p=//')"
        bits="$(printf '%s' "$flat" | grep -oE '[0-9]+ bits' | head -n 1 | tr -cd '0-9')"
    fi
    DKIM_BITS="$bits"

    cdn="$(cname_of "$sel._domainkey.$dom")"
    if [ -n "$cdn" ]; then
        add_finding notice "$sel._domainkey.$dom is a CNAME" \
            "$sel._domainkey.$dom is an alias for $cdn" \
            "a plain TXT record at $sel._domainkey.$dom" \
            "a CNAME is legal but complicates key rotation and breaks flattening/propagation tooling" \
            "publish the key as a TXT record at $sel._domainkey.$dom"
    fi
    recs="$(dns_txt "$sel._domainkey.$dom")"
    rc=$?
    if [ "$rc" -eq 3 ]; then
        add_finding warning "the DKIM lookup could not be completed" \
            "host -t TXT $sel._domainkey.$dom → $(printf '%s' "$DQ_RAW" | head -n 1)" \
            "an authoritative TXT answer for the selector" \
            "DKIM verification cannot be confirmed while the lookup fails" \
            "check the resolver and rerun: host -t TXT $sel._domainkey.$dom"
        return 0
    fi

    recs="$(printf '%s\n' "$recs" | grep -vE '^[[:space:]]*$' || true)"
    n="$(printf '%s\n' "$recs" | sed '/^$/d' | wc -l)"
    if [ "$n" -eq 0 ]; then
        add_finding warning "the DKIM record is missing" \
            "local selector '$sel' for $dom; host -t TXT $sel._domainkey.$dom: NODATA" \
            "the public key of the local selector (the block printed by 'amavisd showkeys' / the AdminNG DKIM panel)" \
            "signatures from this server do not verify: DMARC alignment for @$dom fails and p=reject mail gets rejected" \
            "publish the TXT record for $sel._domainkey.$dom"
        return 0
    fi
    if [ "$n" -gt 1 ]; then
        add_finding warning "more than one TXT record on the DKIM selector" \
            "$n records: $(printf '%s\n' "$recs" | tr '\n' ';')" \
            "exactly one TXT record per selector" \
            "verifiers may concatenate or pick the wrong record: signatures stop verifying" \
            "keep only the current key record"
    fi
    rec="$(printf '%s\n' "$recs" | head -n 1)"
    # a key longer than one 255-byte string (any 2048-bit key) is published as several
    # strings that verifiers concatenate: dns_txt leaves a blank between them, so p= is read
    # whitespace-free (RFC 6376 3.6.1 also allows folding whitespace inside the value).
    dp="$(printf '%s' "$rec" | tr -d '[:space:]' | grep -oE '(^|;)p=[A-Za-z0-9+/=]*' | head -n 1 \
        | sed 's/^;\{0,1\}p=//')"
    if [ -z "$dp" ]; then
        add_finding critical "the DKIM record publishes an empty p= — the key is revoked" \
            "record: $rec" \
            "the public key of selector '$sel'" \
            "every signature from this server fails verification, which is exactly what DMARC reads as spoofing" \
            "republish the key from the AdminNG DKIM panel (show DNS record) at $sel._domainkey.$dom"
    elif [ -n "$lp" ] && [ "$dp" != "$lp" ]; then
        add_finding critical "the published DKIM key does not match the local signing key" \
            "published p=: $(printf '%s' "$dp" | cut -c1-32)... (${#dp} chars)"$'\n'"local p=: $(printf '%s' "$lp" | cut -c1-32)... (${#lp} chars)" \
            "the key material in $f" \
            "the server signs with a key the world does not know: every signature fails, so with DMARC enforcing the domain's own mail is rejected" \
            "republish the record from the AdminNG DKIM panel — do not regenerate the key unless rotation is intended"
    fi
    if ! printf '%s' "$rec" | grep -qiE '(^|;[[:space:]]*)v=DKIM1'; then
        add_finding warning "the DKIM record has no v=DKIM1 tag" \
            "record: $rec" \
            "'v=DKIM1; k=rsa; p=...'" \
            "some verifiers require the version tag and discard the record" \
            "publish the record exactly as shown by the AdminNG DKIM panel / 'amavisd showkeys'"
    fi
    ktag="$(printf '%s' "$rec" | grep -oiE 'k=[a-z0-9]+' | head -n 1 | cut -c3- | tr 'A-Z' 'a-z')"
    if [ -n "$ktag" ] && [ "$ktag" != "rsa" ] && [ "$ktag" != "ed25519" ]; then
        add_finding warning "unknown DKIM key type" \
            "k=$ktag in: $rec" \
            "k=rsa (default) or k=ed25519" \
            "verifiers that do not implement the algorithm ignore the record" \
            "use rsa/ed25519 or drop the tag (rsa is the default)"
    fi
    if [ -n "$bits" ] && [ "$bits" -lt 2048 ]; then
        add_finding notice "the DKIM key is only $bits bits" \
            "selector '$sel' signs with a $bits-bit key" \
            "2048 bits (RFC 8301 requires >= 1024, current practice is >= 2048)" \
            "receivers that score key strength (Gmail/Yahoo bulk-sender rules) may reject or downscore the mail" \
            "rotate to a 2048-bit key (AdminNG DKIM panel or 'amavisd newkey') and republish the selector"
    fi
    return 0
}


# ---------------------------------------------------------------------------
# F. PTR / forward-confirmed reverse DNS
# ---------------------------------------------------------------------------
check_ptr() {
    local dom="$1" ip rev names name fwd dyn
    [ -n "$DOM_MX_IPS" ] || return 0
    dyn='(^|[.-])(dyn|dynamic|dsl|dhcp|ppp|pppoe|pool|cable|dial|dialup|broadband|client)([.-]|[0-9]|$)'
    for ip in $(printf '%s\n' "$DOM_MX_IPS" | grep -v ':' | head -n 2); do
        rev="$(rev4 "$ip").in-addr.arpa"
        names="$(ptr_records "$rev")"
        if [ -z "$names" ]; then
            add_finding warning "an MX IP has no PTR record" \
                "$ip (host -t PTR $rev: NODATA)" \
                "a PTR like ${SUGGESTED_MX}. pointing back at $ip" \
                "a missing PTR is a classic spam signal: your outbound mail is downscored or refused by strict receivers" \
                "ask the IP provider for the rDNS/PTR record ${SUGGESTED_MX}. on $ip"
            continue
        fi
        name="$(printf '%s\n' "$names" | head -n 1)"
        fwd="$(a_records "$name")"
        if ! printf '%s\n' "$fwd" | grep -Fqx "$ip"; then
            add_finding warning "the PTR does not confirm forward (no FCrDNS)" \
                "$rev → $name; host -t A $name → $(printf '%s\n' "$fwd" | tr '\n' ' ' | sed 's/ $//')" \
                "$name to resolve back to $ip" \
                "forward-confirmed rDNS fails, which receivers read as a forgery signal: mail is rejected or heavily downscored" \
                "make $name resolve to $ip (keep PTR and A in sync)"
        fi
        if [ "$name" != "$SUGGESTED_MX" ] && ! printf '%s\n' "$DOM_MX_TARGETS" | grep -Fqx "$name"; then
            add_finding notice "the PTR name differs from the MX hostname" \
                "PTR: $name; MX: $(printf '%s\n' "$DOM_MX_TARGETS" | tr '\n' ' ')" \
                "the PTR to be the MX hostname ($SUGGESTED_MX)" \
                "not a protocol error, but HELO/PTR alignment is what receivers look at to judge legitimacy" \
                "align them when the provider allows it (PTR = ${SUGGESTED_MX}.)"
        fi
        if printf '%s' "$name" | grep -qiE "$dyn"; then
            add_finding warning "the PTR looks like a residential/dynamic address" \
                "PTR: $name" \
                "a static, mail-looking name (e.g. $SUGGESTED_MX)" \
                "dynamic-looking rDNS gets blocked by major receivers regardless of SPF/DKIM" \
                "move the MTA to a static IP with a proper PTR"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# G. optional records — only reported when they exist (or exist half-way)
# ---------------------------------------------------------------------------
check_optional() {
    local dom="$1" recs rc rec n
    recs="$(dns_txt "_mta-sts.$dom")"
    rc=$?
    n=0
    if [ "$rc" -eq 0 ]; then
        recs="$(printf '%s\n' "$recs" | sed '/^[[:space:]]*$/d')"
        n="$(printf '%s\n' "$recs" | sed '/^$/d' | wc -l)"
    fi
    if [ "$n" -gt 0 ]; then
        rec="$(printf '%s\n' "$recs" | head -n 1)"
        if ! printf '%s' "$rec" | grep -qiE '^v=STSv1' || ! printf '%s' "$rec" | grep -qi 'id='; then
            add_finding warning "the MTA-STS policy record is malformed" \
                "_mta-sts.$dom TXT: $rec" \
                "'v=STSv1; id=<unique-id>'" \
                "senders that support MTA-STS ignore the record, and once they cache a policy your breaks/rollbacks go unseen" \
                "publish '_mta-sts.$dom. 3600 IN TXT \"v=STSv1; id=<date-of-change>\"' and bump id= on every policy change"
        fi
        if [ -z "$(a_records "mta-sts.$dom")$(aaaa_records "mta-sts.$dom")" ]; then
            add_finding warning "the MTA-STS policy host does not resolve" \
                "_mta-sts.$dom TXT exists but host -t A/AAAA mta-sts.$dom: NODATA" \
                "mta-sts.$dom serving the policy file over HTTPS" \
                "senders with MTA-STS enabled cannot fetch the policy: delivery fails for them (TLS-RPT will report it)" \
                "create mta-sts.$dom with a valid certificate and the /.well-known/mta-sts.txt policy"
        fi
    elif [ -n "$(a_records "mta-sts.$dom")$(aaaa_records "mta-sts.$dom")" ]; then
        add_finding warning "the MTA-STS host exists but no policy record is published" \
            "mta-sts.$dom resolves, _mta-sts.$dom TXT: NODATA" \
            "_mta-sts.$dom TXT \"v=STSv1; id=...\"" \
            "the host is dead weight: no sender will ever fetch the policy" \
            "publish the _mta-sts TXT record (or remove the host if MTA-STS is not wanted)"
    fi

    recs="$(dns_txt "_smtp._tls.$dom")"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        rec="$(printf '%s\n' "$recs" | sed '/^[[:space:]]*$/d' | head -n 1)"
        if [ -n "$rec" ] && { ! printf '%s' "$rec" | grep -qiE '^v=TLSRPTv1' || ! printf '%s' "$rec" | grep -qi 'rua='; }; then
            add_finding warning "the TLS-RPT record is malformed" \
                "_smtp._tls.$dom TXT: $rec" \
                "'v=TLSRPTv1; rua=mailto:<report address>'" \
                "you receive no TLS failure reports, so certificate/STARTTLS problems stay invisible" \
                "publish '_smtp._tls.$dom. 3600 IN TXT \"v=TLSRPTv1; rua=mailto:postmaster@$dom\"'"
        fi
    fi
    return 0
}


# ---------------------------------------------------------------------------
# H. blocklists
#
# 127.255.255.0/24 is the Spamhaus/URIBL "query refused or invalid" convention and
# 127.0.0.1 means "your resolver/IP is blocked for abuse": both say the answer cannot be
# trusted, they never mean "listed". The free Spamhaus zones answer that to public
# resolvers, which is why DNS_CHECK_RESOLVER exists.
# ---------------------------------------------------------------------------
is_refusal_code() {
    case "$1" in
        127.255.255.*|127.0.0.1) return 0 ;;
    esac
    return 1
}

check_blocklists() {
    local dom="$1" zone q codes code rc ip rev listed
    for zone in $(split_list "$LIST_DOMAINS"); do
        q="$dom.$zone"
        dns_query A "$q"
        rc=$?
        case "$rc" in
            1|2) continue ;;
            3)
                add_finding notice "a domain blocklist could not be reached" \
                    "host -t A $q → $(printf '%s' "$DQ_RAW" | head -n 1)" \
                    "the zone $zone to answer" \
                    "the listing state of $dom is unknown for this run" \
                    "check DNS/firewall access to $zone, or remove it from DNS_CHECK_BLOCKLISTS"
                continue ;;
        esac
        codes="$(printf '%s\n' "$DQ_ANS" | awk '/ has address / { print $NF }')"
        listed=""
        for code in $codes; do
            is_refusal_code "$code" || listed="$listed $code"
        done
        if [ -n "${listed// /}" ]; then
            add_finding critical "the domain is listed on a domain blocklist" \
                "$q →$(printf '%s\n' $listed | sed 's/^/ /' | tr '\n' ' ')" \
                "no listing for $dom" \
                "several receivers (and URI filters in SpamAssassin/SURBL-aware scanners) block or downscore every message from @$dom" \
                "find out why (phishing links hosted on the domain, marketing blasts), fix it and request delisting at $zone"
        elif [ -n "$codes" ]; then
            add_finding notice "the blocklist refused the query — the answer is not trustworthy" \
                "$q → $(printf '%s\n' "$codes" | tr '\n' ' ')" \
                "a real listing answer (127.0.0.2-127.0.0.254) or NXDOMAIN" \
                "we cannot tell whether $dom is listed: a 'refused' reply looks exactly like 'not listed' in most filters" \
                "query $zone from your own recursive resolver (set DNS_CHECK_RESOLVER) or register the public IP for free access"
        fi
    done
    for zone in $(split_list "$LIST_IPS"); do
        for ip in $(printf '%s\n' "$DOM_MX_IPS" | grep -v ':'); do
            rev="$(rev4 "$ip")"
            q="$rev.$zone"
            dns_query A "$q"
            rc=$?
            case "$rc" in
                1|2) continue ;;
                3)
                    add_finding notice "an IP blocklist could not be reached" \
                        "host -t A $q → $(printf '%s' "$DQ_RAW" | head -n 1)" \
                        "the zone $zone to answer" \
                        "the listing state of $ip is unknown for this run" \
                        "check DNS/firewall access to $zone, or remove it from DNS_CHECK_IP_BLOCKLISTS"
                    continue ;;
            esac
            codes="$(printf '%s\n' "$DQ_ANS" | awk '/ has address / { print $NF }')"
            listed=""
            for code in $codes; do
                is_refusal_code "$code" || listed="$listed $code"
            done
            if [ -n "${listed// /}" ]; then
                add_finding critical "an MX IP is listed on an IP blocklist" \
                    "$ip ($q) →$(printf '%s\n' $listed | sed 's/^/ /' | tr '\n' ' ')" \
                    "no listing for $ip" \
                    "receivers using $zone reject your outbound connections at SMTP time: mail from every hosted domain is refused (5.7.1)" \
                    "check $zone for the reason, fix the cause (compromised account, spam complaint) and request delisting"
            elif [ -n "$codes" ]; then
                add_finding notice "the IP blocklist refused the query — the answer is not trustworthy" \
                    "$q → $(printf '%s\n' "$codes" | tr '\n' ' ')" \
                    "a real listing answer (127.0.0.2-127.0.0.254) or NXDOMAIN" \
                    "we cannot tell whether $ip is listed: refused queries are silently treated as 'clean' by most filters" \
                    "query $zone from your own resolver (DNS_CHECK_RESOLVER) or register the public IP for free access at $zone"
            fi
        done
    done
    return 0
}


# ---------------------------------------------------------------------------
# I (and the orchestration around it)
# ---------------------------------------------------------------------------
EXPECTED_MX=""
MX_SOURCE=""

# resolve_expected_mx — the reference set every domain's MX is compared against
resolve_expected_mx() {
    local inferred
    if [ -n "$MX_HOSTNAME" ]; then
        EXPECTED_MX="$(split_list "$MX_HOSTNAME" | sort -u)"
        MX_SOURCE="MX_HOSTNAME"
        return 0
    fi
    MX_SOURCE="inferred"
    if [ -n "${DEFAULT_DOMAIN:-}" ]; then
        inferred="$(mx_targets "$DEFAULT_DOMAIN" | awk '{ print $2 }' | sed '/^$/d' | sort -u)"
    else
        inferred=""
    fi
    if [ -n "$inferred" ]; then
        EXPECTED_MX="$inferred"
        add_finding notice "the expected MX set is inferred, not declared" \
            "MX_HOSTNAME is unset; using what ${DEFAULT_DOMAIN} answers for MX: $(printf '%s\n' "$inferred" | tr '\n' ' ')" \
            "MX_HOSTNAME=<your MX targets> in the operator env file" \
            "the reference is whatever ${DEFAULT_DOMAIN} publishes today, so a wrong but consistent change would validate itself; the MX mismatch is only a warning" \
            "set MX_HOSTNAME (comma-separated) in .env / env.dev — see env.sample"
    else
        add_finding notice "MX_HOSTNAME is unset and there is no MX to infer from" \
            "MX_HOSTNAME unset; host -t MX ${DEFAULT_DOMAIN:-<no DEFAULT_DOMAIN>}: NODATA" \
            "MX_HOSTNAME=<your MX targets> in the operator env file" \
            "the MX set is not compared against anything: a domain pointed at a foreign/typo'd MX is not detected" \
            "set MX_HOSTNAME (comma-separated) in .env / env.dev — see env.sample"
    fi
    return 0
}

# check_report_route — postmaster@<DEFAULT_DOMAIN> must exist for this report to arrive
check_report_route() {
    local dd="${DEFAULT_DOMAIN:-}" row n
    [ -n "$dd" ] || return 0
    row="$(sql "SELECT (SELECT count(*) FROM mailbox WHERE address = 'postmaster@$dd' AND active)
                 + (SELECT count(*) FROM alias WHERE address = 'postmaster@$dd' AND active)")"
    n="$(printf '%s' "$row" | tr -cd '0-9')"
    [ -n "$n" ] || return 0
    if [ "$n" -eq 0 ]; then
        add_finding warning "postmaster@$dd has no mailbox or alias — this report would be lost" \
            "no active mailbox and no active alias for postmaster@$dd" \
            "a postmaster@$dd alias/mailbox (the first-boot seeder creates it)" \
            "the DNS report is sent to postmaster@$dd: without a route the mail bounces and DNS problems stay invisible" \
            "create the alias/mailbox ('AdminNG → aliases', or adminng.py --provision for the default set)"
    fi
    return 0
}

# build_domain_list — active served domains (alias domains excluded), uppercased input fixed
build_domain_list() {
    local out alias
    if [ -n "$DOMAINS_OVERRIDE" ]; then
        DOMAINS="$(split_list "$DOMAINS_OVERRIDE" | sort -u)"
    else
        out="$(sql "SELECT domain FROM domain WHERE active ORDER BY domain")"
        if printf '%s' "$out" | grep -qiE '(^ERROR|^psql:|could not connect|FATAL|could not translate)'; then
            add_finding critical "the catalogue cannot be read" \
                "$(printf '%s\n' "$out" | head -n 2 | tr '\n' ' ')" \
                "a reachable PostgreSQL catalogue ($POSTGRES_HOST/$POSTGRES_DB) with the domain table" \
                "no domain was checked at all: DNS problems accumulate unseen until someone complains" \
                "check the db service and POSTGRES_* / the db password, then rerun from the cron container: /scripts/check_dns.sh --dry-run"
            INTERNAL_ERROR=1
            DOMAINS=""
            return 1
        fi
        DOMAINS="$(printf '%s\n' "$out" | sed '/^$/d')"
        alias="$(sql "SELECT alias_domain FROM alias_domain WHERE active")"
        if [ -n "$alias" ] && ! printf '%s' "$alias" | grep -qiE '(^ERROR|^psql:|could not)'; then
            DOMAINS="$(printf '%s\n' "$DOMAINS" | grep -Fvxf <(printf '%s\n' "$alias" | sed '/^$/d') || true)"
        fi
    fi
    DOMAINS="$(printf '%s\n' "$DOMAINS" | tr 'A-Z' 'a-z' | sed -e 's/[[:space:]]*$//' -e '/^$/d' | sort -u)"
    if [ -z "$DOMAINS" ]; then
        add_finding critical "there is no active domain to check" \
            "the active-domain list is empty" \
            "at least one active domain in the catalogue (or DNS_CHECK_DOMAINS pointing at real ones)" \
            "nothing is verified: this check silently covers nothing" \
            "create the domain in AdminNG, or set DNS_CHECK_DOMAINS=a.com,b.com to probe externally hosted domains"
        INTERNAL_ERROR=1
        return 1
    fi
    return 0
}

# check_domain — the per-domain pipeline
check_domain() {
    local dom="$1"
    DOM_MX_TARGETS=""
    DOM_MX_IPS=""
    DOM_SPF=""
    DOM_SPF_QUAL="none"
    DMARC_P=""
    begin_domain "$dom"
    if ! check_delegation "$dom"; then
        return 0
    fi
    check_mx "$dom"
    check_spf "$dom"
    check_dmarc "$dom"
    check_dkim "$dom"
    check_ptr "$dom"
    check_optional "$dom"
    check_blocklists "$dom"
    return 0
}


# ---------------------------------------------------------------------------
# report rendering + delivery
# ---------------------------------------------------------------------------
REPORT_FILE="$RUN_TMP/report.txt"

# section_counts SECTION — prints "critical warning notice" for a report section
section_counts() {
    awk -F'|' -v s="$1" '$1 == s { c[$2]++ }
        END { printf "%d %d %d\n", c["critical"], c["warning"], c["notice"] }' "$SUMMARY_FILE"
}

# fmt_counts C W N — "1 critical, 2 warnings" / "ok"
fmt_counts() {
    local out=""
    if [ "$1" -gt 0 ]; then out="$1 critical"; fi
    if [ "$2" -gt 0 ]; then out="${out:+$out, }$2 warning$([ "$2" -eq 1 ] || echo s)"; fi
    if [ "$3" -gt 0 ]; then out="${out:+$out, }$3 notice$([ "$3" -eq 1 ] || echo s)"; fi
    printf '%s' "${out:-ok}"
}

render_report() {
    local dom counts
    {
        echo "MailD DNS health check — $(hostname 2>/dev/null || echo cron)"
        echo
        echo "Run      : $STARTED_UTC"
        echo "Resolver : ${RESOLVER:-system default}${FIXTURE_DIR:+   [FIXTURE MODE: $FIXTURE_DIR]}"
        echo "Gate     : $ALERT_LEVEL (findings at or above this level are mailed)"
        echo "Expected : $(printf '%s\n' "${EXPECTED_MX:-<none>}" | tr '\n' ' ')(source: $MX_SOURCE)"
        echo "DKIM keys: $DKIM_DIR"
        echo
        echo "Summary"
        counts="$(section_counts "(deployment)")"
        # shellcheck disable=SC2086
        set -- $counts
        if [ $(( $1 + $2 + $3 )) -gt 0 ]; then
            printf '  %-32s %s\n' "deployment" "$(fmt_counts "$1" "$2" "$3")"
        fi
        for dom in $DOMAINS; do
            counts="$(section_counts "$dom")"
            # shellcheck disable=SC2086
            set -- $counts
            printf '  %-32s %s\n' "$dom" "$(fmt_counts "$1" "$2" "$3")"
        done
        printf '  %-32s %s\n' "totals" \
            "$(fmt_counts "$N_CRIT" "$N_WARN" "$N_NOTICE") — $N_MAILED at/above the gate"
        cat "$DETAIL_FILE"
        echo
        echo "Checked per domain: delegation (NS/SOA); MX (targets, resolution, CNAME, private"
        echo "IPs, declared set); SPF (presence, terminal qualifier, syntax, lookup budget,"
        echo "MX-IP coverage); DMARC (presence, inheritance, p/sp/pct, rua routing); DKIM"
        echo "(local selector, published key vs signing key); PTR/FCrDNS of the MX IPs;"
        echo "MTA-STS and TLS-RPT when published; blocklists ($LIST_DOMAINS / $LIST_IPS)."
        echo
        echo "Notes"
        echo "  - A 'refused' blocklist answer (127.255.255.x) is a notice, never a listing:"
        echo "    the free zones refuse queries coming from public resolvers. Point"
        echo "    DNS_CHECK_RESOLVER at your own resolver to get real answers."
        echo "  - The DKIM comparison uses the keys on the amavis volume, so it reports what"
        echo "    this deployment actually signs with."
        echo "  - Silence is the success signal: no findings at/above '$ALERT_LEVEL' = no mail."
        echo "    DNS_CHECK_ALERT_LEVEL raises or lowers that gate; DNS_CHECK_DOMAINS=none"
        echo "    disables the job entirely."
        echo
        echo "-- "
        echo "MailD automated DNS health check (cron/scripts/check_dns.sh)"
    } > "$REPORT_FILE"
}

send_report() {
    local subject server cnt err
    cnt="$(awk -F'|' -v g="$GATE_RANK" '
        BEGIN { r["critical"] = 3; r["warning"] = 2; r["notice"] = 1 }
        $1 != "(deployment)" && r[$2] >= g { seen[$1] = 1 }
        END { for (d in seen) print d }' "$SUMMARY_FILE" | sed '/^$/d' | wc -l)"
    if [ "$cnt" -eq 0 ]; then
        subject="[ALERT] MailD DNS health check: $N_MAILED deployment finding(s)"
    else
        subject="[ALERT] MailD DNS health check: $N_MAILED finding(s) in ${cnt} domain(s)"
    fi
    server="$(host amavis 2>/dev/null | awk '/has address/ { print $4 }' | head -n 1)"
    [ -n "$server" ] || server="amavis"
    err="$RUN_TMP/swaks.err"
    swaks --server "$server" --port "${AMAVIS_SUBMIT_PORT:-10026}" --protocol SMTP \
        --to "$REPORT_TO" --from "$REPORT_TO" \
        --header "Subject: $subject" --body @"$REPORT_FILE" > /dev/null 2> "$err"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        log "swaks failed (rc=$rc): $(head -n 3 "$err" | tr '\n' ' ')"
        return 1
    fi
    return 0
}


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local dom
    REPORT_TO="${REPORT_TO:-postmaster@${DEFAULT_DOMAIN:-localhost}}"
    if [ "$DOMAINS_OVERRIDE" = "none" ]; then
        log "disabled by DNS_CHECK_DOMAINS=none — nothing checked, no mail"
        exit 0
    fi
    log "start: gate=$ALERT_LEVEL resolver=${RESOLVER:-system} domains=${DOMAINS_OVERRIDE:-catalogue}${FIXTURE_DIR:+ fixture=$FIXTURE_DIR}"
    DOMAINS=""
    begin_domain ""
    resolve_expected_mx
    check_report_route
    if build_domain_list; then
        for dom in $DOMAINS; do
            check_domain "$dom"
        done
    fi
    render_report
    if [ "$DRY_RUN" = "yes" ]; then
        cat "$REPORT_FILE"
    fi
    if [ "$N_MAILED" -eq 0 ]; then
        log "no findings at/above '$ALERT_LEVEL' — silent ($N_CRIT critical, $N_WARN warnings, $N_NOTICE notices)"
        if [ "$INTERNAL_ERROR" -eq 1 ]; then exit 2; fi
        exit 0
    fi
    if [ "$DRY_RUN" = "yes" ]; then
        log "dry run: $N_MAILED finding(s) would be mailed to $REPORT_TO ($N_CRIT critical, $N_WARN warnings, $N_NOTICE notices)"
        if [ "$INTERNAL_ERROR" -eq 1 ]; then exit 2; fi
        exit 1
    fi
    if ! send_report; then
        log "ERROR: the report could not be mailed to $REPORT_TO"
        exit 3
    fi
    log "report mailed to $REPORT_TO: $N_MAILED finding(s) ($N_CRIT critical, $N_WARN warnings, $N_NOTICE notices)"
    if [ "$INTERNAL_ERROR" -eq 1 ]; then exit 2; fi
    exit 1
}

main "$@"

