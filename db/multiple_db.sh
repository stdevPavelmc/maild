#!/bin/bash

set -e
set -u

if [ "$POSTGRES_EXTRA_DB" ]; then
	echo "Additional database requested: $POSTGRES_EXTRA_DB"
	createdb -U $POSTGRES_USER "$POSTGRES_EXTRA_DB"
	echo "Multiple databases created"
fi
