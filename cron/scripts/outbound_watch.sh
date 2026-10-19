#!/bin/bash

# This script is part of MailD
# Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goals (audit F-12, alerting half — the hard throttle is the mta's ratelimitd):
#   - Watch the day's outbound submission volume per authenticated user and alert
#     the mail admin when a user crosses OUTBOUND_ALERT_MESSAGES messages, and
#     whenever the per-user throttle engaged (ratelimitd's "maild-ratelimit:
#     throttled" log lines).
#   - Alert at most once per user per day (marker file in /tmp); accounts in
#     OUTBOUND_ALERT_IGNORE_USERS are never alerted on (the alert-side twin of
#     the mta's OUTBOUND_RATE_EXEMPT_USERS).
#   - A dead ratelimitd is NOT detected here: it is fail-open for mail, and the
#     mta healthcheck already goes unhealthy when it stops answering.
#
# Like resume.sh it needs the production syslog (cron binds the host /var/log,
# every service logs through Docker's syslog driver); in dev test.sh phase G
# materialises one and this job skips cleanly when none exists.

THRESHOLD=${OUTBOUND_ALERT_MESSAGES:-150}
TO="${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}"
SERVER=`host amavis | awk '/has address/ { print $4 }'`
FILES="/var/log/syslog.1 /var/log/syslog"
MARKER="/tmp/maild-outbound-alerted-$(date +%F)"
# Day marker. rsyslog stamps the line at column 0 ("Oct 19 19:42:00 host svc: ..."),
# while Postfix' own maillog line carries a SECOND stamp inside the message
# ("... svc: Oct 19 19:42:43 mta postfix/..."). A fixed " Oct 19 " (leading space)
# only ever matches the doubled Postfix ones and misses every bare line -- and
# ratelimitd prints bare lines, so the throttle engagements would go unnoticed in
# production too. Match the day at the start of the line OR after a separator.
# %e is space-padded by rsyslog ("Oct  9"), hence the [[:space:]]+ and the trim.
MONTH=$(date +%b)
DOM=$(date +%e); DOM="${DOM# }"
DAY_RE="(^|[^[:alnum:]])${MONTH}[[:space:]]+${DOM}([^[:alnum:]]|$)"

# nothing to parse: dev (JSON logging) or a host without rsyslog yet
LOGS="$(ls ${FILES} 2>/dev/null)"
if [ -z "${LOGS}" ] ; then
    echo "MailD: outbound watch: no /var/log/syslog{,.1} present, nothing to do"
    echo "MailD: outbound watch: (production logs through Docker's syslog driver, see env.sample)"
    exit 0
fi

is_ignored() {   # <user> -> 0 when the user is on the alert ignore list
    local u="${1,,}" lst="${OUTBOUND_ALERT_IGNORE_USERS// /}"
    [ -z "${lst}" ] && return 1
    case ",${lst}," in *",${u},"*) return 0 ;; esac
    return 1
}

# today's outbound messages per authenticated user. Only the queue-id "from=" lines count
# (one per accepted message, sasl_username attached because smtpd_sasl_authenticated_header
# = yes); reject lines also carry sasl_username and would double-count.
USERCOUNTS="$(grep -h ${MTA} ${LOGS} 2>/dev/null | grep -E "${DAY_RE}" | grep 'from=<' | \
    grep -o 'sasl_username=[^ ,;)]*' | cut -d= -f2 | tr '[:upper:]' '[:lower:]' | \
    sort | uniq -c | sort -rn)"

# the throttle's own engagement lines, verbatim for the report
THROTTLED="$(grep -h 'maild-ratelimit: throttled' ${LOGS} 2>/dev/null | grep -E "${DAY_RE}")"
THROTTLED_USERS="$(printf '%s\n' "${THROTTLED}" | sed -n 's/.*throttled user=\([^ ]*\).*/\1/p' | sort -u)"

OVER=""
if [ "${THRESHOLD:-0}" -gt 0 ] 2>/dev/null ; then
    OVER="$(printf '%s\n' "${USERCOUNTS}" | awk -v t="${THRESHOLD}" '$1+0 > t {print $2}')"
fi

# only what has not been alerted yet today. A user that is both over the
# threshold and throttled must be reported once, not twice.
NEW=""
for u in ${OVER} ${THROTTLED_USERS} ; do
    is_ignored "${u}" && continue
    grep -qx "${u}" "${MARKER}" 2>/dev/null && continue
    case " ${NEW} " in *" ${u} "*) continue ;; esac
    NEW="${NEW} ${u}"
done

if [ -z "${NEW}" ] ; then
    echo "MailD: outbound watch: no new outbound alerts for $(date +%F)"
    exit 0
fi

REPORT=$(mktemp)

{
    echo "=== Outbound volume watch ($(date -u '+%Y-%m-%d %H:%M UTC')) ==="
    echo ""
    echo "The users below crossed the daily outbound alert threshold"
    echo "(${THRESHOLD} message(s)/user/day) or tripped the per-user outbound rate limit:"
    echo ""
    for u in ${NEW} ; do
        N="$(printf '%s\n' "${USERCOUNTS}" | awk -v u="${u}" '$2 == u {print $1; exit}')"
        echo "  - ${u}: ${N:-0} message(s) submitted today"
    done
    echo ""
    echo "Today's submission volume by user (top 10):"
    printf '%s\n' "${USERCOUNTS}" | head -n 10 | awk '{printf "  %6s  %s\n", $1, $2}'
    if [ -n "${THROTTLED}" ] ; then
        echo ""
        echo "Rate-limit engagements (throttled by the mta's ratelimitd):"
        printf '%s\n' "${THROTTLED}" | sed 's/^/  /'
    fi
    echo ""
    echo "If this is a phished account, change its password (PostfixAdmin or the"
    echo "AdminNG panel) and review the outbound traffic below. The hard per-user"
    echo "limit is OUTBOUND_RATE_RECIPIENTS on the mta (see env.sample)."
} > "${REPORT}"

# email — same channel as resume.sh
swaks \
    --server ${SERVER} \
    --port 10024 \
    --protocol SMTP \
    --to $TO \
    --from $TO \
    --header "Subject: [ALERT] MailD outbound volume watch..." \
    --body @${REPORT} > /dev/null
SWRC=$?

if [ ${SWRC} -eq 0 ] ; then
    echo "MailD: outbound watch: alert sent to $TO for:${NEW}"
    for u in ${NEW} ; do echo "${u}" >> "${MARKER}" ; done
else
    # do NOT mark: the next run retries the alert
    echo "MailD: outbound watch: WARNING - alert delivery failed (rc=${SWRC}), will retry next run" 1>&2
fi

rm -f "${REPORT}"