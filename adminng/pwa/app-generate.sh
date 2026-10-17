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
#   APP_PKG          applicationId, e.g. cu.maild.adminng
#   VERSION_NAME     versionName (default: package.json version)
#   VERSION_CODE     versionCode, integer (default: 1)
#   KEYSTORE         path to the signing keystore (.jks), mounted read-only
#   KEY_ALIAS        key alias inside the keystore
#   KEY_PASSWORD     key password
#   STORE_PASSWORD   keystore password
#
# Output: dist/android/<APP_PKG>-<VERSION_NAME>.apk
#
# NOTE: Bubblewrap prompts for the keystore details at build time; the answers
# are piped in below (newline order: keystore path, passwords, alias...), which
# is the documented Bubblewrap CLI behaviour but has to be re-checked against
# the pinned CLI version on the first real run (plan.md Phase 4).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_URL="${APP_URL:?set APP_URL (the public https URL of the adminng frontend)}"
APP_NAME="${APP_NAME:-MailD AdminNG}"
APP_PKG="${APP_PKG:?set APP_PKG (the Android applicationId, e.g. cu.maild.adminng)}"
VERSION_NAME="${VERSION_NAME:-$(node -p "require('./package.json').version")}"
VERSION_CODE="${VERSION_CODE:-1}"
KEYSTORE="${KEYSTORE:?set KEYSTORE (path to the .jks)}"
KEY_ALIAS="${KEY_ALIAS:?set KEY_ALIAS}"
KEY_PASSWORD="${KEY_PASSWORD:?set KEY_PASSWORD}"
STORE_PASSWORD="${STORE_PASSWORD:?set STORE_PASSWORD}"

[ -f "$KEYSTORE" ] || { echo "app-generate: keystore '$KEYSTORE' not found" >&2; exit 1; }

echo "==> building the PWA (VITE_APP_BASE=$APP_URL)"
docker run --rm -v "$SCRIPT_DIR:/app" -w /app node:22-bookworm \
    bash -lc 'npm ci --no-audit --no-fund && VITE_APP_BASE="$APP_URL" npm run build' \
    || { echo "app-generate: the PWA build failed" >&2; exit 1; }

echo "==> building the Android toolchain image (first run downloads the SDK)"
docker build -f Dockerfile.android -t maild-adminng-apk:local .

echo "==> generating the TWA project and the signed APK"
rm -rf dist/android android-project
mkdir -p dist/android
docker run --rm \
    -v "$SCRIPT_DIR:/app" \
    -v "$(cd "$(dirname "$KEYSTORE")" && pwd)/$(basename "$KEYSTORE"):/keystore.jks:ro" \
    -w /app \
    -e APP_URL="$APP_URL" -e APP_NAME="$APP_NAME" -e APP_PKG="$APP_PKG" \
    -e VERSION_NAME="$VERSION_NAME" -e VERSION_CODE="$VERSION_CODE" \
    -e KEY_ALIAS="$KEY_ALIAS" -e KEY_PASSWORD="$KEY_PASSWORD" -e STORE_PASSWORD="$STORE_PASSWORD" \
    maild-adminng-apk:local bash -lc '
        set -euo pipefail
        npx --yes @bubblewrap/cli init \
            --manifest "$APP_URL/manifest.webmanifest" \
            --directory android-project \
            --skipPwaValidation
        # Bubblewrap persists the manifest answers in the generated project; the
        # signing prompts are answered here (documented CLI order).
        printf "%s\n%s\n%s\n%s\n" "/keystore.jks" "$STORE_PASSWORD" "$KEY_ALIAS" "$KEY_PASSWORD" \
            | npx --yes @bubblewrap/cli build --skipPwaValidation --directory android-project
    '

APK="$(find "$SCRIPT_DIR/android-project" -name '*.apk' -type f | head -n1 || true)"
if [ -z "$APK" ]; then
    echo "app-generate: Bubblewrap produced no APK (check the build output above)" >&2
    exit 1
fi
cp "$APK" "dist/android/${APP_PKG}-${VERSION_NAME}.apk"
echo "==> APK ready: dist/android/${APP_PKG}-${VERSION_NAME}.apk"
