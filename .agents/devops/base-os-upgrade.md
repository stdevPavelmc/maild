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
7. **Caveats pass:** you may find a package renames, a service rename or some
   OS changes that may impact other services/images at build/config time, use
   a temporal caveats.md file to pass info during the upgrade progress to
   next interations, never adds the caveats.md to the git tree.
8. **Conflicts? new version wins:** if you find a uig:gid change, a service
   rename, any needed breaking change that raise a conflict with the actual
   status: new implementations always wins: adapt the actual code to the new
   ways, names, uid:gid, etc.

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

Must work on a featue branch, never work over main or develop, checkout a feature branch over a
clean develop branch

```bash
git checkout develop
git status --short # must be clean
git checkout -b upgrade/<svc>-<new-codename>
```

Make you have a clean baseline with passing tests

```bash
docker compose --env-file env.dev -f docker-compose-dev.yml build
docker compose --env-file env.dev -f docker-compose-dev.yml up -d
docker compose --env-file env.dev -f docker-compose-dev.yml exec <svc> dpkg -l | grep -E 'postfix|dovecot|amavis|clamav|spamassassin|postgresql-client' || true
# mta: postconf -n | mda: doveconf -n | amavis: /usr/sbin/amavisd test-config
```

Ran the provision and the test bed and make sure it pass

