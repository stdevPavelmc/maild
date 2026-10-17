#!/usr/bin/env bash
# Entrypoint / mode dispatcher for the AdminNG browser harness.
#
# Usage: docker compose --env-file env.dev -f docker-compose-dev.yml \
#            run --rm pwa-test <mode> [args...]
# (or simply ./adminng/pwa-test/run.sh <mode>)
#
# Modes:
#   verify        the gate: Playwright flows + installability + Lighthouse budget
#   flows         one spec (tests/<name>.spec.ts: flows, installable, superadmin)
#   a11y          axe-core scan of every screen
#   visual        PNG screenshots, desktop + mobile, EN + ES
#   lighthouse    only the Lighthouse budget
#   shell         interactive shell inside the harness image
#   <command...>  anything else is exec'd verbatim (e.g. npx playwright test --list)
set -euo pipefail
cd /app

mode="${1:-verify}"
shift || true

export ADMINNG_URL="${ADMINNG_URL:-http://localhost:8083}"
export E2E_ARTIFACTS="${E2E_ARTIFACTS:-/artifacts}"
export E2E_UPSTREAM_HOST="${E2E_UPSTREAM_HOST:-adminng}"
export E2E_UPSTREAM_PORT="${E2E_UPSTREAM_PORT:-80}"
export E2E_PROXY_PORT="${E2E_PROXY_PORT:-8083}"
mkdir -p "$E2E_ARTIFACTS"

log() { printf 'pwa-test: %s\n' "$*"; }
TUNNEL_PID=""

cleanup() {
    if [ -n "$TUNNEL_PID" ]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    # The harness runs as root (docker socket + leftover files); give the reports
    # back to the operator so ldata/e2e stays editable from the host.
    if [ "${E2E_CHOWN_UID:-0}" != "0" ] || [ "${E2E_CHOWN_GID:-0}" != "0" ]; then
        chown -R "${E2E_CHOWN_UID:-0}:${E2E_CHOWN_GID:-0}" "$E2E_ARTIFACTS" 2>/dev/null || true
    fi
}
trap cleanup EXIT

wait_for_stack() {
    log "waiting for the adminng frontend on http://${E2E_UPSTREAM_HOST}:${E2E_UPSTREAM_PORT}"
    for _ in $(seq 1 60); do
        if node -e "fetch('http://${E2E_UPSTREAM_HOST}:${E2E_UPSTREAM_PORT}/api/v1/health',{signal:AbortSignal.timeout(3000)}).then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"; then
            return 0
        fi
        sleep 2
    done
    log "the stack did not answer — run ./bootstrap-dev.sh first (or set E2E_UPSTREAM_HOST)"
    return 1
}

start_tunnel() {
    [ "${E2E_TUNNEL:-1}" = "1" ] || return 0
    node /app/proxy.mjs &
    TUNNEL_PID=$!
    for _ in $(seq 1 40); do
        if node -e "require('node:net').connect(Number(process.env.E2E_PROXY_PORT),'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"; then
            return 0
        fi
        sleep 0.25
    done
    log "the localhost tunnel did not start"
    return 1
}

case "$mode" in
    verify)
        wait_for_stack
        start_tunnel
        npx playwright test "$@"
        node lighthouse.mjs
        ;;
    flows | installable | superadmin)
        wait_for_stack
        start_tunnel
        npx playwright test "tests/${mode}.spec.ts" "$@"
        ;;
    a11y | visual)
        wait_for_stack
        start_tunnel
        PWA_TEST_ALL=1 npx playwright test "tests/${mode}.spec.ts" "$@"
        ;;
    lighthouse)
        wait_for_stack
        start_tunnel
        node lighthouse.mjs
        ;;
    shell)
        exec bash "$@"
        ;;
    *)
        exec "$mode" "$@"
        ;;
esac
