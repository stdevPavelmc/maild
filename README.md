# MailD docker version of the MailAD project but using a DB as backend

This project is inspired on [MailAD-Docker](https://github.com/stdevPavelmc/mailad-docker), that is also based on [Mailad](https://github.com/stdevPavelmc/mailad).

This is the docker version with a DB as a backend instead of a domain controler LDAP we have a [telegram group](https://t.me/MailAD_dev) to discuss the development, feel free to join.

This one is a simplificatiom of MailAD, there are some features missing:
- Automatic groups from AD, there is no AD, so use lists on PostfixAdmin
- Others [will be filled...]

## Services

To create a realy dynamic setup we split the mail server in services:

- [**MTA** (Mail Transport Agent)](./mta/) this is the Postfix field, basically the reception and dispatching of mails to and form the mail server/users.
- [**MDA** (Mail Delivery Agent)](./mda/) This is the Dovecot field, this has to do with the users checking his mails from the mailbox, quotas, etc.
- [**AMAVIS** (Advanced filtering)](./amavis), it comprises attachments, anti-virus, anti-spam, etc.
- [**ClamAV**](./clamav/) AV scanning solution
- **Postgres DB** this is the database lo hold the users data.
- [**PostfixAdmin**](./admin/) This is a simple Web Management interface
- [**MUA**](./mua/) This is the mail user agent, aka: Webmail provided by [Snappy Mail](https://github.com/the-djmaze/snappymail/)
- [**Cron**](./cron/) This has to deal with scheduled tasks, and maybe: backups, cleanups, statistics, etc.

Follow the links for each service to get details for each docker image.

**Warning!:** Under no cirscuntance change the name of the hostnames, it will break the setup!!!

## How to Install it?

For detailed and tech filled doc go to [Install.md](Install.md)

# Contributing.

There are many ways to contribute:

- Review this documentation and fix typos, syntax errors, propose better sentences, etc.
- Propose translations for some of the .md files (Any langs, Spanish, German & French are the most commons, but any will work.)
- Test this setup on dev premises, spot and report/suqash bugs, propose new features/fixes, etc.
- Spread the word about it.
- Join to the [telegram group](https://t.me/MailAD_dev) and give some feedback/kudos to the dev.
- Buy the dev a coffee/beer/beef/mouse/? see [this link to know how to send money to the dev](https://github.com/stdevPavelmc/mailad/blob/master/CONTRIBUTING.md#direct-money-donations) to keep it going!
