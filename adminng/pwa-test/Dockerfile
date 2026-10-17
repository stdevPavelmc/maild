# AdminNG browser test harness (service `pwa-test`, DEV ONLY).
#
# A self-contained Playwright + Lighthouse runner: the browsers are baked into the
# official image, so neither the host nor CI needs Node, Chromium or Playwright
# installed. It is a one-shot container (`docker compose run --rm pwa-test`),
# never part of the runtime stack and never in the production compose files.
#
# The image also carries the Docker CLI because the suite approves its own device
# through the documented `adminng.py --approve-device` CLI inside the `api`
# container (the socket is mounted by docker-compose-dev.yml). The approval is
# deliberately out of band: the untrusted device must not be able to authorize
# itself.

ARG PLAYWRIGHT_VERSION=1.64.1
FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble

# Redeclared after FROM: build args are not visible to later stages/RUN lines.
ARG PLAYWRIGHT_VERSION=1.64.1
ARG DOCKER_VERSION=29.9.1
ARG TARGETARCH=amd64

# HOME is writable for any uid: run.sh maps the host uid so the artifacts under
# ldata/e2e are host-owned (no root-owned files in the bind mount).
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    E2E_ARTIFACTS=/artifacts

# Static Docker CLI (Go binary, glibc-compatible): `docker exec` against the api
# container. Only the client is needed; the socket is mounted read-write by the
# dev compose file.
RUN set -eux; \
    case "${TARGETARCH}" in \
        arm64) docker_arch=aarch64 ;; \
        *) docker_arch=x86_64 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz" -o /tmp/docker.tgz; \
    tar -xzf /tmp/docker.tgz -C /tmp; \
    install -m 0755 /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker /tmp/docker.tgz; \
    docker --version

WORKDIR /app

# Dependencies first: the npm layer is cached until the lock changes.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
RUN test "$(node -p "require('@playwright/test/package.json').version")" = "${PLAYWRIGHT_VERSION}" \
    || { echo "pwa-test: the Playwright package and the base image version disagree" >&2; exit 1; }


COPY . .
RUN chmod +x entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["verify"]

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD AdminNG browser test harness" \
      org.opencontainers.image.description="Dev-only Playwright + Lighthouse runner for the AdminNG PWA" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-17"
