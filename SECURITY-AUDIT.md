# MailD — Security Audit

**Date:** 2026-10-31
**Target:** MailD stack, branch `mcp` (full stack: `mta`, `mda`, `mua`, `adminng` api+pwa, `mcp`, `cron`, `db`, `amavis`, `clamav`)
**Type:** Authorized white-box assessment (source available, running dev stack), author-requested.
**Assessor:** Automated multi-agent review + manual exploitation, adversarially cross-verified.

---

## 1. Scope & methodology

### In scope — the production attack surface

Only entry points reachable in a **production** deployment were treated as attack surface:

| Service | Production exposure |
|---------|--------------------|
| `mta` (Postfix) | TCP **25, 465, 587** |
| `mda` (Dovecot) | TCP **993, 995** |
| `adminng` (nginx → FastAPI `api`) | HTTP via operator **Traefik** (TLS-terminated) |
| `mua` (SnappyMail) | HTTP via operator **Traefik** |
| `mcp` (Django) | HTTP via operator **Traefik** |
| `db`, `api`, `amavis`, `clamav`, `cron` | internal only (no published ports) |

Methodology: static review of every service's config, entrypoints and application code; live exploitation against the running dev stack on the production-equivalent ports; each candidate finding was then re-reviewed by an independent adversarial pass that defaulted to *reject* unless a concrete, reachable exploit path could be shown. Findings marked **(verified live)** were reproduced against the running stack by hand.

### Explicitly out of scope (not reported as vulnerabilities)

- **TLS termination.** HTTP apps sit behind a Traefik that terminates TLS with a real certificate in production. "App speaks plain HTTP" / missing HTTPS at the container is by design and not reported.
- **Dev-only port exposure.** The dev compose publishes extras (`db:5432`, `clamav:3310`, `mcp:8085`, `mda:110/143/4190/12345`, `adminng:8084`). The production compose files publish only 25/465/587 and 993/995 — confirmed. Dev exposures are not production findings.
- **Committed *fake* dev secrets** (`env.dev`, `test.creds`) — intentional and git-ignored.

### Severity scale

`CRITICAL` → remote unauth compromise · `HIGH` → privilege escalation / auth bypass / mass data access · `MEDIUM` → meaningful weakening needing a precondition or operator misstep · `LOW` → defense-in-depth / hard-to-reach · `INFO` → hygiene.

---

## 2. Executive summary

The stack is, overall, **well engineered for security**: the open-relay posture is correct, Dovecot SQL injection is blocked at the username-charset layer, the MCP OAuth 2.1 server is a textbook implementation (S256 PKCE enforced, single-use codes, refresh-reuse detection, SSRF-hardened CIMD fetch), the MCP's `X-Forwarded-For` handling is done the *right* way, and the webmail change-password driver is parameterized and self-scoped. Most of what follows is hardening; two issues are genuinely serious.

| # | Severity | Finding | Service |
|---|----------|---------|---------|
| H-01 | **HIGH** | Domain admin can delete any administrator (missing superadmin check) | adminng api |
| H-02 | **HIGH** | Login lockout bypass via spoofable `X-Forwarded-For` (verified live) | adminng api |
| M-01 | MEDIUM | No SMTP SASL brute-force limiting; AUTH on :25 behind an ineffective filter | mta |
| M-02 | MEDIUM | Unauthenticated CIMD fetch → thread-exhaustion DoS + SSRF/status oracle | mcp |
| M-03 | MEDIUM | SnappyMail admin panel internet-exposed (verified live) | mua |
| M-04 | MEDIUM | `.env-prod` not covered by `.gitignore` (latent public-repo secret leak) | repo |
| M-05 | MEDIUM | Internal `api` auto-exposed by default Traefik (`traefik.enable=false` missing) | compose |
| M-06 | MEDIUM | `cron` loads the whole secret file and dumps it to world-readable `/etc/environment` | compose/cron |
| L-01 | LOW | Domain admin can set superadmin-reserved domain fields (transport/quota) | adminng api |
| L-02 | LOW | `reauth-confirm` password check has no rate limiting | adminng api |
| L-03 | LOW | MCP login has no per-IP throttle; ALTCHA PoW is trivial | mcp |
| L-04 | LOW | SMTP recipient-restriction tarpit `sleep` enables smtpd process exhaustion | mta |
| L-05 | LOW | Self-signed TLS private key created world-readable (mode 644) | mta/mda |
| L-06 | LOW | DKIM keys generated at 1024-bit RSA | amavis |
| L-07 | LOW | `MCP_SECRET_KEY` has no placeholder/weak-value guard | mcp |
| L-08 | LOW | Internet-facing services lack `no-new-privileges`/`cap_drop` | compose |
| L-09 | LOW | `cron` bind-mounts host `/var/log` read-write as root | compose |
| L-10 | LOW | DB backups written unencrypted + world-readable | cron |
| I-01 | INFO | `/healthz` reachable through the ingress leaks subsystem status | mcp |

**2 HIGH · 6 MEDIUM · 10 LOW · 1 INFO.**

---

## 3. HIGH findings

### H-01 — Non-superadmin domain admin can delete any administrator  ✅ verified (code) · **REMEDIATED 2026-10-31**

