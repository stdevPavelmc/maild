# Workflows — Build, Run, Debug, Test

Every command below assumes the repo root. Anything that creates containers needs
`--env-file env.dev` (alias it if you like: `dc()='docker compose --env-file env.dev -f docker-compose-dev.yml'`).

## Building & running

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml build            # all
docker compose --env-file env.dev -f docker-compose-dev.yml build mta        # one service
docker compose --env-file env.dev -f docker-compose-dev.yml build --no-cache mta
docker compose --env-file env.dev -f docker-compose-dev.yml up -d            # start all
docker compose --env-file env.dev -f docker-compose-dev.yml up -d mta        # start one
docker compose --env-file env.dev -f docker-compose-dev.yml restart mta
docker compose --env-file env.dev -f docker-compose-dev.yml down
```

After recreating `mda` (new IP!) restart `mta` too — it bakes `virtual_transport =
lmtp:inet:<mda-ip>:24` into `main.cf` at start.

## Debugging

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml ps
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f mta mda amavis
docker compose --env-file env.dev -f docker-compose-dev.yml exec mta bash
docker compose --env-file env.dev -f docker-compose-dev.yml exec mta /check.sh
```

- **Logs:** every service logs to stdout (`maillog_file = /dev/stdout` on the mta);
  `docker compose logs` or the dozzle UI on http://localhost:8082.
- **Health:** each image carries a `HEALTHCHECK` (db: `pg_isready`; mta/mda/amavis/clamav:
  `/check.sh`; admin/mua: `curl -f localhost`). `ps` shows the status.
- **Env inside a container:** `… exec mta env | sort`.
- **DB:** `… exec db pg_isready`; psql session: `… exec db psql -U maild -d mailddb`;
  connectivity from a service: `… exec mta nc -z db 5432` (or `getent hosts db`).
- **Mailboxes:** Maildir under `ldata/vmail/` — `find ldata/vmail -name cur -o -name new`;
  `… exec mda doveadm auth test alice@example.net '<pw>'`;
  `… exec mda doveadm quota get -A`.
- **Content filter:** quarantine in `ldata/amavis/virusmails/`; test with EICAR as an
  **attachment** (byte-exact file only) and the GTUBE string in a body; clamd probe:
  `nc -z localhost 3310`.
- **Mail flow by hand:** `.local/bin/swaks --to alice@example.net --server localhost:587
  --tls --auth-user alice@example.net --auth-password <pw>`.
- **Cron jobs by hand:** `… exec cron /scripts/backup_db.sh`;
  `… exec cron /scripts/resume.sh today`;
  `… exec mda /scripts/quota_report.sh --now --dry-run`.

## Common issues

- **Mail not flowing on a cold stack:** ClamAV is downloading signatures (~230 MB first
  boot) and amavis defers everything until clamd answers. `logs -f clamav`; on restricted
  networks set `ALTERNATE_MIRROR` in `vars/clamav.env`.
- **Admin UI unreachable but container healthy:** dev publishes `8080:80` — check you did
  not remap it to `8080:8080` (Apache listens on 80 in the image).
- **Webmail 403 / entrypoint stuck on `admin_password.txt`:** the mua volume must only
  cover `/var/www/html/data` and be owned by `www-data` — never mount over `/var/www/html`.
- **Auth works, delivery loops:** the mta still points at a dead mda IP — restart the mta.
- **Secret drift:** created the stack without `--env-file env.dev`? Postgres honours its
  password only on first init: `down` → `rm -rf ldata/` → bootstrap again.
- **Port conflicts on the host:** `ss -tulpn | grep -E ':(25|465|587|993|995|5432|8080|8081|8082)\b'`.

## Test suite

```bash
./bootstrap-dev.sh        # once, or after ldata/ reset — provisions test.creds
./test.sh                 # 43 checks
./test.sh --skip-content  # skip EICAR/GTUBE/banned (needs the ClamAV db ready)
./test.sh --skip-quota    # skip the self-cleaning bob@ quota fixture
./test.sh --skip-docker   # wire-level only (no `docker compose exec` assertions)
./test.sh --debug         # trace every step to ./test-debug.log (contains passwords!)
```

- Reads `test.creds`; overridable via env (`DOMAIN`, `ADMINMAIL`, `PASS`, `SERVER`, `FROM`,
  `RELAY_PROBE_DOMAIN`).
- Self-cleaning: quota fixture, sieve scripts and the materialised `/var/log/syslog` are
  restored/removed on exit; transcripts append to `./test.log` (git-ignored).
- Exit code 0 only when every executed check passed. Run the full suite before merging
  changes to mta/mda/amavis/cron/config generation.

## Code & git guidelines

- Shell scripts (bash) for configuration/automation; templates use `_${VAR}_`.
- Follow the Dockerfile order + OCI label rules: `.agents/devops/base-images.md`.
- `.pre-commit` hook stamps `org.opencontainers.image.created` on modified Dockerfiles and
  copyright years on modified executables — install it:
  `cp .pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit`.
- **Compose chain:** mirror perdurable changes `docker-compose-dev.yml` →
  `docker-compose.yml`, then regenerate the strict copies `compose-github.yml` /
  `compose-gitlab.yml` (only the `image:` lines differ) — see `AGENTS.md → Core principles`
  and `.agents/services/configuration.md`.
- Feature branches; commit only when explicitly asked, never commit secrets; clear commit
  messages naming the touched service(s).
- Update the matching `.agents/` doc and `Changelog.md` in the same change.
