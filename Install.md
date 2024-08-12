# MailD detailed install instructions

There are two ways of setting this up, from scratch/local and from docker hub; but both has some requirements:

## Requirements

- A valid `docker` and `docker compose` plugins installed.
- Access to dockerhub to pull images; in some envs [Cuba, cough!] or when you are behind a proxy you need extra steps to make it work. That is out of the scope of this guide: google it!
- Access to an ubuntu & debian repository to pull packages for the install.
- The mailserver in where you go to install this solution must have a unique hostname shared with the "email server" and will be tied to the first/default domain you install it; further domains must use the nameserver of the first domain as server.
- According to above one, you need too fix/setup SPF/DKIM/DMARK for every email domain pointing to the hostname of the first domain.
- We use `maild.cu` as example, let´s say `mails.maild.cu` is the name of the default domain host, if you setup a second or third domain, for example `noobster.cu`: this one must be registered on the DNS with `mails.maild.cu` as mail server and all the SPF/DKIM/DMARC/SRV/etc DNS registers must poit to `mails.maild.cu`.

## Some tech details you need to know

1. Docker Volumes

This stack uses docker volumes to share data, so any persisten data will be handled by a docker volume.

2. SSL Certs & HTTPS

This stack generate a self signed certificate if a Let's Encrypt one is not found on the host [For the MTA & MDA use]; setting up the Let's Encrypt cert is out of the scope, google it.

We don't handle any Secure Layer (SSL/HTTPS) on the web servers for the standard `docker-compose.yml`, that's up to you; we recommend a reverse proxy handling this, Traefik or Nginx, for example. (See compose-gitlab.yml for a Traefik example)

The host must have the same name as the mailserver (as mentioned earlier) for the Let's Encrypt to manage it, the certs must be on the standard `/etc/letsencrypt` location.

This said, the webmail will listen on port 80 and the web admin interface will listen on port 8080.

3. Snappy Mail is the default webmail or server, it´s on active development and has a live community, that's why my choice for it; if you don't like it and want to uses another, just comment/change the webmail service on the matching docker compose file.

4. Postfix Admin as the admin web interface for handling domains and users is the default choice, it's open, free, slim and effective. Some features you may not know, buy you will need it:

- Import tools, you can import domains and users from csv files, google it.
- You can create admins for specific domains, to delegate the admin rights of that domain only.
- Others...

5. The maildir folder is fully compatible with MailAD and Docker-MailAD, just a note: users maildirs will be contained  under a folder with the name of the domain. This will ease the migration from one to the another.

6. The postfixadmin management interface needs a REAL email domain, one that's searcheable on the internet with a MX DNS register, or it won't work; stay alert to the red warnings.

## Install it from internet

You have two options:

- Dockerhub repository [compose-dockerhub.yml], this is the default pick, but it's blocked on some countries (Cuba, cough!)
- Github docker repository [compose-github.yml], this is the recommended if you are in Cuba 😉

Pick the one you like and use the file, for the propose of this tutorial I will pich the Github one, as it's the least commonly used one; but both work the same.

1. Copy the `env.sample` file to `.env` file and tweak/change/update the configs to your needs.
2. Review the `vars/` dirs to check if you need to tweak any service variable.
3. Install it like this:

```sh
you@yourpc:~/$ docker compose -f compose-github.yml pull
you@yourpc:~/$ docker compose -f compose-github.yml up
```

