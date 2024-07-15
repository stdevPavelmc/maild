#!/bin/bash

# This script is part of MailD
# Copyright 2020-2024 Pavel Milanes Costa <pavelmc@gmail.com>
#
# Goal:
#   - Cycle trough the list of maildirs in the mail storage and check
#       - does the domain exist?
#       - there is not an user with that maildir?
#       - check the time of the latest modification time
#           - Warn the sysadmins about the folder, size and stalled time

# import a local settings
source /etc/environment

# some vars
VMAILSTORAGE=/home/vmail

# Setup the postgres elements, craaft the auth credentials & secure it
echo "$POSTGRES_HOST:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" > ~/.pgpass
chmod 0600 ~/.pgpass &1>2

# check if a mailbox is valid, it will return:
#
# no:   non existing mailbox
# yes:  valid mailbox
# ina:  valid, but disabled mailbox
# dom:  domain does not exist
function check_mailbox {
    # arguments
    # 1 - username
    # 2 - doamin

    # Vars
    DOMAINF=/tmp/domains.txt
    USERSF=/tmp/users.txt

    # check if the domain file exists
    if [ ! -f $DOMAINF ] ; then
        # Domain file does not exist
        # query to get the domains
        QUERY="SELECT domain FROM domain WHERE domain='${2}';"

        # Run psql command to connect to database and run query
        psql -h $POSTGRES_HOST -d $POSTGRES_DB -U $POSTGRES_USER -c "$QUERY" -w > $DOMAINF
    fi

    # check if the users file exists
    if [ ! -f $USERSF ] ; then
        # Users file does not exist
        # query to get the users
        QUERY="SELECT username,active FROM mailbox;"
        psql -h $POSTGRES_HOST -d $POSTGRES_DB -U $POSTGRES_USER -c "$QUERY" -w > $USERSF
    fi   

    # validate logic
    if [ -z "$(grep ${2} $DOMAINF)" ] ; then
        # Domain does not exist
        echo "dom"
    else
        # Domain exists, check if the user exists
        active=$(cat $USERSF | grep " ${1}@${2} " | cut -d '|' -f 2 | tr -d ' ')
        if [ "$active" ] ; then
            # existm but active or not?
            if [ "$active" == "f" ] ; then
                # inactive
                echo "ina"
            else
                # active
                echo "yes"
            fi
        else
            # not exist
            echo "no"
        fi
    fi
}

# Get details about the folders
function getdetails {
    # just one parameter the particular maildir
    # return an array:
    #   - size and name
    #   - age in days

    # get the data
    size=`du -sh ${1}`
    age=`echo $((($(date +%s) - $(date +%s -r ${1})) / 86400))`

    # return
    echo "${size}|${age}"
}

# action on non existent or inactive accounts
function register() {
    # 1 - username
    # 2 - domain
    # 3 - type (no / ina)

    maildir="${2}/${1}"
    data=`getdetails ${VMAILSTORAGE}/${maildir}`
    days=`echo $data | cut -d '|' -f2`
    months=$((${days} / 30))
    size=`echo $data | cut -d '|' -f1 | awk '{print $1}'`

    # check to see to what list it's sended
    if [ ${days} -gt 273 ] ; then
        # older than 75 % of a year
        if [ ${days} -gt 365 -a ] ; then
            # delete!
            if [ "${3}" == "no" ] ; then
                # safe to erase
                printf "%s months/(%s days)\t%s\t%s\n" "${months}" "${days}" "${size}" "${maildir}" >> ${erasedlist}
            else
                # warn as inactive
                printf "%s months/(%s days)\t%s\t%s\n" "${months}" "${days}" "${size}" "${maildir} [INACTIVE]" >> ${erasedlist}
            fi

            # check for real deletion
            if [ "$MAILDIRREMOVAL" == "YES" -a "${3}" == "no" ] ; then
                # delete it for good
                rm -rdf "${VMAILSTORAGE}/${maildir}"
            fi
        else
            # warn
            printf "%s months/(%s days)\t%s\t%s\n" "${months}" "${days}" "${size}" "${maildir}" >> ${warnlist}
        fi
    else
        # stalled on time, just notice
        printf "%s months/(%s days)\t%s\t%s\n" "${months}" "${days}" "${size}" "${maildir}" >> ${stalledlist}
    fi
}

