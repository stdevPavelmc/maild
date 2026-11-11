#!/bin/sh
# MailD mua2 healthcheck: Apache answers and Roundcube renders its login page (PHP, the rendered
# configuration and the database session store all work — a broken db_dsnw is a 500 here).
curl -fsS --max-time 4 -H 'Host: localhost' http://127.0.0.1/ 2>/dev/null | grep -q 'rcmloginuser' || exit 1
exit 0