4. Now Go to the [Server Setup](#server-setup) section and do the config, and came back when done.
5. Ctrl+C to stop the inline server, and run it for good on the backgound:

```sh
you@yourpc:~/$ docker compose -f compose-online.yml up -d
```

That's it.

If you are using an orchestrator or utomated deploy, you must be aware that after domain configurationyou need to take down and then up the whole stack before you can use it on production, this to apply the latest DB chnges on the setup process.

## Build & Deploy from scratch/local

In this case you are building the whole images and so:

1. Copy the `env.sample` file to `.env` file and tweak/change/update the configs to your needs.
2. Review the services dirs to check if you need to tweak any service variable.
3. Build it:

```sh
you@yourpc:~/$ docker compose pull
you@yourpc:~/$ docker compose build
```

And wait for the build to end.

4. run it:

```sh
you@yourpc:~/$ docker compose up
```

4. Now Go to the [Server Setup](#server-setup) section and do the config, and came back when done.
5. Ctrl+C to stop the inline server, and run it for good on the backgound:

```sh
you@yourpc:~/$ docker compose up -d
```

That's it.

## Bonus tracks: local repos, Gitlab & traefik

What if you have local Ubuntu and Debian repos and whant to use them; or save internet time as your connection sucks!

Don't fear, I has been there too, there is a trick.

Just tweak the `sources.list_debian` & `sources.list_ubuntu` files and then run the `setrepos.sh` script with no parameter to setup the local repos, that will setup the local build env to use your repos and download build sources (snappy mail and postfixadmin)

If you need to clean it to use normal [from internet] way you can run the `setrepos.sh` with any parameter to remove them.

If you like to manage the deployment on a Gitlab CI/CD there is a sample `.gitlab-ci.yml` file on this repo and a `env.sample_gitlab` for your to read; note that Gitlab flow uses the `compose-gitlab.yml` file as target, so rename it as docker-compose.yml and you are for a go.

Also, the Gitlab config is tweaked to use Traefik, so there is some labels there to make it work.

# Server Setup

## Setup instructions

After successfully starting it for the first time you need o initiate the DB config, peace of kake:

If you ended with the admin container mapped to (for example) https://mails.domain.com you need to point your browser to: https://mails.domain.com/setup.php, to do the one time setup.

You need to find the OTP setup password in the container `maild-admin`'s logs, this password is a one time password and will change with **EACH reboot** of that container. It will look like this on the logs:

```sh
[...]
####################### !!! #############################
OTP SETUP PASSWORD: RanDomStringThatChangesOnEveryReboot
####################### !!! #############################
[...]
```

Once you have entered the setup password it will make some checks and then you need to create a superadmin account on the PostfixAdmnin app, this account will have admin on all of the domains provisioned on this server by default; note that the first field "Setup Password" is the OTP one.

![Setup_first](./imgs/setup_first_screen.png)

Use the setup password to create a superadmin account, it must be a valid email address of the default domain, but there are a few caveats:

- Please be careful and observe the warnings in red on that page: the webadmin app will check for a valid domain on the internet, if you have not setup the records for the domain it will fail, if the webadmin can't ask the internet if that domain is valid it will fail.
- Take into account that **this is not a real email mailbox** even when it looks like one, you may create the mailbox for that email if needed later in the setup process.

**I repeat:** *This admin account is NOT a mailbox, and will have a different password storage place if you create a mailbox with that name. So you can end having the admin with one password and a real mailbox with ANOTHER password.*

## Domain setup

After ending the setup, go to the login page https://mails.domain.com for example, login and create the new domain, the same domain you setup on the `.env` file; then:

- Add the superadmin mailbox [the superadmin account is the one you created in the setup phase] it needs to match the one you declared on the `.env` file; that email is the one that will receive default mails and notices from the mail server.
- Review the email aliases (postmaster/abuse/hostmaster) and edit it if needed.
- Start to add users to the domain, you can import users in bulk using the PostfixAdmin tools, google it, its easy.
- take down and up the whole stack before you can use it on production, this to apply the latest DB chnges on the setup process [the next DKIM step will not work without a reboot of the stack]

## DKIM

Did you take down and up the hole stack after configuring the domain? no, go and do it, or this step will not work.

Ok, go to the maild_amavis container logs and search for the DKIM signature to use on your domain, look for a segment like this:

```
=|| DKIM / DNS config for maild.cu ||=
; key#1 1024 bits, s=2ck9waejsv2blkpbhffm, d=maild.cu, /var/lib/amavis/dkim/maild.cu.pem
2ck9waejsv2blkpbhffm._domainkey.maild.cu.       3600 TXT (
  "v=DKIM1; p="
  "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDCghuUcneR3QE4l6sPEHSzGQTv"
  "qck2efIlk0wNDphqQUaaKUAGCk/iR51oUZvBo4bqhu4fs3frGTthO9zL0CNFDZiC"
  "repRRrw21XDx4rpkYR7a4bshgiuR3czq1dLp03FDFjbVVzKjGQFGQ6dL5lEnlFbH"
  "QqrF2lYBvVNHpo4V4wIDAQAB")
```

This DKIM key is ready to setup on the DNS server for that domain, and it's fixed for this domain; that means it's saved on the amavis docker volume and will survive reboots.

In this example, the key needs to be setup as a `TXT record` under the name `2ck9waejsv2blkpbhffm._domainkey` in the DNS domain and the contents is all the lines between "" but and whitout them as a single line.

If you add a new domain via the postfixadmin interface you need to restart the amavis container and search on the logs the new key for that domain.
