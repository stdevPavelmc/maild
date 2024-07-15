FROM php:8.3-apache

LABEL maintainer="Pavel Milanes <pavelmc@gmail.com>"

#repodebian

# old 2.27.3 (You must update the domain.json template!!!)
#ARG SNAPPY_VERSION=2.35.3
ARG SNAPPY_VERSION=2.36.4

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

COPY snappymail.ini /usr/local/etc/php/conf.d/snappymail.ini
COPY domain.json /tmp/domain.json

COPY docker-entrypoint.sh check.sh /
RUN chmod +x /*.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

HEALTHCHECK --interval=1m --timeout=3s --start-period=30s --retries=2 \
    CMD curl -f http://localhost/ || exit 1

# CMD ["apache2-foreground"]

