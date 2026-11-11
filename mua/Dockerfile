# MailD mua — Roundcube webmail on Debian (replaced SnappyMail in 2.0.0-rc3).
#
# Debian 13 "trixie" + Debian's own PHP 8.4 (apache2 + mod_php, prefork). PHP comes from the
# Debian archive on purpose: the Debian Security Team backports PHP CVE fixes into trixie's
# 8.4 for the whole life of the release, and `apt-get upgrade` below pulls every security update
# published up to the build (the slim base tag lags the security archive by days).
FROM debian:trixie-slim

# Roundcube release. Bump procedure (mua/README.md → "Updating Roundcube"):
#   1. read the release notes (every 1.7.x so far is a security release);
#   2. download roundcubemail-<ver>-complete.tar.gz + .asc from GitHub and check the signature:
#        gpg --recv-keys F3E4C04BB3DB5D4215C45F7F5AB2BAA141C4F7D5   (Roundcube Developers)
#        gpg --verify roundcubemail-<ver>-complete.tar.gz.asc roundcubemail-<ver>-complete.tar.gz
#   3. put the tarball's sha256 below. The build refuses any other file.
# 1.7.6 (2026-11-09): 17 security fixes (Sieve script injection, IMAP CRLF command injection,
# CSRF bypasses, SSRF filter bypasses, ImageMagick input, session unserialize DoS, …).
ARG ROUNDCUBE_VERSION=1.7.6
ARG ROUNDCUBE_SHA256=0168085bf0bfeeb5d4eca3b9730effbe610dbdb380a68567d292fec51f09db36

# 1. dependencies. Deliberately NOT installed (attack surface the release notes keep fixing):
#    ImageMagick and php-gd (thumbnail/conversion input bugs; previews are served unresized),
#    php-ldap (no LDAP here), gnupg (enigma is off), aspell (spell checking is off).
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get install -y --no-install-recommends \
        apache2 \
        libapache2-mod-php8.4 \
        php8.4-cli \
        php8.4-curl \
        php8.4-intl \
        php8.4-mbstring \
        php8.4-pgsql \
        php8.4-xml \
        php8.4-zip \
        postgresql-client \
        ca-certificates \
        curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Roundcube, verified against the pinned hash, then trimmed: no web installer, no
#    installer entry point, no bundled samples that are not used.
RUN set -eu; \
    cd /tmp; \
    curl -fsSL -o rc.tar.gz \
      "https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"; \
    echo "${ROUNDCUBE_SHA256}  rc.tar.gz" | sha256sum -c -; \
    mkdir -p /var/www/roundcube; \
    tar xzf rc.tar.gz --strip-components=1 -C /var/www/roundcube; \
    rm -f rc.tar.gz; \
    cd /var/www/roundcube; \
    rm -rf installer public_html/installer.php config/config.inc.php.sample \
           plugins/example_addressbook plugins/squirrelmail_usercopy plugins/enigma \
           plugins/autologon plugins/debug_logger logs temp; \
    rm -f /var/www/html/index.html

# Apache: mod_php needs prefork; only what Roundcube needs is enabled, the rest is off
RUN a2dismod -f autoindex status negotiation cgi 2>/dev/null || true; \
    a2enmod headers rewrite expires deflate; \
    a2dissite 000-default; \
    a2disconf other-vhosts-access-log serve-cgi-bin security 2>/dev/null || true; \
    rm -rf /var/www/html

# 3. MailD code: Apache vhost, PHP settings, Roundcube config, the directory plugin
COPY apache/roundcube.conf /etc/apache2/sites-available/roundcube.conf
COPY apache/security.conf /etc/apache2/conf-available/maild-security.conf
COPY php/maild.ini /etc/php/8.4/apache2/conf.d/90-maild.ini
COPY php/maild.ini /etc/php/8.4/cli/conf.d/90-maild.ini
COPY config/config.inc.php /var/www/roundcube/config/config.inc.php
COPY plugins/ /var/www/roundcube/plugins/
COPY render-config.php docker-entrypoint.sh check.sh /usr/local/lib/maild/

