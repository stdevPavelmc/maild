#!/bin/bash

# This script is part of MailD
# Copyright 2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goals:
#   - Daily report of the mailboxes over a quota fill threshold (80% by
#     default) in 5% slots, grouped per domain, so the admin can chase the
#     offenders before mail starts to bounce
#   - The ones over 99% are flagged as critical and lead each domain section
#   - Mailboxes under the threshold are not reported at all
#   - Send it to the mail admin
#
# It lives in the mda (dovecot) container and the entrypoint starts it as a
# background loop: it sleeps 60s and fires the report on the first tick past
# QUOTA_REPORT_HOUR:QUOTA_REPORT_MINUTE (00:01 by default) that has no report
# yet today. Run it with --now to fire it right away and exit.
#
# The data comes straight from dovecot (doveadm quota get -A), so the figures
# are exactly what the quota plugin enforces: active mailboxes only (the SQL
# iterate_query filters on active='1'), STORAGE value/limit in KB, and a limit
# of '-' or 0 means unlimited (those are never reported).
#
# Delivery goes through dovecot-lda with the quota enforcement disabled, the
# same path the quota-warning script uses: the report must land even when the
# admin mailbox is itself over quota.

# ------------------------------------------------------------------ defaults --
VMAILSTORAGE=/home/vmail
LDA=/usr/lib/dovecot/dovecot-lda
LDA_LOG=/var/log/quota-report-lda.log

TICK=60                                            # loop sleep, in seconds
THRESHOLD=${QUOTA_REPORT_THRESHOLD:-80}            # report from this fill % up
CRITICAL=${QUOTA_REPORT_CRITICAL:-99}              # over this fill % = critical
HOUR=${QUOTA_REPORT_HOUR:-0}                       # daily fire time, hour
MINUTE=${QUOTA_REPORT_MINUTE:-1}                   # daily fire time, minute
ONLY_WHEN_WARN=${QUOTA_REPORT_ONLY_WHEN_WARN:-no}  # yes: only mail when there are offenders
MAX_PER_SLOT=${QUOTA_REPORT_MAX_PER_SLOT:-0}       # 0 = list every offender
MAX_ATTEMPTS=${QUOTA_REPORT_MAX_ATTEMPTS:-5}       # delivery attempts per day

TO="${MAIL_ADMIN_USER:-postmaster}@${DEFAULT_DOMAIN}"

# the day stamp must survive a container recreate and vmail is the only
# always-mounted writable volume here; it's a dotfile on the storage root, so
# the */* globs of the other maintenance scripts never see it
STAMP=${VMAILSTORAGE}/.maild-quota-report.last
STAMP_FALLBACK=/tmp/maild-quota-report.last

# the loop and a manual --now run take separate locks: the loop holds its own
# for as long as the container lives, so it must never block a manual run
LOCK_LOOP=/tmp/maild-quota-report.lock
LOCK_NOW=/tmp/maild-quota-report-now.lock

WORK=$(mktemp -d)
RAW=${WORK}/raw
CAND=${WORK}/cand
SORTED=${WORK}/sorted
COUNTS=${WORK}/counts
REPORT=${WORK}/report
MSG=${WORK}/msg

trap "rm -rf ${WORK}" EXIT

# ------------------------------------------------------------------- helpers --
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] quota-report: $*"
}