```bash
./bootstrap-dev.sh
./test.sh
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
# amavis: amavisd-new 7zip unrar-free cabextract spamassassin gpg netcat-openbsd bind9-host postgresql-client
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

> **Package-name traps on `resolute` (measured on the `clamav` and `amavis`
> steps; they apply to every service).** `netcat` is a *virtual* package with two
> providers (`netcat-openbsd` in `main`, `netcat-traditional` in `universe`) and
> apt refuses to choose: `E: Package 'netcat' has no installation candidate`.
> Install `netcat-openbsd` explicitly. `libclamunrar9` no longer exists either —
> `clamav` takes `libclamunrar12` (multiverse; the base image enables
> `main universe restricted multiverse`, so it resolves). `p7zip-full` is gone
> too: `7zip` provides it (`Provides: p7zip, p7zip-full`) and still ships
> `/usr/bin/7z`, `/usr/bin/7za`, `/usr/bin/7zr` and `/usr/bin/p7zip`.
> `clamav` and `amavis` are fixed; `mta` and `mda` still install `netcat` and will
> hit the same wall.
>
> **Renamed binaries/daemons.** `amavisd-new` 2.13 installs **`/usr/sbin/amavisd`**
> and *no longer* ships the `/usr/sbin/amavisd-new` name jammy had (the man page is
> still `amavisd-new.8`). Everything that spawns the daemon must follow
> (`amavis/docker-entrypoint.sh`: `genrsa`, `showkeys`, `test-config`,
> `foreground`). `$pid_file`/`$lock_file` are still under `/var/run/amavis/`, so
> `sa-update-loop.sh`'s HUP-reload keeps working. Grep each service's entrypoint
> for the daemon name before bumping it.
>
> **Dropped `listen`-style directives — the silent killer (guardrail 8).** On
> `clamav` the resolute `clamd.conf` dropped `TCPSocket 3310`; on `amavis`
> `20-debian_defaults` is *not* where `$inet_socket_bind = ''` comes from (it is
> MailD's own edit) and the package default is **loopback only**
> (`Amavis/Conf.pm`: `$inet_socket_bind = '127.0.0.1'`). Take the pristine file
> and the `mta → amavis:10024` hop dies with a connection refused that only shows
> up when mail is sent. Diff for the socket/bind/listen lines explicitly.

> **Dynamic service uid/gid drift — the new ids win (guardrail 8).** Debian/Ubuntu
> allocate `clamav` (and the other service users) dynamically from the 100–999
> range, so they move with the base: jammy gave `101:102`, resolute `100:101`.
> **Never pin them in the Dockerfile** — drop any pin you find and adapt the local
> environment to what the image actually runs as. Each image ends with `USER
> <svc>`: the dev bench owns its bind mounts (`bootstrap-dev.sh`: `ldata/clamav`
> → `100:101`), while production named volumes are pre-populated from the image
> and inherit the ids automatically — an *existing* prod volume keeps the old
> owner and needs a one-off `chown` (remedy in `Changelog.md`). Get it wrong and
> the service cannot read its own data (clamd dies on its signature database, the
> healthcheck and every content-filter check fail). Measure it in the §3.2
> throwaway container (`id clamav`) and land the image **and** the
> `bootstrap-dev.sh` change together, in the same commit.
>
> **…except when two containers share a filesystem.** The `clamav` container mounts
> the amavis volume: clamd is asked to `CONTSCAN` the files amavisd wrote into its
> TEMPBASE, so clamd's *user* must be in the amavis *group* (those temp dirs/files
> are `0750`/`0640`). On jammy this worked by accident — the distro handed uid 101
> to both services; resolute gives amavis `994:994` and clamav `100:101`, so AV
> failed on every message (`AV: ALL VIRUS SCANNERS FAILED`, "File path check
> failure: Permission denied") while every container still reported *healthy*. A
> group shared across two images **must** be pinned somewhere: `clamav/Dockerfile`
> carries `ARG AMAVIS_GID=994` (supplementary-group membership lives in the image's
> own `/etc/group`, it cannot follow the other image's dynamic allocation) and the
> entrypoint asserts access to `/var/lib/amavis/tmp` at start. Before calling a step
> done, walk every *shared* mount in that service's compose entry for this trap —
> and remember the acceptance suite is what catches it (EICAR/GTUBE checks).

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

> **Shortcut with proof (measured on the `amavis` step).** Before hand-merging a
> 20 KB template, compare the *two pristine* trees: `docker cp` the old base's
> package files out of a `ubuntu:<old>` throwaway container (same package list as
> the Dockerfile, §3.2) and `cmp -s` them file by file against the new base's.
> When a template file is byte-identical between the two releases, the archived
> MailD file **is** the ported result (pristine + MailD's edits, nothing upstream
> lost), so `cp` it over instead of merging hunk by hunk. On `amavis` every
> `conf.d` file was identical jammy↔resolute **except `21-ubuntu_defaults`**, while
> MailD's archived files differed from the *jammy pristine* in 7 files — i.e.
> `$inet_socket_bind = ''`, `hostname -d`, the full `$banned_filename_re`, the
> ClamAV-only `@av_scanners`, the commented `$unix_socketname`, `X_HEADER_LINE` and
> the syslog block were **MailD's own edits**, not distro defaults. Never assume
> either way: `cmp` first, and where the pristines differ, merge that file hunk by
> hunk.

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
bash`, `env | sort`, `doveadm` / `postconf` / `amavisd test-config`
(see `.agents/devops/workflows.md → Debugging`). Typical traps: ClamAV
first signature download (~230 MB, amavis defers mail until clamd
answers); `mta` pointing at a dead `mda` IP; `cron`/`mda` waiting on a
missing `init.pre` because `amavis` did not seed the volume; a bind mount
whose owner no longer matches the image's service uid/gid (guardrail 8 —
compare `id <svc>` in the image with `ls -ldn ldata/<svc>`).

## 4. SpamAssassin shared-volume contract (amavis → cron, mda)

`amavis/Dockerfile` stages distro files at `/etc/spamassassin.dist`; on boot
`amavis/docker-entrypoint.sh` seeds the shared volume if `init.pre` is
absent and (re)writes `/etc/spamassassin/maild.cf` (Bayes path, autolearn
thresholds from `vars/amavis.env`). `mda` and `cron` entrypoints **wait**
for `/etc/spamassassin/init.pre` before proceeding. Consequences:

> **Measured on the `amavis` step — what is actually mounted.** Only
> `/var/lib/spamassassin` is shared: the dev compose bind-mounts
> `./ldata/spamassassin` and production mounts the `spamassassin` named volume,
> **both only on `amavis`**. `/etc/spamassassin` is an *anonymous* volume of the
> `amavis` container (declared as `VOLUME` in its Dockerfile) and is never mounted
> anywhere else; `mda` and `cron` ship their own copy inside their images, so their
> `while [ ! -f /etc/spamassassin/init.pre ]` gate is satisfied by their own file.
> Because compose **preserves anonymous volumes across a container recreate**, a
> rebuilt image can come up on the *old* base's `/etc/spamassassin` (jammy's
> `v3*.pre` under SpamAssassin 4.0) while the `/etc/spamassassin.dist` staging is
> skipped (`init.pre` exists): validate with `--renew-anon-volumes` (or `down`
> first) and check that the `.pre` set matches the new release. The `saconf` volume
> named in `.agents/architecture/overview.md` and `.agents/services/catalog.md`
> exists in no compose file — doc drift, not an upgrade blocker.

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

