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
  `/check.sh`; admin/mua: `curl -f localhost`; api: `GET /health` with the adminng DB
  answering; adminng: `wget /`). `ps` shows the status.
- **Env inside a container:** `… exec mta env | sort`.
- **DB:** `… exec db pg_isready`; psql session: `… exec db psql -U maild -d mailddb`;
  connectivity from a service: `… exec mda nc -z db 5432`, or `… exec mta getent hosts db`
  anywhere (the mta image does not ship `nc`: nothing in it needed netcat, unlike the amavis,
  clamav and mda healthchecks).
- **AdminNG:** the PWA is on http://localhost:8083 (nginx serves it and proxies `/api/v1/`
  to `api`); `… logs -f adminng api` for its two halves; the adminng DB is
  `… exec db psql -U maild -d adminng`; browsers are authorized from the server side with
  `… exec api adminng.py --list-devices` / `--approve-device <uuid>` (see
  `adminng/README.md`). Health through the proxy: `curl -sf localhost:8083/api/v1/health`.
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
- **Webmail plugins:** the baseline is `MUA_PLUGINS` (downloaded at build, copied from the image
  into the volume on every boot). What is installed vs enabled:
  `… exec mua ls /var/www/html/data/_data_/_default_/plugins/` and
  `… exec mua grep -A3 '\[plugins\]' /var/www/html/data/_data_/_default_/configs/application.ini`.
- **Mailbox password change:** the webmail's *Settings → Password* runs the `change-password`
  plugin against MailD's own driver (`mua/plugins/change-password-maild/`). Verify a password
  with `… exec mda doveadm auth test <user> '<password>'` (mind the auth cache, below) or a real
  IMAP login: `curl --insecure -u '<user>:<password>' imaps://localhost:993/ -X 'LIST "" "INBOX"'`.
- **Webmail admin panel (`/?admin`):** the entrypoint prints the credentials at boot —
  `… logs mua | grep -A3 'admin panel'`. The login is `MUA_ADMIN_USER` (`maild` by default) and
  the password is the OTP shown there (generated on the first boot, kept in the data volume;
  `MUA_ADMIN_PASSWORD` pins it). If the banner says `unchanged, set from the admin panel`, the
  password is the one somebody set in the UI. Quick check that the config is intact:
  `… exec mua php -r 'var_dump(parse_ini_file("/var/www/html/data/_data_/_default_/configs/application.ini", true) !== false);'`.

## Common issues

- **Mail not flowing on a cold stack:** ClamAV is downloading signatures (~230 MB first
  boot) and amavis defers everything until clamd answers. `logs -f clamav`; on restricted
  networks set `ALTERNATE_MIRROR` in the operator env file (`env.dev`/`.env`).
- **Admin UI unreachable but container healthy:** dev publishes `8080:80` — check you did
  not remap it to `8080:8080` (Apache listens on 80 in the image).
- **The old password still authenticates after a change (or `doveadm auth test` disagrees with the
  webmail):** Dovecot caches auth results for `auth_cache_ttl` — **1 minute** in MailD
  (`auth_cache_negative_ttl = 0`, both in `mda/dovecot/conf.d/10-auth.conf`). A password that was
  valid seconds ago can therefore still log in for up to a minute; the new one is always accepted
  immediately, and using it refreshes the cache. `… exec mda doveadm auth cache flush` clears it
  on the spot. (Before 1.4.0-rc the TTLs were Dovecot's defaults — 10 min / 1 h — which made an
  old password look alive for ten minutes and could lock a user out of a password he had mistyped
  before adopting it.)
- **A webmail plugin is gone/disabled after a boot:** the baseline is `MUA_PLUGINS` (see above) —
  the entrypoint re-enables it on every boot, so disable it there *and* in the admin panel. The
  plugin *settings* (`configs/plugin-*.json`) are never touched by the boot.
- **Webmail 403 / no per-domain configs:** the mua volume must only cover
  `/var/www/html/data` and be owned by `www-data` — never mount over `/var/www/html`. The
  entrypoint waits (bounded, `MUA_CONFIG_WAIT_TIMEOUT`) for SnappyMail to write
  `application.ini`; the `WARNING: SnappyMail did not create …` line means that volume is not
  writable.
- **`/?admin` rejects the OTP from the logs:** the SnappyMail config did not parse, so the app
  fell back to its factory defaults and minted a password of its own (`AuthError[102]`).
  `config-setup.php` now reports the credentials it stored (`MUA_ADMIN_PASSWORD_SOURCE` in
  `docker compose logs mua`) and validates the file, rolling it back if it is damaged — check
  that log line first, and set `MUA_ADMIN_PASSWORD` + restart `mua` to get a known password.
