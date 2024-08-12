FROM php:8.3-apache

LABEL original_maintainer="David Goodwin <david@codepoets.co.uk> (@DavidGoodwin) PorfixAdmin project"
LABEL image.app="MailD, http://github.com/stdevPavelmc/maild"
LABEL image.name="MailD Mail Administrator UI, aka: Web Administration"
LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"
LABEL last_modified="2024-08-11"

#repodebian

# docker-entrypoint.sh dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    gosu \
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

ENV POSTFIXADMIN_VERSION=$POSTFIXADMIN_VERSION
ENV POSTFIXADMIN_SHA512=$POSTFIXADMIN_SHA512
ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

RUN set -eu; sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf; \
    sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

RUN mkdir -p /usr/src/postfixadmin

COPY postfixadmin-${POSTFIXADMIN_VERSION}.tar.gz /usr/src/postfixadmin/postfixadmin.tar.gz

RUN set -eu; \
    cd /usr/src/postfixadmin; \
    echo "$POSTFIXADMIN_SHA512 *postfixadmin.tar.gz" | sha512sum -c -; \
    tar -xf postfixadmin.tar.gz -C /usr/src/postfixadmin --strip-components=1; \
    rm postfixadmin.tar.gz; \
    # Does not exist in tarball but is required
    mkdir -p /usr/src/postfixadmin/templates_c; \
    chown -R www-data:www-data /usr/src/postfixadmin

COPY docker-entrypoint.sh /
RUN chmod +x /docker-entrypoint.sh

# DEBUG tools only on debug build
ARG DEBUG
RUN if [ "$DEBUG" ]; then \
    apt-get update && apt-get install -y nano ; \
    fi

HEALTHCHECK --interval=1m --timeout=3s --start-period=30s --retries=2 \
    CMD curl -f http://localhost/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["apache2-foreground"]