# 4. owners and permissions: the application tree is root-owned and read-only for the web
#    server (www-data cannot rewrite any PHP file it executes); writable state lives in
#    /var/lib/roundcube (root only: the generated des_key, volume), the generated config in
#    /run/maild-roundcube (root:www-data 0640) and uploads in /tmp/roundcube.
RUN a2ensite roundcube && a2enconf maild-security && \
    chown -R root:root /var/www/roundcube && \
    find /var/www/roundcube -type d -exec chmod 0755 {} + && \
    find /var/www/roundcube -type f -exec chmod 0644 {} + && \
    chmod 0755 /var/www/roundcube/bin/*.sh /usr/local/lib/maild/*.sh && \
    mkdir -p /var/lib/roundcube && chmod 0700 /var/lib/roundcube

# --- MailD default configuration (env schema) ---------------------------------------------
# Every tunable defaults HERE; a same-named variable in the operator env file wins at runtime.
# Secrets are never baked: ROUNDCUBE_DB_PASSWORD (the restricted role, see db/ensure_roles.sh)
# must come from the operator env file. ROUNDCUBE_DES_KEY is optional (empty = generated once
# and kept in /var/lib/roundcube). Full matrix: .agents/services/configuration.md.
ENV BANNER_TITLE=Webmail \
    MTA=mta \
    MDA=mda \
    POSTGRES_HOST=db \
    POSTGRES_DB=mailddb \
    PASSWORD_SCHEME=argon2id \
    MCP_SERVICE_EMAIL= \
    AUTO_PROVISION=yes \
    PROVISION_VERSION=1 \
    PROVISION_WAIT_TIMEOUT=180 \
    ROUNDCUBE_DB=roundcube \
    ROUNDCUBE_DB_USER=maild_roundcube \
    ROUNDCUBE_DES_KEY= \
    ROUNDCUBE_PRODUCT_NAME= \
    ROUNDCUBE_LANGUAGE=en_US \
    ROUNDCUBE_SESSION_LIFETIME=30 \
    ROUNDCUBE_TRUSTED_HOSTS= \
    ROUNDCUBE_TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 \
    ROUNDCUBE_DIRECTORY_SCOPE=domain \
    ROUNDCUBE_DIRECTORY_ALIASES=yes \
    ROUNDCUBE_DIRECTORY_HIDE= \
    ROUNDCUBE_AUTOCOMPLETE_MIN=3 \
    ROUNDCUBE_PASSWORD_MIN_LENGTH=8 \
    ROUNDCUBE_UPLOAD_MAX=24M \
    MAX_MESSAGESIZE=34865152 \
    ROUNDCUBE_DEBUG=

# compose passes an explicit allow-list (no env_file): a bare key the operator file does not set
# reaches the container UNSET, which also drops the default above. Snapshot the defaults so the
# entrypoint can restore every unset one (same pattern as cron) — the image stays their source.
RUN env | grep -E '^(BANNER_TITLE|MTA|MDA|POSTGRES_HOST|POSTGRES_DB|PASSWORD_SCHEME|AUTO_PROVISION|PROVISION_[A-Z_]+|ROUNDCUBE_[A-Z_]+|MAX_MESSAGESIZE)=' \
        | grep -v '^ROUNDCUBE_DB_PASSWORD=' > /etc/maild-image.env

VOLUME ["/var/lib/roundcube"]
EXPOSE 80

ENTRYPOINT ["/usr/local/lib/maild/docker-entrypoint.sh"]
# "apache" = the webmail; any other command runs instead (debugging), with no configuration step
CMD ["apache"]

HEALTHCHECK --interval=1m --timeout=5s --start-period=60s --retries=2 \
    CMD /usr/local/lib/maild/check.sh

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD Webmail (Roundcube)" \
      org.opencontainers.image.description="MailD webmail client (Roundcube on Debian trixie + PHP 8.4): catalogue directory, password change per PASSWORD_SCHEME, Sieve filters" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-11-11"
