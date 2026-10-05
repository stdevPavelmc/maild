# AGENTS.md — MailD Project Instructions for AI Agents

MailD is a Docker-based complete mail server (derived from MailAD) that replaces the LDAP
backend with **PostgreSQL**: Postfix (SMTP), Dovecot (IMAP/POP3/Sieve), Amavis + ClamAV
(content filtering), PostfixAdmin (web admin), SnappyMail (webmail) and a cron container
for maintenance jobs.

## Quick Reference

| Service  | Role                                              | Dev ports                 |
|----------|---------------------------------------------------|---------------------------|
| `db`     | PostgreSQL catalogue (domains, users, aliases…)   | 5432                      |
| `mta`    | Postfix — SMTP in/out                             | 25, 465, 587              |
| `mda`    | Dovecot — IMAP/POP3/Sieve, mail delivery          | 110, 143, 993, 995, 4190  |
| `amavis` | Content filter (spam + AV relay, DKIM signing)    | 10024                     |
| `clamav` | ClamAV antivirus engine                           | 3310                      |
| `admin`  | PostfixAdmin web admin UI                         | 8080                      |
| `mua`    | SnappyMail webmail                                | 8081                      |
| `cron`   | Scheduled jobs: db backup, traffic resume, SA…    | —                         |
| `dozzle` | Dev-only live container log viewer                | 8082                      |

## Core Principles — never break these

- **Never rename service hostnames** (`db`, `mta`, `mda`, `amavis`, `clamav`, `admin`,
  `mua`, `cron`) — they are hardcoded across entrypoints, Postfix/Dovecot/Amavis config
  and the test suite.
- **Never change the database schema** without a migration script. `db/ensure_databases.sh`
  only *creates missing* databases (`POSTGRES_EXTRA_DB`); it never alters existing ones.
- **Environment variable names are immutable** across the chain:
  `env.dev` (dev) / `.env` (prod) → compose interpolation → `vars/*.env` → container templates.
- **Never commit secrets.** `.env`, `test.creds`, `ldata/`, `*.log` and `.local/` are
  git-ignored; `env.dev` carries *fake* committed dev secrets on purpose. Warn the user if
  real passwords/certs are about to be committed.
- **First-boot provisioning is sentinel-driven.** `admin/seed.sh` seeds the catalogue and
  writes the `maild_provision` row; `amavis`/`mua`/`mta` wait on it before their config
  stage (no manual `setup.php`, no stack restart). Keep the seeder idempotent and
  non-destructive, and keep `AUTO_PROVISION=no` working as the manual fallback.
- Local work **always** uses `docker-compose-dev.yml`; never run the production
  `docker-compose.yml` locally.
- Every compose command that creates containers **must** pass `--env-file env.dev`
  (compose does *not* interpolate `env_file:` contents; without the flag the db password
  drifts from the one the volume was initialised with).

## Fast lane (local dev)

```bash
./bootstrap-dev.sh                       # provision + start the dev stack with fixtures (idempotent)
./test.sh                                # black-box acceptance suite (43 checks) against the fixtures
./test.sh --skip-content --skip-quota    # faster subset (skip AV/SPAM and the quota fixture)
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f mta
```

- `bootstrap-dev.sh` provisions: `ldata/` dirs, self-signed certs, and the test fixtures —
  `DEFAULT_DOMAIN` (`sysadmin@<domain>`, the PostfixAdmin superadmin) plus `example.net`
  (`alice`, `bob`, `charlie`, `dylan`, `alice` as domain admin, default aliases), a quota
  fixture on `bob@`, and `test.creds` (mode 0600, git-ignored) with every password.
  Idempotent; refuses to run against a stack built with different secrets.
- `test.sh` covers: SMTP policy (25/465/587, two open-relay negatives), TLS/AUTH, aliases
  and plus-addressing, IMAP/POP3 read-back, EICAR/GTUBE/banned-attachment filtering,
  mailbox quota (552 at RCPT, NDR, warnings), Sieve redirect, DKIM and the cron jobs
  (db backup + daily traffic resume).

## Debugging (details: .agents/devops/workflows.md)

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f <svc>   # or dozzle :8082
docker compose --env-file env.dev -f docker-compose-dev.yml exec mta bash   # shell in
docker compose --env-file env.dev -f docker-compose-dev.yml exec mta /check.sh   # health
```

- Fixture mailboxes: `alice|bob|charlie|dylan@example.net` (+ `sysadmin@maild.cu`);
  passwords in `test.creds`. The same password works over IMAP/SMTP and the PostfixAdmin UI.
- A local `swaks` binary lives at `.local/bin/swaks` (git-ignored).

## Detailed documentation

| File | Content |
|------|---------|
| `.agents/architecture/overview.md` | System map, mail flow, startup order, data layout, entrypoints, healthchecks, cron schedule |
| `.agents/services/catalog.md` | Per-service roles, ports, volumes, env_file lists, cold-start expectations |
| `.agents/services/provisioning.md` | First-boot provisioning: sentinel, leader/worker gate, the `PROVISION_*`/`MAIL_ADMIN_PASSWORD` variables, operations |
| `.agents/services/configuration.md` | Env chain (`env.dev`/`.env` → compose → `vars/` → templates), adding a variable, DB schema changes |
| `.agents/devops/base-images.md` | Base images (canonical rules + current drift), Dockerfile order, OCI LABELS, pre-commit hook |
| `.agents/devops/environment-setup.md` | Prerequisites, `bootstrap-dev.sh` reference, access points, reset, safety rules |
| `.agents/devops/workflows.md` | Build/run/debug commands, per-service debugging, test suite, git guidelines |

**Doc rule:** any change to services, ports, env vars, entrypoints, base images or the dev
workflow must update the matching `.agents/` file in the same commit.

## Getting help

- Project docs: `README.md`, `INSTALL.md`, `DEV-SETUP.md`, `Changelog.md`
- Config reference: `env.sample` (every variable commented) and `vars/*.env`
- Telegram group: https://t.me/MailAD_dev — Issues: GitHub issues
