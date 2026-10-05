#!/bin/sh

# Is postfix running?
# Probe the master pidfile + a signal-0 test instead of `postfix status`: the latter routes
# "the Postfix mail system is running: PID: N" through postlog -> maillog_file (=/dev/stdout),
# which appended a line to the container log on every healthcheck tick (once a minute). The
# pidfile check is silent and equivalent.
QUEUE_DIR="$(postconf -h queue_directory 2>/dev/null)"
PIDFILE="${QUEUE_DIR:-/var/spool/postfix}/pid/master.pid"
if [ ! -s "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null ; then
	echo "postfix is not responding"
	exit 1
fi
echo "postfix ready"

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
