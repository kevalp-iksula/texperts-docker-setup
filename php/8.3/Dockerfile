# syntax=docker/dockerfile:1
################################################################################
# PHP 8.3 FPM for Adobe Commerce 2.4.7 (the upgrade BASELINE runtime)
#
# 2.4.7 supports PHP 8.1-8.3; 8.3 is the newest it allows and matches the
# project's Cloud .magento.app.yaml (type: php:8.3). Extension set is identical
# to the 8.5 image so the same code runs on either profile.
# Build context is ./php (not ./php/8.3) so shared files can be copied in.
################################################################################
FROM php:8.3-fpm-bookworm

ARG UID=1000
ARG GID=1000

# The extension installer resolves each extension's system deps for us, which
# is far less brittle than hand-maintaining an apt list per PHP release.
COPY --from=mlocati/php-extension-installer:latest /usr/bin/install-php-extensions /usr/local/bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        unzip \
        curl \
        default-mysql-client \
        procps \
        vim-tiny \
        cron \
        rsync \
    && rm -rf /var/lib/apt/lists/*

# Extensions required by Adobe Commerce 2.4.7 (same set as 2.4.9), plus opcache
# and xdebug. xsl + sodium are also called out in the project's .magento.app.yaml.
# newrelic (also in app.yaml) is Cloud APM only and is intentionally omitted.
# Xdebug is installed but NOT enabled — the entrypoint switches it on only when
# XDEBUG_ENABLED=1, so the default path carries no debugger overhead.
RUN install-php-extensions \
        bcmath \
        exif \
        ftp \
        gd \
        intl \
        opcache \
        pdo_mysql \
        soap \
        sockets \
        sodium \
        sysvmsg \
        sysvsem \
        sysvshm \
        xsl \
        zip \
        redis \
        xdebug

# Composer 2.x
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Align the container's www-data with the host user so files written by
# Composer/Magento inside the container stay editable on the host.
RUN if [ "$(id -u www-data)" != "${UID}" ]; then \
        groupmod -o -g "${GID}" www-data && \
        usermod  -o -u "${UID}" -g "${GID}" www-data; \
    fi && \
    mkdir -p /var/www/magento /var/www/.composer/cache && \
    chown -R www-data:www-data /var/www

COPY 8.3/php.ini /usr/local/etc/php/conf.d/zz-magento.ini
COPY www.conf /usr/local/etc/php-fpm.d/zz-www.conf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/magento

# The FPM master stays root (it needs that to spawn workers as www-data, per
# www.conf) while every worker that touches your code drops to www-data.
# Run one-off commands as the right user: docker compose exec -u www-data php ...

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
