# Base OS Upgrade Playbook — Ubuntu LTS rollover for the core services

From time to time a new Ubuntu LTS goes stable and the core mail images must
move to it. This document is the step-by-step guidance for an agent doing that
move.

Scope: the five services built `FROM ubuntu:<codename>` today — `mta`, `mda`,
`amavis`, `clamav`, `cron`. Out of scope: `db` (`postgres:<major>-bookworm`),
`admin` / `mua` (`php:8.x-apache`). Those have their own upstream cadence and
their own upgrade path; do not bundle them into an Ubuntu LTS rollover.

Canonical base rule + current drift table: `.agents/devops/base-images.md`.
Env chain (`env.dev`/`.env` → compose → `vars/*.env` → `_<VAR>_` templates):
`.agents/services/configuration.md`. Build/run/test commands:
`.agents/devops/workflows.md`. Provisioning sentinel:
`.agents/services/provisioning.md`.

> **Naming in this doc:** `<tpl>` = the service template dir ("the service
> template files"), `<old>` / `<new>` = distro codenames (e.g. `jammy` →
> `resolute`).

## 0. Guardrails — never break these

1. **One docker service at a time, never all at once.** Finish + green
   `test.sh` on service N before touching service N+1.
2. **Local work only on `docker-compose-dev.yml` with `--env-file env.dev`.**
   Never run the production `docker-compose.yml` locally.
3. **Immutable identifiers:** service hostnames (`db`, `mta`, `mda`,
   `amavis`, `clamav`, `admin`, `mua`, `cron`), env var names, volume mount
   points. See `AGENTS.md → Core principles`.
4. **Never commit secrets.** `.env`, `test.creds`, `ldata/`, `*.log`,
   `.local/` are git-ignored. Warn loudly if any are staged.
5. **Feature branch per service** (e.g. `upgrade/mta-resolute`). Keep the
   pristine-extract commit separate from the ported-customizations commit so
   reviewers can `diff` them.
6. **Doc rule:** every landed service updates, in the same commit,
   `.agents/devops/base-images.md`, `Changelog.md`, and this file if the
   procedure itself changed.

## 1. Service order — dependency-aware, not alphabetical

`mda` and `cron` block at boot until `amavis` seeds the shared SpamAssassin
volume (`/etc/spamassassin/init.pre` + `maild.cf` + bayes dir); `mta` bakes
the live `mda`/`amavis` IPs into `main.cf` at start and hard-depends on
`mda`+`amavis`+`clamav`. Out-of-order upgrades boot against a stale volume
or dead IPs and produce phantom failures.

| Step | Service | Why this position |
|------|---------|-------------------|
| 1 | `clamav` | No upstream MailD deps; smallest template (`clamav/clamav/`); unblocks `amavis` AV path. |
| 2 | `amavis` | Seeds shared `saconf` volume (`/etc/spamassassin.dist` → `/etc/spamassassin/`, writes `maild.cf`). Must land before `mda`/`cron`. |
| 3a | `mda` | Waits on `amavis` volume (`while [ ! -f /etc/spamassassin/init.pre ]`). Needs the **new** amavis volume. |
| 3b | `cron` | Same wait on `amavis` volume; PGDG `postgresql-client` must track `db/Dockerfile`. Can go with `mda` once `amavis` is green. |
| 4 | `mta` | Last: hard-depends on `mda`, `amavis`, `clamav`. Restart after any `mda` recreate (LMTP IP bake). |

`db`, `admin`, `mua` are not part of this sequence.

## 2. Template inventory — what gets archived and re-extracted

