# See /usr/share/postfix/main.cf.dist for a commented, more complete version

# Welcome Banner
smtpd_banner = $myhostname ESMTP

# domain is MUA job, not mine
append_dot_mydomain = no

# delay warning every 4 hors
delay_warning_time = 4h

# local aliases
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases

# get hostname and set is as real domain
myhostname = _HOSTNAME_
mydomain = $myhostname

# default destination, our domains will be virtual
mydestination = $myhostname, localhost.$mydomain, localhost
myorigin = $myhostname

# Relayhost, if an IP [1.2.3.4]
relayhost = _RELAY_

# safe nets, local and amavis only
mynetworks = 127.0.0.0/8, admin, _AMAVISIP_

# only IPv4
inet_protocols = ipv4

# listen on all interfaces
inet_interfaces = all

# misc configs
recipient_delimiter = +
biff = no
home_mailbox = maildir/
readme_directory = /usr/share/doc/postfix
html_directory = /usr/share/doc/postfix/html

# Message size:
# 1024 * 1024 * MB * 1.08 (8% for headers)
# 2MB by default
message_size_limit = _MESSAGESIZE_

# no mailbox limit (will be  handled via dovecot)
mailbox_size_limit = 0

# amavis content filtering
content_filter = smtp-amavis:_AMAVISHN_:10024

# SASL via dovecot
smtpd_sasl_type = dovecot
smtpd_sasl_path = inet:mda:12345

# SALS settings
smtpd_sasl_auth_enable = yes
smtpd_sasl_authenticated_header = yes
smtpd_sasl_security_options = noanonymous
broken_sasl_auth_clients = yes

# TLS
smtpd_tls_cert_file = /certs/mail.crt
smtpd_tls_key_file = /certs/mail.key
smtpd_tls_CAfile = 
smtp_tls_security_level = may
smtpd_tls_security_level = may
smtpd_sasl_tls_security_options = $smtpd_sasl_security_options
smtpd_tls_auth_only = yes
smtp_tls_loglevel = 1
smtpd_tls_loglevel = 1

# Attacks proteciton: LogJam, FREAK & POODLE
smtpd_tls_eecdh_grade = strong
smtpd_tls_ciphers = high
smtpd_tls_mandatory_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1
smtpd_tls_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1
smtp_tls_mandatory_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1
smtp_tls_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1
smtpd_tls_exclude_ciphers = aNULL, eNULL, EXPORT, DES, RC4, MD5, PSK, aECDH, EDH-DSS-DES-CBC3-SHA, EDH-RSA-DES-CBC3-SHA, KRB5-DES, CBC3-SHA
smtpd_tls_dh1024_param_file = /certs/RSA2048.pem

# EHLO RESTRICTION
smtpd_helo_required = yes
smtpd_helo_restrictions =
    permit_mynetworks
    reject_invalid_helo_hostname
# This ones are disabled as not all host has valid names and fqdn
#    reject_unknown_hostname
#    reject_non_fqdn_hostname

# CLIENT RESTRICTIONS
# Introduce a small delay to poke pipeliners and the catch them
#smtpd_client_restrictions = sleep 1, reject_unauth_pipelining
#smtpd_delay_reject = no

# Users mapping login vs email
# to avoid user1@ can send as user2@
smtpd_sender_login_maps = proxy:pgsql:/etc/postfix/pgsql/virtual_email2user.cf
relay_recipient_maps = proxy:pgsql:/etc/postfix/pgsql/virtual_email2user.cf

# error misc
smtpd_error_sleep_time = 1s
smtpd_soft_error_limit = 60
smtpd_hard_error_limit = 10

# disable verify
disable_vrfy_command = yes

# headers and body checks
header_checks = regexp:/etc/postfix/rules/header_checks
body_checks = regexp:/etc/postfix/rules/body_checks

# POSTSCREEN filtering on port 25
# By default postscreen withelist the mynetworks net.
postscreen_access_list = permit_mynetworks
# action for bad servers in blacklist
postscreen_blacklist_action = drop
# if new lines, bad dog!
postscreen_bare_newline_action = drop
# disable verify
postscreen_disable_vrfy_command = yes
# enforce the greet action
postscreen_greet_action = drop
# no pipelining
postscreen_pipelining_action = drop
# no auth in SMTP(25)
postscreen_command_filter = pcre:/etc/postfix/rules/command_filter.pcre
# DNSRBL in postscreen
postscreen_dnsbl_threshold = 3
postscreen_dnsbl_action = enforce
postscreen_dnsbl_sites = _DNSBL_LIST_

# sender
smtpd_sender_restrictions =
    # me and myself
    permit_mynetworks

    # identity checks
    reject_unauthenticated_sender_login_mismatch
    reject_sender_login_mismatch

    # reject if the sender domain has a invalid DNS configured
    reject_unknown_sender_domain

    # black list
    check_sender_access hash:/etc/postfix/rules/blacklist

    # check everyone list protection
    check_recipient_access hash:/etc/postfix/rules/everyone_list_check

    # relay only if auth
    permit_sasl_authenticated

# recipients
smtpd_recipient_restrictions =
    # quota policy
    check_policy_service inet:mda:12340

    # check spf settings
    check_policy_service unix:private/policy-spf

    # me and myself
    permit_mynetworks

    # reject nfqn, domain is MUA job
    reject_non_fqdn_recipient

    # rejectt if the recipient domain is nor resolved
    reject_unknown_recipient_domain

    # reject if not a valid user
    reject_unlisted_recipient

    # cclose open relay
    reject_unauth_destination

    # relay if auth
    permit_sasl_authenticated

# Security shadow copy must be a valid user
always_bcc = _ALWAYSBCC_

# avoid double copy on messages when always_bcc is enabled
receive_override_options = no_address_mappings

# Debug verbosity for an ip...
# debug_peer_list = 172.17.0.1
# debug_peer_level = 16

# virtual domains linking
virtual_mailbox_domains = proxy:pgsql:/etc/postfix/pgsql/virtual_domains_maps.cf
virtual_mailbox_maps = proxy:pgsql:/etc/postfix/pgsql/virtual_mailbox_maps.cf
virtual_alias_maps = proxy:pgsql:/etc/postfix/pgsql/virtual_alias_maps.cf
relay_domains = $mydestination, proxy:pgsql:/etc/postfix/pgsql/relay_domains.cf
virtual_mailbox_base = /home/vmail
virtual_minimum_uid = 100
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000
virtual_transport = lmtp:inet:mda:24

# dovecot lmtp 1 by 1
dovecot_destination_recipient_limit = 1
dovecot_destination_concurrency_limit = 1

# force know users list, depends on the virtual_mailbox_maps table
smtpd_reject_unlisted_recipient = yes

# SMTP sasl to upstream
# see comments on /etc/postfix/sasl_passwd
#smtp_sasl_auth_enable = yes
#smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd

# compat level 
compatibility_level = 2

# bounce templates
#bounce_template_file = /etc/postfix/bounce.es.cf
bounce_template_file = /etc/postfix/bounce.en.cf

# docker, logging to stdout, see also postlog on master.cf
maillog_file = /dev/stdout
maillog_file_prefixes = /var, /dev, /tmp
