# Development Environment Setup

## Prerequisites

- Docker + compose v2; bash; openssl; curl; git.
- Free host ports: 25, 110, 143, 465, 587, 993, 995, 4190, 5432, 8081, 8082, 8083, 8084, 12345.
- A local `swaks` binary is handy: `.local/bin/swaks` (git-ignored dir).

## Quick start (one command)

```bash
./bootstrap-dev.sh
```

Idempotent. Creates `ldata/` dirs + self-signed certs + `env.dev`-driven stack, waits for
every dependency (bounded), provisions fixtures, writes `test.creds`, verifies the logins.
Re-run any time; `--help` lists all options.

### Useful bootstrap-dev.sh options

| Option | Effect |
|--------|--------|
| `--no-start` | assume the stack is already up, never call `up` |
| `--skip-verify` | skip the IMAP + admin-row verification |
| `--skip-clamav-wait` | do not wait for the first ~230 MB signature download |
| `--skip-default-domain` | only provision the test domain (`example.net`); exports `AUTO_PROVISION=no` for that run |
| `--domain` / `--users` | override the test domain / mailboxes (default `example.net`, `alice,bob,charlie,dylan`) |
| `--superadmin` | also make the test-domain admin a catalogue superadmin |
| `--rotate-creds` | new passwords even if `test.creds` exists |
| `--creds <file>` | different credentials file |

## Manual path (what bootstrap automates)

```bash
mkdir -p ldata/{db,vmail,spool,clamav,amavis,spamassassin,mua_web,logs,certs,dozzle,backups}
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout ldata/certs/mail.key -out ldata/certs/mail.crt \
  -subj "/C=JM/ST=Kingston/L=Kingston/O=MailD/OU=Dev/CN=mail.localhost"
openssl dhparam -out ldata/certs/RSA2048.pem 2048
# --env-file env.dev is MANDATORY on every up/build — see .agents/services/configuration.md
docker compose --env-file env.dev -f docker-compose-dev.yml up -d
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f
```

First-boot provisioning (fresh stacks): the dev stack shares production's default
`AUTO_PROVISION=yes`, so the `db` container creates the catalogue schema and the `api`
container seeds `sysadmin@DEFAULT_DOMAIN` by itself on the first boot (watch
`docker compose logs api`); `bootstrap-dev.sh` then re-asserts the `test.creds` passwords.
It seeds **only** `DEFAULT_DOMAIN` + the sentinel row (`maild_provision`, which `mta`/`mda`/
`amavis`/`mua` gate on) — the `example.net` fixtures, the vmail homes, the SnappyMail domain
configs and `test.creds` come from `bootstrap-dev.sh`. For a hand-seeded stack set
`AUTO_PROVISION=no` and run `docker compose exec api adminng.py --provision`.

## Access points (dev)

| Service | URL / address |
|---------|---------------|
| Webmail (mua) | http://localhost:8081 |
| AdminNG PWA | http://localhost:8083 |
| AdminNG PWA (TLS, dev) | https://localhost:8084 — LAN: `https://<lan-ip>:8084`; import `ldata/certs/adminng-ca.der` on the device first |
| Log viewer (dozzle) | http://localhost:8082 |
| PostgreSQL | localhost:5432 — user `maild`, db `mailddb` (+ `contacts`), password = `POSTGRES_PASSWORD` from `env.dev` |
| SMTP / SMTPS / Submission | localhost:25 / 465 / 587 |
| POP3 / IMAP / TLS | 110 / 143 / 993 / 995 |
| ManageSieve | 4190 |

## Fixtures

`test.creds` (mode 0600, git-ignored) holds the password of every provisioned mailbox:
`sysadmin@<DEFAULT_DOMAIN>` (catalogue superadmin), `alice|bob|charlie|dylan@example.net`
(alice is the domain admin of example.net; bob carries the 5 MB quota fixture). The same
password works over IMAP/SMTP and in AdminNG (the dev fixtures stay on md5crypt `$1$…` on
purpose; the AdminNG API verifies legacy hashes until the 2027-02-01 removal).

## Dev vs production

| Aspect | Development | Production |
|--------|-------------|------------|
| Compose file | `docker-compose-dev.yml` | `docker-compose.yml` (external net `maild`, Traefik in front) |
| Env source | `env.dev` (interpolation + `env_file`); image `ENV` defaults behind it | `.env` (interpolation + `env_file`); image `ENV` defaults behind it |
| Volumes | `./ldata/*` bind mounts | named volumes (`/var/backups/maild` for dumps) |
| Images | `pavelmc/maild-*:develop`, built locally | CI-published tags |
| Ports | everything exposed for debugging | 25/465/587, 993/995; UIs behind Traefik |
| Logging | JSON to stdout (`docker compose logs`, dozzle) | syslog driver → host rsyslog (needed by `resume.sh`) |
| Restart policy | `unless-stopped` | `always` |

## Safety rules

1. Never run the production compose file locally; never touch production data from dev.
2. `ldata/` is disposable in dev: `down` → `rm -rf ldata/` → re-run bootstrap. Never delete
   production volumes like that.
3. `ldata/vmail` must be owned by uid/gid 5000, `ldata/mua_web` by `www-data` — bootstrap
   repairs both; `sudo chown -R 5000:5000 ldata/vmail` if you create them by hand.
4. Never commit secrets/certs (`.env`, `test.creds`, `ldata/`, `*.log`, `.local/` are
   git-ignored). Warn loudly if any are staged.

## Reset everything

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml down
sudo rm -rf ldata/
./bootstrap-dev.sh
```
