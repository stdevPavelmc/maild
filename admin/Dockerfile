FROM php:8.1-apache-bookworm

# docker-entrypoint.sh dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    gosu \
    postgresql-client \
    ; \
    rm -rf /var/lib/apt/lists/*

# Install required PHP extensions
RUN set -ex; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    libc-client2007e-dev \
    libkrb5-dev \
    libpq-dev \
    libsqlite3-dev \
    ; \
    \
    docker-php-ext-configure \
    imap --with-imap-ssl --with-kerberos \
    ; \
    \
    docker-php-ext-install -j "$(nproc)" \
    imap \
    pdo_mysql \
    pdo_pgsql \
    pdo_sqlite \
    pgsql \
    ; \
    \
    # reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
    | awk '/=>/ { print $3 }' \
    | sort -u \
    | xargs -r dpkg-query -S \
    | cut -d: -f1 \
    | sort -u \
    | xargs -rt apt-mark manual; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*

ARG POSTFIXADMIN_VERSION=3.3.13
ARG POSTFIXADMIN_SHA512=bf7daaa089ee3adc4b557f1a7d0509d78979ef688fb725bab795f5c9d81e8774296245fde0cb184db51e9185cad381682c3ecc0bfadf852388b499a0a95cca64

ENV POSTFIXADMIN_VERSION $POSTFIXADMIN_VERSION
ENV POSTFIXADMIN_SHA512 $POSTFIXADMIN_SHA512
ENV APACHE_DOCUMENT_ROOT /var/www/html/public

# --- MailD default configuration (new env schema) --------------------------------
# The deployment defaults for this service live HERE now: each image bakes only the
# variables its own entrypoint/scripts consume, as ENV defaults. Any same-named variable
# in the operator's env file (docker compose env_file / environment / docker run -e)
# overrides these at runtime — never rebuild the image to deploy a different value.
# Secrets are NEVER baked: POSTGRES_PASSWORD and MAIL_ADMIN_PASSWORD (empty ⇒ OTP)
# must come from the operator env file (dev: env.dev, prod: .env — see env.sample).
# The entrypoint maps POSTGRES_* onto POSTFIXADMIN_DB_* when set. Full variable matrix:
# .agents/services/configuration.md.
# Stack-wide scheme for the hashes seed.sh provisions (Argon2id by default; the
# md5crypt escape hatch ends 2027-02-01 — .agents/services/configuration.md).
# NOTE: PostfixAdmin (deprecated dev-only fallback) keeps its own
# POSTFIXADMIN_ENCRYPT=md5crypt and CANNOT verify Argon2id hashes — its logins
# only work for accounts still on legacy hashes. Accepted: PA is not a
# supported production surface.
ENV POSTGRES_HOST=db \
    POSTGRES_DB=mailddb \
    POSTGRES_USER=maild \
    POSTFIXADMIN_DB_TYPE=pgsql \
    POSTFIXADMIN_SMTP_SERVER=mta \
    POSTFIXADMIN_SMTP_PORT=25 \
    POSTFIXADMIN_ENCRYPT=md5crypt \
    PASSWORD_SCHEME=argon2id \
    AUTO_PROVISION=yes \
    PROVISION_VERSION=1 \
    PROVISION_WAIT_TIMEOUT=180 \
    PROVISION_FORCE=no

RUN set -eu; sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf; \
    sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

RUN set -eu; \
    curl -fsSL -o postfixadmin.tar.gz "https://github.com/postfixadmin/postfixadmin/archive/postfixadmin-${POSTFIXADMIN_VERSION}.tar.gz"; \
    echo "$POSTFIXADMIN_SHA512 *postfixadmin.tar.gz" | sha512sum -c -; \
    # upstream tarball include ./postfixadmin-postfixadmin-${POSTFIXADMIN_VERSION}/
    mkdir /usr/src/postfixadmin; \
    tar -xf postfixadmin.tar.gz -C /usr/src/postfixadmin --strip-components=1; \
    rm postfixadmin.tar.gz; \
    # Does not exist in tarball but is required
    mkdir -p /usr/src/postfixadmin/templates_c; \
    chown -R www-data:www-data /usr/src/postfixadmin

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY seed.sh /seed.sh
RUN chmod +x /docker-entrypoint.sh /seed.sh

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano ; \
    fi

HEALTHCHECK --interval=1m --timeout=3s --start-period=30s --retries=2 \
    CMD curl -f http://localhost/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["apache2-foreground"]

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD Admin UI (PostfixAdmin)" \
      org.opencontainers.image.description="MailD web administration interface for domains, mailboxes and aliases (PostfixAdmin)" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      cu.maild.original-maintainer="David Goodwin <david@codepoets.co.uk> (@DavidGoodwin), PostfixAdmin project" \
      org.opencontainers.image.created="2026-10-18"