> **Remediation (branch `mcp`, see `Changelog.md`):** all `/admins` routes are now
> role-scoped with the enforcement in `catalogue` (single choke point behind the
> advisory lock): a domain admin manages only the non-super administrators fully
> inside its own domains, never a superadmin, never itself; self-delete is banned
> for every admin and the last-superadmin guard is row-level. Regression coverage:
> `test.sh` I11b/I11c, `test_catalogue.py` `AdminPermissionTests`.
>
> **Follow-up (2026-11-01):** opening the `/admins` CRUD to domain admins introduced a
> cross-tenant mailbox takeover — `create_admin` checked the managed `domains` but not
> the admin's own *address*, and the admin password is mirrored onto the same-named
> mailbox (`_mirror_mailbox_password`), so `alice@example.net` could create
> `victim@other.tld` scoped to `example.net` and reset that mailbox's password. Fixed:
> for a non-superadmin caller the new admin's address must be in its domains, and
> `_assert_manageable` applies the same rule to update/disable/delete (a
> foreign-address peer stays superadmin-only). The tenant list scope is now
> case-insensitive. Coverage: `test_catalogue.py` test_07–09, `test.sh` I11c.

- **Severity:** HIGH · **CWE-862** (Missing Authorization) / **CWE-269** (Improper Privilege Management)
- **Location:** [adminng/api/app/routers/admins.py:66-73](adminng/api/app/routers/admins.py#L66) → [adminng/api/app/catalogue.py:757-770](adminng/api/app/catalogue.py#L757)

**Defect.** Every `/admins` route is `Depends(require_superadmin)` — except `delete_admin`, which is `Depends(require_reauth)`:

```python
@router.delete("/{username}", status_code=204, ...)
def delete_admin(username, request, principal: Principal = Depends(require_reauth)):
    catalogue.delete_admin(principal, username)      # ← no superadmin check here either
```

`require_reauth` only resolves `get_principal` and validates a 30-second `X-Security-Validation-Token`; it does **not** check `principal.superadmin`. `catalogue.delete_admin()` performs only a *last-active-superadmin* guard — it never checks the caller's role (it receives `principal` and ignores it). The author clearly knows `require_reauth != superadmin` — [routers/devices.py:83](adminng/api/app/routers/devices.py#L83) re-adds an explicit `if not principal.superadmin` check for exactly this reason. It is simply missing here.

**Exploit (via the production nginx → api proxy).** A legitimate non-superadmin domain admin (e.g. the fixture `alice@example.net`) on an approved device:
1. `POST /api/v1/auth/reauth-confirm {"password": "<their own password>"}` → any principal may mint a `security_validation_token`.
2. `DELETE /api/v1/admins/<victim>` with `Authorization: Bearer …`, `X-Device-ID`, `X-Device-Secret`, `X-Security-Validation-Token`.

`require_reauth` passes (did/sub/scope all match the caller) and the target admin row + its `domain_admins` rows are deleted and its sessions revoked.

**Impact.** A low-privilege tenant admin can delete **other administrators**: every superadmin except the last active one (the last-superadmin guard still holds), plus every peer/other-tenant domain admin. Cross-privilege, cross-tenant destruction of the administrator set — removal of rival/oversight admins and denial of administrative access. Target usernames (e.g. the provisioned `sysadmin@DEFAULT_DOMAIN`) are public/guessable.

**Fix.** Require superadmin **and** re-auth. Minimal, mirroring `routers/devices.py:83`:

```python
# in delete_admin, before catalogue.delete_admin(...)
if not principal.superadmin:
    raise ApiError(403, "FORBIDDEN", "superadmin only")
```

Cleaner — add a combined dependency and use it on the route:

```python
# auth.py
def require_superadmin_reauth(principal: Principal = Depends(require_reauth)) -> Principal:
    if not principal.superadmin:
        raise ApiError(403, "FORBIDDEN", "superadmin only")
    return principal
```

Defense-in-depth: assert `principal.superadmin` at the top of `catalogue.delete_admin` too (it already receives `principal`).

---

### H-02 — Login lockout / brute-force protection bypass via spoofable `X-Forwarded-For`  ✅ verified live · **REMEDIATED 2026-10-31**

> **Remediation (branch `mcp`, see `Changelog.md`):** `client_ip()` now walks the
> `X-Forwarded-For` chain right-to-left and returns the right-most hop that is not a
> trusted proxy (`ADMINNG_TRUSTED_PROXIES`, computed from the attached subnets when
> unset), always appending the socket peer and failing closed on unparseable hops —
> the MCP rule. The lockout key, the TOTP-step lockout and the stored
> `audit_event.ip`/`device.last_ip` can no longer be forged or rotated. Regression
> coverage: `test.sh` I16b/I16c, `test_client_ip.py`.
>
> **Follow-up (2026-11-01):** the computed default trusted the whole attached subnet,
> *including the docker gateway* — the source of any published-port (docker-proxy) or
> host-originated connection, whose `X-Forwarded-For` is client-controlled (it is why
> `env.dev` had needed `none`). The default now excludes the gateway(s)
> (`settings.attached_gateways`, logged at boot); an explicit list is still taken
> verbatim. `env.dev` dropped its `none` deviation, so I16b/I16c now exercise the
> production rule live; `env.sample` warns that `none` turns the lockout into a
> per-username DoS. Companion hardening still
> open: **M-05** (Traefik auto-exposing the raw `api`, which would remove the proxy
> hop entirely) — fix it next.

- **Severity:** HIGH · **CWE-307** (Improper Restriction of Excessive Auth Attempts) / **CWE-290** (Auth Bypass by Spoofing)
- **Location:** [adminng/api/app/audit.py:56-61](adminng/api/app/audit.py#L56) (`client_ip`), consumed by [adminng/api/app/ratelimit.py](adminng/api/app/ratelimit.py) (key = `username` + `ip`)

**Defect.** `client_ip()` trusts the **first** (left-most) value of `X-Forwarded-For`:

```python
def client_ip(request) -> str | None:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",", 1)[0].strip()   # ← attacker-controlled
    return request.client.host if request.client else None
```

nginx *appends* the real socket IP to any client-supplied `X-Forwarded-For` (`$proxy_add_x_forwarded_for`), so the left-most element is always whatever the client sent. The login lockout ([ratelimit.py](adminng/api/app/ratelimit.py)) keys on `(username, ip)` and locks after `ADMINNG_LOGIN_MAX_FAILURES` (5). Rotating `X-Forwarded-For` per request makes every attempt a distinct key → the lockout never arms.

**Proof (live, against the dev nginx on :8083):**

```
BASELINE (fixed IP):     attempt 5 → HTTP 429  (locked)
BYPASS (rotating XFF):   12 attempts → all HTTP 401, never 429
```

**Impact.**
1. **Unlimited online password guessing** against any AdminNG admin — the documented brute-force control (technical-draft §4.6) is defeated. (Superadmins are still gated by TOTP; non-superadmin domain admins are *not* required to have TOTP by default — `ADMINNG_TOTP_REQUIRED=superadmin` — so for them password-guessing with an approved device yields full tokens.)
2. **Also weakens the TOTP step** — `login_step2`'s lockout is on the same spoofable key.
3. **Audit-trail integrity.** The same value is stored verbatim into `audit_event.ip`, `rate_limit.ip`, `device.last_ip` (all `text` columns, no IP validation), so an attacker forges the IP in their own audit records. Stored-XSS via this field is largely blocked by the strict CSP (`script-src 'self'`), but log integrity is not.

**The correct pattern already exists in this repo.** The MCP does it right — [mcp/app/asgi.py](mcp/app/asgi.py) `client_ip()` walks the XFF chain **right-to-left** and returns the right-most hop **not** in `MCP_TRUSTED_PROXIES`. AdminNG should adopt the same approach.

**Fix.**
- Add an `ADMINNG_TRUSTED_PROXIES` setting (CIDR list; default the docker network / empty).
- Rewrite `client_ip()` to return the right-most XFF hop that is not a trusted proxy, falling back to `request.client.host`; **validate** the result with `ipaddress.ip_address()` before using/storing it (drop to the socket peer on failure).
- Belt-and-braces: strip inbound `X-Forwarded-For`/`X-Real-IP` from untrusted clients at nginx (`proxy_set_header X-Forwarded-For $remote_addr;` instead of `$proxy_add_x_forwarded_for`, since there is exactly one proxy hop below Traefik), or have Traefik set a single trusted header.
- See H-01 companion **M-05**: if the `api` is reachable without traversing nginx, there is *no* proxy to append the header, making this trivially exploitable — fix both.

---

## 4. MEDIUM findings

### M-01 — No SMTP SASL brute-force limiting; AUTH offered on :25 behind an ineffective filter  ✅ verified live · **REMEDIATED 2026-11-01**

> **Remediation (branch `mcp`):** `smtpd_sasl_auth_enable = no` globally (587/465 keep it);
> `smtpd_client_auth_rate_limit = SMTP_AUTH_RATE_LIMIT` (60/min, every smtpd) and
> `smtpd_client_connection_rate_limit = SMTP_CONNECTION_RATE_LIMIT` (60/min) on 587/465 only —
> deliberately not on :25, where a deployment may receive everything from one upstream relay.
> Dead filters removed. Verified live: EHLO on :25 after STARTTLS advertises no AUTH, 587 does;
> `postconf` shows the limits. fail2ban not shipped (needs host NET_ADMIN) — operator option.

- **Severity:** MEDIUM · **CWE-307**
- **Location:** [mta/postfix/main.cf.s:59](mta/postfix/main.cf.s#L59) (`smtpd_sasl_auth_enable = yes`, global); dead controls [mta/postfix/rules/command_filter.pcre](mta/postfix/rules/command_filter.pcre), [auth_filter.pcre](mta/postfix/rules/auth_filter.pcre)

**Defect.** There is **no** SASL auth rate-limiting anywhere in `mta/` (`grep` for `smtpd_client_auth_rate_limit` = none; the only `smtpd_client_*_rate_limit` lines sit on the internal :10025 amavis listener, set to 0). The only lockout in the stack (`adminng/api/app/ratelimit.py`) covers the *web* login, not mail SASL. Dovecot adds only a per-attempt delay (`auth_failure_delay`, default ~2 s), which is parallelizable across connections; `smtpd_client_connection_count_limit` defaults to 50 concurrent/IP and source IPs can be rotated.

The intended "no AUTH on port 25" control is ineffective three ways: `auth_filter.pcre` is **referenced nowhere** (dead file); `command_filter.pcre` is wired via `postscreen_command_filter`, which only inspects postscreen's pre-handoff phase (never the post-STARTTLS `AUTH` inside the backend `smtpd`); and it matches only the literal `AUTH LOGIN` while the server offers `AUTH PLAIN`. (Note: postscreen itself *is* enabled by default — `DNSBL_ENABLE=true` in [mta/Dockerfile:56](mta/Dockerfile#L56) — so DNSBL/greet/pipelining protections do run; it is specifically the AUTH filter that does nothing.)

Verified live: `openssl s_client -starttls smtp -connect :25` + `EHLO` advertises `250-AUTH PLAIN`.

**Impact.** Unmonitored online credential stuffing against every mailbox over 465/587 (and 25). A hit yields full mailbox access *and* send-as (the envelope is bound to the SASL user by `smtpd_sender_login_maps`). Mitigated by TLS-only AUTH (no cleartext credential leak), Argon2id hashing and the ~2 s Dovecot delay — hence MEDIUM, not HIGH.

**Fix.**
1. Add anvil throttling in `main.cf.s` (the `anvil` service already exists): `smtpd_client_auth_rate_limit = 10`, `smtpd_client_connection_rate_limit = 30`. Optionally ship fail2ban keyed on the `SASL … authentication failed` log lines (maillog already reaches the cron container).
2. Stop offering AUTH on the MX port: set `smtpd_sasl_auth_enable = no` as the **global** default in `main.cf.s:59` — submission ([master.cf.s:22](mta/postfix/master.cf.s#L22)) and smtps ([master.cf.s:47](mta/postfix/master.cf.s#L47)) already set `-o smtpd_sasl_auth_enable=yes` explicitly, so they keep AUTH.
3. Delete the dead/ineffective filters (`auth_filter.pcre`, and `postscreen_command_filter`/`command_filter.pcre`) so they are not mistaken for a working control.

### M-02 — Unauthenticated CIMD fetch in `/oauth/authorize`: thread-exhaustion DoS + SSRF/status oracle · **REMEDIATED 2026-11-01**

> **Remediation (branch `mcp`):** worse than reported — Django runs every sync view of a worker
> on one shared thread, so a fetch stalled the whole worker, not one request. `authorize` is now
> async and runs the fetch via `asyncio.to_thread`; `clients.admit` caps uncached fetches per IP
> (10/10 min) and concurrency (4/worker, fail fast); failed URLs are remembered 5 min in
> `notice_throttle` (shared across workers); 2 s connect / 3 s read; one generic browser error,
> cause logged. Coverage: pytest (budget, cap, slot release, generic message) and `test.sh` O4b
> (live: generic body, no re-fetch across workers).

- **Severity:** MEDIUM · **CWE-918** (SSRF) / **CWE-400** (Resource Exhaustion)
- **Location:** [mcp/app/oauth/clients.py:59](mcp/app/oauth/clients.py#L59) & [:151](mcp/app/oauth/clients.py#L151), reached from [mcp/app/oauth/views.py:99](mcp/app/oauth/views.py#L99)

**Defect.** `GET /oauth/authorize` is unauthenticated and calls `clients.resolve(client_id)`; any uncached `https://…` client_id triggers `fetch_document` (DNS + TLS + GET to the attacker-named URL). Only *dynamic client registration* is rate-limited — CIMD resolution is not. The SSRF controls themselves are strong (public-IP-only, connect-to-checked-address so no DNS rebinding, no redirects, 5 s/64 KB caps), so this is **not** a classic internal-SSRF. The residual issues: (a) the 5 s synchronous fetch runs inside a Django view with `MCP_WORKERS=2`, so pointing `client_id` at a public IP that blackholes packets ties up a worker 5 s per request → a handful of concurrent requests exhaust the pool (unauth DoS of the whole MCP); (b) upstream status/connection outcomes are reflected to the browser → a liveness/status oracle and request-origin laundering on the MCP's IP.

**Fix.**
- Rate-limit CIMD resolution per source IP (reuse the DCR counter), pass `_ip(request)` into `resolve`.
- Negatively cache failures (short-lived marker) so repeats short-circuit instead of re-fetching.
- Return a single generic error to the browser ("unknown or unreachable client"); log the real status/exception server-side only.
- Bound concurrency (module-level semaphore around `fetch_document`) and split connect vs read timeouts; ideally make `authorize` async and run the fetch via `asyncio.to_thread`. Document an operator Traefik rate-limit on the `/oauth` router as defense-in-depth.

### M-03 — SnappyMail admin panel internet-exposed  ✅ verified live · **REMEDIATED 2026-11-01**

> **Remediation (branch `mcp`):** `config-setup.php` writes `allow_admin_panel = Off` unless
> `MUA_ADMIN_PANEL=on` (new, image default `off`). Verified live: `/?admin` 403 with the
> default, 200 with `on`, back to 403 with `off`; the webmail stays 200. `test.sh` checks it.

- **Severity:** MEDIUM · **CWE-284** (Improper Access Control — exposed management interface)
- **Location:** [mua/config-setup.php:259-261](mua/config-setup.php#L259) (security section writes only `admin_login`)

**Defect.** Production Traefik routes `Host(webmail.${DEFAULT_DOMAIN}) → mua:80`; the SnappyMail admin console lives on that *same* host at `/?admin`. `config-setup.php` applies only `admin_login`, so the image defaults survive: `allow_admin_panel = On`, `[admin_panel] host = ""` (any host), `admin_totp = ""` (no 2FA). Verified live: `GET /?admin` → HTTP 200 with the admin login UI. The admin password itself is strong (`random_bytes(16)`, bcrypt-stored) and there is a per-response `fault_delay` — but no lockout.

**Impact.** The full SnappyMail management surface is internet-reachable to anonymous clients: online guessing of the admin login (`maild` + password) and a reachable target for any current/future SnappyMail admin-panel auth/RCE CVE. A taken panel controls IMAP/SMTP targets for all users and the change-password driver DSN (the mua holds the catalogue-owner `POSTGRES_*` creds in its env).

**Fix.** In `config-setup.php` default `allow_admin_panel` to `Off`, enabled only when e.g. `MUA_ADMIN_PANEL=on`; optionally set `[admin_panel] host` to an internal-only name so the panel is never served on the public webmail host, and allow requiring `admin_totp`. Add the `MUA_ADMIN_PANEL` ENV default (off) in the mua Dockerfile and document it.

### M-04 — `.env-prod` is not covered by `.gitignore` (latent public-repo secret leak)  ✅ verified · **REMEDIATED 2026-11-01**

> **Remediation (branch `mcp`):** `.gitignore` now ignores `.env*` (`git check-ignore`
> confirms `.env-prod`; `env.dev`/`env.sample` stay tracked) and the `.pre-commit` hook
> refuses any staged `.env*` file (verified with a dummy file). `.env-prod` stays in place,
> never committed — no rotation needed.

- **Severity:** MEDIUM · **CWE-538** (Insertion of Sensitive Info into Externally-Accessible File) / **CWE-540**
- **Location:** [.gitignore](.gitignore) (ignores `.env` exactly, not `.env-prod`) + `./.env-prod` (untracked, present)

**Defect.** `.gitignore` ignores the exact filename `.env`, not `.env-prod`/`.env.prod`/`.env.local`. `git check-ignore .env-prod` → **not ignored**; `git status` lists it `??`. The repo is intended to be public. A routine `git add -A` stages the production operator file and a push publishes the whole production secret set (DB password, `ADMINNG_SECRET_KEY` = the JWT signing + Fernet-root key, mail/webmail admin passwords, MCP secrets).

**Status:** `git log --all -- .env-prod` is empty → **never committed yet**. This is a latent leak, not an active breach. (Per the repo's own rule, I'm flagging it rather than touching the file.)

**Fix.** Broaden the ignore to a glob: replace the `.env` lines with `.env*`. (`env.dev`/`env.sample` have no leading dot, so `.env*` never matches the intentional fakes — no un-ignore exceptions needed.) Then move/rename `.env-prod` out of the tree (or to `.env`, already ignored) and confirm with `git check-ignore .env-prod`. Rotation of the four secrets is precautionary only (never pushed). Consider a pre-commit hook rejecting staged high-entropy `*.env*` files.

### M-05 — Internal `api` auto-exposed by default Traefik (missing `traefik.enable=false`)  ✅ verified · **REMEDIATED 2026-11-01**

> **Remediation (branch `mcp`):** `db`, `api`, `cron`, `amavis`, `clamav`, `mda` and `mta` carry
> `traefik.enable=false` in all three production compose files; INSTALL.md requires
> `--providers.docker.exposedbydefault=false`. `test.sh` statically checks that only
> `adminng`/`mua`/`mcp` are routed. Same commit: the §8 `compose-github.yml` drift is gone —
> every file serves AdminNG at `admin.${DEFAULT_DOMAIN}` with the router named `adminng`.

- **Severity:** MEDIUM · **CWE-668** (Exposure of Resource to Wrong Sphere)
- **Location:** [docker-compose.yml:67-98](docker-compose.yml#L67) (`api`, no labels) + `compose-github.yml` / `compose-gitlab.yml`

**Defect.** All containers share the external `maild` network the operator's Traefik joins. Only `adminng`/`mua`/`mcp` carry `traefik.enable=true`; **no** service carries `traefik.enable=false`. Traefik's docker provider defaults to `exposedByDefault=true` with a default rule `Host(<container-name>)`. The `api` container EXPOSEs HTTP 8080, so a stock Traefik (exactly what the docs tell the operator to run) auto-creates a router for it. An attacker then reaches the raw FastAPI via `curl -k https://<ingress>/ -H 'Host: maild-api'`, **bypassing the nginx `adminng` layer** entirely — skipping its path whitelist (`/api/v1/`, `/health`) and security headers, and (critically) presenting a request with **no trusted proxy to append `X-Forwarded-For`**, making **H-02** trivially exploitable.

**Fix.** Add `labels: ["traefik.enable=false"]` to every non-ingress service (`db`, `api`, `cron`, `amavis`, `clamav`, `mda`, `mta`) in **all three** production compose files (same commit, per the compose-chain rule), keeping `traefik.enable=true` only on `adminng`/`mua`/`mcp`. Also document in INSTALL.md that the operator must run Traefik with `--providers.docker.exposedbydefault=false`. Keep `ADMINNG_API_DOCS=no` in production (already the default).

### M-06 — `cron` loads the full secret file and dumps it to world-readable `/etc/environment`  ✅ verified · **REMEDIATED 2026-11-01**

> **Remediation (branch `mcp`):** no `env_file` on cron in any compose file — an explicit
> allow-list instead; the entrypoint rewrites `/etc/environment` with mode 600. Side finding
> while fixing: a bare allow-list key the operator leaves unset *removes* the image ENV
> default (Docker gets `KEY` without `=`), so the cron image snapshots its defaults at build
> and the entrypoint restores them. **The `mcp` allow-list has the same latent defect**
> (`MCP_WORKERS`, `MCP_DB`, `MCP_IMAP_HOST`, … are unset in the container; the Python
> settings' own fallbacks currently mask it) — tracked separately. Coverage: `test.sh` (mode,
> no foreign secrets, tunable pass-through) and the full G-phase cron checks.

- **Severity:** MEDIUM · **CWE-526** (Exposure via Environment) / **CWE-250**
- **Location:** [cron/docker-entrypoint.sh:7](cron/docker-entrypoint.sh#L7) (env dump) + [docker-compose.yml:299-300](docker-compose.yml#L299) (`env_file: - .env` on cron) + chained compose files

**Defect.** The cron service loads `env_file: - .env` (the whole operator secret file) and the entrypoint appends the entire environment to `/etc/environment` (verified mode 0644). That file ends up holding `MCP_DOVECOT_MASTER_PASSWORD`, `ADMINNG_SECRET_KEY`, `MCP_SECRET_KEY`, `MCP_DB_PASSWORD`, `POSTFIXADMIN_SETUP_PASSWORD` — **none** of which any `cron/scripts/*` references (the jobs only need `POSTGRES_PASSWORD`, `DEFAULT_DOMAIN`, `MAIL_ADMIN_USER`). The project already recognises this anti-pattern — the `mcp` service deliberately omits `env_file` "because the operator file carries every other service's secrets"; cron does the opposite. Reachable precondition: cron runs root jobs over attacker-influenced data (`sa-learn --file` over delivered mail, log parsing), so any code-exec in that context reads every secret.

**Impact.** A single cron compromise escalates to full-stack secret disclosure: Dovecot master (IMAP to **every** mailbox), `ADMINNG_SECRET_KEY`/`MCP_SECRET_KEY` (forge admin/user sessions, decrypt TOTP seeds), DB password.

**Fix.** Remove `env_file: - .env` from the cron service in all three compose files; replace with an explicit allow-list in the existing `environment:` block (mirror the `mcp` pattern) — keep `POSTGRES_PASSWORD`/`DEFAULT_DOMAIN`/`MAIL_ADMIN_USER` plus the few tunables cron actually overrides (`JUNK_RETENTION_DAYS`, `BACKUP_*`, `SA_HAM_SAMPLE_*`, `DNS_CHECK_*`, `OUTBOUND_ALERT_*`). Secondary: in the entrypoint, write (not append) `/etc/environment` and `chmod 600` it.

---

## 5. LOW findings

### L-01 — Domain admin can set superadmin-reserved domain fields
**CWE-269** · [adminng/api/app/routers/domains.py:65-74](adminng/api/app/routers/domains.py#L65) → [catalogue.py:227-240](adminng/api/app/catalogue.py#L227).
`PUT /api/v1/domains/{domain}` is gated by `get_principal` + `ensure_domain_allowed` only (no superadmin gate), and `update_domain` writes every non-null `DomainUpdate` field — including `transport`, `backupmx`, `maxquota`, `quota`. A domain admin can `PUT {"transport":"smtp:[attacker.host]:25"}` to reroute their own domain's delivery, or raise `maxquota`/`quota` above superadmin-set caps. Scoped to their own domain(s), so impact is confined to that tenant, but these are superadmin-only capabilities in the PostfixAdmin model.
**Fix.** When `not principal.superadmin`, strip/reject `transport`, `backupmx`, `maxquota`, `quota` (leave `description`, `active` editable); or split `DomainUpdate` into tenant vs superadmin subsets.

### L-02 — `reauth-confirm` has no rate limiting
**CWE-307** · [adminng/api/app/auth.py:631-657](adminng/api/app/auth.py#L631).
`login_step1/step2/webauthn` all call `ratelimit.check/failure`; `reauth_confirm` verifies the account password with no throttle (only an audit record). An attacker holding a stolen access token + device secret (but not the password) can brute-force the password to obtain a destructive-action token. Bounded (needs a stolen session) but a real gap vs. the login paths.
**Fix.** Wrap the `_verify_credentials` call in `ratelimit.check` / `ratelimit.failure` / `ratelimit.success` exactly like `login_step1` (shared `rate_limit` table). Pair with H-02's `client_ip` fix so the IP half of the key cannot be rotated.

### L-03 — MCP user login has no per-IP throttle; ALTCHA PoW trivial
**CWE-307** · [mcp/app/mcpcore/webauth.py:24,78](mcp/app/mcpcore/webauth.py#L78); [mcp/app/webapi/api.py:79-103](mcp/app/webapi/api.py#L79).
Lockout keys on `username+IP` and arms only after 5 same-user/same-IP failures; ALTCHA `max_number=100000` solves in ms and challenges are unlimited. Horizontal spraying (one password across many addresses from one IP) never arms a lockout. The MCP `client_ip` is non-spoofable, so a per-IP cap is effective here.
**Fix.** Add a username-independent per-IP failure throttle (e.g. 20/15 min) before `accounts.login`; raise `ALTCHA_MAX_NUMBER` to ≥1,000,000 and rate-limit `GET /webapi/altcha/challenge`.

### L-04 — SMTP recipient-restriction tarpit `sleep` enables smtpd process exhaustion  ✅ verified live
**CWE-400** · [mta/postfix/main.cf.s:194](mta/postfix/main.cf.s#L194) (`sleep _SMTP_TARPIT_DELAY_`).
The F-07 tarpit is a blocking `sleep` (default 2 s) in `smtpd_recipient_restrictions` on the process-per-connection public smtpd, reached unauthenticated for any RCPT to a hosted domain (verified: unauth `RCPT TO:<probe@maild.cu>` took 2.23 s). With `smtpd_recipient_limit=1000`, one pipelined session holds a process ~33 min; `default_process_limit=100` caps the pool, so a couple of source IPs can saturate it → temporary denial of inbound mail. Self-healing, no data gain.
**Fix.** Remove the blocking `sleep`; deter harvesting with non-blocking controls (postscreen is already on; add `smtpd_client_recipient_rate_limit`, a lower `smtpd_client_connection_count_limit`, and cap `-o smtpd_recipient_limit=20` on the :25 service). If a tarpit is kept, bound per-session recipients and keep the delay small relative to `default_process_limit`.

### L-05 — Self-signed TLS private key created world-readable (644)  ✅ verified live
**CWE-732** · [mta/docker-entrypoint.sh:370](mta/docker-entrypoint.sh#L370) & [mda/configure.sh:38](mda/configure.sh#L38) (`chmod +r /certs/mail.key`).
When no operator cert is supplied, both entrypoints generate a self-signed key and `chmod +r` it → mode 644, readable by `other`. The non-root mail workers (postfix uid 101, vmail uid 5000) that parse untrusted input on the exposed ports are each "other" relative to `root:root` and can read the TLS private key; a worker memory-disclosure/RCE leaks it (passive decryption / MITM). The key also sits on the shared `/certs` volume.
**Fix.** Replace `chmod +r` with `chmod 600 /certs/mail.key` (both Postfix and Dovecot load the key as root before dropping privileges). Matches the already-correct 600 handling of `adminng.key`/`adminng-ca.key`.

### L-06 — DKIM keys generated at 1024-bit RSA
**CWE-326** · [amavis/docker-entrypoint.sh:282](amavis/docker-entrypoint.sh#L282) (`amavisd genrsa ${KEY} 1024`).
DKIM signing is on by default; keys are hardcoded to 1024-bit, deprecated by RFC 8301. A factored key lets an attacker forge DKIM (and thus pass DMARC) for the deployment's domains → high-credibility spoofing. README already claims 2048.
**Fix.** `amavisd genrsa ${KEY} ${DKIM_KEY_BITS:-2048}`; add `DKIM_KEY_BITS=2048` to the amavis Dockerfile ENV; document the regenerate-and-republish-TXT migration for existing deployments (the `if [ ! -f ${KEY} ]` guard never rotates existing keys).

### L-07 — `MCP_SECRET_KEY` has no placeholder/weak-value guard
**CWE-1392** · [mcp/app/maild_mcp/settings.py:50](mcp/app/maild_mcp/settings.py#L50).
`SECRET_KEY = env_required("MCP_SECRET_KEY")` enforces only non-empty; `env.sample` ships the literal `change-me-openssl-rand-hex-32`. AdminNG guards exactly this ([adminng/api/app/bootstrap.py:28](adminng/api/app/bootstrap.py#L28) `PLACEHOLDER_SECRET_KEYS`); the MCP does not. This key derives the token-hash HMAC, opaque-handle signing, ALTCHA PoW key and the Fernet key for the stored external SMTP password — a known value lets an attacker forge handles/ALTCHA solutions and (if the DB leaks) decrypt SMTP creds.
**Fix.** Mirror AdminNG's placeholder check in `mcp_boot` (warn/refuse on the shipped `change-me-…` literals for `MCP_SECRET_KEY`, `MCP_DB_PASSWORD`, `MCP_DOVECOT_MASTER_PASSWORD`).

### L-08 — Internet-facing services lack `no-new-privileges` / `cap_drop`
**CWE-250 / CWE-732** · [docker-compose.yml](docker-compose.yml) `mta`/`mda`/`mua`/`adminng`/`api` (none set `security_opt`/`cap_drop`/`read_only`; contrast `mcp` at :375-381).
`mcp` is the only hardened service. The images facing untrusted traffic ship the usual setuid-root binaries and run with Docker's full default capability set and `no-new-privileges` off, so a worker-process foothold can escalate to in-container root (blast radius includes the writable shared `/certs` and `/home/vmail`).
**Fix.** Mirror the mcp hardening across all three compose files: minimum `security_opt: ["no-new-privileges:true"]` on `mta`/`mda`/`mua`/`adminng`/`api`; then `cap_drop: [ALL]` + minimal `cap_add` (mta/mda: `NET_BIND_SERVICE,SETUID,SETGID,CHOWN,DAC_OVERRIDE`; adminng nginx similar; api can drop all); `read_only: true` + `tmpfs` for adminng/api. Optionally strip unused setuid bits in the Dockerfiles.

### L-09 — `cron` bind-mounts host `/var/log` read-write as root
**CWE-668** · [docker-compose.yml:301-304](docker-compose.yml#L301) (`- /var/log:/var/log`).
The cron service mounts the **host** `/var/log` RW, runs as root, no `cap_drop`/`no-new-privileges`, and processes attacker-influenced data (pflogsumm/sa-learn/DNS). A code-exec there gains root write to host logs (anti-forensics) and can fill the host filesystem (host DoS).
**Fix.** Make the mount `:ro` (cron only reads host logs) in all three compose files, and add `cap_drop: [ALL]` + `security_opt: ["no-new-privileges:true"]`.

### L-10 — DB backups written unencrypted + world-readable
**CWE-312 / CWE-732** · [cron/scripts/backup_db.sh:46,125,208,290](cron/scripts/backup_db.sh#L46).
Backups are created with the default umask (dir 0755, files 0644) and no encryption, retained 15 days, containing mailbox Argon2id hashes, TOTP ciphertext, session/device/webauthn rows, token hashes, OAuth clients/codes and the audit trail. Compounded by M-06 (the signing keys live in the same cron container), so one cron/volume compromise yields both ciphertext and the keys to decrypt it. Backups are the artifact most likely to travel to lower-trust storage.
**Fix.** (a) `umask 077` + `mkdir -m 0700` for the backup dir. (b) Envelope-encrypt each dump to an operator public key (`… | age -r "$BACKUP_AGE_RECIPIENT"` or `gpg -e`), gated on the recipient var; validate the encrypted artifact. (c) Keep the app signing keys out of the cron container (see M-06).

---

## 6. INFO

### I-01 — `/healthz` reachable through the ingress leaks subsystem status
**CWE-200** · [mcp/app/mcpcore/views.py:31](mcp/app/mcpcore/views.py#L31); mcp Traefik router rule.
The mcp router matches the host with no path restriction, so `/healthz` is anonymously reachable and returns per-subsystem booleans (db/catalogue/imap).
**Fix.** Tighten the router rule to `Host(...) && !Path(/healthz)` (the internal Dockerfile healthcheck hits `127.0.0.1:8080/healthz` directly, not via Traefik), or return only the aggregate status for non-loopback callers. Chain-update all three compose files.

---

## 7. Verified secure (tested, no action needed)

These were actively probed/reviewed and found robust — recorded so future changes don't regress them:

- **SMTP open relay is closed.** Unauth foreign→foreign is rejected (`reject_unauth_destination`; sender-domain check fires first); VRFY disabled; ETRN not abusable; `mynetworks` tight (`127.0.0.0/8` + amavis). Postfix 3.10 default handles SMTP smuggling (bare-newline).
- **Postfix pgsql maps** use `%s` (auto-escaped by Postfix) → no SQLi.
- **Dovecot SQL passdb/userdb** interpolate `%{user}` inside quotes, guarded by `auth_username_chars` (no quote/metacharacter can reach the query) → no SQLi. `ssl = required` (no cleartext auth pre-TLS on 993/995).
- **Dovecot sieve-extprograms** exposes only `vnd.dovecot.pipe`, restricted to `sieve_pipe_bin_dir`; the learn scripts pass the message as a *file* (no shell interpolation). ManageSieve (4190) isn't exposed in production → no user-supplied-sieve RCE.
- **Dovecot MCP master user** is IMAP-only (fails over POP3/ManageSieve/SMTP-AUTH), the userdb still requires the target mailbox `active='1'`, master logins are logged, and the master-users file is `0640 root:dovecot`.
- **MCP OAuth 2.1 server** — S256 PKCE enforced (authorize rejects non-S256/missing challenge); auth codes single-use (`select_for_update` + `used`), 2 min, bound to client+redirect_uri+PKCE+resource; access/refresh tokens opaque + hashed at rest; refresh rotation with family-wide reuse detection; scopes can only be narrowed; consent endpoint is Bearer-authenticated and binds the code to the logged-in account and *its own* addresses (no CSRF, no cross-account mint).
- **MCP CIMD fetch** SSRF controls are strong (https-only, public-IP-only, connect-to-checked-address so no DNS rebinding, no redirects, 5 s/64 KB caps) — see M-02 for the residual DoS/oracle.
- **MCP `X-Forwarded-For`** handled correctly (right-most untrusted hop vs `MCP_TRUSTED_PROXIES`) — the model AdminNG should copy (H-02).
- **MCP master tokens** require `X-MailD-Act-As` (single mailbox), a CIDR IP allowlist, and per-request act-as validation; all audited.
- **MUA change-password driver** uses a parameterized PDO statement scoped to `WHERE username = :username AND active`, where the username is the session's own `$oAccount->Email()` → no SQLi, no cross-account change.
- **AdminNG session/token design** — HS256 with a fixed algorithm list (no alg-confusion), `purpose` claim per token kind, device binding (`did` must equal `X-Device-ID` + device-secret possession factor), short access TTL, refresh rotation with reuse → revoke, password reset not exposed; `ADMINNG_API_DOCS` correctly defaults off in production.
- **Password hashing** Argon2id by default, scheme-dispatched verify that fails closed; md5crypt is a date-gated legacy path.

---

## 8. Out of scope / accepted risk (noted, not counted)

- **Webmail ↔ Dovecot plaintext IMAP/Sieve** (`mua` → `mda:143`/`:4190`, no TLS) lives entirely on the internal docker network; 143/4190 are not published in production. Acceptable given network isolation; revisit if the internal network is ever shared with untrusted workloads.
- **cron jobs run as root** parsing attacker-influenced mail/logs. No injection was found (static queries, `sa-learn --file`, quoted shell vars). Still, privilege separation (drop to a non-root user for parse jobs) would reduce the blast radius of any future parser bug — tracked implicitly via L-08/L-09.
- **`compose-github.yml` drift** (chain-consistency bug, not security): its adminng Traefik router/host is `admin`/`admin.${DEFAULT_DOMAIN}` while `docker-compose.yml` and `compose-gitlab.yml` use `adminng`/`adminng.${DEFAULT_DOMAIN}`. Violates the strict-copy rule; worth fixing in the same pass as M-05/M-06 since those touch all three files.

---

## 9. Remediation priority

1. **Now:** H-01 (one authz check), H-02 (`client_ip` rewrite), M-04 (`.gitignore` one-liner — latent secret leak).
2. **Next:** M-05 + M-06 + L-08/L-09 (compose hardening, one chained pass across the three files), M-03 (webmail admin panel), M-01 (SMTP SASL throttle), M-02 (CIMD DoS).
3. **Then:** the remaining LOW items and I-01, folded into routine hardening.

*Per the project doc rule, any config/compose/env change above must update the matching `.agents/` doc in the same commit, and the three production compose files must be chain-updated together.*