## 6. `mda` — Dovecot 2.3 → 2.4 is a rewrite, not a package swap (measured 2026-10-16)

`ubuntu:jammy` → `ubuntu:resolute` moves Dovecot **2.3.16 → 2.4.2**. The "pristine files are
byte-identical" shortcut of §3.3 does **not** apply here: 2.4 refuses 2.3 configuration outright
("New 2.4 packages are not compatible with old 2.3 configuration"), so the whole `/etc/dovecot`
tree was rewritten. Every item below was validated twice — `doveconf` on the real package and then
at runtime (throwaway container, then the dev stack, then the acceptance suite).

* `dovecot_config_version = 2.4.0` + `dovecot_storage_version = 2.4.0` must be the first
  non-comment lines of `dovecot.conf`.
* Every section needs a name, and the two catch-alls are gone: `plugin { }` is now
  "Unknown section name: plugin" and the `dict { }` skeleton is "missing section name". Service
  listeners need names as well: MailD's `inet_listener { port = 12345 }` (Postfix SASL — the mta's
  `smtpd_sasl_path = inet:<mda>:12345`, i.e. **cross-service**) and `inet_listener { port = 12340 }`
  (Postfix quota policy) became `inet_listener auth` and `inet_listener quota-status`.
* `mail_location` is gone → `mail_driver = maildir` + `mail_path = ~/maildir`; the `%d`/`%n`
  modifiers are gone → `%{user | domain}` / `%{user | username}` (chainable filters).
* SSL: `ssl_cert`/`ssl_key`/`ssl_dh` → `ssl_server_cert_file`/`ssl_server_key_file`/
  `ssl_server_dh_file`, and they take a plain path — the 2.3 `<` prefix would read the file
  *content* into the setting. `ssl_prefer_server_ciphers = yes` → `ssl_server_prefer_ciphers =
  server` (values client|server).
* `disable_plaintext_auth = no` has **no** successor: 2.4 rejects `auth_allow_cleartext = yes`
  together with `ssl = required` ("has no effect with ssl=required"). With TLS mandatory the old
  setting was already inert, so it is simply dropped.
* The legacy `$setting` expansion is gone: `$mail_plugins` and `$default_internal_user` are taken as
  literal plugin/user names and the daemon refuses to start (`service(auth-worker) User doesn't
  exist: $default_internal_user`). Write the lists out, or reference with `$SET:<name>`.
* `plugin { sieve = ...; sieve_dir = ...; sieve_default = ... }` → `sieve_script <name> { type =
  personal|default|before; driver = file; path; active_path }`. `sieve_user_log` and
  `sieve_global_path` no longer exist ("Unknown setting").
* imapsieve: `imapsieve_mailboxN_*` → a `sieve_script` inside `namespace inbox { mailbox Junk { … }
  }` plus a top-level `imapsieve_from Junk { sieve_script … }`, and the plugin moved:
  `sieve_plugins = sieve_imapsieve sieve_extprograms` (2.4 ships imapsieve as a sieve plugin, on top
  of the `imap_sieve` mail plugin that 20-imap.conf still loads).
* Sieve extension lists take a bool block: `sieve_extensions { vnd.dovecot.pipe = yes }`. The 2.3
  `= +vnd.dovecot.pipe` spelling only emits "ignored unknown extension '+vnd.dovecot.pipe'" — the
  extension stays disabled and the learning scripts stop compiling. A parse check that only looks
  at the exit status will not catch this: `doveconf` returns 0 and warns on stderr.
* Quota: `plugin { quota = maildir:User quota … }` → a named root `quota "User quota" { driver =
  maildir; storage_grace = 20M; warning warn95 { quota_storage_percentage = 95; execute
  quota-warning { args = 95 %{user} } } }`; `quota_rule`/`quota_rule2` → `storage_size` and the
  per-mailbox `quota_storage_extra`; `quota_status_*`/`quota_mail_size` are top-level. Percentage
  grace does not exist any more (absolute size only).
