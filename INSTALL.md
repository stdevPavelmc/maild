# MailD install instructions

MailD is a complete mail server built from Docker containers (Postfix, Dovecot, Amavis +
ClamAV, PostfixAdmin, SnappyMail and a maintenance cron) that keeps its domain/user
catalogue in PostgreSQL.

This guide takes you from a bare host to a **working server in one command**: on the first
boot the stack *provisions itself*. You no longer need to open `/setup.php`, dig the OTP out
of the logs, create the domain by hand or "take the stack down and up again" — all of that is
automated (see [What happens automatically on the first boot](#what-happens-automatically-on-the-first-boot)).

## Requirements

- A valid `docker` engine and the `docker compose` v2 plugin.
- Access to the container registry (Docker Hub, GitHub `ghcr.io` or your own). Some networks
  block Docker Hub (Cuba, behind a proxy): use the GitHub compose or a pre-built registry.
  That is out of scope here — google it.
- A host **hostname shared with the mail domain** (e.g. `mails.maild.cu`). It is tied to the
  first/default domain; any further domain must point its MX + SPF/DKIM/DMARC/SRV records at
  this hostname.
- The default domain (and every extra domain) must have correct public DNS records: `A`/`MX`
  for the host, plus `SPF`, `DKIM` (see [DKIM](#dkim)) and `DMARC`.

## Quick start (automated)

1. Copy the sample env file and edit it:

   ```sh
   cp env.sample .env
   ```

   At minimum set:

   - `DEFAULT_DOMAIN` — your first mail domain (e.g. `maild.cu`).
   - `MAIL_ADMIN_USER` — the administrator local part (default `sysadmin`).
   - `MAIL_ADMIN_PASSWORD` — the password of the administrator (superadmin). Leave it empty
     to have one generated and printed in `docker compose logs admin`.
   - `POSTGRES_PASSWORD` — the database password (pick a strong one).

2. Review `vars/` if you need to tweak a service.

3. Pick the compose file for your case and start the stack (the `maild` network is external,
   create it once with `docker network create maild`):

   ```sh
   # Internet / Docker Hub — preferred, general use:
   docker compose -f docker-compose.yml pull
   docker compose -f docker-compose.yml up -d

   # GitHub images — restricted countries (e.g. Cuba) / Docker Hub blocked:
   docker compose -f compose-github.yml pull
   docker compose -f compose-github.yml up -d

   # GitLab registry — for GitLab users, paired with the shipped .gitlab-ci.yml:
   docker compose -f compose-gitlab.yml pull
   docker compose -f compose-gitlab.yml up -d
   ```

4. Watch the first boot provision itself:

   ```sh
   docker compose -f docker-compose.yml logs -f admin
   ```

   When you see `seed: catalogue provisioned: domain=... admin=...` the server is ready.

That's it — the deployment is usable. Jump to [First login](#first-login).

> Building from source instead of pulling? Same flow, just build first:
> `docker compose build` before the `up -d`, on the compose file with `build:` sections.

## What happens automatically on the first boot

The stack seeds the catalogue and configures the boot-time services for you:

1. **`db`** creates the databases and the `maild_provision` sentinel table (an idempotent
   migration; no PostfixAdmin core table is changed).
2. **`admin`** runs PostfixAdmin's `upgrade.php` (schema), then `admin/seed.sh` creates:
   - the `DEFAULT_DOMAIN` domain,
   - the superadmin `MAIL_ADMIN_USER@DEFAULT_DOMAIN` (password `MAIL_ADMIN_PASSWORD`),
   - the matching mailbox with the **same** password (so it is also a real IMAP account),
   - the default aliases `postmaster`/`abuse`/`hostmaster`/`webmaster` → the administrator,
   - and, last, the `maild_provision` sentinel row.
3. **`amavis`, `mua`, `mta`** wait (bounded, `PROVISION_WAIT_TIMEOUT`) for that sentinel
   before they run their configuration, because they cache the domain list at start:
   - `amavis` generates the DKIM key(s),
   - `mua` writes the SnappyMail per-domain config,
   - `mta` builds the virtual aliases.

   Waiting *before* their config stage is what removes the old "take the stack down and up"
   step: they read a fully provisioned catalogue on their one and only config run. It is also
   safe under an orchestrator (swarm/CI) because the sentinel + an advisory lock serialise the
   seeder. This is why **no `docker restart` is needed** — and it is why the stack works the
   same whether it is started by hand, by `docker stack deploy` or by a GitLab pipeline.

Because the catalogue is written directly in the database, the provisioner does **not** need
to reach the internet, and it bypasses the PostfixAdmin "the domain must resolve on the
internet to be accepted" check that made the old manual setup fail on fresh domains.

## First login

- **Admin UI (PostfixAdmin):** open `https://mails.domain.com/admin` (or `http://host:8080`)
  and log in as `sysadmin@<DEFAULT_DOMAIN>` with `MAIL_ADMIN_PASSWORD` (or the generated
  password from `docker compose logs admin`).
- From there create **additional** domains, users and aliases. Bulk import is supported
  (CSV) via the PostfixAdmin tools.
- **Webmail (SnappyMail):** open `https://webmails.domain.com` (or the webmail port of your
  compose file) and log in with a mailbox you created.

> The first domain is already there: do **not** recreate it, or you will get a duplicate.

## DKIM

`amavis` generates one DKIM key per domain and prints the DNS record it needs. Read it:

```sh
docker compose -f compose-github.yml logs amavis | grep -A12 'DKIM / DNS config'
```

You get a block like:

```
=|| DKIM / DNS config for maild.cu ||=
; key#1 1024 bits, s=2ck9waejsv2blkpbhffm, d=maild.cu, /var/lib/amavis/dkim/maild.cu.pem
2ck9waejsv2blkpbhffm._domainkey.maild.cu.       3600 TXT (
  "v=DKIM1; p="
  "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDCghuUcneR3QE4l6sPEHSzGQTv"
  ...)
```

Publish the name `<selector>._domainkey.<domain>` as a `TXT` record whose contents is all the
quoted lines joined into one line. The key is stored in the amavis volume and survives
reboots. If you add a **new** domain later through the UI, `docker compose restart amavis`
so it generates that domain's key, then read it from the logs again.

## Isolated / restricted networks

The automated flow needs **no** internet access at provisioning time, but a few knobs help
on air-gapped, proxied or low-bandwidth hosts:

- **Docker Hub blocked (Cuba, proxies):** use `compose-github.yml` (`ghcr.io` images) or a
  private registry built by the CI.
- **ClamAV updates:** the first boot downloads ~230 MB of signatures. On a restricted link
  set `ALTERNATE_MIRROR` in `vars/clamav.env`.
- **Prefer the classic manual setup:** set

  ```sh
  AUTO_PROVISION=no
  ```

  in `.env`. The stack then starts exactly as before: the admin container prints a one-time
  **OTP setup password** and you finish by hand — see [Manual mode](#manual-mode-auto_provisionno).

Other provisioning knobs (see `env.sample`): `PROVISION_VERSION` (bump to re-assert the
defaults), `PROVISION_WAIT_TIMEOUT`, `PROVISION_FORCE` (re-write the admin password).

## HTTPS & web UIs

MailD does **not** terminate TLS for the web UIs; every production compose file ships
Traefik labels that route `webmail.<DEFAULT_DOMAIN>` (webmail) and
`mailadmin.<DEFAULT_DOMAIN>` (admin). You **must** front the stack with a reverse proxy /
ingress controller that terminates TLS (Traefik, Nginx, …) — it is **not** provided. Attach
the ingress to the external `maild` network (create it once with
`docker network create maild`) so it can reach the `admin` and `mua` containers, both
listening on port 80 inside the stack.

The host must carry the same name as the mail server (see Requirements) for Let's Encrypt,
and the certs must live in the standard `/etc/letsencrypt` location.

## Deploy contexts

| Context | What to do |
|---------|------------|
| **Single server** | `docker compose -f compose-*.yml up -d`; the stack provisions itself. |
| **Docker stack / swarm** | `docker stack deploy`; the sentinel + advisory lock make the concurrent start safe. |
| **GitLab CI** | The pipeline builds `.env` from `env.sample_gitlab` + CI variables (`MAIL_ADMIN_PASSWORD`, `POSTGRES_PASSWORD`) and deploys `compose-gitlab.yml`. The first deploy seeds itself; the CI can poll `maild_provision` to confirm readiness. |

## Manual mode (AUTO_PROVISION=no)

If you set `AUTO_PROVISION=no` you get the original hand-driven flow. After the first start:

1. Open `https://mails.domain.com/setup.php`.
2. Find the OTP setup password in the `maild-admin` logs (it changes on **every** reboot):

   ```
   ####################### !!! #############################
   OTP SETUP PASSWORD: RanDomStringThatChangesOnEveryReboot
   ####################### !!! #############################
   ```

3. Create the superadmin account with that setup password. It must be a valid address of the
   default domain, and PostfixAdmin checks it resolves on the internet (it fails otherwise).
   Remember: **this is a login, not a mailbox** — you can create a mailbox of the same name
   with a *different* password.
4. Log in, create the domain, add the administrator mailbox, review the aliases, add users.
5. Take the stack down and up so the boot-time services pick up the changes
   (`docker compose … down && docker compose … up -d`), then do [DKIM](#dkim).

## Tech details

- **Volumes:** all persistent data lives in Docker volumes (mail, catalogue, filters, certs).
- **SSL certs:** a self-signed cert is generated if no Let's Encrypt one is found (for the
  MTA/MDA); setting up Let's Encrypt is up to you.
- **Webmail:** SnappyMail is the default; swap/comment the `mua` service if you prefer another.
- **PostfixAdmin:** open-source web admin; supports CSV import and per-domain admins.
- **Maildir:** compatible with MailAD / Docker-MailAD; per-user maildirs live under a folder
  named after the domain, which eases migrations.

## Bonus: GitLab & Traefik

There is a sample `.gitlab-ci.yml` and `env.sample_gitlab` in the repo; the GitLab flow uses
`compose-gitlab.yml` (the pipeline sets `COMPOSE_FILE=compose-gitlab.yml` and the `IMG_*`
image variables). Every production compose file already carries the Traefik labels, so any
of them can sit behind a Traefik ingress. On a slow/restricted link pre-download build
sources and use the `local` Dockerfile variants.
