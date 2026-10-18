#!/usr/bin/env bash
#
# keystore-generate.sh — create the Android signing keystore for the AdminNG APK.
#
# This is the DEV/TEST path: it generates a throwaway key with local passwords so
# `app-generate.sh` can run on a workstation. For a real release, generate the key
# on a trusted machine, keep it in a password manager and use the same alias and
# passwords in the repository secrets (see "Signing keystore" in adminng/README.md).
#
# Environment:
#   OUT              output path                (default: ./android.keystore)
#   KEY_ALIAS        key alias                  (default: maild-apk)
#   STORE_PASSWORD   keystore password          (default: generated, printed)
#   KEY_PASSWORD     key password               (default: same as STORE_PASSWORD)
#   DNAME            certificate subject        (default: CN=MailD AdminNG, OU=Dev, ...)
#   VALIDITY         days                       (default: 3650)
#   FORCE=1          overwrite an existing file
#
# Output:
#   <OUT>            the JKS keystore (mode 0600)
#   <OUT>.b64        base64 of the keystore, ready for the KEYSTORE_BASE64 secret
#
# Requires `keytool` (a JDK). If it is missing, the script falls back to Docker
# (`maild-adminng-apk:local` when built, otherwise it pulls eclipse-temurin:17-jdk).
set -euo pipefail

OUT="${OUT:-$PWD/android.keystore}"
KEY_ALIAS="${KEY_ALIAS:-maild-apk}"
DNAME="${DNAME:-CN=MailD AdminNG, OU=Dev, O=MailD, L=Havana, C=CU}"
VALIDITY="${VALIDITY:-3650}"

die() { echo "keystore-generate: $*" >&2; exit 1; }

if [ -e "$OUT" ] && [ "${FORCE:-0}" != "1" ]; then
    die "'$OUT' already exists (set FORCE=1 to overwrite)"
fi

# Dev convenience: a random, printable password when the caller did not set one.
if [ -z "${STORE_PASSWORD:-}" ]; then
    STORE_PASSWORD="$(openssl rand -hex 12)"
fi
KEY_PASSWORD="${KEY_PASSWORD:-$STORE_PASSWORD}"

OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
OUT_NAME="$(basename "$OUT")"
mkdir -p "$OUT_DIR"

# Prefer a local JDK; otherwise use the toolchain image (or a plain JDK image).
DOCKER_IMAGE=""
if ! command -v keytool >/dev/null 2>&1; then
    if docker image inspect maild-adminng-apk:local >/dev/null 2>&1; then
        DOCKER_IMAGE="maild-adminng-apk:local"
    else
        DOCKER_IMAGE="eclipse-temurin:17-jdk-jammy"
    fi
fi

keytool_run() {
    if [ -z "$DOCKER_IMAGE" ]; then
        keytool "$@"
    else
        # Rewrite the host paths to their in-container equivalents.
        local args=()
        for arg in "$@"; do
            case "$arg" in
                "$OUT") args+=("/keys/$OUT_NAME") ;;
                *) args+=("$arg") ;;
            esac
        done
        docker run --rm -u "$(id -u):$(id -g)" -v "$OUT_DIR:/keys" -w /keys \
            "$DOCKER_IMAGE" keytool "${args[@]}"
    fi
}

echo "==> generating a 2048-bit RSA key (alias '$KEY_ALIAS', $VALIDITY days)"
keytool_run -genkeypair \
    -keystore "$OUT" -storetype JKS -alias "$KEY_ALIAS" \
    -keyalg RSA -keysize 2048 -validity "$VALIDITY" \
    -storepass "$STORE_PASSWORD" -keypass "$KEY_PASSWORD" \
    -dname "$DNAME" -noprompt

chmod 600 "$OUT" 2>/dev/null || true

echo "==> verifying"
keytool_run -list -v -keystore "$OUT" -storepass "$STORE_PASSWORD" \
    | grep -E 'Alias name|Creation date|Valid from|SHA256:' | sed 's/^/    /'

B64="${OUT}.b64"
if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$OUT" > "$B64"
else
    base64 < "$OUT" | tr -d '\n' > "$B64"
fi
chmod 600 "$B64" 2>/dev/null || true

cat <<EOF

==> keystore ready: $OUT
    alias         : $KEY_ALIAS
    store password: $STORE_PASSWORD
    key password  : $KEY_PASSWORD

    Local build (one line):
      DOCKER_NETWORK=host JAVA_TOOL_OPTIONS='-Djava.net.preferIPv6Addresses=true' \\
      KEYSTORE="$OUT" KEY_ALIAS="$KEY_ALIAS" \\
      KEY_PASSWORD='$KEY_PASSWORD' STORE_PASSWORD='$STORE_PASSWORD' \\
      APP_URL=https://adminng.example.com APP_PKG=cu.maild.adminng \\
      ./app-generate.sh

    CI (repository secrets, base64 without newlines):
      KEYSTORE_BASE64 = contents of $B64
      KEY_ALIAS       = $KEY_ALIAS
      KEY_PASSWORD    = $KEY_PASSWORD
      STORE_PASSWORD  = $STORE_PASSWORD

    This is a DEV/TEST key. Back up a production keystore and its passwords:
    losing them means you cannot update an already published app (Play App
    Signing can mitigate this, but it is an operator decision).
EOF
