#!/bin/sh

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>

# check amavis still working
curl --silent --head --fail http://localhost || exit 1

# if MTAIP still has the same IP, if not reboot
MTAIP=`host ${MTA} | awk '/has address/ { print $4 }'`
if [ "$MTAIP" != "$(cat /tmp/MTAIP)" ] ; then
	echo "MTA IP has changed, need to reboot"
	exit 1
fi

# if MDAIP still has the same IP, if not reboot
MDAIP=`host ${MDA} | awk '/has address/ { print $4 }'`
if [ "$MDAIP" != "$(cat /tmp/MDAIP)" ] ; then
	echo "MDA IP has changed, need to reboot"
	exit 1
fi

exit 0