| Service | Template dir(s) | Archive example | Never archive (logic, not distro files) |
|---------|-----------------|-----------------|------------------------------------------|
| `mta` | `mta/postfix/` (`main.cf.s`, `master.cf.s`, `pgsql/`, `rules/`, `aliases/`, `bounce.*.cf`, `postfix-openssl.cnf`) | `mta/postfix-jammy/` | `Dockerfile`, `docker-entrypoint.sh`, `check.sh` |
| `mda` | `mda/dovecot/` (`dovecot.conf`, `conf.d/`, `dovecot-sql.conf.ext`, `dovecot-openssl.cnf`) | `mda/dovecot-jammy/` | `sieve-pipe/`, `scripts/`, `dovecot/sieve/*.sieve` (MailD-owned, copy over — see §3.3), `configure.sh`, entrypoint, `check.sh` |
| `amavis` | `amavis/amavis/` (`conf.default/`, `en_US/`) + `amavis/spamassassin/` (`*.pre`, `*.cf`, `local.cf`, `sa-update-hooks.d/`) | `amavis/amavis-jammy/` + `amavis/spamassassin-jammy/` | `docker-entrypoint.sh`, `check.sh`, `sa-update-loop.sh` |
| `clamav` | `clamav/clamav/` (`clamd.conf`, `freshclam.conf`) | `clamav/clamav-jammy/` | `docker-entrypoint.sh`, `check.sh` |
| `cron` | `cron/spamassassin/` (maintenance script, must match **new** amavis) | `cron/spamassassin-jammy/` | `crontab`, `scripts/*`, `docker-entrypoint.sh` |

Keep archives in-tree until **all five** services are on the new LTS and the
full suite is green; then delete them in one cleanup commit. They are the
side-by-side reference for `diff -r <tpl>-<old> <tpl>`.

## 3. Per-service procedure

### 3.0 Prep — baselines before touching anything

```bash
git status --short   # must be clean
git checkout -b upgrade/<svc>-<new-codename>
grep -H '^FROM' <svc>/Dockerfile
docker compose --env-file env.dev -f docker-compose-dev.yml exec <svc> dpkg -l | grep -E 'postfix|dovecot|amavis|clamav|spamassassin|postgresql-client' || true
# mta: postconf -n | mda: doveconf -n | amavis: /usr/sbin/amavisd-new test-config
```

Record old codename, old `FROM`, and package versions for the §7 doc updates.

### 3.1 Archive the current templates

```bash
mv mta/postfix mta/postfix-jammy
# adjust per §2 table, e.g. mv amavis/amavis amavis/amavis-jammy && mv amavis/spamassassin amavis/spamassassin-jammy
git add -A && git commit -m "<svc>: archive <tpl> templates from <old> before <new> upgrade"
```

Do not edit the archive afterwards — it is the read-only reference.

### 3.2 Extract pristine templates from the target base

Pull the target and install **exactly the package list in `<svc>/Dockerfile`**:

```bash
docker pull ubuntu:<new-codename>
docker run --rm -it --name tpl-<svc>-<new> ubuntu:<new-codename> bash
# inside the temp container:
apt-get update && apt-get install -y <packages from Dockerfile>
# mta: postfix postfix-pcre postfix-pgsql postfix-policyd-spf-python
# mda: dovecot-pop3d dovecot-imapd dovecot-pgsql dovecot-sieve dovecot-lmtpd dovecot-managesieved spamassassin python3
# amavis: amavisd-new p7zip-full unrar-free cabextract spamassassin gpg
# clamav: clamav-daemon clamav-freshclam libclamunrar12
# cron: swaks pflogsumm bind9-host spamassassin cron ca-certificates (+ PGDG postgresql-client-<MAJOR>, see box)
```

Copy out from a second shell (locate conffiles first with
`dpkg -L <pkg> | grep /etc` inside the temp container):

```bash
docker cp tpl-<svc>-<new>:/etc/postfix ./mta/postfix
docker cp tpl-<svc>-<new>:/etc/dovecot ./mda/dovecot
docker cp tpl-<svc>-<new>:/etc/amavis ./amavis/amavis-pristine
docker cp tpl-<svc>-<new>:/etc/spamassassin ./amavis/spamassassin
docker cp tpl-<svc>-<new>:/etc/clamav ./clamav/clamav
```

Rearrange to the exact in-repo layout (`conf.default/` vs `conf.d/`,
`spamassassin.dist` staging, permissions) by comparing with the
`<svc>/Dockerfile` `COPY`/`ADD` lines. Commit pristine as-is first:

