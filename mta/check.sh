#!/bin/sh

# is postfix still working
case "$(echo | nc 127.0.0.1 25 -w1)" in
	"220 "*" ESMTP"*)
		echo "postfix ready"
		;;
	*)
		echo "postfix is not responding"
		exit 1
		;;
esac

# if AMAVISIP still has the same IP, if not reboot
AMAVISIP=`host ${AMAVIS} | awk '/has address/ { print $4 }'`
if [ "$AMAVISIP" != "$(cat /tmp/AMAVISIP)" ] ; then
	echo "Amavis IP has changed, need to reboot"
	exit 1
fi

exit 0
