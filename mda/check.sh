#!/bin/sh

case "$(echo | nc 127.0.0.1 110 -w1)" in
	"+OK Dovecot"*" ready"*)
		echo "dovecot ready"
		;;
	*)
		echo "dovecot is not responding"
		exit 1
		;;
esac

exit 0
