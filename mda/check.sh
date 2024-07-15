#!/bin/sh

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>

case "$(printf "QUIT\n" | nc localhost 110 -w1 | head -n1)" in
	"+OK Dovecot"*" ready"*)
		echo "dovecot ready"
		;;
	*)
		echo "dovecot is not responding"
		exit 1
		;;
esac

exit 0
