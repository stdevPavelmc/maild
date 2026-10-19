#!/usr/bin/env bash
#
# tls-cert-generate.sh — create the local CA + server certificate used by the
# optional AdminNG HTTPS listener (dev host port 8084, see nginx/tls.conf).
#
# Why a separate CA instead of the shared `mail.crt`? The mail certificate is a
# self-signed leaf with no Subject Alternative Name, so browsers refuse it. This
# script writes a small local CA plus a leaf with explicit SANs (the host name,
# localhost and *every* global IPv4 on the machine — a laptop with ethernet and
# WiFi has more than one), which is what Chrome/Android require. It lives in the
# same shared certs volume (`ldata/certs`) but never touches `mail.crt`/`mail.key`:
# SMTP/IMAP TLS is unaffected.
#
# The CA certificate (not the key) must be installed on every client device:
#   Android: Settings -> Security -> Encryption & credentials ->
#            Install a certificate -> CA certificate -> Install anyway
# The phone can download it from the plain-HTTP listener: http://<lan-ip>:8083/ca.der
#
# Environment:
#   OUT_DIR     output directory          (default: <repo>/ldata/certs)
#   IP          extra IPv4/IPv6 SANs      (space/comma separated, repeatable;
#                                          every global IPv4 on the host is added
#                                          automatically, this only adds more)
#   DNS         extra DNS SANs            (space/comma separated, repeatable)
#   CA_DAYS     CA validity in days       (default: 3650)
#   LEAF_DAYS   leaf validity in days     (default: 825)
#   CA_CN       CA common name            (default: MailD AdminNG Local CA)
#   CA_ORG      organisation              (default: MailD)
#   FORCE=1     regenerate the CA and the leaf (every device must re-trust the CA)
#   RENEW=1     re-issue only the leaf against the existing CA (no device action)
#
# Flags: --force, --renew, --out DIR, --ip ADDR, --dns NAME, --help
#
# Output (mode):
#   adminng-ca.crt   0644  the CA certificate (distribute this)
#   adminng-ca.der   0644  DER copy for the Android certificate installer
#   adminng-ca.key   0600  CA private key (never leaves the host)
#   adminng.crt      0644  server certificate (leaf)
#   adminng.key      0600  server private key
#   adminng-chain.crt 0644 leaf + CA (convenience for other clients)
#   adminng-ca.srl   0644  CA serial (kept so RENEW=1 does not reuse a serial)
#
# Requires: openssl (1.1.1+ for -addext). No root: the directory must be
# writable by the invoking user; bootstrap-dev.sh fixes the ownership of a
# root-created ldata/certs automatically.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/ldata/certs}"
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-825}"
CA_CN="${CA_CN:-MailD AdminNG Local CA}"
CA_ORG="${CA_ORG:-MailD}"
FORCE="${FORCE:-0}"
RENEW="${RENEW:-0}"
IP="${IP:-}"
DNS="${DNS:-}"

die() { echo "tls-cert-generate: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

usage() {
    # Print the leading comment block (everything after the shebang, up to the
    # first line of code) without hard-coding its length.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --renew) RENEW=1 ;;
        --out)   [ $# -ge 2 ] || die "--out needs a directory"; OUT_DIR="$2"; shift ;;
        --ip)    [ $# -ge 2 ] || die "--ip needs an address"; IP="$IP $2"; shift ;;
        --dns)   [ $# -ge 2 ] || die "--dns needs a name"; DNS="$DNS $2"; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

command -v openssl >/dev/null 2>&1 || die "openssl is required (install openssl)"

mkdir -p "$OUT_DIR" || die "cannot create '$OUT_DIR'"
[ -w "$OUT_DIR" ] || die "'$OUT_DIR' is not writable; run 'sudo chown -R $(id -u):$(id -g) "$OUT_DIR"' and retry"

CA_KEY="$OUT_DIR/adminng-ca.key"
CA_CRT="$OUT_DIR/adminng-ca.crt"
CA_DER="$OUT_DIR/adminng-ca.der"
CA_SRL="$OUT_DIR/adminng-ca.srl"
LEAF_KEY="$OUT_DIR/adminng.key"
LEAF_CRT="$OUT_DIR/adminng.crt"
LEAF_CSR="$OUT_DIR/adminng.csr"
CHAIN="$OUT_DIR/adminng-chain.crt"

# --------------------------------------------------------------- SAN list ----
# Order matters only for readability; the first DNS name becomes the CN.
san_items=()
add_ip() { [ -n "${1:-}" ] && san_items+=("IP:$1"); }
add_dns() { [ -n "${1:-}" ] && san_items+=("DNS:$1"); }

# Primary LAN address (the default route); used for the next-steps hints.
detect_lan_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true
}

# Every global IPv4 on the host, minus container/VM bridges. A build machine can
# have several NICs (ethernet + WiFi); the build origin may name any of them, so
# all of them must be in the SAN or Chrome/curl fail with
# ERR_TLS_CERT_ALTNAME_INVALID ("no alternative certificate subject name").
detect_lan_ips() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}' \
        | while read -r iface cidr; do
            case "$iface" in
                docker* | br-* | veth* | lxcbr* | virbr* | tun* | tap* | zt* | wg*) continue ;;
            esac
            printf '%s\n' "${cidr%%/*}"
        done
}