- **Auth works, delivery loops:** the mta still points at a dead mda IP — restart the mta.
- **Secret drift:** created the stack without `--env-file env.dev`? Postgres honours its
  password only on first init: `down` → `rm -rf ldata/` → bootstrap again.
- **Port conflicts on the host:** `ss -tulpn | grep -E ':(25|465|587|993|995|5432|8080|8081|8082)\b'`.

## Test suite

```bash
./bootstrap-dev.sh        # once, or after ldata/ reset — provisions test.creds
./test.sh                 # 76 checks
./test.sh --skip-content  # skip EICAR/GTUBE/banned (needs the ClamAV db ready)
./test.sh --skip-quota    # skip the self-cleaning bob@ quota fixture
./test.sh --skip-docker   # wire-level only (no `docker compose exec` assertions)
./test.sh --debug         # trace every step to ./test-debug.log (contains passwords!)
```

- Reads `test.creds`; overridable via env (`DOMAIN`, `ADMINMAIL`, `PASS`, `SERVER`, `FROM`,
  `RELAY_PROBE_DOMAIN`).
- Beyond the mail path it exercises the SpamAssassin chain: the daily Bayes learning job (run
  twice, so its `flock` release is proven), the imapsieve Junk-move learning trigger (a real
  IMAP COPY) and the `sa-update` loop with the rules it maintains (`spamassassin --lint` plus
  the `.pre` family of the installed major).
- Self-cleaning: quota fixture, sieve scripts and the materialised `/var/log/syslog` are
  restored/removed on exit; transcripts append to `./test.log` (git-ignored).
- Exit code 0 only when every executed check passed. Run the full suite before merging
  changes to mta/mda/amavis/cron/config generation.

## AdminNG browser suite (Playwright + Lighthouse)

The PWA has its own gates. They run in the dev-only `pwa-test` container
(`adminng/pwa-test/`), which carries the pinned Playwright + Chromium and Lighthouse, so
neither the host nor CI needs Node, a browser or `npx playwright install`:

```bash
./adminng/pwa-test/run.sh verify        # flows + installability + Lighthouse budget (the gate)
./adminng/pwa-test/run.sh flows         # one spec (flows | installable | superadmin)
./adminng/pwa-test/run.sh superadmin    # TOTP login (enrolls only on first run) + devices panel
./adminng/pwa-test/run.sh a11y          # axe-core WCAG 2.1 A/AA audit, JSON per screen
./adminng/pwa-test/run.sh visual        # PNG screenshots: desktop/mobile, EN/ES
./adminng/pwa-test/run.sh lighthouse
./adminng/pwa-test/run.sh shell         # interactive shell inside the harness image
cd adminng/pwa && npm run i18n:check    # en/es parity; also inside `npm run build`
```

- The service is dev-only (`profiles: ["test"]` in `docker-compose-dev.yml`); `up` never
  starts it and it is absent from the production compose files. `run.sh` maps the invoking
  uid/gid, so everything under `ldata/e2e/` stays host-owned.
- Inside the container the entrypoint tunnels `http://localhost:8083` to `http://adminng:80`.
  `localhost` is a secure context, so the service worker / installability / offline
  assertions behave exactly as on the host or against a real deployment.
- Device approval stays out of band: the suite drives
  `adminng.py --approve-device <id>` in the api container (`docker exec`, socket
  mounted by the dev compose file). The other specs cover the UI path (devices panel, re-auth +
  armed authorize).
- The superadmin helpers **never reset the TOTP credential**: they read the enrolled seed with
  `tests/totp_code.py` (the same helper `test.sh` uses) and only enroll when the API asks for it,
  so an authenticator enrolled on a phone survives `verify`/`superadmin`/`a11y`/`visual`. A
  consumed 30 s step is retried once with the next one.
- `tests/flows.spec.ts` (one context, stepped): pending device → CLI approval → login as
  `alice@example.net` → create an account → delete it with the re-auth + 5 s armed button →
  domain scope → ES/EN switch → offline banner with the FAB disabled.
- `tests/installable.spec.ts`: manifest fields, active service worker controlling the page
  and the app booting from the cache offline.
- `lighthouse.mjs`: performance ≥ 0.85, accessibility ≥ 0.9, best-practices ≥ 0.9; SEO is
  reported only (a private panel disallows crawling in `public/robots.txt`).
- Artifacts: `ldata/e2e/{report,results,screens,a11y,lighthouse.report.{json,html}}`.
- The suite is destructive to the fixtures it creates (accounts are deleted, devices stay
  approved); it never touches existing mailboxes.
- CI: `.github/workflows/pwa-e2e.yml`, `workflow_dispatch` only (builds the ten dev images).


## AdminNG Android APK (Phase 4)

`adminng/pwa/app-generate.sh` wraps the PWA in a signed TWA APK, fully in Docker:

