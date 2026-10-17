FROM php:8.3-apache

# if updated you must review domain.json against the new version !!!
ARG SNAPPY_VERSION=2.38.2

# install base tools
RUN apt-get update && \
    apt-get install -y \
        postgresql-client \
        curl \
        wget \
        bind9-host  \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libmcrypt-dev \
        libpq-dev

RUN docker-php-ext-install pdo pdo_pgsql && \
    docker-php-source delete
    
RUN cd /var/www/html/ && \
    wget https://github.com/the-djmaze/snappymail/releases/download/v${SNAPPY_VERSION}/snappymail-${SNAPPY_VERSION}.tar.gz && \
    tar xvzf snappymail-${SNAPPY_VERSION}.tar.gz && \
    chown -R www-data:www-data /var/www/html/ && \
    rm snappymail-${SNAPPY_VERSION}.tar.gz

# The MailD baseline plugins. They are fetched here (pinned) and copied into the data volume by
# the entrypoint on every boot, so a fresh deployment has them and an image bump refreshes them;
# their *settings* live in the volume and are never touched.
# Bump these together with SNAPPY_VERSION: every package declares the SnappyMail version it needs
# (its REQUIRED const) and the repository only keeps the newer builds (see
# .agents/services/catalog.md -> mua).
ARG PLUGIN_XORIGINATINGIP_VERSION=2.0
ARG PLUGIN_CHANGEPASSWORD_VERSION=2.38
ARG PLUGIN_TWOFACTORAUTH_VERSION=2.19.0
RUN mkdir -p /opt/maild/plugins && cd /opt/maild/plugins && \
    for p in add-x-originating-ip-header-${PLUGIN_XORIGINATINGIP_VERSION} \
             change-password-${PLUGIN_CHANGEPASSWORD_VERSION} \
             two-factor-auth-${PLUGIN_TWOFACTORAUTH_VERSION} ; do \
        wget -q "https://snappymail.eu/repository/v2/plugins/${p}.tgz" && \
        tar xzf "${p}.tgz" && rm -f "${p}.tgz" ; \
    done

# MailD's own change-password driver. It is a sibling package of `change-password` (the extension
# point that plugin globs: plugins/change-password-<name>/driver.php) so that installing or
# updating the plugin from the admin panel cannot overwrite it.
COPY plugins/ /opt/maild/plugins/

RUN chown -R www-data:www-data /opt/maild/plugins

# --- MailD default configuration (new env schema) --------------------------------
# The deployment defaults for this service live HERE now: each image bakes only the
# variables its own entrypoint/scripts consume, as ENV defaults. Any same-named variable
# in the operator's env file (docker compose env_file / environment / docker run -e)
# overrides these at runtime — never rebuild the image to deploy a different value.
# Secrets are NEVER baked: POSTGRES_PASSWORD and MUA_ADMIN_PASSWORD (empty ⇒ generated
# + printed in the logs) must come from the operator env file (dev: env.dev, prod:
# .env — see env.sample). Full variable matrix: .agents/services/configuration.md.
ENV BANNER_TITLE=Webmail \
    MTA=mta \
    MDA=mda \
    POSTGRES_HOST=db \
    POSTGRES_DB=mailddb \
    POSTGRES_USER=maild \
    POSTGRES_EXTRA_DB=contacts \
    MUA_ADMIN_USER=maild \
    MUA_CONFIG_WAIT_TIMEOUT=120 \
    MUA_PLUGINS=add-x-originating-ip-header,change-password,two-factor-auth \
    AUTO_PROVISION=yes \
    PROVISION_VERSION=1 \
    PROVISION_WAIT_TIMEOUT=180

COPY snappymail.ini /usr/local/etc/php/conf.d/snappymail.ini
COPY domain.json /tmp/domain.json

COPY docker-entrypoint.sh check.sh config-setup.php /
RUN chmod +x /*.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

HEALTHCHECK --interval=1m --timeout=3s --start-period=30s --retries=2 \
    CMD curl -f http://localhost/ || exit 1

# CMD ["apache2-foreground"]


# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD Webmail (SnappyMail)" \
      org.opencontainers.image.description="MailD webmail client (SnappyMail), CI build with upstream download" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-16"
