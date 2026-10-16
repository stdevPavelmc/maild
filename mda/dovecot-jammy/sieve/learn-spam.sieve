/* MailD: learn as spam any message the user moves into Junk */
require ["vnd.dovecot.pipe", "copy", "imapsieve"];

pipe :copy "learn-spam.sh";