```bash
cd adminng/pwa
./keystore-generate.sh                               # dev/test key -> android.keystore + .b64
APP_URL=https://adminng.example.com APP_PKG=cu.maild.adminng \
KEYSTORE=/path/android.keystore KEY_ALIAS=maild-apk \
KEY_PASSWORD=… STORE_PASSWORD=… ./app-generate.sh   # -> dist/android/<pkg>-<version>.apk
```

- `keystore-generate.sh` prints the exact `KEYSTORE/KEY_ALIAS/KEY_{,STORE_}PASSWORD` exports and
  the base64 for the `KEYSTORE_BASE64` CI secret. It needs `keytool` (JDK) or Docker; production
  keys must be generated on a trusted machine and backed up.
- The build writes `twa-manifest.json` and drives Bubblewrap's `update` + `build` from inside
  `android-project/`; the signing passwords go through
  `BUBBLEWRAP_KEYSTORE_PASSWORD`/`BUBBLEWRAP_KEY_PASSWORD`.
- Toolchain: `adminng/pwa/Dockerfile.android` (JDK 17, SDK 36 + build-tools 36.1, Bubblewrap).
  The Gradle and SDK caches are the named volumes `maild-adminng-apk-gradle` /
  `maild-adminng-apk-sdk`; the SDK volume is seeded from the image and survives runtime installs.
- If the IPv4 route to `dl.google.com` is filtered (404 while IPv6 works), add
  `DOCKER_NETWORK=host JAVA_TOOL_OPTIONS=-Djava.net.preferIPv6Addresses=true`.
- LAN/phone APK build (HTTPS on dev port 8084 with the local CA):
  `APP_URL=https://<lan-ip>:8084 APP_CA_CERT=ldata/certs/adminng-ca.crt … ./app-generate.sh`.
  `adminng/pwa/tls-cert-generate.sh` (or `bootstrap-dev.sh`) creates
  `ldata/certs/adminng-{ca,}.crt`; install `adminng-ca.der` on the phone first. The APK runs as
  a Custom Tab on an IP origin (Digital Asset Links need a DNS name).
- The `APP_URL` host must be in the leaf certificate **SAN**, not just trusted: the generator
  lists the host name, `localhost` and **every global IPv4** (multi-NIC hosts have several). If
  a NIC/LAN IP changed after the leaf was issued, Chrome/Node fail with
  `ERR_TLS_CERT_ALTNAME_INVALID`; re-issue the leaf against the same CA and restart the listener:
  `cd adminng/pwa && RENEW=1 ./tls-cert-generate.sh --ip <lan-ip>` then
  `docker compose --env-file env.dev -f docker-compose-dev.yml restart adminng`.
- Artifacts are git-ignored (`adminng/pwa/dist/`, `android-project/`, `twa-manifest.json`,
  `*.keystore*`).
- CI: `.github/workflows/android-apk.yml` runs the script with the keystore secrets.
- Full runbook: [`adminng/pwa/README.md`](../../adminng/pwa/README.md) (keystore lifecycle,
  network/IPv6 workaround, troubleshooting).

## GitHub Actions CI

`.github/workflows/docker-image.yml` runs on `develop`/`main` (push + pull request). It is a
**single job with three ordered, gated phases** — a step only runs when every previous step
succeeded, which is how "phase 2 only if phase 1 passed" is enforced:

1. **Validate, build and test** — runs on *every* event, including pull requests:
   validate all four compose files (`docker compose config -q`), build the `:develop` images,
   run `./bootstrap-dev.sh` (brings the stack up, waits for db/schema/HTTP/ClamAV readiness,
   provisions the fixtures and writes `test.creds`) and then run `./test.sh`.
   The job installs `swaks` + `libnet-ssleay-perl` first: `test.sh`'s no-root fallback
   unpacks only the swaks script and cannot do TLS, which fails every 465/587 and
   authenticated check.
   `config` also resolves every `env_file:`, and the production files list the git-ignored
   `.env`, so the job first materialises a throwaway `.env` from `env.sample`;
   `compose-gitlab.yml` is validated with placeholder `IMG_*`/`TAG`.
2. **Push images** — `push` events only, only if phase 1 passed: retag the local `:develop`
   images for `pavelmc/maild-<svc>` (Docker Hub) and `ghcr.io/stdevpavelmc/maild-<svc>` and
   push them as `:develop` on `develop` or `:latest` on `main`.
3. **Version tag** — `push` to `main` only, only if phases 1-2 passed: tag the `:latest`
   images with the `VERSION` file value (e.g. `1.3.0-rc`) and push them to both registries.

PRs never log into a registry nor push. Secrets: `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN`
(Docker Hub) and the automatic `GITHUB_TOKEN` (ghcr.io). The images are built once and only
retagged, so all three phases must stay in the **same job** — separate jobs run on different
runners and could not see the locally built images.

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
