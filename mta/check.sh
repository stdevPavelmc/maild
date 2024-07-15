#!/bin/sh

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>

# is postfix still working
case "$(printf "HELO healthcheck\nQUIT\n\n" | nc 127.0.0.1 25 -w1 | head -n1)" in
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

# if MDAIP still has the same IP, if not reboot
MDAIP=`host ${MDA} | awk '/has address/ { print $4 }'`
if [ "$MDAIP" != "$(cat /tmp/MDAIP)" ] ; then
	echo "MDA IP has changed, need to reboot"
	exit 1
fi

# if MUAIP still has the same IP, if not reboot
MUAIP=`host ${MUA} | awk '/has address/ { print $4 }'`
if [ "$MUAIP" != "$(cat /tmp/MUAIP)" ] ; then
	echo "MUA IP has changed, need to reboot"
	exit 1
fi

# if ADMINIP still has the same IP, if not reboot
ADMINIP=`host ${ADMIN} | awk '/has address/ { print $4 }'`
if [ "$ADMINIP" != "$(cat /tmp/ADMINIP)" ] ; then
	echo "ADMIN IP has changed, need to reboot"
	exit 1
fi

exit 0
