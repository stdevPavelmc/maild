#!/bin/sh

# Check amavis still working, on both listeners (10024 = mta, 10026 = cron/mcp).
# A plain banner read proves the daemon answers and leaves no state behind; loopback is in
# both ACLs (52-maild-acl).
for PORT in 10024 10026 ; do
	case "$(nc localhost ${PORT} -w1 </dev/null | head -n1)" in
		"220"*" ready"*)
			;;
		*)
			echo "amavis not responding on ${PORT}"
			exit 1
			;;
	esac
done
echo "amavis ready"

# if CLAMAVIP still has the same IP, if not reboot
CLAMAVIP=`host ${CLAMAV} | awk '/has address/ { print $4 }'`
if [ "$CLAMAVIP" != "$(cat /tmp/CLAMAVIP)" ] ; then
	echo "ClamAV IP has changed, need to reboot"
	exit 1
fi

# MTA/CRON: the peer-IP watchdog (docker-entrypoint.sh) follows a moved peer within
# PEER_WATCH_INTERVAL and rewrites these files, so a mismatch here is only transient; it
# stays (unhealthy) when the watchdog is disabled. ClamAV's address is baked into
# 15-av_scanners and still needs a restart.
# if MTAIP still has the same IP, if not reboot
MTAIP=`host ${MTA} | awk '/has address/ { print $4 }'`
if [ "$MTAIP" != "$(cat /tmp/MTAIP)" ] ; then
	echo "MTA IP has changed, need to reboot"
	exit 1
fi

# if CRONIP still has the same IP, if not reboot
CRONIP=`host ${CRON} | awk '/has address/ { print $4 }'`
if [ "$CRONIP" != "$(cat /tmp/CRONIP)" ] ; then
	echo "CRON IP has changed, need to reboot"
	exit 1
fi

exit 0
