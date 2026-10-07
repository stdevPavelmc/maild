FROM php:8.3-apache

# if updated you must review domain.json against the new version !!!
ARG SNAPPY_VERSION=2.38.2

# install base tools
RUN apt-get update && \
    apt-get install -y \
        postgresql-client \
        curl \
        wget \
        crudini \
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

COPY snappymail.ini /usr/local/etc/php/conf.d/snappymail.ini
COPY domain.json /tmp/domain.json

COPY docker-entrypoint.sh check.sh /
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
      org.opencontainers.image.created="2026-10-04"
