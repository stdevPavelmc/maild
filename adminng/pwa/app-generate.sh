#!/usr/bin/env bash
#
# app-generate.sh — build the AdminNG PWA and wrap it in a signed Android APK
# (Trusted Web Activity) with Bubblewrap, entirely inside Docker.
#
# The APK is a thin shell around the deployed PWA: it loads $APP_URL, so the
# server must serve the manifest at $APP_URL/manifest.webmanifest (the `adminng`
# container does) and terminate TLS (the operator's ingress).
#
# Required environment:
#   APP_URL          public base URL, e.g. https://adminng.example.com
#   APP_NAME         display name (default: MailD AdminNG)
#   APP_SHORT_NAME   launcher name (default: AdminNG)
#   APP_PKG          applicationId (default: cu.maild.adminng)
#   VERSION_NAME     versionName (default: package.json version)
#   VERSION_CODE     versionCode, integer (default: 1)
#   KEYSTORE         path to the signing keystore (.jks), mounted read-only
#   KEY_ALIAS        key alias inside the keystore
#   KEY_PASSWORD     key password
#   STORE_PASSWORD   keystore password
#
# Optional:
#   DOCKER_NETWORK   network for docker build/run (default: daemon default).
#                    On networks whose IPv4 route to dl.google.com is filtered
#                    the Android SDK/Gradle downloads fail; `host` fixes it.
#   GRADLE_CACHE_VOLUME, ANDROID_SDK_VOLUME
#                    named volumes for the Gradle and SDK caches
#                    (default: maild-adminng-apk-gradle / maild-adminng-apk-sdk).
#                    The SDK volume is seeded from the image on first use and keeps
#                    anything Bubblewrap installs later; `docker volume rm` to reset.
#
# Output: dist/android/<APP_PKG>-<VERSION_NAME>.apk
#
# Signing keystore: `keystore-generate.sh` (next to this script) creates a dev/test
# JKS and prints the exact environment for this script; production keys are
# generated the same way on a trusted machine and stored as repository secrets.
#
# Bubblewrap's `init` is interactive even when a manifest is passed (it asks for
# the domain, app name, package id and colors). This script therefore writes
# `twa-manifest.json` itself and drives the deterministic `update` + `build`
# commands, passing the signing passwords through Bubblewrap's documented
# BUBBLEWRAP_KEYSTORE_PASSWORD / BUBBLEWRAP_KEY_PASSWORD variables.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_URL="${APP_URL:?set APP_URL (the public https URL of the adminng frontend)}"
APP_NAME="${APP_NAME:-MailD AdminNG}"
APP_SHORT_NAME="${APP_SHORT_NAME:-AdminNG}"
APP_PKG="${APP_PKG:-cu.maild.adminng}"
VERSION_NAME="${VERSION_NAME:-$(node -p "require('./package.json').version")}"
VERSION_CODE="${VERSION_CODE:-1}"
KEYSTORE="${KEYSTORE:?set KEYSTORE (path to the .jks)}"
KEY_ALIAS="${KEY_ALIAS:?set KEY_ALIAS}"
KEY_PASSWORD="${KEY_PASSWORD:?set KEY_PASSWORD}"
STORE_PASSWORD="${STORE_PASSWORD:?set STORE_PASSWORD}"

[ -f "$KEYSTORE" ] || { echo "app-generate: keystore '$KEYSTORE' not found" >&2; exit 1; }

# A Trusted Web Activity only behaves as an app on a secure origin: service
# workers and the digital-asset-links check need https (or localhost). An http
# LAN URL still builds, but the phone shows a Custom Tab with a URL bar.
case "$APP_URL" in
    https://* | http://localhost* | http://127.0.0.1*) ;;
    *)
        echo "app-generate: warning: APP_URL is not https — the TWA needs a secure origin;" >&2
        echo "             use the TLS ingress URL for a real device (http is a local experiment only)." >&2
        ;;
esac

# Docker network for the build and the Bubblewrap run (empty = daemon default).
# On networks whose IPv4 path to dl.google.com is filtered (the Android SDK
# repository answers 404 there while IPv6 works), `DOCKER_NETWORK=host` makes the
# toolchain image build and Gradle's downloads work.
DOCKER_NETWORK="${DOCKER_NETWORK:-}"
NETWORK_ARGS=()
if [ -n "$DOCKER_NETWORK" ]; then
    NETWORK_ARGS=(--network "$DOCKER_NETWORK")
fi

# Previous runs use root inside the toolchain container (it needs /root and the
# SDK); the bind mount may therefore contain root-owned files. Reclaim them
# before npm/rm touch them, so the whole tree stays owned by the invoking user.
echo "==> reclaiming files left by previous builds"
docker run --rm "${NETWORK_ARGS[@]}" -v "$SCRIPT_DIR:/app" -e U="$(id -u)" -e G="$(id -g)" \
    node:22-bookworm sh -c \
    'chown -R "$U:$G" /app/node_modules /app/dist /app/android-project /app/twa-manifest.json \
        /app/app-release-signed.apk /app/app-release-unsigned.apk 2>/dev/null || true'

