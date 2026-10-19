# AdminNG PWA + Android APK

This folder contains the PWA itself (`src/`, Vite + React, served by the `adminng`
container) and the **Android packaging pipeline**:

| File | Purpose |
|---|---|
| `app-generate.sh` | builds the PWA and wraps it in a signed TWA APK, fully in Docker |
| `keystore-generate.sh` | creates the Android signing keystore (dev/test, or the release key) |
| `tls-cert-generate.sh` | local CA + server certificate for the optional HTTPS listener (LAN/phone) |
| `Dockerfile` | runtime image: builds the bundle, serves it with nginx (service `adminng`) |
| `nginx/` | `default.conf` (HTTP vhost), `tls.conf` (optional 8084 vhost), `snippets/` (shared headers/locations) |
| `Dockerfile.android` | toolchain image: JDK 17 + Android SDK 36 / build-tools 36.1 + Bubblewrap |
| `android-project/`, `dist/`, `twa-manifest.json`, `*.keystore*` | generated, git-ignored |

The APK is a **Trusted Web Activity**: it opens `APP_URL` in a Chrome-backed full-screen
shell. It is same-origin with the API, so the phone runs the normal AdminNG flow (register on
first login → `PENDING` → superadmin approval → login/2FA).

> `APP_URL` must be **https** for a real device: a TWA needs a secure origin (service worker,
> install prompt, digital asset links and `crypto.randomUUID`). Plain `http` is rejected by
> `app-generate.sh` — it cannot even log in. On a LAN, use the optional 8084 listener with the
> local CA (§2.1).

## TL;DR

```bash
cd adminng/pwa
./keystore-generate.sh                      # once — keep the printed passwords

DOCKER_NETWORK=host JAVA_TOOL_OPTIONS='-Djava.net.preferIPv6Addresses=true' \
APP_URL=https://adminng.example.com APP_PKG=cu.maild.adminng \
KEYSTORE=$PWD/android.keystore KEY_ALIAS=maild-apk \
KEY_PASSWORD='…' STORE_PASSWORD='…' ./app-generate.sh
```

Drop `DOCKER_NETWORK` and `JAVA_TOOL_OPTIONS` on a healthy network (§3). Details below.

## 1. Create and preserve the signing keystore

The APK must be signed with a key you keep. Android identifies an app by its package name
**and** signing certificate: with a different key you cannot update an already installed app.

### 1.1 Generate it (dev/test)

```bash
cd adminng/pwa
./keystore-generate.sh
#   -> ./android.keystore      (JKS, mode 0600)
#   -> ./android.keystore.b64  (base64, no newlines — for the KEYSTORE_BASE64 secret)
```

It prints the exports to use with `app-generate.sh` and the secret values. If you do not set a
password it generates a random one and prints it; copy it somewhere safe **before** closing the
terminal.

No JDK on the machine? The script falls back to Docker (`maild-adminng-apk:local` when it has
been built, else `eclipse-temurin:17-jdk-jammy`), so `keytool` is not a prerequisite.

The same command with explicit values (what the script does under the hood):

```bash
keytool -genkeypair -keystore android.keystore -storetype JKS \
    -alias maild-apk -keyalg RSA -keysize 2048 -validity 3650 \
    -storepass 'CHANGE_ME' -keypass 'CHANGE_ME' \
    -dname 'CN=MailD AdminNG, OU=Dev, O=MailD, L=Havana, C=CU' -noprompt
chmod 600 android.keystore
base64 -w0 android.keystore > android.keystore.b64    # macOS: base64 -i android.keystore | tr -d '\n'
```

Overrides for `keystore-generate.sh`: `OUT`, `KEY_ALIAS` (default `maild-apk`),
`STORE_PASSWORD`, `KEY_PASSWORD` (defaults to the store password), `DNAME`, `VALIDITY` (days,
default 3650), `FORCE=1` to overwrite an existing file.

Notes:

- Passwords must be at least **6 characters** (a `keytool` requirement).
- `-storetype JKS` is intentional: Bubblewrap + `apksigner` handle it. The “JKS is a
  proprietary format” warning is harmless; `apksigner` still produces v2/v3 signatures.
- Use a **different key for releases** than for development. Never reuse the dev key for a
  published app.

### 1.2 Preserve it