```bash
git add -A && git commit -m "<svc>: pristine <tpl> templates from ubuntu:<new>"
```

> **`cron` PGDG special case.** `cron/Dockerfile` installs
> `postgresql-client-${PG_CLIENT_MAJOR}` from the PGDG repo because Ubuntu
> LTS ships an older client than `db/Dockerfile`'s server
> (`postgres:<major>`). Bump `ARG PG_CLIENT_MAJOR` + `ARG PGDG_SUITE`
> (`<new-codename>-pgdg`) together — `cron/scripts/backup_db.sh` checks the
> pair at runtime, and an older client once wrote a ~20-byte empty dump it
> reported as SUCCESS. Verify with `pg_dump --version` in the built image.

> **Package-name traps on `resolute` (measured on the `clamav` step; they apply to
> every service).** `netcat` is a *virtual* package with two providers
> (`netcat-openbsd` in `main`, `netcat-traditional` in `universe`) and apt refuses
> to choose: `E: Package 'netcat' has no installation candidate`. Install
> `netcat-openbsd` explicitly. `libclamunrar9` no longer exists either — `clamav`
> takes `libclamunrar12` (multiverse; the base image enables
> `main universe restricted multiverse`, so it resolves). `clamav` is fixed;
> `mta`, `mda` and `amavis` still install `netcat` and will hit the same wall.

> **Dynamic service uid/gid drift.** Debian/Ubuntu allocate `clamav` (and the
> other service users) dynamically from the 100–999 range: jammy landed on
> `101:102`, resolute on `100:101`. The dev testbed owns `ldata/clamav` as
> `101:102` (`bootstrap-dev.sh`) and each image runs `USER <svc>`, so a landed
> service **must pin the ids in its Dockerfile** (`groupmod`/`usermod`) whenever
> they drift — otherwise clamd cannot read its signature database and the
> healthcheck plus every content-filter check fails. Check with `id clamav` in a
> throwaway container built from the target base, before porting.

### 3.3 Port the MailD customizations (the core of the job)

1. Inventory every MailD placeholder in the archive:
   `grep -rn '_[A-Z][A-Z_]*_' <tpl>-<old>/ | sort | uniq -c | sort -rn`.
   Cross-check against the producers: `<svc>/docker-entrypoint.sh`
   (+ `mda/configure.sh`) `CFILE` construction and `vars/<svc>.env`.
2. `diff -r <tpl>-<old> <tpl>` (old-customized vs new-pristine). For each
   hunk decide: **re-apply** (MailD logic), **drop** (obsolete distro
   default), or **adapt** (directive renamed/moved).
3. MailD-owned files — copy over verbatim, then re-check placeholders:
   `mta/postfix/rules/*`, `mta/postfix/pgsql/*`, `mta/postfix/aliases/*`,
   `mta/postfix/bounce.*.cf`, `mda/dovecot/sieve/*.sieve`,
   `cron/crontab`, `cron/scripts/*`. Never copy a whole pristine file away
   — merge hunk by hunk.
4. On a logic clash (directive removed/renamed/changed semantics, new
   required stanza): check `man <conf>` in the temp container,
   `/usr/share/doc/<pkg>/changelog*` + `NEWS.Debian.gz`, and upstream
   release notes via web search. If two readings remain plausible, **stop
   and ask the user** — do not guess on mail-routing, TLS, auth, or
   content-filter semantics.
5. Preserve the `_<VAR>_` spelling exactly (leading + trailing underscore):
   the entrypoint `sed s/"\_${v}\_"/.../g` only matches that form.

```bash
git add -A && git commit -m "<svc>: port MailD customizations onto ubuntu:<new> templates"
```

### 3.4 Audit the boot scripts and env chain

* `<svc>/docker-entrypoint.sh` (+ `mda/configure.sh`,
  `amavis/sa-update-loop.sh`, `cron/scripts/*`, `mda/scripts/*`):
  still-referenced vars, dead vars from dropped directives, new vars the
  new templates require.
* `<svc>/check.sh`: probe semantics unchanged (Postfix pidfile + peer-IP
  checks on `mta`; config-test gates where present).
