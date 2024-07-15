#!/bin/bash

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>

set -e
set -u

if [ "$POSTGRES_EXTRA_DB" ]; then
	echo "Additional database requested: $POSTGRES_EXTRA_DB"
	createdb -U $POSTGRES_USER "$POSTGRES_EXTRA_DB"
	echo "Multiple databases created"
fi