- **Keep the `.jks` and its passwords outside the repository** (password manager, encrypted
  backup, CI secret store). The generated file inside `adminng/pwa/` is git-ignored on purpose
  (`*.keystore`, `*.keystore.b64`, `*.apk`, `*.aab`), but a git-ignored file is still only as
  safe as the disk it sits on.
- Back up **three** things together: the `.jks`, `STORE_PASSWORD`, `KEY_PASSWORD` (and the
  alias). Losing any of them means you cannot sign an update; the only escape is Play App
  Signing (Google holds the app signing key) or publishing under a new package id.
- Restrict permissions: `chmod 600 android.keystore android.keystore.b64`.
- Do not copy the keystore into images, commits, tickets or chat. The CI workflow receives it
  as a base64 secret and materializes it with mode 0600 only for the duration of the job.
- Rotation is only trivial before the first publication (or with Play App Signing). Treat the
  release key as permanent and document who holds the backup.

### 1.3 Give it to CI

`.github/workflows/android-apk.yml` reads (repo → Settings → Secrets and variables → Actions):

| Secret / variable | Value |
|---|---|
| `KEYSTORE_BASE64` | contents of `android.keystore.b64` |
| `KEY_ALIAS` | `maild-apk` (or your alias) |
| `KEY_PASSWORD` | the key password |
| `STORE_PASSWORD` | the keystore password |
| `ADMINNG_APP_URL` (variable) | public **https** URL of the frontend |

## 2. Build the APK

```bash
cd adminng/pwa
APP_URL=https://adminng.example.com \
APP_PKG=cu.maild.adminng \
KEYSTORE=$PWD/android.keystore \
KEY_ALIAS=maild-apk \
KEY_PASSWORD='…' STORE_PASSWORD='…' \
./app-generate.sh
# ==> APK ready: dist/android/cu.maild.adminng-<version>.apk
```

Nothing Android-related is needed on the host: every step is a container.

> `APP_URL` must be reachable **from the build machine**: Bubblewrap downloads
> `${APP_URL}/manifest.webmanifest` and the icon to generate the TWA project. Build after the
> ingress/DNS is live (or point it at the dev stack for an experiment). On a LAN origin the host
> must also be listed in the server certificate SAN — see §2.1.

1. checks `${APP_URL}/manifest.webmanifest` over the expected trust chain, then builds the
   root-relative PWA bundle (`node:22-bookworm`);
2. builds `Dockerfile.android` (JDK 17 + Android SDK + Bubblewrap; the first run downloads the
   SDK, later runs are cached);
3. writes `twa-manifest.json` and runs Bubblewrap `update` + `build` from inside
   `android-project/`, signing with the keystore;
4. copies the signed APK to `dist/android/`.

| Variable | Required | Default / meaning |
|---|---|---|
| `APP_URL` | yes | public base URL; **https** for real devices |
| `APP_PKG` | yes | applicationId, e.g. `cu.maild.adminng` |
| `KEYSTORE` | yes | path to the `.jks` on the host |
| `KEY_ALIAS` | yes | alias inside the keystore |
| `KEY_PASSWORD` | yes | key password |
| `STORE_PASSWORD` | yes | keystore password |
| `APP_NAME` | no | `MailD AdminNG` |
| `APP_SHORT_NAME` | no | `AdminNG` (launcher label) |
| `VERSION_NAME` | no | `package.json` version |
| `VERSION_CODE` | no | `1` |
| `DOCKER_NETWORK` | no | network for `docker build`/`run` (see §3) |
| `JAVA_TOOL_OPTIONS` | no | forwarded to every JVM (see §3) |
| `APP_CA_CERT` | no | CA certificate to trust for a LAN https origin, e.g. `ldata/certs/adminng-ca.crt` (§2.1) |
| `GRADLE_CACHE_VOLUME` | no | `maild-adminng-apk-gradle` |
| `ANDROID_SDK_VOLUME` | no | `maild-adminng-apk-sdk` |

### 2.1 HTTPS on a LAN (local CA)

A TWA needs a secure origin: the service worker, the install prompt, Digital Asset Links and
`crypto.randomUUID()` are unavailable over plain `http`. For a phone on the LAN, the dev stack
serves HTTPS on **8084** with a certificate issued by a **local CA**:

