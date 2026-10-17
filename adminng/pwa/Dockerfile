# AdminNG frontend image (service `adminng`).
#
# Stage 1 builds the PWA (Vite + React + TS + Tailwind); stage 2 serves the
# static bundle with nginx and reverse-proxies /api/v1/ to the internal `api`
# service (see nginx/default.conf). No env_file is needed: the bundle is fully
# static and the API is same-origin.

FROM node:22-alpine AS build
WORKDIR /app

COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then \
        npm ci --no-audit --no-fund; \
    else \
        npm install --no-audit --no-fund; \
    fi

COPY . .
RUN npm run build

FROM nginx:1.27-alpine

COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80

# Alpine's busybox wget: no extra package needed.
HEALTHCHECK --interval=1m --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD AdminNG frontend" \
      org.opencontainers.image.description="MailD AdminNG PWA frontend: static admin UI + /api/v1 reverse proxy to the api service" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-16"
