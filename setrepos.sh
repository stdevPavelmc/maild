#!/bin/bash

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goal:
#   - Set/Remove repositories in the docker containers for local repos or internet repos
#
# Arguments:
# NONE - Set all repositories
# ANY  - Remove all repositories
#
# Repos are get from the source.lost_[debian/ubuntu]
# where debian is bookworm/12 & ubuntu is Jammy/22.04
# So set there your local repos and you are done

# Docker dirs as an array to be iterared
declare -a UBUNTU_DOCKERDIRS=("amavis" "clamav" "cron" "mda" "mta" )
declare -a DEBIAN_DOCKERDIRS=("admin" "db" "mua")
UBUNTU_SOURCES="sources.list_ubuntu"
DEBIAN_SOURCES="sources.list_debian"

# Check if any parameter is passed
if [ -z "$1" ]; then
    # Set repositories
    echo "Set repositories"

    # iterate over the debian docker dirs, copy the sources.list and set the COPY statement 
    for DIR in "${DEBIAN_DOCKERDIRS[@]}"; do
        cp ${DEBIAN_SOURCES} ${DIR}/sources.list
        SET=$(cat ${DIR}/Dockerfile | grep "sources.list")
        if [ -z "${SET}" ] ; then
            # Add the COPY statement
            sed '/^#repodebian$/a\COPY ./sources.list /etc/apt/source.list.d/debian.sources' -i ${DIR}/Dockerfile
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
else
    # Remove repositories
    echo "Remove repositories"

    # remove the COPY statement in the Dockerfiles
    find ./ -type f -name "*Dockerfile" -exec sed s/"^.*sources\.list.*$"// -i {} \; -print

    # remove any newlines left behind
    find ./ -type f -name "*Dockerfile" -exec sed '/^$/N;/^\n$/D' -i {} \;

    # remove the sources.list files
    find ./ -type f -name "*sources.list" -print -exec rm {} \; 
fi