```bash
# once (bootstrap-dev.sh does it automatically), from the repository root:
./adminng/pwa/tls-cert-generate.sh
#   -> ldata/certs/adminng-ca.crt / .der   (the CA: install this on the phone)
#   -> ldata/certs/adminng.crt / .key      (server cert; SAN = hostname + localhost
#                                           + every global IPv4 on the machine)

# build against it:
cd adminng/pwa
APP_URL=https://<lan-ip>:8084 \
APP_CA_CERT=../../ldata/certs/adminng-ca.crt \
APP_PKG=cu.maild.adminng \
KEYSTORE=$PWD/android.keystore KEY_ALIAS=maild-apk \
KEY_PASSWORD='…' STORE_PASSWORD='…' ./app-generate.sh
```

`APP_CA_CERT` is the only trust knob: it makes the build machine trust the private CA
(manifest preflight **and** Bubblewrap). Without it, an HTTPS URL with a private CA fails fast
with `UNABLE_TO_VERIFY_LEAF_SIGNATURE` instead of after the Gradle build.

The `APP_URL` host must also be in the **certificate SAN**, not just trusted: a multi-NIC host
(ethernet + WiFi) has more than one LAN IP, and only the ones listed in the SAN verify. The
generator adds every global IPv4 automatically, so a freshly issued leaf covers them all; if a
NIC/IP changed after the leaf was issued, re-issue it (same CA, no device action) and restart
the listener:

```bash
cd adminng/pwa && RENEW=1 ./tls-cert-generate.sh --ip <new-lan-ip>
docker compose --env-file env.dev -f docker-compose-dev.yml restart adminng  # reloads the cert
```

