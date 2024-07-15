#!/bin/sh

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>

if [ "$(echo PING | nc localhost 3310)" = "PONG" ]; then
    echo "ping successful"
else
    echo 1>&2 "ping failed"
    exit 1
fi