# vars
stalledlist=`mktemp`
domainlist=`mktemp`
warnlist=`mktemp`
erasedlist=`mktemp`
mail=0
dom=0

# check every domain, then mailbox
for d in `ls ${VMAILSTORAGE} | sort | xargs`; do
    # d has the domain
    for m in `ls ${VMAILSTORAGE}/${d}/ | sort | xargs` ; do
        # m is the mailbox, or user name part of the email
        maildir="${VMAILSTORAGE}/${d}/${m}"

        # only dirs
        if [ ! -d "$maildir" ] ; then
            continue
        fi

        # only when the domain is valid
        if [ ${dom} -eq 1 ] ; then
            continue
        fi

        # check for the status of the mailbox
        R=$(check_mailbox ${m} ${d})

        # switch case for the possible output values of the function
        case $R in
            "no" | "ina")
                mail=1
                register ${m} ${d} ${R}
                ;;
            "dom")
                dom=1
                ;;
            *)
                ;;
        esac
    done

    # if the domain has been marked as non existent warn it
    if [ ${dom} -eq 1 ] ; then
        # get the datta
        data=`getdetails ${VMAILSTORAGE}/${d}`
        days=`echo $data | cut -d '|' -f2`
        months=$((${days} / 30))
        size=`echo $data | cut -d '|' -f1 | awk '{print $1}'`

        # record it
        printf "%s months/(%s days)\t%s\t%s\n" "${months}" "${days}" "${size}" "${d}" >> ${domainlist}

        # reset for the next domain
    fi
done

# must create the email?
if [ $mail -ne 0 -o -s $domainlist ] ; then
    mail=`mktemp`

    echo "Greetings, " >> $mail
    echo " " >> $mail
    echo "We detected some maildir/domains folder(s) left behind; that's normal when" >> $mail
    echo "you delete users or domains, we will send you a resume for this issues at" >> $mail
    echo "weekly pace when it's the case." >> $mail
    echo " " >> $mail

    # domains first
    if [ -s $domainlist ] ; then
        echo "=== DOMAINS THAT NEED ATTENTION ========================================" >> $mail
        printf "Age\t\t\tSize\tDomain Folder\n" >> $mail
        cat "${domainlist}" >> $mail
        echo " " >> $mail
        echo "As a domain folder is a whole important achive, we will not delete it," >> $mail
        echo "however, it's adviced to backup it and delete it if appropiated" >> $mail
        echo " " >> $mail
    fi

    # stalled less than 10 months
    if [ -s "${stalledlist}" ] ; then
        echo "=== MAILBOXES THAT NEED ATTENTION ========================================" >> $mail
        printf "Age\t\t\tSize\tMaildir\n" >> $mail
        cat "${stalledlist}" >> $mail
        echo " " >> $mail
    fi
    # warn zone > 10 < 12 months
    if [ -s "${warnlist}" ] ; then
        echo "=== MAILBOXES THAT WILL BE ERASED SOON! ==================================" >> $mail
        printf "Age\t\t\tSize\tMaildir\n" >> $mail
        cat "${warnlist}" >> $mail
        echo " " >> $mail
    fi
    # deleted
    if [ -s "${erasedlist}" ] ; then
        echo "=== ERASED MAILBOXES =====================================================" >> $mail
        printf "Age\t\t\tSize\tMaildir\n" >> $mail
        cat "${erasedlist}" >> $mail
        echo " " >> $mail
        # warn if not removed
        if [ "$MAILDIRREMOVAL" != "YES" ] ; then
            echo "WARNING! No maildir was erased, to be removed you need to specify variable named" >> $mail
            echo "'MAILDIRREMOVAL=YES' on this container to be able to automatically erase mailboxes" >> $mail
            echo " " >> $mail
        fi
    fi

    echo "--" >> $mail
    echo "Kindly, MailD server." >> $mail
    echo " " >> $mail

    # emails to the sysadmins group or the mailadmin?
    TO="${MAIL_ADMIN_USER}@${DEFAULT_DOMAIN}"

    # get the address for the amavis server on real time
    SERVER=`host amavis | awk '/has address/ { print $4 }'`

    # send the email
    cat $mail | swaks \
        --server ${SERVER} \
        --port 10024 \
        --protocol SMTP \
        --to $TO \
        --from $TO \
        --body @${mail} \
        --header "Subject: MailD about unused server folders..." > /dev/null

fi
