#!/bin/bash

# This script is part of MailD
# Copyright 2026 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goals:
#   - Keep the SpamAssassin rules fresh, running sa-update once a day
#   - Reload amavisd after installing new rules, so the children pick
#     them up without restarting the container
#
# It's started in the background by the container entrypoint and logs
# to stdout (collected by the syslog logging driver).

CHANNEL="updates.spamassassin.org"
HOUR=${SA_UPDATE_HOUR:-2}
MINUTE=${SA_UPDATE_MINUTE:-50}
PIDFILE=/var/run/amavis/amavisd.pid

# seconds to sleep until the next scheduled run, with a random jitter
# of up to 20 minutes to avoid stampedes against the update servers
function seconds_until_next_run() {
    local now target
    now=$(date +%s)
    target=$(date -d "today ${HOUR}:${MINUTE}" +%s)
    if [ ${target} -le ${now} ] ; then
        target=$(date -d "tomorrow ${HOUR}:${MINUTE}" +%s)
    fi
    echo $((target - now + (RANDOM % 1200)))
}

# wait a little at boot, the mail flow has priority on startup
sleep $((RANDOM % 300))

while : ; do
    sleep $(seconds_until_next_run)

    echo "sa-update-loop: checking for new SpamAssassin rules"
    sa-update --channel ${CHANNEL}
    R=$?

    case ${R} in
        0)
            # rules updated, reload amavisd so the children use them
            echo "sa-update-loop: new rules installed, reloading amavisd"
            if [ -f ${PIDFILE} ] ; then
                kill -HUP $(cat ${PIDFILE})
            else
                echo "sa-update-loop: WARN, pid file not found, amavisd NOT reloaded"
            fi
            ;;
        4)
            echo "sa-update-loop: no rule updates available"
            ;;
        *)
            echo "sa-update-loop: WARN, sa-update exited with code ${R}"
            ;;
    esac
done