echo "==> building the PWA (VITE_APP_BASE=$APP_URL)"
docker run --rm "${NETWORK_ARGS[@]}" --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e APP_URL="$APP_URL" -v "$SCRIPT_DIR:/app" -w /app node:22-bookworm \
    bash -lc 'npm ci --no-audit --no-fund && VITE_APP_BASE="$APP_URL" npm run build' \
    || { echo "app-generate: the PWA build failed" >&2; exit 1; }

echo "==> building the Android toolchain image (first run downloads the SDK)"
docker build "${NETWORK_ARGS[@]}" -f Dockerfile.android -t maild-adminng-apk:local .


echo "==> generating the TWA project and the signed APK"
rm -rf dist/android android-project app-release-signed.apk twa-manifest.json
mkdir -p dist/android

# Host and start path come straight from APP_URL (https://host[:port]/path).
URL_REST="${APP_URL#*://}"
APP_HOST="${URL_REST%%/*}"
if [[ "$URL_REST" == */* ]]; then
    START_URL="/${URL_REST#*/}"
else
    START_URL="/"
fi

cat > twa-manifest.json <<JSON
{
  "packageId": "${APP_PKG}",
  "host": "${APP_HOST}",
  "name": "${APP_NAME}",
  "launcherName": "${APP_SHORT_NAME}",
  "display": "standalone",
  "themeColor": "#0f172a",
  "themeColorDark": "#0f172a",
  "navigationColor": "#0f172a",
  "navigationColorDark": "#0f172a",
  "navigationDividerColor": "#0f172a",
  "navigationDividerColorDark": "#0f172a",
  "backgroundColor": "#0f172a",
  "enableNotifications": false,
  "startUrl": "${START_URL}",
  "iconUrl": "${APP_URL%/}/icon.svg",
  "appVersion": "${VERSION_NAME}",
  "appVersionCode": ${VERSION_CODE},
  "signingKey": { "path": "/keystore.jks", "alias": "${KEY_ALIAS}" },
  "generatorApp": "bubblewrap-cli",
  "webManifestUrl": "${APP_URL%/}/manifest.webmanifest",
  "fallbackType": "customtabs",
  "features": {},
  "alphaDependencies": { "enabled": false },
  "enableSiteSettingsShortcut": true,
  "isChromeOSOnly": false,
  "isMetaQuest": false,
  "minSdkVersion": 24,
  "orientation": "default",
  "fingerprints": [],
  "additionalTrustedOrigins": [],
  "retainedBundles": [],
  "splashScreenFadeOutDuration": 300
}
JSON

docker run --rm "${NETWORK_ARGS[@]}" \
    -v "$SCRIPT_DIR:/app" \
    -v "$(cd "$(dirname "$KEYSTORE")" && pwd)/$(basename "$KEYSTORE"):/keystore.jks:ro" \
    -v "${GRADLE_CACHE_VOLUME:-maild-adminng-apk-gradle}:/root/.gradle" \
    -v "${ANDROID_SDK_VOLUME:-maild-adminng-apk-sdk}:/opt/android-sdk" \
    -w /app \
    -e BUBBLEWRAP_KEYSTORE_PASSWORD="$STORE_PASSWORD" \
    -e BUBBLEWRAP_KEY_PASSWORD="$KEY_PASSWORD" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e JAVA_OPTS="${JAVA_OPTS:-}" -e GRADLE_OPTS="${GRADLE_OPTS:-}" \
    -e JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-}" \
    maild-adminng-apk:local bash -lc '
        set -euo pipefail
        mkdir -p android-project
        cp twa-manifest.json android-project/twa-manifest.json
        # Bubblewrap invokes ./gradlew from the working directory, and the project
        # manifest/checksum live beside it: build from inside the project.
        cd android-project
        bubblewrap update --skipVersionUpgrade
        bubblewrap build --skipPwaValidation
        chown -R "$HOST_UID:$HOST_GID" /app/android-project /app/twa-manifest.json \
            /app/app-release-signed.apk /app/app-release-unsigned.apk 2>/dev/null || true
    '

# Bubblewrap leaves the signed artifact next to the manifest; the project tree
# keeps the unsigned/intermediate files.
APK=""
for candidate in "$SCRIPT_DIR/android-project/app-release-signed.apk" \
                 "$SCRIPT_DIR"/android-project/app/build/outputs/apk/release/*-signed.apk; do
    if [ -f "$candidate" ]; then
        APK="$candidate"
        break
    fi
done
if [ -z "$APK" ]; then
    echo "app-generate: Bubblewrap produced no signed APK (check the build output above)" >&2
    exit 1
fi
cp "$APK" "dist/android/${APP_PKG}-${VERSION_NAME}.apk"
echo "==> APK ready: dist/android/${APP_PKG}-${VERSION_NAME}.apk"

