#!/bin/sh
################################################################################
# PHP container entrypoint
# Toggles Xdebug per-run, then hands off to the real command (php-fpm).
################################################################################
set -eu

XDEBUG_INI="/usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini"
XDEBUG_OFF="/usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini.disabled"

# Xdebug ships installed but inert. Enabling it costs ~2-3x on every request,
# so it stays off unless XDEBUG_ENABLED=1 is set in .env.
if [ "${XDEBUG_ENABLED:-0}" = "1" ]; then
    if [ -f "$XDEBUG_OFF" ]; then
        mv "$XDEBUG_OFF" "$XDEBUG_INI"
    fi
    cat > "$XDEBUG_INI" <<EOF
zend_extension=xdebug
xdebug.mode=${XDEBUG_MODE:-debug}
xdebug.start_with_request=trigger
xdebug.client_host=${XDEBUG_CLIENT_HOST:-host.docker.internal}
xdebug.client_port=${XDEBUG_CLIENT_PORT:-9003}
xdebug.discover_client_host=0
xdebug.idekey=PHPSTORM
xdebug.max_nesting_level=800
xdebug.log_level=0
EOF
    echo "[entrypoint] Xdebug ENABLED (mode=${XDEBUG_MODE:-debug}, client=${XDEBUG_CLIENT_HOST:-host.docker.internal}:${XDEBUG_CLIENT_PORT:-9003})"
else
    if [ -f "$XDEBUG_INI" ]; then
        mv "$XDEBUG_INI" "$XDEBUG_OFF"
    fi
    echo "[entrypoint] Xdebug disabled (set XDEBUG_ENABLED=1 in .env to turn on)"
fi

# Warn rather than fail: the stack must still boot before Magento exists, so
# Phase 3 has somewhere to install into.
if [ ! -f /var/www/magento/composer.json ]; then
    echo "[entrypoint] NOTE: no composer.json at /var/www/magento — Magento is not installed yet."
    echo "[entrypoint]       That is expected until Phase 3. See docs/PHASE_3_PLAN.md."
fi

if [ ! -s /var/www/.composer/auth.json ]; then
    echo "[entrypoint] NOTE: Composer auth.json is empty or missing."
    echo "[entrypoint]       Run ./scripts/composer-auth.sh before installing Magento."
fi

exec "$@"
