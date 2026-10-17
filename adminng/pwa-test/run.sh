#!/usr/bin/env bash
# Host wrapper for the AdminNG browser harness (DEV ONLY).
#
# Runs the one-shot `pwa-test` container against the running dev stack:
#   ./adminng/pwa-test/run.sh verify
#   ./adminng/pwa-test/run.sh visual
#   ./adminng/pwa-test/run.sh shell
#
# It creates ldata/e2e as the invoking user and passes the uid/gid through, so
# the reports and screenshots are host-owned (never root-owned bind mounts).
# The image is rebuilt from the working tree on every run (cached layers); set
# PWA_TEST_NO_BUILD=1 to reuse the existing image.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
cd "$ROOT"

if [ ! -f test.creds ]; then
    echo "pwa-test: test.creds is missing — run ./bootstrap-dev.sh first" >&2
    exit 1
fi

mode="${1:-verify}"
shift || true

mkdir -p ldata/e2e
# Pass the invoking identity through so the entrypoint can hand the artifacts back
# (the container itself runs as root: docker socket access, Chromium sandbox off).
export PWA_TEST_UID="$(id -u)"
export PWA_TEST_GID="$(id -g)"

if [ ! -S /var/run/docker.sock ]; then
    echo "pwa-test: /var/run/docker.sock is missing — device approval will fail" >&2
fi

build=()
if [ "${PWA_TEST_NO_BUILD:-0}" != "1" ]; then
    build=(--build)
fi

exec docker compose --env-file env.dev -f docker-compose-dev.yml \
    run --rm "${build[@]}" pwa-test "$mode" "$@"