Without that, Chrome/curl fail with `ERR_TLS_CERT_ALTNAME_INVALID` ("no alternative certificate
subject name matches …"); the `app-generate.sh` preflight detects this and prints the command.

Install the CA on the phone:

1. Chrome → `http://<lan-ip>:8083/ca.der` (the CA certificate is public; the key never leaves
   the host).
2. Settings → Security → Encryption & credentials → **Install a certificate → CA certificate →
   Install anyway** (needs a screen lock; OEM menus vary).
3. Force-stop Chrome, then open `https://<lan-ip>:8084/` — padlock, no warning.
4. Install the APK. On an **IP origin** Digital Asset Links cannot be verified, so Chrome shows
   it as a **Custom Tab** (URL bar). That is expected and fully functional: service worker,
   offline shell and login all work over the trusted HTTPS origin. A chrome-less (standalone)
   app needs a DNS name that resolves to the server plus a served `assetlinks.json`.

Notes:

- `http://` builds are refused by `app-generate.sh`: they cannot log in at all
  (`crypto.randomUUID` is secure-context only), so they are not a supported test path.
- `RENEW=1 ./tls-cert-generate.sh` re-issues the leaf against the same CA (no device action);
  `FORCE=1` regenerates the CA too, so **every** device must re-import `adminng-ca.der`.
- The certificates live in the shared `ldata/certs` volume; `mail.crt`/`mail.key` are untouched,
  so SMTP/IMAP TLS is unaffected.
- Production does not use this listener: the operator's ingress terminates TLS and the stack
  publishes no 443 (AGENTS.md).


## 3. The network / IPv6 case

Symptoms (any of them, before the app is compiled):

- `[3/8] RUN … wget … commandlinetools…` → `exit code: 8`;
- `Failed to download any source lists` / `IO exception while downloading manifest`;
- `Could not find com.android.tools.build:gradle:8.9.1` or a stalled Gradle distribution.

Cause: on some networks the **IPv4** route to `dl.google.com` (and the Gradle services) answers
404 while IPv6 works, and the JVM prefers IPv4.

Fix: give the build containers the host network stack **and** make every JVM prefer IPv6:

```bash
DOCKER_NETWORK=host \
JAVA_TOOL_OPTIONS='-Djava.net.preferIPv6Addresses=true' \
APP_URL=https://adminng.example.com APP_PKG=cu.maild.adminng \
KEYSTORE=$PWD/android.keystore KEY_ALIAS=maild-apk \
KEY_PASSWORD='…' STORE_PASSWORD='…' \
./app-generate.sh
```

Why **both**:

- `DOCKER_NETWORK=host` is passed to `docker build` and to the Bubblewrap `docker run`, so
  `wget`/`curl` (command-line tools, SDK packages) use the host interfaces and its working
  route;
- `JAVA_TOOL_OPTIONS` is inherited by every JVM the build spawns — `sdkmanager`, `gradlew` and
  the **Gradle daemon** — which is where the Maven artifacts (AGP, AndroidX,
  androidbrowserhelper) are fetched. `JAVA_OPTS`/`GRADLE_OPTS` are forwarded too, but do not
  reliably reach the daemon.

On a healthy network omit both. If IPv4 works and IPv6 does not, use
`JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true` instead. This is build-environment only:
it changes nothing inside the APK.

## 4. Caches, outputs and resets

- Output: `dist/android/<pkg>-<version>.apk` (Bubblewrap also leaves
  `android-project/app-release-signed.apk` and the `.aab`). `dist/` is Vite's output directory
  as well, so the PWA build cleans it: a **failed** run can remove the previous APK, a
  successful run recreates it.
- Volumes: `maild-adminng-apk-gradle` (Gradle wrapper + dependencies) and
  `maild-adminng-apk-sdk` (seeded from the image; keeps packages installed at runtime). After
  an image bump reset them with
  `docker volume rm maild-adminng-apk-sdk maild-adminng-apk-gradle`.
- The image already ships `platforms;android-36` + `build-tools;36.1.0` — Bubblewrap 1.27 pins
  36.1.0 and AGP 8.9 compiles against 36 — so a normal run does not re-download them.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `wget … exit code: 8` at step 3/8 | retired command-line-tools archive or IPv4 404 | the image tries four versions and both fetchers; on a filtered network use `DOCKER_NETWORK=host` |
| `Failed to download any source lists` | `sdkmanager` over IPv4 | `JAVA_TOOL_OPTIONS=-Djava.net.preferIPv6Addresses=true` |
| `Could not find com.android.tools.build:gradle…` | Gradle daemon over IPv4 | same `JAVA_TOOL_OPTIONS`, plus `DOCKER_NETWORK=host` |
| `./gradlew: not found` | Bubblewrap run outside the project dir | use the script (it `cd`s into `android-project/`) |
| `minSdkVersion … cannot be smaller than 24` | TWA helper floor | the script generates `minSdkVersion: 24` |
| `keystore '…' not found` | wrong path, not absolute | pass an absolute `KEYSTORE` |
| APK opens with a URL bar | IP origin: Digital Asset Links cannot be verified | expected on a LAN IP; a DNS name + `assetlinks.json` is needed for standalone |
| `UNABLE_TO_VERIFY_LEAF_SIGNATURE` during the build | the build does not trust the local CA | pass `APP_CA_CERT=/path/to/adminng-ca.crt` |
| `ERR_TLS_CERT_ALTNAME_INVALID` during the build | the cert SAN does not list the `APP_URL` host (e.g. a second NIC / changed LAN IP) | `RENEW=1 ./tls-cert-generate.sh --ip <host>` then `restart adminng` (§2.1); or build against an IP that is already in the SAN |
| `ERR_CERT_AUTHORITY_INVALID` on the phone | CA not installed, or SAN does not match the URL | install `ca.der`; check `openssl x509 -ext subjectAltName` lists the exact IP/host |
| `http://` rejected by `app-generate.sh` | TWA needs a secure origin (by design) | use `https://<lan-ip>:8084` with the local CA (§2.1) |
| `Permission denied` under `android-project/` | files created by the root container | the script reclaims ownership before/after every run |

## 6. Verify an APK

```bash
cd adminng/pwa
docker run --rm -v "$PWD/dist/android:/apk:ro" maild-adminng-apk:local bash -lc '
  BT=$(ls -d /opt/android-sdk/build-tools/* | tail -1)
  $BT/apksigner verify --print-certs /apk/cu.maild.adminng-*.apk
  $BT/aapt dump badging /apk/cu.maild.adminng-*.apk | head -5'
```

Expect `Verifies`, the v2/v3 schemes, your certificate DN, the package id, versionName/Code and
`minSdkVersion`.

## 7. Related docs

- [`../README.md`](../README.md) — AdminNG services, API, device bootstrap.
- [`../doc/plan.md`](../doc/plan.md) — Phase 4 notes, including every trap this pipeline hit.
- [`.agents/devops/workflows.md`](../../.agents/devops/workflows.md) — CI and daily commands.

