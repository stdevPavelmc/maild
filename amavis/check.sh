#!/bin/sh

# check amavis still working
case "$(echo | nc 127.0.0.1 10024 -w1)" in
	"220"*" ready"*)
		echo "amavis ready"
		;;
	*)
		echo "amavis not responding"
		exit 1
		;;
esac

# if CLAMAVIP still has the same IP, if not reboot
CLAMAV=`host ${CLAMAV} | awk '/has address/ { print $4 }'`
if [ "$CLAMAVIP" != "$(cat /tmp/CLAMAVIP)" ] ; then
	echo "ClamAV IP has changed, need to reboot"
	exit 1
fi


exit 0
