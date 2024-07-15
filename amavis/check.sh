#!/bin/sh

# check amavis still working
case "$(printf "HELO healthcheck\nQUIT\n\n" | nc localhost 10024 -w1 | head -n1)" in
	"220"*" ready"*)
		echo "amavis ready"
		;;
	*)
		echo "amavis not responding"
		exit 1
		;;
esac

# if CLAMAVIP still has the same IP, if not reboot
CLAMAVIP=`host ${CLAMAV} | awk '/has address/ { print $4 }'`
if [ "$CLAMAVIP" != "$(cat /tmp/CLAMAVIP)" ] ; then
	echo "ClamAV IP has changed, need to reboot"
	exit 1
fi

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
