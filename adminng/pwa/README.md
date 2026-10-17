# AdminNG PWA + Android APK

This folder contains the PWA itself (`src/`, Vite + React, served by the `adminng`
container) and the **Android packaging pipeline**:

| File | Purpose |
|---|---|
| `app-generate.sh` | builds the PWA and wraps it in a signed TWA APK, fully in Docker |
| `keystore-generate.sh` | creates the Android signing keystore (dev/test, or the release key) |
| `Dockerfile` | runtime image: builds the bundle, serves it with nginx (service `adminng`) |
| `Dockerfile.android` | toolchain image: JDK 17 + Android SDK 36 / build-tools 36.1 + Bubblewrap |
| `android-project/`, `dist/`, `twa-manifest.json`, `*.keystore*` | generated, git-ignored |

The APK is a **Trusted Web Activity**: it opens `APP_URL` in a Chrome-backed full-screen
shell. It is same-origin with the API, so the phone runs the normal AdminNG flow (device
handshake → `PENDING` → superadmin approval → login/2FA).

> `APP_URL` must be **https** for a real device. A TWA needs a secure origin (service worker +
> digital asset links); an `http://192.168.x.y` build still compiles but opens as a Custom Tab
> with a URL bar. `http://localhost` is the only usable http form, and only on the same machine.

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
> ingress/DNS is live (or point it at the dev stack for an experiment).

1. builds the PWA with `VITE_APP_BASE=$APP_URL` (`node:22-bookworm`);
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
| `GRADLE_CACHE_VOLUME` | no | `maild-adminng-apk-gradle` |
| `ANDROID_SDK_VOLUME` | no | `maild-adminng-apk-sdk` |

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
| APK opens with a URL bar | `APP_URL` is not https | use the TLS ingress URL for device tests |
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