is_yes() {
    case "$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')" in
        yes|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

# where the day stamp goes: the vmail volume when it is there, /tmp otherwise
stamp_file() {
    if [ -d "${VMAILSTORAGE}" ] ; then
        echo "${STAMP}"
    else
        echo "${STAMP_FALLBACK}"
    fi
}

# sets STAMP_DATE (empty when today's report is not out yet) and STAMP_ATTEMPTS
stamp_read() {
    local F=$(stamp_file)
    local D="" A=""

    STAMP_DATE=""
    STAMP_ATTEMPTS=0

    if [ -f "${F}" ] ; then
        read D A < "${F}"
        if [ "${D}" = "$(date +%Y-%m-%d)" ] ; then
            STAMP_DATE=${D}
            STAMP_ATTEMPTS=${A:-0}
        fi
    fi
}

# $1 = delivery attempts made today (0 = the report went out)
stamp_write() {
    if ! echo "$(date +%Y-%m-%d) ${1}" > "$(stamp_file)" 2>/dev/null ; then
        log "ERROR: cannot write the day stamp, the report may repeat today"
        return 1
    fi
}

# ---------------------------------------------------------------- the report --
# Ask dovecot for the quota of every active mailbox and render the report
#   $1 = the file to write the report to
#   sets SEEN / UNLIM / UNDER / REPORTED for the caller
# Returns 0 when the report was rendered, 1 when dovecot gave us nothing.
build_report() {
    local OUT=${1}

    # one shot for every active mailbox. Only the STORAGE rows matter: there is
    # no message-count limit configured, so the MESSAGE rows carry no limit.
    doveadm quota get -A > ${RAW} 2>/dev/null
    local RC=$?

    if [ ${RC} -ne 0 ] || [ ! -s "${RAW}" ] ; then
        log "ERROR: 'doveadm quota get -A' failed (rc=${RC}), no report"
        return 1
    fi

    # the username is $1 and the quota root name may hold spaces ("User quota"),
    # so value/limit/% are read from the end of the line: NF-2, NF-1 and NF
    awk -v thr="${THRESHOLD}" -v crit="${CRITICAL}" -v defdom="${DEFAULT_DOMAIN}" \
        -v counts="${COUNTS}" '
        /STORAGE/ {
            seen++
            user = $1
            used = $(NF-2) + 0
            lim = $(NF-1)

            # no limit ("-" or 0) = unlimited, there is nothing to fill
            if (lim == "-" || lim + 0 <= 0) { unlim++; next }

            pct = (used * 1000 / (lim + 0)) / 10        # one decimal

            # under the threshold: not reported at all, as required
            if (pct <= thr + 0) { under++; next }

            # the slots are anchored on multiples of 5, the critical one on top
            if (pct > crit + 0) {
                rank = 0
                bound = crit + 0
            } else {
                bound = int(pct / 5) * 5
                if (bound == pct) bound -= 5            # on a line: the slot below
                rank = (95 - bound) / 5 + 1
            }
            reported++

            dom = user
            sub(/.*@/, "", dom)
            print sprintf("%d|%s|%d|%d|%.1f|%d|%d|%s", \
                (dom == defdom ? 0 : 1), dom, rank, bound, pct, used, lim + 0, user)
        }
        END {
            print sprintf("%d %d %d %d", seen + 0, unlim + 0, under + 0, \
                reported + 0) > counts
        }
    ' ${RAW} | sort -t'|' -k1,1n -k2,2 -k3,3n -k5,5gr > ${SORTED}

    read SEEN UNLIM UNDER REPORTED < ${COUNTS}
    SEEN=${SEEN:-0} ; UNLIM=${UNLIM:-0} ; UNDER=${UNDER:-0} ; REPORTED=${REPORTED:-0}

    render_report "${SORTED}" "${OUT}"
}

# Render the sorted offenders into the plain text report
#   $1 = the sorted candidate file, $2 = the file to write the report to
render_report() {
    local IN=${1}
    local OUT=${2}

    awk -v thr="${THRESHOLD}" -v crit="${CRITICAL}" \
        -v today="$(date '+%Y-%m-%d %H:%M')" \
        -v seen="${SEEN}" -v unlim="${UNLIM}" -v under="${UNDER}" \
        -v reported="${REPORTED}" -v maxslot="${MAX_PER_SLOT}" '
        function rule(title, ch,    s, n) {
            s = ch ch ch " " title " "
            n = length(s)
            while (n < 74) { s = s ch; n++ }
            return s
        }
        function hsize(kb,    v) {
            v = kb + 0
            if (v < 1024) return sprintf("%.0f KB", v)
            v = v / 1024
            if (v < 1024) return sprintf("%.1f MB", v)
            return sprintf("%.1f GB", v / 1024)
        }
        BEGIN {
            FS = "|"
            # the lowest slot is the threshold rounded down to a multiple of 5
            maxrank = int((95 - int(thr / 5) * 5) / 5) + 1
            prevrank = -1
            print "MailD daily mailbox quota report (" today ")"
            print ""
            print "Mailboxes over " thr "% of their quota, grouped per domain and in 5% slots,"
            print "worst first; the ones under " thr "% are not listed."
            print "Figures from dovecot (doveadm quota get -A): active mailboxes only, exactly"
            print "as the quota plugin accounts them."
            print ""
        }
        {
            dom = $2 ; rank = $3 + 0 ; bound = $4 + 0 ; pct = $5 + 0
            used = $6 + 0 ; lim = $7 + 0 ; user = $8 ; pctstr = $5

            if (dom != prevdom) {
                if (prevdom != "") print ""
                print rule("DOMAIN: " dom, "=")
                prevdom = dom ; prevrank = -1 ; ndom++
            }
            if (rank != prevrank) {
                if (prevrank >= 0) print ""
                if (rank == 0)
                    print rule("CRITICAL: over " crit "% (about to refuse mail!)", "-")
                else
                    print rule("over " bound "%", "-")
                printf "%-11s %-11s %-8s %s\n", "Used", "Limit", "Fill", "Mailbox"
                prevrank = rank ; nslot = 0
            }
            if (maxslot > 0 && nslot >= maxslot) { hidden++ ; next }
            nslot++
            cnt[rank]++
            tag = (pct >= 100) ? "   [OVER QUOTA]" : ""
            printf "%-11s %-11s %-8s %s%s\n", hsize(used), hsize(lim), pctstr "%", user, tag
        }
        END {
            if (NR > 0) print ""
            if (reported + 0 == 0) {
                print rule("NOTHING TO REPORT", "=")
                print "No mailbox is over " thr "% of its quota. All clear."
                print ""
            }
            print rule("SUMMARY", "=")
            printf "Domains listed: %d   mailboxes seen: %d   reported (over %s%%): %d\n", ndom + 0, seen + 0, thr, reported + 0
            s = "  critical (>" crit "%): " (cnt[0] + 0)
            for (k = 1; k <= maxrank; k++)
                s = s "   over " (95 - 5 * (k - 1)) "%: " (cnt[k] + 0)
            print s
            printf "Not reported: %d under %s%%, %d without a quota limit (unlimited)\n", under + 0, thr, unlim + 0
            if (hidden + 0 > 0)
                printf "Hidden by QUOTA_REPORT_MAX_PER_SLOT=%d: %d\n", maxslot + 0, hidden + 0
            print ""
            print "--"
            print "Kindly, MailD server."
        }
    ' ${IN} > ${OUT}
}

# ------------------------------------------------------------------ delivery --
# Hand the report to the LDA for the mail admin, with the quota enforcement off
#   $1 = the report file, $2 = the subject
deliver_report() {
    local REPORT=${1}
    local SUBJECT=${2}

    # no format=flowed here: it would reflow the aligned columns of the report
    {
        echo "From: postmaster@${DEFAULT_DOMAIN}"
        echo "To: ${TO}"
        echo "Subject: ${SUBJECT}"
        echo "Date: $(date -R)"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo "Auto-Submitted: auto-generated"
        echo ""
        cat ${REPORT}
    } > ${MSG}

    # the explicit log paths keep this out of /dev/stderr, which the dovecot-lda
    # binary resolves against its own process and not ours (same fix the
    # quota-warning script needed); noenforcing so the report lands even when
    # the admin mailbox is itself over quota
    ${LDA} -d "${TO}" \
        -o "plugin/quota=maildir:User quota:noenforcing" \
        -o "log_path=${LDA_LOG}" \
        -o "info_log_path=${LDA_LOG}" \
        -o "debug_log_path=${LDA_LOG}" < ${MSG}

    return $?
}

# Build the report and, unless this is a dry run, deliver it. 0 on success.
run_report() {
    if ! build_report "${REPORT}" ; then
        return 1
    fi

    if [ ${DRY_RUN} -eq 1 ] ; then
        cat ${REPORT}
        log "dry run: report rendered on stdout (${REPORTED} mailbox(es) over ${THRESHOLD}%)"
        return 0
    fi

    if [ ${REPORTED} -gt 0 ] ; then
        SUBJECT="[WARN] MailD daily quota report (${REPORTED} mailbox(es) over ${THRESHOLD}%)"
    else
        SUBJECT="[OK] MailD daily quota report (no mailbox over ${THRESHOLD}%)"
    fi

    # nothing to warn about and the admin only asked for warnings
    if [ ${REPORTED} -eq 0 ] && is_yes "${ONLY_WHEN_WARN}" ; then
        log "no mailbox over ${THRESHOLD}% and QUOTA_REPORT_ONLY_WHEN_WARN is on, mail skipped"
        return 0
    fi

    if deliver_report "${REPORT}" "${SUBJECT}" ; then
        log "report sent to ${TO} (${REPORTED} mailbox(es) over ${THRESHOLD}%)"
        return 0
    fi

    log "ERROR: delivery to ${TO} failed, see ${LDA_LOG}"
    return 1
}

# -------------------------------------------------------------------- the loop --
loop() {
    exec 200>${LOCK_LOOP}
    if ! flock -n 200 ; then
        log "another quota report loop is already running, exiting"
        exit 0
    fi

    # minutes of the day; the 10# is mandatory, 0008/0009 are invalid octal
    local TARGET=$(( 10#${HOUR} * 60 + 10#${MINUTE} ))

    log "loop started: daily report past $(printf '%02d:%02d' ${HOUR} ${MINUTE}) to ${TO}, threshold ${THRESHOLD}%"

    # in-memory guard, the stamp file is the persistent one
    LAST_SENT=""

    while true ; do
        sleep ${TICK}

        local NOW=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
        if [ ${NOW} -lt ${TARGET} ] ; then
            continue
        fi

        local TODAY=$(date +%Y-%m-%d)
        if [ "${LAST_SENT}" = "${TODAY}" ] ; then
            continue
        fi

        stamp_read
        if [ -n "${STAMP_DATE}" ] ; then
            # today's report is already out, or we gave up on delivering it
            LAST_SENT=${TODAY}
            continue
        fi

        # a permanent delivery failure must not turn into a mail storm
        if [ ${STAMP_ATTEMPTS} -ge ${MAX_ATTEMPTS} ] ; then
            log "ERROR: ${MAX_ATTEMPTS} delivery attempts failed today, giving up until tomorrow"
            LAST_SENT=${TODAY}
            continue
        fi

        if run_report ; then
            LAST_SENT=${TODAY}
            # a dry run only rendered the report on stdout, it must not consume
            # today's stamp or the real report would be skipped all day
            [ ${DRY_RUN} -eq 1 ] || stamp_write 0
        else
            stamp_write $((STAMP_ATTEMPTS + 1))
            log "attempt $((STAMP_ATTEMPTS + 1)) of ${MAX_ATTEMPTS} for today failed"
        fi
    done
}

usage() {
    cat << EOF
MailD daily mailbox quota report (mda container)

Usage: quota_report.sh [--loop] [--now] [--dry-run] [-h|--help]

  (no args), --loop   background loop: fire the report on the first tick past
                      ${HOUR}:$(printf '%02d' ${MINUTE}) with no report yet today, then keep
                      sleeping (this is how the entrypoint starts it); never exits
  --now               do not loop: fire the report once and exit (0 on success)
  --dry-run           render the report on stdout, deliver nothing, write no stamp
  -h, --help          this text

Env knobs (documented in env.sample):
  QUOTA_REPORT_THRESHOLD       report from this fill % up               (${THRESHOLD})
  QUOTA_REPORT_CRITICAL        over this fill % the mailbox is critical (${CRITICAL})
  QUOTA_REPORT_HOUR            daily fire hour                          (${HOUR})
  QUOTA_REPORT_MINUTE          daily fire minute                        (${MINUTE})
  QUOTA_REPORT_ONLY_WHEN_WARN  yes: only mail when there are offenders  (${ONLY_WHEN_WARN})
  QUOTA_REPORT_MAX_PER_SLOT    cap per domain and slot, 0 = list all    (${MAX_PER_SLOT})
  QUOTA_REPORT_MAX_ATTEMPTS    delivery attempts per day                (${MAX_ATTEMPTS})
EOF
}

# ---------------------------------------------------------------------- main --
DRY_RUN=0
MODE=loop

while [ $# -gt 0 ] ; do
    case ${1} in
        --loop) MODE=loop ;;
        --now) MODE=now ;;
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help) usage ; exit 0 ;;
        *) echo "Unknown option: ${1}" >&2 ; usage ; exit 1 ;;
    esac
    shift
done

if [ -z "${DEFAULT_DOMAIN}" ] ; then
    log "ERROR: DEFAULT_DOMAIN is not set, cannot build the report"
    exit 1
fi

if [ ! -x "${LDA}" ] && [ ${DRY_RUN} -eq 0 ] ; then
    log "ERROR: ${LDA} is not there, cannot deliver the report"
    exit 1
fi

if [ "${MODE}" = "now" ] ; then
    # a manual run takes its own lock, so it never collides with the loop
    exec 201>${LOCK_NOW}
    if ! flock -n 201 ; then
        log "another manual quota report is already running, exiting"
        exit 0
    fi

    if run_report ; then
        # a manual run counts as today's report, so the loop will not repeat it
        if [ ${DRY_RUN} -eq 0 ] ; then
            stamp_write 0
        fi
        exit 0
    fi
    exit 1
fi

loop

