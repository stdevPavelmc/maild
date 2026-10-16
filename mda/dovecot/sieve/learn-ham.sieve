/* MailD: learn as ham any message the user moves out of Junk
   (the pipe helper skips messages still flagged as spam) */
require ["vnd.dovecot.pipe", "copy", "imapsieve"];

pipe :copy "learn-ham.sh";
