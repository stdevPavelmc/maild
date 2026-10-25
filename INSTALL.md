# MailD install instructions

MailD is a complete mail server built from Docker containers (Postfix, Dovecot, Amavis +
ClamAV, AdminNG, SnappyMail and a maintenance cron) that keeps its domain/user
catalogue in PostgreSQL.

This guide takes you from a bare host to a **working server in one command**: on the first
boot the stack *provisions itself*. You no longer need to open `/setup.php`, dig the OTP out
of the logs, create the domain by hand or "take the stack down and up again" — all of that is
automated (see [What happens automatically on the first boot](#what-happens-automatically-on-the-first-boot)).

## Requirements

- A valid `docker` engine and the `docker compose` v2 plugin.
- **Open ports on the host** (firewall/NAT accordingly): `25`, `465`, `587` (SMTP, SMTPS,
  Submission) and `993`, `995` (IMAPS, POP3S) — there is **no** plaintext 143/110 in the
  production compose files. The web UIs are served behind your TLS ingress on `80`/`443`
  (see [HTTPS & web UIs](#https--web-uis)).
- Access to the container registry (Docker Hub, GitHub `ghcr.io` or your own). Some networks
  block Docker Hub (Cuba, behind a proxy): use the GitHub compose or a pre-built registry.
  That is out of scope here — google it.
- A host **hostname shared with the mail domain** (e.g. `mails.maild.cu`). It is tied to the
  first/default domain; any further domain must point its MX + SPF/DKIM/DMARC/SRV records at
  this hostname.
- A writable **`/certs` directory on the host**. Every production compose file bind-mounts it
  into `mta` and `mda` (`/certs:/certs`); Docker creates it when it is missing. On the first
  boot the stack fills it with a self-signed `mail.crt`/`mail.key` pair plus
  `RSA2048.pem` (the MDA's DH parameters, which is why the first start takes a few extra
  seconds). Drop your own certificate under those exact names to replace the self-signed one
  (see [Tech details](#tech-details)).
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
   - `MAIL_ADMIN_PASSWORD` — the superadmin login *and* the password of its mailbox — is optional: comment the line out and one is generated and printed in `docker compose logs api`.
   - `POSTGRES_PASSWORD` — the database password (`openssl rand -hex 18`).
   - `ADMINNG_SECRET_KEY` — signs the AdminNG JWTs and encrypts the enrolled TOTP seeds
     (`openssl rand -hex 32`).

   Note that `POSTGRES_PASSWORD` and `ADMINNG_SECRET_KEY` are **enforced**, not suggested: the
   compose files carry a `${VAR:?…}` guard, and `docker compose` refuses to start (or even to
   interpolate) without them giving:
   `error while interpolating services.api.environment.ADMINNG_SECRET_KEY`:
   required variable ADMINNG_SECRET_KEY is missing a value`. **Replace the `change-me-…` 
   placeholders that `env.sample` ships**: they are real, publicly known values, so a starter
   that keeps `ADMINNG_SECRET_KEY=change-me-openssl-rand-hex-32` runs with a signing key anyone
   can read here and could mint administrator tokens with (the API also logs a warning about it
   on every boot). Rotating the key later invalidates live sessions and enrolled authenticators.

2. Every tunable defaults **inside the service images** (ENV in the Dockerfiles): to
   deviate from a default, uncomment the matching line in your `.env` (the commented
   catalogue) — never leave a variable empty (comment it out instead). Full default
   catalogue: `.agents/services/configuration.md`.

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
   docker compose -f docker-compose.yml logs -f api
   ```

   When you see `api: INFO - catalogue provisioned: domain=... admin=...` the server is ready.

**Quick check before you continue** (every item below was verified on a fresh single-host
`maild.cu` deployment):

- `docker compose -f docker-compose.yml ps` — every service should be `Up`/`healthy`
  (`clamav` may take a while the first time while it downloads ~230 MB of signatures).
- The catalogue was seeded **exactly once** (a second `up -d` must not re-provision or
  regenerate the DKIM key):

  ```sh
  docker compose -f docker-compose.yml logs api | grep 'catalogue provisioned'
  docker compose -f docker-compose.yml exec db psql -U maild -d mailddb \
    -c 'select domain from domain;' \
    -c 'select username from mailbox;' \
    -c 'select version from maild_provision;'
  ```

  Expect your domain, `sysadmin@<DEFAULT_DOMAIN>` and one `maild_provision` row (version `1`).
- The DKIM key for the default domain exists (see [DKIM](#dkim) for the record to publish):

  ```sh
  docker compose -f docker-compose.yml logs amavis | grep -A12 'DKIM / DNS config'
  ```

- Both web UIs answer inside the stack — this works **before** your TLS ingress exists, and
  it is how you tell a broken stack from a broken proxy:

  ```sh
  docker run --rm --network maild curlimages/curl:latest -s -o /dev/null -w 'adminng %{http_code}\n' http://adminng/
  docker run --rm --network maild curlimages/curl:latest -s -o /dev/null -w 'webmail %{http_code}\n' http://mua/
  ```

  Expect `adminng 200` and `webmail 200`. `docker compose exec api adminng.py --list-devices`
  must answer too (that one proves the API reached `ADMINNG_DB`).
- Send a mail from an external account (e.g. Gmail) to `sysadmin@<DEFAULT_DOMAIN>` and read
  it back on the webmail: that confirms SMTP + content filtering + delivery in one go.

That's it — the deployment is usable. Jump to [First login](#first-login).

> Building from source instead of pulling? Same flow, just build first:
> `docker compose build` before the `up -d`, on the compose file with `build:` sections.

## What happens automatically on the first boot

The stack creates its schema and seeds the catalogue for you:

1. **`db`** creates the databases (`mailddb`, `contacts`, `adminng`) and applies its
   migrations: `001_maild_provision.sql` (the `maild_provision` sentinel table) and
   `002_postfixadmin_catalogue.sql` (the PostfixAdmin catalogue schema — MailD's own
   snapshot, no PostfixAdmin container involved).
2. **`api`** waits for that schema, then seeds:
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

- **Admin UI (AdminNG):** open `https://adminng.<DEFAULT_DOMAIN>` (or `http://host:8083` in
  dev) and log in as `sysadmin@<DEFAULT_DOMAIN>` with `MAIL_ADMIN_PASSWORD` (or the generated
  password from `docker compose logs api`). The first browser must be approved server-side
  (`docker compose exec api adminng.py --approve-device '<uuid>'`), then the superadmin
  enrolls TOTP on first login — see [`adminng/README.md`](./adminng/README.md).
- From there create **additional** domains, users and aliases (a new domain gets the four
  default aliases automatically). Bulk import is supported (CSV, "Carga inicial").
  > The first domain is already there: do **not** recreate it, or you will get a duplicate.
- **Webmail (SnappyMail):** open `https://webmail.<DEFAULT_DOMAIN>` — served behind your TLS
  ingress (the production compose files expose no webmail port; the dev stack is at
  `http://localhost:8081`) — and log in with a mailbox you created.
- **Webmail admin panel:** `https://webmail.domain.com/​?admin` — the login (default `maild`)
  and the password are printed by the webmail container on every boot, as an OTP:
  `docker compose logs mua | grep -A3 'admin panel'`. The password is generated on the first
  boot and kept in the data volume; set `MUA_ADMIN_PASSWORD` to pin a known one.
- **Changing a mailbox password:** users do it themselves from the webmail (**Settings →
  Password**). MailD ships the SnappyMail `change-password` plugin wired to its own catalogue
  driver, so the new password is immediately valid over IMAP/POP3/SMTP.
  Because Dovecot caches authentication results for a minute (`auth_cache_ttl` in
  `mda/dovecot/conf.d/10-auth.conf`), the *previous* password can still be accepted for up to
  that minute — the new one always works at once, and
  `docker compose exec mda doveadm auth cache flush` removes any doubt.
  The baseline plugins (X-Originating-IP header, change-password, TOTP two-factor) are installed
  and enabled on every boot — `MUA_PLUGINS` in `env.sample` lists them.

## Password hashes and the 2027-02-01 deadline

Mailbox/administrator passwords are hashed with **Argon2id** by default
(`{ARGON2ID}$argon2id$…`, `PASSWORD_SCHEME=argon2id`), written identically by
first-boot provisioning, the AdminNG API and the webmail change-password driver.
Older deployments carry **legacy md5crypt (`$1$…`)** hashes; both formats are
valid in the same column and Dovecot verifies either, so nothing breaks on
upgrade. Two things to know:

- **The PostfixAdmin UI is retired.** The `admin` service no longer exists: its schema duty
  lives in `db/migrations/002_postfixadmin_catalogue.sql` and its seeder in the `api`. Do not
  point an old PostfixAdmin instance at the catalogue — its `upgrade.php` would re-run
  unguarded migrations against a schema MailD now owns.
- **Weak-scheme support is removed on 2027-02-01.** From that date MailD
  releases refuse `PASSWORD_SCHEME=md5crypt`, Dovecot's
  `auth_allow_weak_schemes` goes back to `no`, and any remaining `$1$` hash stops
  authenticating. Rows migrate on a password change or automatically on the
  next IMAP/POP3 login (rehash-on-login); watch progress with
  `docker compose exec api adminng.py --legacy-hashes`. The mda logs a startup
  warning with the remaining count on every boot.

## DKIM

`amavis` generates one DKIM key per domain and prints the DNS record it needs. Read it
(with the compose file you deployed with):

```sh
docker compose -f docker-compose.yml logs amavis | grep -A12 'DKIM / DNS config'
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
  set `ALTERNATE_MIRROR` in your `.env`.
- **Prefer to seed by hand:** set

  ```sh
  AUTO_PROVISION=no
  ```

  in `.env`. The stack then starts unseeded; run
  `docker compose exec api adminng.py --provision` once — see
  [Manual mode](#manual-mode-auto_provisionno).

Other provisioning knobs (see `env.sample`): `PROVISION_VERSION` (bump to re-assert the
defaults), `PROVISION_WAIT_TIMEOUT`, `PROVISION_FORCE` (re-write the admin password).

## HTTPS & web UIs

MailD does **not** terminate TLS for the web UIs; every production compose file ships
Traefik labels that route `webmail.<DEFAULT_DOMAIN>` (webmail) and
`adminng.<DEFAULT_DOMAIN>` (AdminNG). You **must** front the stack with a reverse proxy /
ingress controller that terminates TLS (Traefik, Nginx, …) — it is **not** provided. Attach
the ingress to the external `maild` network (create it once with
`docker network create maild`) so it can reach the `adminng` and `mua` containers, both
listening on port 80 inside the stack.

The host must carry the same name as the mail server (see Requirements) for Let's Encrypt,
and the certs must live in the standard `/etc/letsencrypt` location. The two UI hostnames
(`webmail.<DEFAULT_DOMAIN>` and `adminng.<DEFAULT_DOMAIN>`) must resolve to the ingress and be
covered by its certificate; if you serve them under other names, also override
`ADMINNG_WEBAUTHN_RP_ID`/`ADMINNG_WEBAUTHN_ORIGINS` (see
[AdminNG](#adminng-optional-but-recommended)). Before the ingress exists, check the containers
from inside the `maild` network with the `curlimages/curl` commands of the
[quick check](#quick-start-automated): a `200` there means the stack is fine and the proxy is
what needs fixing.

## Deploy contexts

| Context | What to do |
|---------|------------|
| **Single server** | `docker compose -f compose-*.yml up -d`; the stack provisions itself. |
| **Docker stack / swarm** | `docker stack deploy`; the sentinel + advisory lock make the concurrent start safe. |
| **GitLab CI** | The pipeline builds `.env` from `env.sample_gitlab` + the CI/CD variables (`DEFAULT_DOMAIN`, `MAIL_ADMIN_USER`, `POSTGRES_PASSWORD`, `MAIL_ADMIN_PASSWORD`) and deploys `compose-gitlab.yml`. The first deploy seeds itself; the CI can poll `maild_provision` to confirm readiness. |

## Manual mode (AUTO_PROVISION=no)

If you set `AUTO_PROVISION=no` the boot-time seeder is skipped and you seed the catalogue
yourself — useful for scripted deployments, air-gapped hosts, or when you want to choose the
administrator password at a specific moment:

1. Start the stack normally (`docker compose … up -d`). It comes up with an empty catalogue:
   no domain, no superadmin.
2. Run the seeder once inside the `api` container:

   ```sh
   docker compose -f docker-compose.yml exec api adminng.py --provision
   ```

   It creates `DEFAULT_DOMAIN`, the superadmin `MAIL_ADMIN_USER@DEFAULT_DOMAIN`, its mailbox
   (same password), the four default aliases and the `maild_provision` row. The password comes
   from `MAIL_ADMIN_PASSWORD`; if that is empty the command prints a generated one.
3. `--force` re-asserts the administrator password on an already provisioned catalogue:

   ```sh
   docker compose -f docker-compose.yml exec api adminng.py --provision --force
   ```

4. The amavis/mua/mta gates wait out `PROVISION_WAIT_TIMEOUT` (180s by default) in this mode
   before configuring themselves. To make that instant, restart them after step 2:
   `docker compose -f docker-compose.yml restart amavis mua mta`, then do [DKIM](#dkim).

## Upgrading the database (PostgreSQL major)

The catalogue can be moved to a newer PostgreSQL major (e.g. 15 → 18) with a full dump and a
restore into a freshly initialised cluster: the data directories are major-incompatible, so it is
never a plain image swap and never an in-place start. The step-by-step procedure, its caveats
(collation, the `--clean --if-exists` restore, the provisioning sentinel, downtime, secrets) and
the rollback path are in [`db_upgrade.md`](db_upgrade.md).

## Outbound throttle & abuse alerts (per-user)

Submission over `465`/`587` counts envelope recipients per SASL user over
`OUTBOUND_RATE_WINDOW` (1 hour by default); past `OUTBOUND_RATE_RECIPIENTS` (200
recipients/user/hour by default, `0` disables the throttle) Postfix defers the extra
recipients with `450 4.7.1` until the window frees up. This protects your IP reputation,
it is not a malfunction:

- To exempt a notification/list sender (hard bypass, from any IP) list its account in
  `OUTBOUND_RATE_EXEMPT_USERS` (comma-separated). An exempt account still cannot spoof
  other senders.
- Every throttle engagement is logged as a greppable
  `maild-ratelimit: throttled user=...` line in the `mta` logs.
- The throttle daemon **fails open by contract**: if it dies it stops no mail, but the
  `mta` healthcheck goes unhealthy (it probes the throttle) and the entrypoint keeps
  restarting it until you look.
- Additionally, the `cron` container mails the administrator an hourly `[ALERT]` (at :23)
  for each user/day past `OUTBOUND_ALERT_MESSAGES` (150 messages/day/user, `0` = off),
  honouring `OUTBOUND_ALERT_IGNORE_USERS` (accounts never alerted on). If you run a
  high-volume list relay, raise these limits or exempt the sender accounts.

On inbound `25` (unauthenticated) a recipient-enumeration attempt is **tarpitted**: the
connection stalls after invalid recipients on purpose — that pause is anti-abuse, not a
hung server.

## Tech details

- **Volumes:** all persistent data lives in Docker volumes (mail, catalogue, filters, certs).
- **SSL certs:** a self-signed cert is generated if no Let's Encrypt one is found (for the
  MTA/MDA); setting up Let's Encrypt is up to you.
- **Webmail:** SnappyMail is the default; swap/comment the `mua` service if you prefer another.
- **AdminNG:** the web admin (per-domain admins, CSV bulk import, audit trail) — see
  [AdminNG](#adminng-optional-but-recommended).
- **Maildir:** compatible with MailAD / Docker-MailAD; per-user maildirs live under a folder
  named after the domain, which eases migrations.

## AdminNG (optional but recommended)

The stack also ships **AdminNG**, a PWA-first admin interface served by the `adminng` container
and backed by the `api` container (`ADMINNG_DB` holds devices, sessions, TOTP seeds and the
audit trail). It is the only web administration UI — PostfixAdmin and its `admin` container
were retired in 2026-10 (see `Changelog.md`).

1. **Set `ADMINNG_SECRET_KEY`** in `.env` (`openssl rand -hex 32`) — replace the
   `change-me-openssl-rand-hex-32` placeholder, never ship it. It signs the AdminNG JWTs and
   encrypts the TOTP seeds; the stack refuses to start without the *variable*, and the API
   logs a warning for as long as the placeholder is still in place. Rotating it invalidates
   sessions and enrolled authenticators.
2. `docker compose up -d` exposes it at `https://adminng.<DEFAULT_DOMAIN>` (Traefik) — or the
   dev stack at <http://localhost:8083>.
3. **Approve the first browser from the server side** (there is no silent auto-approval):
   `docker compose exec api adminng.py --list-devices` then
   `docker compose exec api adminng.py --approve-device '<uuid>'`. The browser
   registers itself by signing in, then shows its device ID (and a short fingerprint) on the
   lock screen; verify the requester before approving. Approval is device-scoped: once the
   browser is approved, any admin may sign in from it.
4. The first superadmin login requires TOTP enrollment (QR + code). Domain admins without an
   enrolled authenticator sign in with their password (TOTP is mandatory for superadmins).
5. **Passkeys need the real hostname.** The image defaults
   (`ADMINNG_WEBAUTHN_RP_ID=localhost` and
   `ADMINNG_WEBAUTHN_ORIGINS=http://localhost:8083,https://localhost:8084`) are for the dev
   stack only: a browser refuses a passkey whose RP ID does not match the page's origin, so
   the login page silently keeps offering password + TOTP. For the production URLs add to
   `.env` and re-run `docker compose up -d`:

   ```sh
   ADMINNG_WEBAUTHN_RP_ID=adminng.maild.cu
   ADMINNG_WEBAUTHN_ORIGINS=https://adminng.maild.cu
   ```

   List every public origin (comma-separated, no spaces, include a non-default port); they
   must sit inside the RP ID's DNS suffix. Password + TOTP login works either way — this only
   enables the passkey flow.

Daily backups now include the AdminNG database (`maild_adminng_*.sql.gz`). Full details:
`adminng/README.md`, `adminng/doc/technical-draft.md`, `adminng/doc/plan.md`.

## Bonus: GitLab & Traefik

There is a sample `.gitlab-ci.yml` and `env.sample_gitlab` in the repo; the GitLab flow uses
`compose-gitlab.yml` (the pipeline sets `COMPOSE_FILE=compose-gitlab.yml` and the `IMG_*`
image variables). Every production compose file already carries the Traefik labels, so any
of them can sit behind a Traefik ingress. On a slow/restricted link pre-download build
sources and use the `local` Dockerfile variants.
