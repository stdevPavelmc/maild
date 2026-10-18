#!/bin/sh
# MailD: catalogue credentials for the rehash-on-login postlogin script
# (scripts/rehash-password.sh). The _POSTGRES_*_ placeholders are substituted
# by configure.sh's blind find/sed on first boot — the same mechanism and the
# same variables the auth-sql.conf.ext SQL driver uses (no port: the mda
# always talks to the db on 5432). Sourced (never executed) by the postlogin
# script, which runs as the vmail user: keep 0640 root:vmail (set in the
# Dockerfile).
export POSTGRES_HOST=_POSTGRES_HOST_
export POSTGRES_USER=_POSTGRES_USER_
export POSTGRES_DB=_POSTGRES_DB_
export POSTGRES_PASSWORD=_POSTGRES_PASSWORD_