* **The quota root must not declare `storage_size` when userdb supplies the limit**: a configured
  size *shadows* the `quota_storage_size` returned by userdb, silently pinning every mailbox to
  that number (measured: 5 MB in the catalogue was still reported as 100M). Return the limit from
  userdb and leave the root without a size.
* SQL: `dovecot-sql.conf.ext` is not shipped any more. `passdb { driver = sql args = … }` →
  `sql_driver = pgsql` + `pgsql <host> { parameters { user/password/dbname } }` + `passdb sql {
  query = …; default_password_scheme = … }` / `userdb sql { query = …; iterate_query = … }`, with
  `%{user}` instead of `%u`.
* **MD5-CRYPT (and the other weak schemes) are disabled by default in 2.4.** PostfixAdmin,
  `admin/seed.sh` and `bootstrap-dev.sh` all hash md5crypt, so the mda needs
  `auth_allow_weak_schemes = yes` or no mailbox can log in (2.4 logs "Weak password schemes are
  allowed" as the standing reminder).
* Package/file drift: `netcat` is virtual (install `netcat-openbsd`); `20-lmtpd.conf` is
  `20-lmtp.conf` upstream — and Debian's new version sets `auth_username_format =
  %{user | username | lower}` inside `protocol lmtp`, which strips the domain MailD's SQL lookups
  need, so it must not be carried over blindly.
* `doveadm quota get` keeps its old output shape as long as the quota root keeps its name ("User
  quota"): `test.sh` and `mda/scripts/quota_report.sh` parse those columns.

Trap for later validation runs: Dovecot/Debian repopulate an **empty** `/etc/dovecot` from the
packaged `/usr/share/dovecot` defaults on first start, so a candidate tree copied into a container
that has already started Dovecot once is silently partly ignored. Always `rm -rf /etc/dovecot/*`
before dropping a tree in.

## 7. `cron` — the PGDG client trap is gone on resolute (measured 2026-10-16)

* jammy had to fetch `postgresql-client-15` from PGDG because the distro only shipped 14 — that
  mismatch (client older than the server) is the one that produced the silent 20-byte "successful"
  dumps. resolute ships **`postgresql-client-18`**, which is ≥ the working-tree server
  (`postgres:15-bookworm`) *and* equal to the canonical target (`postgres:18-bookworm`), so the
  image installs the distro package (`ARG PG_CLIENT_MAJOR=18`) and the keyring/repository/`curl`
  steps are gone. PGDG *does* publish `resolute-pgdg` (verified) for the day a server major beyond
  18 arrives.
* **`pflogsumm` moved from `/usr/sbin` to `/usr/bin`** between 1.1.5 and 1.1.14: a hardcoded path
  breaks the resume with "No such file or directory" and mails an empty report. Resolve tools from
  `PATH`. The report layout is stable ("Grand Totals", "Per-Hour Traffic Summary", the
  received/delivered tallies, the domain).
* SpamAssassin 3.4.6 → 4.0.2 in this image only affects `sa-learn`: the `Learned tokens from N
  message(s)` line and the `--dump magic` `non-token data:` fields are unchanged, and with no bayes
  db it prints the same error the scripts already tolerate (they default to 0).
* Other jumps: swaks 20201014 → 20240103, bind9-host 9.18 → 9.20, cron `3.0pl1-200ubuntu1` (same
  daemon, `-f -L 2` and `/etc/crontab` unchanged) — none needed script changes.
* `cron/spamassassin/` is a **reference copy** of Debian's `/etc/cron.daily/spamassassin`; the image
  never installs it (the Dockerfile purges `/etc/cron.*/*`, and the rules refresh runs in `amavis`).
  Refresh it from the new base for the record, but do not expect it to run.
* cron now carries a HEALTHCHECK (`/var/run/crond.pid` + `kill -0`), so it is no longer the
  documented exception.
* Cross-service: recreating cron changes its IP, and amavis bakes it (`_CRONIP_`) — so **restart
  amavis** after recreating cron, and then the mta (it bakes amavis's address; its peer watchdog
  also re-resolves, but a restart is deterministic).




