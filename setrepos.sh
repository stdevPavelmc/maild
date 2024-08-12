#!/bin/bash

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goal:
#   - Set/Remove repositories in the docker containers for local repos or internet repos
#
# Arguments:
# NONE - Set all repositories to local and all downloadable files to work on full local.
# ANY  - Set repos to internet and all downloadable files to work on full internet.
#
# Repos are get from the source.lost_[debian/ubuntu]
# where debian is bookworm/12 & ubuntu is Jammy/22.04
# So set there your local repos and you are done

# Docker dirs as an array to be iterared
declare -a UBUNTU_DOCKERDIRS=("amavis" "clamav" "cron" "mda" "mta" )
declare -a DEBIAN_DOCKERDIRS=("admin" "db" "mua")
declare -a LOC_INT=("admin" "mua")
UBUNTU_SOURCES="sources.list_ubuntu"
DEBIAN_SOURCES="sources.list_debian"
SNAPPY_VERSION=2.36.4
POSTFIXADMIN_VERSION=3.3.13

# Check if any parameter is passed
if [ -z "$1" ]; then
    # Set repositories
    echo "Set repositories"

    # set the correct dockerfiles
    for DIR in "${LOC_INT[@]}"; do
        cat ./${DIR}/local.Dockerfile > ./${DIR}/Dockerfile
    done

    # copy localfiles
    cp snappymail-${SNAPPY_VERSION}.tar.gz ./mua/
    cp postfixadmin-${POSTFIXADMIN_VERSION}.tar.gz ./admin/

    # iterate over the debian docker dirs, copy the sources.list and set the COPY statement 
    for DIR in "${DEBIAN_DOCKERDIRS[@]}"; do
        cp ${DEBIAN_SOURCES} ${DIR}/sources.list
        SET=$(cat ${DIR}/Dockerfile | grep "sources.list")
        if [ -z "${SET}" ] ; then
            # Add the COPY statement
            sed '/^#repodebian$/a\COPY ./sources.list /etc/apt/sources.list.d/debian.sources' -i ${DIR}/Dockerfile
        fi

        echo "Setup ${DIR} for local repos"
    done

    # iterate over the ubuntu docker dirs, copy the sources.list and set the COPY statement 
    for DIR in "${UBUNTU_DOCKERDIRS[@]}"; do
        cp ${UBUNTU_SOURCES} ${DIR}/sources.list
        SET=$(cat ${DIR}/Dockerfile | grep "sources.list")
        if [ -z "${SET}" ] ; then
            # Add the COPY statement
            sed '/^#repoubuntu$/a\COPY ./sources.list /etc/apt/sources.list' -i ${DIR}/Dockerfile
        fi

        echo "Setup ${DIR} for local repos"
    done

    # Download all downloadable files to local
    if [ ! -f "snappymail-${SNAPPY_VERSION}.tar.gz" ]; then
        # Download snappymail
        wget https://github.com/the-djmaze/snappymail/releases/download/v${SNAPPY_VERSION}/snappymail-${SNAPPY_VERSION}.tar.gz
    fi
    if [ ! -f "postfixadmin-${POSTFIXADMIN_VERSION}.tar.gz" ]; then
        # download postfixadmin
        wget "https://github.com/postfixadmin/postfixadmin/archive/postfixadmin-${POSTFIXADMIN_VERSION}.tar.gz"
    fi
else
    # Remove repositories
    echo "Remove repositories"

    # set the correct dockerfiles
    for DIR in "${LOC_INT[@]}"; do
        cat ./${DIR}/internet.Dockerfile > ./${DIR}/Dockerfile
    done

    # remove the COPY statement in the Dockerfiles
    find ./ -type f -name "*Dockerfile" -exec sed s/"^.*sources\.list.*$"// -i {} \; -print

    # remove any newlines left behind
    find ./ -type f -name "*Dockerfile" -exec sed '/^$/N;/^\n$/D' -i {} \;

    # remove the sources.list files
    find ./ -type f -name "*sources.list" -print -exec rm {} \;
fi