* New/renamed knob → follow `.agents/services/configuration.md → Adding a
  new configuration option`: document + default in `env.sample` → forward
  in `vars/<svc>.env` (`VAR=${VAR}` above the `Do not edit` marker) →
  `_<VAR>_` in the template → substitution in the entrypoint. Keep scripts
  executable, `set -e`-style, with the service log prefix.
* If you cannot decide whether a var is still needed or what a safe
  default is, **ask the user** (options + your recommendation).

### 3.5 Bump the Dockerfile

* `FROM ubuntu:<new-codename>`; adjust renamed/dropped packages.
* Keep the four-concern order (deps → extra apps → copy code → perms),
  `VOLUME` / `EXPOSE` / `HEALTHCHECK` / `ENTRYPOINT` / `CMD`, and the
  trailing OCI label block (`org.opencontainers.image.created` last — the
  pre-commit hook rewrites it). See `.agents/devops/base-images.md`.
* Port exposure per `AGENTS.md`: mta 25/465/587, mda 993/995 (no plaintext
  mda ports in production files).

### 3.6 Validate — boot it, then prove it with the suite

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml build <svc>
docker compose --env-file env.dev -f docker-compose-dev.yml up -d <svc>
docker compose --env-file env.dev -f docker-compose-dev.yml logs -f <svc>
docker compose --env-file env.dev -f docker-compose-dev.yml exec <svc> /check.sh
# after mda recreate, restart mta (LMTP IP is baked at mta start):
docker compose --env-file env.dev -f docker-compose-dev.yml restart mta
# full stack + acceptance suite:
docker compose --env-file env.dev -f docker-compose-dev.yml up -d
./bootstrap-dev.sh
./test.sh
```

Fast iteration: `./test.sh --skip-content --skip-quota`. Exit code 0 only
when every executed check passed — run the **full** suite before moving to
the next service and before merging. Debug via `logs -f`, `exec <svc>
bash`, `env | sort`, `doveadm` / `postconf` / `amavisd-new test-config`
(see `.agents/devops/workflows.md → Debugging`). Typical traps: ClamAV
first signature download (~230 MB, amavis defers mail until clamd
answers); `mta` pointing at a dead `mda` IP; `cron`/`mda` waiting on a
missing `init.pre` because `amavis` did not seed the volume.

## 4. SpamAssassin shared-volume contract (amavis → cron, mda)

`amavis/Dockerfile` stages distro files at `/etc/spamassassin.dist`; on boot
`amavis/docker-entrypoint.sh` seeds the shared volume if `init.pre` is
absent and (re)writes `/etc/spamassassin/maild.cf` (Bayes path, autolearn
thresholds from `vars/amavis.env`). `mda` and `cron` entrypoints **wait**
for `/etc/spamassassin/init.pre` before proceeding. Consequences:

* Never upgrade `cron/spamassassin/` from Debian docs — take it from the
  **new amavis** pristine tree so all three containers agree.
* Keep `bayes_path` (`SA_BAYES_PATH`, default
  `/var/lib/spamassassin/bayes/db`), `bayes_file_mode 0666`, and the `0777`
  bayes-dir chmod — amavis (scanner), cron (root batch learning), and mda
  (`vmail` imapsieve learning) all write there.
* After `amavis` lands, verify `maild.cf` regeneration +
  `sa-update-loop.sh` reloads amavisd on new rules before calling
  `mda`/`cron` done.

## 5. Mixed-stack tracking — the stack is mixed until the upgrade ends

A rollover spans several per-service PRs; between first and last land the
stack runs old + new bases side by side. Make that visible:

1. `.agents/devops/base-images.md`: move the finished service row to the
   new base (or flip the drift-table cell) so the file always reflects the
   tree as-committed.
2. `Changelog.md`: one `Changed:` line per landed service
   (`<svc> base moved ubuntu:<old> → ubuntu:<new>; <pkg> <v1> → <v2>`).
3. While any row still shows the old base, the upgrade is **not done** —
   say so in the PR (`Upgrade in progress: <done>/<total> on ubuntu:<new>`).