SHORT_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
add_dns "$SHORT_HOST"
add_dns "$SHORT_HOST.local"
add_dns localhost
add_ip 127.0.0.1
LAN_IP="$(detect_lan_ip)"
[ -n "$LAN_IP" ] && add_ip "$LAN_IP"
while read -r addr; do add_ip "$addr"; done < <(detect_lan_ips)

# Word splitting is intentional: IP/DNS accept space- or comma-separated lists.
for item in ${IP//,/ }; do add_ip "$item"; done
for item in ${DNS//,/ }; do add_dns "$item"; done

declare -A seen=()
SAN=""
for item in "${san_items[@]}"; do
    [ -n "${seen[$item]:-}" ] && continue
    seen[$item]=1
    SAN="${SAN:+$SAN,}$item"
done
[ -n "$SAN" ] || die "could not build a SAN list"

PRIMARY="${SAN%%,*}"
PRIMARY="${PRIMARY#*:}"

# ------------------------------------------------------------- existing? -----
if [ -f "$LEAF_CRT" ] && [ -f "$LEAF_KEY" ] && [ -f "$CA_CRT" ] && [ -f "$CA_KEY" ] \
    && [ "$FORCE" != "1" ] && [ "$RENEW" != "1" ]; then
    log "already present in $OUT_DIR (use FORCE=1 to regenerate the CA+leaf, RENEW=1 for a new leaf)"
    openssl x509 -in "$LEAF_CRT" -noout -subject -enddate 2>/dev/null | sed 's/^/    /'
    exit 0
fi

if [ ! -f "$CA_CRT" ] || [ ! -f "$CA_KEY" ] || [ "$FORCE" = "1" ]; then
    if [ -f "$CA_CRT" ]; then
        log "WARNING: regenerating the CA — every device must re-import adminng-ca.der"
    fi
    log "creating the local CA (${CA_DAYS} days)"
    rm -f "$CA_CRT" "$CA_KEY" "$CA_SRL" "$CHAIN"
    openssl req -x509 -new -nodes -newkey rsa:3072 -sha256 \
        -days "$CA_DAYS" \
        -keyout "$CA_KEY" -out "$CA_CRT" \
        -subj "/CN=$CA_CN/O=$CA_ORG" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" \
        >/dev/null 2>&1 || die "openssl failed to create the CA"
    chmod 0600 "$CA_KEY"
    chmod 0644 "$CA_CRT"
elif [ "$RENEW" = "1" ]; then
    log "renewing the leaf against the existing CA"
fi

# ------------------------------------------------------------------- leaf ----
log "creating the server certificate for $SAN (${LEAF_DAYS} days)"
rm -f "$LEAF_CRT" "$LEAF_KEY" "$LEAF_CSR"
openssl req -new -nodes -newkey rsa:2048 -sha256 \
    -keyout "$LEAF_KEY" -out "$LEAF_CSR" \
    -subj "/CN=$PRIMARY/O=$CA_ORG" \
    >/dev/null 2>&1 || die "openssl failed to create the leaf key/CSR"

EXT_FILE="$(mktemp)"
trap 'rm -f "$EXT_FILE" "$LEAF_CSR"' EXIT
cat >"$EXT_FILE" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName=$SAN
EOF

openssl x509 -req -in "$LEAF_CSR" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAserial "$CA_SRL" -CAcreateserial \
    -days "$LEAF_DAYS" -sha256 \
    -extfile "$EXT_FILE" \
    -out "$LEAF_CRT" \
    >/dev/null 2>&1 || die "openssl failed to sign the leaf"

chmod 0600 "$LEAF_KEY"
chmod 0644 "$LEAF_CRT" "$CA_SRL"

# DER copy: what the Android certificate installer expects.
openssl x509 -in "$CA_CRT" -outform DER -out "$CA_DER" || die "could not write $CA_DER"
chmod 0644 "$CA_DER"

cat "$LEAF_CRT" "$CA_CRT" >"$CHAIN"
chmod 0644 "$CHAIN"

openssl verify -CAfile "$CA_CRT" "$LEAF_CRT" >/dev/null 2>&1 \
    || die "the generated certificate does not verify against the CA"

# --------------------------------------------------------------- summary -----
FINGERPRINT="$(openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
NOT_AFTER="$(openssl x509 -in "$LEAF_CRT" -noout -enddate | sed 's/^notAfter=//')"
LAN_ADDRS="$(detect_lan_ips | tr '\n' ' ')"
LAN_ADDRS="${LAN_ADDRS% }"

printf '\n'
log "local CA       : $CA_CRT"
log "                 $CA_DER (Android installer)"
log "server cert    : $LEAF_CRT"
log "                 SAN: $SAN"
log "                 valid until: $NOT_AFTER"
log "CA fingerprint : $FINGERPRINT"
printf '\n'
log "next steps:"
printf '    LAN addresses : %s\n' "${LAN_ADDRS:-<lan-ip>}"
printf '    1. install the CA on the phone: open http://<%s>:8083/ca.der in Chrome, then\n' "${LAN_IP:-<lan-ip>}"
printf '       Settings -> Security -> Encryption & credentials -> Install a certificate\n'
printf '       -> CA certificate -> Install anyway (requires a screen lock).\n'
printf '    2. open https://<%s>:8084/ and confirm the padlock.\n' "${LAN_IP:-<lan-ip>}"
printf '    3. build the APK with APP_CA_CERT=%s\n' "$CA_CRT"
printf '       (any LAN address above works as the APP_URL host; all are in the SAN)\n\n'
