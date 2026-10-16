# Development Environment Setup

## Prerequisites

- Docker + compose v2; bash; openssl; curl; git.
- Free host ports: 25, 110, 143, 465, 587, 993, 995, 4190, 5432, 8080, 8081, 8082, 12345.
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
| `--skip-verify` | skip IMAP + web-login verification |
| `--skip-clamav-wait` | do not wait for the first ~230 MB signature download |
| `--skip-default-domain` | only provision the test domain (`example.net`) |
| `--domain` / `--users` | override the test domain / mailboxes (default `example.net`, `alice,bob,charlie,dylan`) |
| `--superadmin` | also make the test-domain admin a PostfixAdmin superadmin |
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

PostfixAdmin setup (fresh stacks): the dev stack shares production's default
`AUTO_PROVISION=yes`, so the `admin` container seeds `sysadmin@DEFAULT_DOMAIN` by itself on the
first boot (watch `docker compose logs admin`); `bootstrap-dev.sh` then re-asserts the
`test.creds` passwords. The classic OTP + `http://localhost:8080/setup.php` path is still there
when you set `AUTO_PROVISION=no`.

## Access points (dev)

| Service | URL / address |
|---------|---------------|
| Webmail (mua) | http://localhost:8081 |
| Admin (PostfixAdmin) | http://localhost:8080 |
| Log viewer (dozzle) | http://localhost:8082 |
| PostgreSQL | localhost:5432 — user `maild`, db `mailddb` (+ `contacts`), password = `POSTGRES_PASSWORD` from `env.dev` |
| SMTP / SMTPS / Submission | localhost:25 / 465 / 587 |
| POP3 / IMAP / TLS | 110 / 143 / 993 / 995 |
| ManageSieve | 4190 |

## Fixtures

`test.creds` (mode 0600, git-ignored) holds the password of every provisioned mailbox:
`sysadmin@<DEFAULT_DOMAIN>` (PostfixAdmin superadmin), `alice|bob|charlie|dylan@example.net`
(alice is the domain admin of example.net; bob carries the 5 MB quota fixture). The same
password works over IMAP/SMTP and the PostfixAdmin UI (md5crypt `$1$…`).

## Dev vs production

| Aspect | Development | Production |
|--------|-------------|------------|
| Compose file | `docker-compose-dev.yml` | `docker-compose.yml` (external net `maild`, Traefik in front) |
| Env source | `env.dev` + `env.sample` via `--env-file`/`env_file` | `.env` with real secrets |
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
